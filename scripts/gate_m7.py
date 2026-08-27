#!/usr/bin/env python3
"""M7 gate: routing, health, circuit breaking, and fallback (HARNESS.md M7).

HARNESS.md calls this phase the project's core value and its riskiest stretch,
and the reason is worth restating here: a routing defect does not look like a
defect. The request still gets an answer, the answer still parses, and the only
trace is traffic that went somewhere the operator did not intend.

The suites carry almost all of the weight — a parity corpus against the Python
oracle, a golden breaker timeline, the fallback invariants, the concurrency
accounting, and a fault soak. What this script adds is the set of properties
that are true of the build rather than of any run.

Three of those are worth the reader's attention.

The oracle must never become reachable from the product. It exists to be an
independent statement of the rules, and an implementation that called it would
turn the parity test into a tautology.

The selector must be a pure function. Determinism (M7 DoD 2) is asserted by
running it a hundred times, which proves the property for those hundred runs; a
selector that reads a clock or mutates state could still pass that and diverge
under load. So the calls it is allowed to make are checked directly.

And the out-parameter clock is checked at every call site. `af_monotonic_ns`
writes through a pointer and returns a status; a call site that treats it as
value-returning writes eight bytes of clock over whatever the register happened
to hold. That is not hypothetical — it shipped in M6, over the configuration
snapshot's reference count, and nothing crashed.
"""
from __future__ import annotations

import argparse
import json
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


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def code_of(path: Path) -> str:
    """An assembly file with its comments removed.

    Every check below asks what the code does. A file that explains itself well
    mentions the things it deliberately avoids, and a check that greps raw text
    reads those explanations as violations — which is how the first version of
    this script reported that the selector consults the oracle, because it says
    in a comment that it must not.
    """
    lines = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.split(";", 1)[0]
        if stripped.strip():
            lines.append(stripped)
    return "\n".join(lines)


