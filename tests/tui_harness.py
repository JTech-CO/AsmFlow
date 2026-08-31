"""Shared subprocess, PTY, and golden helpers for the M10 console tests."""
from __future__ import annotations

import errno
import os
import re
import select
import signal
import shlex
import struct
import subprocess
import time
import unicodedata
import unittest
from pathlib import Path
from typing import Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures" / "tui"


def build_dir() -> Path:
    value = Path(os.environ.get("BUILD_DIR", "build"))
    return value if value.is_absolute() else ROOT / value


def binary_path(name: str) -> Path:
    return build_dir() / "debug" / name


def require_binary(name: str) -> Path:
    if os.name != "posix":
        raise unittest.SkipTest("AsmFlow M10 binaries and PTY tests require Linux/POSIX")
    path = binary_path(name)
    if not path.is_file():
        raise unittest.SkipTest(f"{path} is not built; run `make build-debug` first")
    if not os.access(path, os.X_OK):
        raise AssertionError(f"test artifact is not executable: {path}")
    return path


def controlled_env(overrides: Mapping[str, str] | None = None) -> dict[str, str]:
    """Return a deterministic, intentionally small console environment."""
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", "/tmp"),
        "TERM": "xterm-256color",
        "LC_ALL": "C.UTF-8",
        "LANG": "C.UTF-8",
        "TZ": "UTC",
    }
    if overrides:
        env.update(overrides)
    return env


def canonical_layout(raw: bytes | str) -> str:
    if isinstance(raw, bytes):
        text = raw.decode("utf-8")
    else:
        text = raw
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    # The interactive top bar owns a real UTC clock. Layout goldens exercise
    # geometry rather than a particular wall-clock second, so canonical dumps
    # replace just that documented display shape and leave all other numbers
    # (revision, counts, latency) exact.
    text = re.sub(r"\b\d{2}:\d{2}:\d{2} UTC\b", "<TIME UTC>", text)
    lines = [line.rstrip(" ") for line in text.split("\n")]
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines) + ("\n" if lines else "")


def display_width(text: str) -> int:
    width = 0
    for char in text:
        if char == "\t":
            width += 8 - (width % 8)
            continue
        category = unicodedata.category(char)
        if category in ("Mn", "Me", "Cf"):
            continue
        if category.startswith("C"):
            raise AssertionError(f"control character U+{ord(char):04X} in layout")
        width += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return width


def assert_layout_bounds(text: str, width: int, height: int) -> None:
    lines = text.splitlines()
    if len(lines) > height:
        raise AssertionError(f"layout has {len(lines)} rows in a {height}-row terminal")
    for number, line in enumerate(lines, 1):
        measured = display_width(line)
        if measured > width:
            raise AssertionError(
                f"layout row {number} is {measured} columns in a {width}-column "
                f"terminal: {line!r}"
            )


def run_layout_dump(
    binary: Path,
    socket_path: str,
    *,
    screen: str,
    width: int,
    height: int,
    extra_args: Sequence[str] = (),
    env: Mapping[str, str] | None = None,
    timeout: float = 10.0,
) -> subprocess.CompletedProcess[bytes]:
    runner = shlex.split(os.environ.get("ASMFLOW_TUI_RUNNER", ""))
    command = [
        *runner,
        str(binary),
        "--socket",
        socket_path,
        *extra_args,
        "--dump-layout",
        f"{width}x{height}",
        "--screen",
        screen,
    ]
    return subprocess.run(
        command,
        cwd=ROOT,
        env=controlled_env(env),
        input=b"",
        capture_output=True,
        timeout=timeout,
        check=False,
    )


