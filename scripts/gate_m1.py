#!/usr/bin/env python3
"""M1 gate: toolchain and build foundation.

Checks the Definition of Done in HARNESS.md 1 / M1:

  1. asmflowd --version and asmflow-tui --version match VERSION
  2. both binaries exit 0 after --help and leave terminal modes untouched
  3. the debug build carries DWARF; the release build follows the strip policy
  4. zero linker warnings, zero executable stack, zero text relocations
  5. CI and local builds run the same command (asserted by inspecting ci.yml)
  6. build artifacts are not tracked by git

Standard library only, so a clean checkout can run it without installing
anything beyond the toolchain itself.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

BINARIES = ("asmflowd", "asmflow-tui")


class GateError(RuntimeError):
    pass


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60, **kwargs)


def need_tool(name: str) -> None:
    if (
        subprocess.run(
            ["sh", "-c", f"command -v {name}"], capture_output=True
        ).returncode
        != 0
    ):
        raise GateError(f"required tool not found on PATH: {name}")


# --- DoD 1 and 2 -----------------------------------------------------------


def check_version_and_help(build_dir: Path, version: str) -> None:
    for mode in ("debug", "release"):
        for name in BINARIES:
            path = build_dir / mode / name
            if not path.is_file():
                raise GateError(f"missing build artifact: {path}")
            if not os.access(path, os.X_OK):
                raise GateError(f"build artifact is not executable: {path}")

            result = run([str(path), "--version"])
            if result.returncode != 0:
                raise GateError(
                    f"{path} --version exited {result.returncode}: {result.stderr.strip()}"
                )
            line = result.stdout.strip()
            expected_prefix = f"{name} {version} ("
            if not line.startswith(expected_prefix):
                raise GateError(
                    f"{path} --version printed {line!r}; expected it to start with "
                    f"{expected_prefix!r} so VERSION and the binary cannot drift"
                )
            if mode not in line:
                raise GateError(
                    f"{path} --version does not report its build mode: {line!r}"
                )

            for flag in ("--help", "-h"):
                result = run([str(path), flag])
                if result.returncode != 0:
                    raise GateError(f"{path} {flag} exited {result.returncode}")
                if not result.stdout.strip():
                    raise GateError(f"{path} {flag} produced no output")

            # An unknown option must be a usage error, not a silent success.
            result = run([str(path), "--definitely-not-an-option"])
            if result.returncode != 2:
                raise GateError(
                    f"{path} accepted an unknown option (exit {result.returncode}); "
                    "expected exit 2"
                )


def check_terminal_mode_preserved(build_dir: Path) -> None:
    """DoD 2: --help must not change terminal modes.

    Both binaries are run on a pseudo-terminal and the full termios state of the
    slave side is compared before and after. This is the check that keeps the
    console binary honest once ncursesw is linked into it.
    """
    import pty
    import termios

    for mode in ("debug", "release"):
        for name in BINARIES:
            path = build_dir / mode / name
            master, slave = pty.openpty()
            try:
                before = termios.tcgetattr(slave)
                result = subprocess.run(
                    [str(path), "--help"],
                    stdin=slave,
                    stdout=slave,
                    stderr=slave,
                    timeout=30,
                )
                after = termios.tcgetattr(slave)
                if result.returncode != 0:
                    raise GateError(f"{path} --help on a pty exited {result.returncode}")
                if before != after:
                    raise GateError(
                        f"{path} --help changed terminal modes:\n"
                        f"  before={before}\n  after ={after}"
                    )
            finally:
                os.close(master)
                os.close(slave)


# --- DoD 3 -----------------------------------------------------------------


def check_symbols(build_dir: Path) -> None:
    for name in BINARIES:
        debug = build_dir / "debug" / name
        out = run(["readelf", "-WS", str(debug)]).stdout
        if ".debug_info" not in out:
            raise GateError(f"debug build has no DWARF .debug_info: {debug}")

        release = build_dir / "release" / name
        out = run(["readelf", "-WS", str(release)]).stdout
        if ".debug_info" in out:
            raise GateError(
                f"release build still carries DWARF; strip policy not applied: {release}"
            )
        if ".symtab" in out:
            raise GateError(f"release build still carries a symbol table: {release}")
        if not (build_dir / "release" / f"{name}.debug").is_file():
            raise GateError(
                f"release build did not produce separate debug symbols: {name}.debug"
            )
        if ".gnu_debuglink" not in out:
            raise GateError(
                f"release build is missing .gnu_debuglink back to {name}.debug"
            )


# --- DoD 4 -----------------------------------------------------------------


def check_link_security(build_dir: Path) -> None:
    for mode in ("debug", "release"):
        for name in BINARIES:
            path = build_dir / mode / name

            segments = run(["readelf", "-Wl", str(path)]).stdout
            stack = [ln for ln in segments.splitlines() if "GNU_STACK" in ln]
            if not stack:
                raise GateError(f"{path} has no GNU_STACK segment")
            # The flags column is the trailing "RW  0x10" style field.
            if re.search(r"\bRWE\b|\bE\b", stack[0].split("0x")[-1]):
                raise GateError(f"{path} has an executable stack: {stack[0].strip()}")
            if "GNU_RELRO" not in segments:
                raise GateError(f"{path} was linked without RELRO")

            dynamic = run(["readelf", "-Wd", str(path)]).stdout
            if "TEXTREL" in dynamic:
                raise GateError(f"{path} contains text relocations")
            if "BIND_NOW" not in dynamic and "(FLAGS)" not in dynamic:
                raise GateError(f"{path} was not linked with -z now")

            header = run(["readelf", "-Wh", str(path)]).stdout
            if "DYN (" not in header:
                raise GateError(f"{path} is not a position-independent executable")


def check_no_linker_warnings(build_dir: Path) -> None:
    """DoD 4: rebuild from scratch and assert the toolchain emitted nothing.

    `-Wl,--fatal-warnings` in the Makefile already turns a linker warning into a
    failed build; this re-runs the build to confirm it is genuinely warning-free
    rather than merely cached.
    """
    # GNU make expands BUILD_DIR inside pattern-rule target names.  Passing an
    # absolute repository path that contains whitespace therefore splits one
    # target into several words even though subprocess correctly preserves the
    # command-line argument.  Keep an in-repository build directory relative to
    # ROOT; the same artifacts are selected without injecting ROOT's spelling
    # into make syntax.
    try:
        make_build_dir = build_dir.relative_to(ROOT)
    except ValueError:
        make_build_dir = build_dir
    result = subprocess.run(
        ["make", "--no-print-directory", "build", f"BUILD_DIR={make_build_dir}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=900,
    )
    if result.returncode != 0:
        raise GateError(f"rebuild failed:\n{result.stdout}\n{result.stderr}")
    noise = [
        line
        for line in (result.stderr or "").splitlines()
        if "warning" in line.lower() or "error" in line.lower()
    ]
    if noise:
        raise GateError("toolchain emitted warnings:\n  " + "\n  ".join(noise))


# --- DoD 5 and 6 -----------------------------------------------------------


def check_ci_uses_make(_: Path) -> None:
    ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    for target in ("make check", "make gate-m1"):
        if target not in ci:
            raise GateError(f"CI does not run {target!r}; local and CI builds would drift")


def check_artifacts_untracked(build_dir: Path) -> None:
    ignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
    for pattern in ("build/", "dist/", "*.o"):
        if pattern not in ignore:
            raise GateError(f".gitignore does not exclude {pattern!r}")

    inside_repo = build_dir.resolve().is_relative_to(ROOT)
    if inside_repo and (ROOT / ".git").exists():
        tracked = run(
            ["git", "ls-files", "--error-unmatch", str(build_dir.name)], cwd=ROOT
        )
        if tracked.returncode == 0:
            raise GateError(f"{build_dir} is tracked by git")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", default="build")
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    build_dir = (ROOT / args.build_dir).resolve()

    checks = [
        ("toolchain present", lambda: [need_tool(t) for t in ("nasm", "gcc", "readelf", "objcopy")]),
        ("version and help", lambda: check_version_and_help(build_dir, args.version)),
        ("terminal modes preserved", lambda: check_terminal_mode_preserved(build_dir)),
        ("symbol policy", lambda: check_symbols(build_dir)),
        ("link security", lambda: check_link_security(build_dir)),
        ("no toolchain warnings", lambda: check_no_linker_warnings(build_dir)),
        ("CI parity", lambda: check_ci_uses_make(build_dir)),
        ("artifacts untracked", lambda: check_artifacts_untracked(build_dir)),
    ]

    try:
        for label, check in checks:
            check()
            print(f"[ok] {label}")
    except GateError as exc:
        print(f"[fail] {exc}", file=sys.stderr)
        return 1
    print(f"M1 gate passed for AsmFlow {args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
