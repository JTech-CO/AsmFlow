#!/usr/bin/env python3
"""M5 gate: the gateway HTTP listener and its contract (HARNESS.md M5).

The behavioural work is done by the five suites under `tests/`, which drive a
real daemon over TCP. What is left for this script is the set of properties that
are true of the build rather than of a request: which libraries each binary
links, that the leniency surface is fully covered, and that the C shim is still
an adapter rather than a place where policy has quietly accumulated.

The last two are the ones worth having. "Leniency is disabled" is only a real
statement if every switch llhttp offers is accounted for, and a shim that starts
making decisions is how the assembly-first invariant erodes without anyone
noticing.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

FAILED = False


def fail(message: str) -> None:
    global FAILED
    FAILED = True
    print(f"[fail] {message}", file=sys.stderr)


def ok(label: str) -> None:
    print(f"[ok] {label}")


def run(command: list, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(
        command, cwd=ROOT, capture_output=True, text=True, check=False, **kwargs
    )


def dynamic_libraries(binary: Path) -> set:
    result = run(["readelf", "-W", "-d", str(binary)])
    if result.returncode != 0:
        fail(f"readelf failed on {binary}: {result.stderr.strip()}")
        return set()
    return set(re.findall(r"Shared library: \[([^\]]+)\]", result.stdout))


def check_linkage(build_dir: Path) -> None:
    """The console must not link the HTTP parser, and the daemon must."""
    daemon = build_dir / "debug" / "asmflowd"
    console = build_dir / "debug" / "asmflow-tui"
    for binary in (daemon, console):
        if not binary.exists():
            fail(f"{binary} is missing; run `make build-debug` first")
            return

    daemon_libs = dynamic_libraries(daemon)
    if not any(name.startswith("libllhttp") for name in daemon_libs):
        fail(f"asmflowd does not link llhttp: {sorted(daemon_libs)}")

    console_libs = dynamic_libraries(console)
    for forbidden in ("libllhttp", "libsqlite3", "libcurl"):
        if any(name.startswith(forbidden) for name in console_libs):
            fail(f"asmflow-tui links {forbidden}, which is daemon-only")
    ok("library boundaries")


def defined_symbols(binary: Path) -> set:
    result = run(["nm", "--defined-only", str(binary)])
    if result.returncode != 0:
        return set()
    return {line.split()[-1] for line in result.stdout.splitlines() if line.strip()}


def check_symbol_boundary(build_dir: Path) -> None:
    """No part of the data plane is linked into the console."""
    console = build_dir / "debug" / "asmflow-tui"
    if not console.exists():
        fail("asmflow-tui is missing")
        return
    leaked = sorted(
        name
        for name in defined_symbols(console)
        if name.startswith("af_http_") or name.startswith("af_llhttp_")
    )
    if leaked:
        fail(f"asmflow-tui contains data-plane code: {leaked[:6]}")
    ok("the console carries no data-plane code")


def llhttp_header() -> Path | None:
    for candidate in (
        Path("/usr/include/llhttp.h"),
        Path("/usr/local/include/llhttp.h"),
    ):
        if candidate.exists():
            return candidate
    result = run(["pkg-config", "--cflags-only-I", "libllhttp"])
    if result.returncode == 0:
        for token in result.stdout.split():
            candidate = Path(token[2:]) / "llhttp.h"
            if candidate.exists():
                return candidate
    return None


def check_leniency_coverage() -> None:
    """Every leniency switch llhttp offers is explicitly turned off.

    Leaving a switch at its default would make "leniency is disabled" a claim
    about a library version rather than about AsmFlow, and a new switch in a
    future release would silently arrive enabled-by-default one day.
    """
    header = llhttp_header()
    if header is None:
        fail("llhttp.h was not found; the leniency surface cannot be checked")
        return
    declared = set(
        re.findall(r"\bvoid (llhttp_set_lenient_[a-z0-9_]+)\(", header.read_text())
    )
    if not declared:
        fail(f"no leniency setters were found in {header}")
        return
    shim = (ROOT / "src/ffi/llhttp_shim.c").read_text(encoding="utf-8")
    missing = sorted(name for name in declared if f"{name}(parser, 0)" not in shim)
    if missing:
        fail(
            f"{len(missing)} leniency switch(es) are not explicitly disabled: "
            f"{missing}"
        )
    enabled = re.findall(r"llhttp_set_lenient_[a-z0-9_]+\(parser, ([^)]+)\)", shim)
    for value in enabled:
        if value.strip() != "0":
            fail(f"a leniency switch is set to {value.strip()} rather than 0")
    ok(f"every leniency switch ({len(declared)}) is explicitly off")


def check_shim_is_an_adapter() -> None:
    """AGENTS.md invariant 2: the C boundary decides nothing.

    A shim is allowed to forward and to report. It is not allowed to allocate,
    to compare, or to apply a limit — those are the things that would make the
    security-relevant behaviour live in C rather than in the assembly above it.
    """
    shim = (ROOT / "src/ffi/llhttp_shim.c").read_text(encoding="utf-8")
    code = re.sub(r"/\*.*?\*/", "", shim, flags=re.S)
    code = re.sub(r"//[^\n]*", "", code)
    for banned in (
        "malloc",
        "calloc",
        "realloc",
        "free(",
        "strcmp",
        "strncmp",
        "memcmp",
        "strstr",
        "sprintf",
        "strcpy",
    ):
        if banned in code:
            fail(f"src/ffi/llhttp_shim.c uses {banned}; policy belongs in assembly")
    # One `if` guards the settings table's one-time preparation and one guards a
    # null pointer. More than a handful would mean decisions have moved in.
    conditionals = len(re.findall(r"\bif\s*\(", code))
    if conditionals > 3:
        fail(
            f"src/ffi/llhttp_shim.c has {conditionals} conditionals; an adapter "
            f"should have almost none"
        )
    ok("the llhttp shim is still an adapter")


def check_contract_documents_every_code() -> None:
    """Every code the catalogue can emit is written down in the contract."""
    source = (ROOT / "src/http/http_response.asm").read_text(encoding="utf-8")
    contract = (ROOT / "docs/API_CONTRACT.md").read_text(encoding="utf-8")
    codes = set(re.findall(r'^e_\w+:\s+db "([a-z0-9_]+)"', source, re.MULTILINE))
    if len(codes) < 10:
        fail(f"only {len(codes)} error codes were found; the parse is wrong")
        return
    missing = sorted(code for code in codes if f"`{code}`" not in contract)
    if missing:
        fail(f"emitted but undocumented error codes: {missing}")
    ok(f"the contract documents all {len(codes)} error codes")


def check_no_request_data_in_messages() -> None:
    """A refusal names a rule, never a value from the request.

    The catalogue's messages are fixed strings, so this is checkable by reading
    them: any format specifier would mean something from the request is being
    substituted in.
    """
    source = (ROOT / "src/http/http_response.asm").read_text(encoding="utf-8")
    messages = re.findall(r'^m_\w+:\s+db "([^"]*)"', source, re.MULTILINE)
    if len(messages) < 10:
        fail(f"only {len(messages)} messages were found; the parse is wrong")
        return
    for message in messages:
        if "%" in message:
            fail(f"a catalogue message interpolates: {message!r}")
    ok(f"all {len(messages)} refusal messages are fixed text")


def run_suite(name: str, module: str, build_dir: Path) -> None:
    result = subprocess.run(
        [sys.executable, "-m", "unittest", module],
        cwd=ROOT,
        env={**os.environ, "BUILD_DIR": str(build_dir)},
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        fail(f"{name} failed:\n{result.stdout}\n{result.stderr}")
        return
    # unittest exits 0 on a run that skipped every test. The suites here skip
    # when the daemon is not built — correct under `make check`, which is the
    # buildless M0 gate, and a silent hole here, where the build is a
    # prerequisite. A skip under the gate means the binary was not found.
    if "skipped=" in result.stderr or re.search(r"Ran 0 tests", result.stderr):
        fail(f"{name} skipped tests under the gate:\n{result.stderr}")
        return
    counted = re.search(r"Ran (\d+) test", result.stderr)
    ok(f"{name} ({counted.group(1) if counted else '?'} tests)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default="build")
    parser.add_argument(
        "--skip-suites",
        action="store_true",
        help="check only the static properties (the Makefile runs the suites)",
    )
    arguments = parser.parse_args()
    build_dir = Path(arguments.build_dir)
    if not build_dir.is_absolute():
        build_dir = ROOT / build_dir

    check_linkage(build_dir)
    check_symbol_boundary(build_dir)
    check_leniency_coverage()
    check_shim_is_an_adapter()
    check_contract_documents_every_code()
    check_no_request_data_in_messages()

    if not arguments.skip_suites:
        for name, module in (
            ("HTTP contract", "tests.test_http_contract"),
            ("HTTP limits", "tests.test_http_limits"),
            ("smuggling corpus", "tests.test_http_smuggling"),
            ("fragmentation corpus", "tests.test_http_fragments"),
            ("fault suite", "tests.test_http_faults"),
            ("request soak", "tests.test_http_soak"),
        ):
            run_suite(name, module, build_dir)

    if FAILED:
        print("M5 gate failed", file=sys.stderr)
        return 1
    print("M5 gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