class PtySession:
    """One console process attached to a size-controlled pseudo-terminal."""

    def __init__(
        self,
        argv: Sequence[str | os.PathLike[str]],
        *,
        width: int = 100,
        height: int = 30,
        env: Mapping[str, str] | None = None,
    ) -> None:
        if os.name != "posix":
            raise unittest.SkipTest("M10 PTY tests require a POSIX host")
        self.argv = [str(value) for value in argv]
        self.width = width
        self.height = height
        self.env = controlled_env(env)
        self.master_fd = -1
        self.slave_fd = -1
        self.process: subprocess.Popen[bytes] | None = None
        self.output = bytearray()
        self.termios_before: list[object] | None = None

    def __enter__(self) -> "PtySession":
        import termios

        self.master_fd, self.slave_fd = os.openpty()
        self._set_winsize(self.width, self.height)
        self.termios_before = termios.tcgetattr(self.slave_fd)
        self.process = subprocess.Popen(
            self.argv,
            cwd=ROOT,
            env=self.env,
            stdin=self.slave_fd,
            stdout=self.slave_fd,
            stderr=self.slave_fd,
            close_fds=True,
            start_new_session=True,
        )
        os.set_blocking(self.master_fd, False)
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    @property
    def pid(self) -> int:
        assert self.process is not None
        return self.process.pid

    def send(self, data: bytes | str) -> None:
        if isinstance(data, str):
            data = data.encode("utf-8")
        offset = 0
        deadline = time.monotonic() + 5.0
        while offset < len(data):
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out writing keys {data!r} to PTY")
            try:
                offset += os.write(self.master_fd, data[offset:])
            except BlockingIOError:
                select.select([], [self.master_fd], [], 0.05)

    def resize(self, width: int, height: int) -> None:
        self.width, self.height = width, height
        self._set_winsize(width, height)
        os.killpg(self.pid, signal.SIGWINCH)

    def signal(self, sig: int) -> None:
        os.killpg(self.pid, sig)

    def read_available(self, timeout: float = 0.0) -> bytes:
        deadline = time.monotonic() + timeout
        chunks = bytearray()
        while True:
            wait = max(0.0, deadline - time.monotonic()) if timeout else 0.0
            ready, _, _ = select.select([self.master_fd], [], [], wait)
            if not ready:
                break
            try:
                chunk = os.read(self.master_fd, 65536)
            except BlockingIOError:
                continue
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            chunks.extend(chunk)
            self.output.extend(chunk)
            if timeout and time.monotonic() >= deadline:
                break
        return bytes(chunks)

    def wait_for_output(self, needle: bytes | str, timeout: float = 5.0) -> bytes:
        if isinstance(needle, str):
            needle = needle.encode("utf-8")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if needle in self.output:
                return bytes(self.output)
            self.read_available(min(0.1, deadline - time.monotonic()))
            if self.process is not None and self.process.poll() is not None:
                self.read_available()
                break
        raise AssertionError(
            f"PTY output never contained {needle!r}; output={bytes(self.output)!r}"
        )

    def wait(self, timeout: float = 10.0) -> int:
        assert self.process is not None
        try:
            code = self.process.wait(timeout=timeout)
        finally:
            self.read_available(0.1)
        return code

    def termios_after(self) -> list[object]:
        import termios

        return termios.tcgetattr(self.slave_fd)

    def assert_terminal_restored(self) -> None:
        import termios

        assert self.termios_before is not None
        after = self.termios_after()
        if after != self.termios_before:
            before_flags = int(self.termios_before[3])
            after_flags = int(after[3])
            names = (
                ("ECHO", termios.ECHO),
                ("ICANON", termios.ICANON),
                ("ISIG", termios.ISIG),
            )
            changed = [
                name
                for name, flag in names
                if bool(before_flags & flag) != bool(after_flags & flag)
            ]
            raise AssertionError(
                "terminal attributes were not restored"
                + (f" ({', '.join(changed)})" if changed else "")
                + f":\n  before={self.termios_before!r}\n  after ={after!r}"
            )

    def close(self) -> None:
        if self.process is not None and self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
                self.process.wait(timeout=2.0)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.process.wait(timeout=2.0)
        if self.master_fd >= 0:
            try:
                os.close(self.master_fd)
            except OSError:
                pass
            self.master_fd = -1
        if self.slave_fd >= 0:
            try:
                os.close(self.slave_fd)
            except OSError:
                pass
            self.slave_fd = -1

    def _set_winsize(self, width: int, height: int) -> None:
        import fcntl
        import termios

        fcntl.ioctl(
            self.slave_fd,
            termios.TIOCSWINSZ,
            struct.pack("HHHH", height, width, 0, 0),
        )


_PADDING = re.compile(rb"\$<[^>]+>")


def _terminfo_bytes(name: str, term: str = "xterm-256color") -> bytes:
    import curses

    curses.setupterm(term=term)
    value = curses.tigetstr(name) or b""
    return _PADDING.sub(b"", value)


def assert_cursor_and_screen_restored(
    output: bytes, term: str = "xterm-256color"
) -> None:
    """Check terminal output state that termios itself cannot represent."""
    civis = _terminfo_bytes("civis", term)
    visible = tuple(
        value
        for value in (_terminfo_bytes("cnorm", term), _terminfo_bytes("cvvis", term))
        if value
    )
    if civis and civis in output:
        hidden_at = output.rfind(civis)
        shown_at = max((output.rfind(value) for value in visible), default=-1)
        if shown_at <= hidden_at:
            raise AssertionError("cursor was hidden but no later normal/visible state was emitted")
    smcup = _terminfo_bytes("smcup", term)
    rmcup = _terminfo_bytes("rmcup", term)
    if smcup and smcup in output and (not rmcup or output.rfind(rmcup) < output.rfind(smcup)):
        raise AssertionError("alternate screen was entered but not left")


_SGR = re.compile(rb"\x1b\[([0-9;]*)m")


def color_sgr_sequences(output: bytes) -> list[bytes]:
    """Return SGR sequences that select a foreground/background colour."""
    found: list[bytes] = []
    for match in _SGR.finditer(output):
        params = [int(value or "0") for value in match.group(1).split(b";")]
        colored = any(
            30 <= value <= 38
            or 40 <= value <= 48
            or 90 <= value <= 97
            or 100 <= value <= 107
            for value in params
        )
        # 39 and 49 only restore defaults and are allowed.
        if colored and not all(value in (0, 39, 49) for value in params):
            found.append(match.group(0))
    return found