def run(command: list, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(
        command, cwd=ROOT, capture_output=True, text=True, check=False, **kwargs
    )


# --- DoD 1: the oracle stays independent -----------------------------------


def check_oracle_is_not_reachable_from_the_product() -> None:
    """`tests/route_oracle.py` states the rules a second time, or it states
    nothing. An implementation that consulted it would agree with it by
    construction.

    Prose about the oracle is not a reference to it — `src/routing/` explains
    at length that it must stay independent — so what is checked is imports.
    """
    for path in sorted(ROOT.rglob("*.py")):
        relative = path.relative_to(ROOT)
        if relative.parts[0] in ("tests", "scripts"):
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        if re.search(r"^\s*(from|import)\s+.*route_oracle", text, re.MULTILINE):
            fail(f"{relative} imports the routing oracle")
            return
    ok("the routing oracle is imported only by tests")


def check_fixtures_are_test_only(build_dir: Path) -> None:
    """The corpus builders exist so the parity test can assemble a scenario.
    A daemon that linked them would be a daemon with a second way to build a
    route."""
    daemon = build_dir / "debug" / "asmflowd"
    if not daemon.exists():
        fail(f"{daemon} is missing; run `make build-debug` first")
        return
    result = run(["nm", "--defined-only", str(daemon)])
    symbols = {line.split()[-1] for line in result.stdout.splitlines() if line.strip()}
    leaked = sorted(name for name in symbols if name.startswith("af_rt_"))
    if leaked:
        fail("test-only routing fixtures are linked into asmflowd: " + ", ".join(leaked))
        return
    if "af_route_corpus_main" in symbols:
        fail("the routing corpus harness is linked into asmflowd")
        return
    ok("the routing fixtures are test-only")


# --- DoD 2: the selector is a pure function --------------------------------

IMPURE_CALLS = (
    "af_monotonic",
    "af_realtime",
    "af_clock",
    "af_alloc",
    "af_free",
    "af_health_success",
    "af_health_failure",
    "af_health_begin",
    "af_health_end",
)


def check_the_selector_is_pure() -> None:
    source = code_of(ROOT / "src/routing/routing_select.asm")
    called = set(re.findall(r"call\s+(af_\w+)", source))
    impure = sorted(
        name for name in called if any(name.startswith(bad) for bad in IMPURE_CALLS)
    )
    if impure:
        fail(
            "the selector calls something that reads a clock or mutates state: "
            + ", ".join(impure)
        )
        return
    ok(f"the selector is a pure function of its inputs ({len(called)} calls, all pure)")


def check_every_policy_is_implemented() -> None:
    schema = json.loads(read("config/asmflow.schema.json"))
    policies = schema["$defs"]["route"]["properties"]["policy"]["enum"]
    source = code_of(ROOT / "src/routing/routing_select.asm")
    missing = [
        name for name in policies if f"AF_POLICY_{name.upper()}" not in source
    ]
    if missing:
        fail("policies the schema allows but the selector does not name: " + ", ".join(missing))
        return
    ok(f"all {len(policies)} routing policies are implemented")


# --- DoD 4: the breaker is monotonic ---------------------------------------


def check_the_breaker_uses_the_monotonic_clock() -> None:
    """A cooldown measured against the wall clock would reopen early, or never,
    the moment an operator corrected the system time — and the failure would
    look like a routing defect."""
    source = code_of(ROOT / "src/routing/routing_health.asm")
    if "af_realtime" in source:
        fail("the circuit breaker reads the wall clock")
        return
    if "af_monotonic" not in source:
        fail("the circuit breaker reads no clock at all")
        return
    ok("every circuit deadline is monotonic")


def check_the_clock_out_parameter_is_never_misused() -> None:
    """`af_monotonic_ns(u64 *out)` returns a status, not a reading.

    A call site that ignores the out-parameter writes the reading over whatever
    the register held and then uses the status as if it were a timestamp. M6
    shipped exactly that, writing over the configuration snapshot's reference
    count on every generation request; `af_monotonic_now` exists so a caller
    that wants a value can ask for one.
    """
    offenders = []
    for path in sorted((ROOT / "src").rglob("*.asm")) + sorted(
        (ROOT / "tests").rglob("*.asm")
    ):
        lines = code_of(path).splitlines()
        for index, line in enumerate(lines):
            if not re.search(r"call\s+af_monotonic_ns\b", line):
                continue
            window = " ".join(lines[max(0, index - 4) : index])
            if not re.search(r"lea\s+rdi\s*,", window):
                offenders.append(f"{path.relative_to(ROOT)}: {line.strip()}")
    if offenders:
        fail(
            "af_monotonic_ns is called without an out-pointer at: "
            + ", ".join(offenders)
        )
        return
    ok("every af_monotonic_ns call site supplies an out-pointer")


# --- DoD 5-7: the fallback rules -------------------------------------------


def check_the_commit_barrier_is_first_and_final() -> None:
    source = code_of(ROOT / "src/providers/provider_exchange.asm")
    start = source.find("af_prov_may_fall_back:")
    if start < 0:
        fail("nothing decides whether a fallback may occur")
        return
    body = source[start : source.find("AF_LEAVE", source.find(".no:", start))]
    committed = body.find("AF_PX_F_COMMITTED")
    retryable = body.find("af_prov_is_retryable")
    if committed < 0:
        fail("the fallback decision does not consider the commit point")
        return
    if retryable >= 0 and committed > retryable:
        fail("the commit point is checked after the retryable class, not before")
        return
    if re.search(r"and\s+qword\s+\[\w+ \+ PX_FLAGS\], ~AF_PX_F_COMMITTED", source):
        fail("the commit flag is cleared somewhere; a commit is not reversible")
        return
    ok("the commit barrier is checked first and never cleared")


def check_every_retryable_class_is_mapped() -> None:
    """`fallback.retryable` names six classes. Each has to map onto an
    AF_E_UP_* code, or naming it in a configuration would do nothing."""
    schema = json.loads(read("config/asmflow.schema.json"))
    classes = schema["$defs"]["fallback"]["properties"]["retryable"]["items"]["enum"]
    source = code_of(ROOT / "src/providers/provider_error.asm")
    table = source[source.find("retry_map:") : source.find("retry_map_end:")]
    missing = [
        name for name in classes if f"AF_RETRY_{name.upper()}" not in table
    ]
    if missing:
        fail("retryable classes with no mapping: " + ", ".join(missing))
        return
    ok(f"all {len(classes)} retryable classes map onto a failure code")


# --- DoD 9: the concurrency counter ----------------------------------------


def check_the_concurrency_slot_has_one_release() -> None:
    """One claim, one release, from one function.

    A counter that is not returned on some path does not fail visibly. It makes
    the provider look progressively busier until it is permanently ineligible,
    and the only symptom is traffic that stopped arriving.
    """
    source = code_of(ROOT / "src/providers/provider_exchange.asm")
    releases = re.findall(r"call\s+af_health_end\b", source)
    if len(releases) != 1:
        fail(
            f"the concurrency slot is released from {len(releases)} places; "
            "exactly one, inside af_prov_attempt_release, is the whole point"
        )
        return
    release_function = source[source.find("af_prov_attempt_release:") :]
    release_function = release_function[: release_function.find("\nglobal ")]
    if "af_health_end" not in release_function:
        fail("the release does not happen inside af_prov_attempt_release")
        return
    claims = re.findall(r"call\s+af_health_begin\b", source)
    if len(claims) != 1:
        fail(f"the slot is claimed from {len(claims)} places; it should be one")
        return
    if "AF_PX_F_COUNTED" not in source:
        fail("nothing records that a slot is held")
        return
    ok("the concurrency slot is claimed once and released through one function")


def run_suite(name: str, module: str, build_dir: Path) -> None:
    result = subprocess.run(
        [sys.executable, "-m", "unittest", module],
        cwd=ROOT,
        env={**os.environ, "BUILD_DIR": str(build_dir)},
        capture_output=True,
        text=True,
        check=False,
        timeout=1800,
    )
    if result.returncode != 0:
        fail(f"{name} failed:\n{result.stdout}\n{result.stderr}")
        return
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

    check_oracle_is_not_reachable_from_the_product()
    check_fixtures_are_test_only(build_dir)
    check_the_selector_is_pure()
    check_every_policy_is_implemented()
    check_the_breaker_uses_the_monotonic_clock()
    check_the_clock_out_parameter_is_never_misused()
    check_the_commit_barrier_is_first_and_final()
    check_every_retryable_class_is_mapped()
    check_the_concurrency_slot_has_one_release()

    if not arguments.skip_suites:
        for name, module in (
            ("routing parity", "tests.test_routing_parity"),
            ("circuit timeline", "tests.test_circuit_timeline"),
            ("fallback invariants", "tests.test_fallback_invariant"),
            ("routing concurrency", "tests.test_routing_concurrency"),
            ("routing fault soak", "tests.test_routing_fault_soak"),
        ):
            run_suite(name, module, build_dir)

    if FAILED:
        print("M7 gate failed", file=sys.stderr)
        return 1
    print("M7 gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
