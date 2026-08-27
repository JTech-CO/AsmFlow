#!/usr/bin/env python3
"""M6 gate: the upstream client, Responses/Chat, and streaming (HARNESS.md M6).

The behavioural work is done by the four suites under `tests/`, which drive a
real daemon against a mock provider whose wire bytes the test controls. What is
left for this script is everything that is a property of the build rather than
of a transfer.

Three of those checks are the ones worth having.

libcurl offers three ways to run the multi interface and two of them own the
wait. Using either would give the daemon a second event loop, which ADR 0002
exists to prevent, and the symptom would not be a failing test — it would be a
daemon whose control socket stops answering while a provider is slow. So the
shim is checked for what it does NOT export.

Every security-relevant transfer option is set explicitly by the assembly. A
default is a property of a libcurl version; a call is a property of AsmFlow.
Certificate verification, redirect following, and the permitted scheme list are
each checked to be set rather than inherited.

And the client's own credential must never appear in an upstream request. That
one is asserted behaviourally too, but a static check costs nothing and catches
the version of the mistake where a well-meaning change adds header forwarding.
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


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def run(command: list, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(
        command, cwd=ROOT, capture_output=True, text=True, check=False, **kwargs
    )


# --- DoD 1 and 2: the boundary is an adapter -------------------------------

# The multi-interface entry points that own the wait. Using one of these would
# make libcurl the reactor and AsmFlow a caller inside it.
BLOCKING_CURL_CALLS = (
    "curl_multi_perform",
    "curl_multi_wait",
    "curl_multi_poll",
    "curl_multi_fdset",
    "curl_easy_perform",
)


def check_no_second_event_loop() -> None:
    """ADR 0002: one loop. libcurl is driven, it does not drive."""
    shim = read("src/ffi/curl_shim.c")
    for name in BLOCKING_CURL_CALLS:
        if name in shim:
            fail(
                f"src/ffi/curl_shim.c calls {name}, which would make libcurl "
                "the event loop"
            )
            return
    if "curl_multi_socket_action" not in shim:
        fail("the shim does not use curl_multi_socket_action")
        return
    ok("libcurl is driven by AsmFlow's loop, not the other way round")


def check_shim_is_an_adapter() -> None:
    """AGENTS.md invariant 2: no policy on the C side of the boundary.

    A policy on this side would look like a decision made from a value: a
    comparison against a header name, a URL, or a number that is really a
    limit. NULL checks and the sentinel translation the header owns are what
    an adapter is allowed to contain.
    """
    source = read("src/ffi/curl_shim.c")
    body = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)

    for banned in ("strcmp", "strncmp", "strstr", "malloc(", "getenv", "fopen"):
        if banned in body:
            fail(f"src/ffi/curl_shim.c uses {banned}; the shim is not an adapter")

    # A string literal on this side would be a policy AsmFlow cannot see: a
    # default URL, a header, a scheme list. The shim is allowed none.
    literals = [
        text
        for text in re.findall(r'"((?:[^"\\]|\\.)*)"', body)
        if text and not text.startswith("curl/")
    ]
    if literals:
        fail(f"src/ffi/curl_shim.c contains string literals: {literals[:5]}")

    exported = re.findall(r"^(?:const char \*|void \*|void|int64_t|int|size_t) "
                          r"?(af_curl_\w+)\(", body, re.MULTILINE)
    if len(exported) < 20:
        fail(f"only {len(exported)} shim exports were parsed; the check is wrong")
        return
    ok(f"the libcurl shim is still an adapter ({len(exported)} exports)")


# --- DoD 7: nothing security-relevant is left to a default ------------------

REQUIRED_SETTERS = {
    "af_curl_set_tls_verify": "certificate verification",
    "af_curl_set_follow_location": "redirect following",
    "af_curl_set_protocols": "the permitted scheme list",
    "af_curl_set_nosignal": "signal handling",
    "af_curl_set_accept_encoding": "content coding",
    "af_curl_set_connect_timeout_ms": "the connect timeout",
    "af_curl_set_timeout_ms": "the request timeout",
    "af_curl_set_low_speed": "the stall detector",
}


def check_every_transfer_option_is_stated() -> None:
    source = read("src/providers/provider_exchange.asm")
    missing = [
        f"{name} ({what})"
        for name, what in REQUIRED_SETTERS.items()
        if f"call    {name}" not in source
    ]
    if missing:
        fail("these transfer options are left to a libcurl default: " + ", ".join(missing))
        return
    ok(f"all {len(REQUIRED_SETTERS)} transfer options are set explicitly")


def check_tls_verification_is_not_configurable_off() -> None:
    """`allow_insecure_private_http` permits plain HTTP, not a bad certificate.

    The two are easy to conflate, and conflating them would turn a narrow
    convenience for a local runtime into a way to disable verification against
    a public provider.
    """
    source = read("src/providers/provider_exchange.asm")
    match = re.search(
        r"call\s+af_curl_set_tls_verify", source
    )
    if match is None:
        fail("TLS verification is never set")
        return
    window = source[max(0, match.start() - 400) : match.start()]
    if "PRV_ALLOW_INSECURE" in window:
        fail(
            "TLS verification depends on allow_insecure_private_http; that "
            "option permits plain HTTP, not an unverified certificate"
        )
        return
    ok("TLS verification is unconditional")


# --- DoD 2: the client's credential does not travel ------------------------

CLIENT_ONLY_FIELDS = ("HC_AUTH", "HC_NAME", "HC_VALUE")


def check_no_client_header_is_forwarded() -> None:
    for name in ("src/providers/provider_adapter.asm", "src/providers/provider_exchange.asm"):
        source = read(name)
        for field in CLIENT_ONLY_FIELDS:
            if field in source:
                fail(
                    f"{name} reads {field}; a client header must not reach a "
                    "provider, and the client's credential least of all"
                )
                return
    ok("no client-supplied header reaches a provider")


# --- DoD 8 and the contract: the commit point ------------------------------


def check_commit_point_is_recorded() -> None:
    """docs/API_CONTRACT.md 8: once a byte is out, no fallback.

    The flag has to be set where the head is written and must never be cleared,
    or "committed" becomes a value that can drift away from the truth.
    """
    source = read("src/providers/provider_exchange.asm")
    if "AF_PX_F_COMMITTED" not in source:
        fail("nothing records the commit point")
        return
    if re.search(r"and\s+qword\s+\[\w+ \+ PX_FLAGS\], ~AF_PX_F_COMMITTED", source):
        fail("the commit flag is cleared somewhere; a commit is not reversible")
        return
    head_sent = source.find("AF_PX_F_HEAD_SENT | AF_PX_F_COMMITTED")
    if head_sent < 0:
        fail("the head is written without recording the commit")
        return
    ok("the commit point is recorded where the head is written")


# --- the catalogue and the contract ----------------------------------------


def catalogue_codes() -> list:
    """The `code` strings the daemon can emit, in AF_HERR_* order."""
    source = read("src/http/http_response.asm")
    table = source[
        source.index("af_http_error_table:") : source.index("af_http_error_table_end:")
    ]
    names = re.findall(r"dq\s+\d+,\s+AF_ERRCLASS_\w+,\s+(e_\w+),", table)
    codes = []
    for name in names:
        match = re.search(rf'^{name}:\s+db "([^"]+)"', source, re.MULTILINE)
        if match:
            codes.append(match.group(1))
    return codes


def check_contract_documents_every_code() -> None:
    codes = catalogue_codes()
    if len(codes) < 20:
        fail(f"only {len(codes)} catalogue codes were parsed; the check is wrong")
        return
    contract = read("docs/API_CONTRACT.md")
    missing = sorted({code for code in codes if f"`{code}`" not in contract})
    if missing:
        fail("codes the daemon can emit but the contract does not document: "
             + ", ".join(missing))
        return
    ok(f"the contract documents all {len(set(codes))} error codes")


def check_upstream_classes_are_documented() -> None:
    """Every AF_E_UP_* has to be classified, or a failure falls through."""
    errors = read("include/errors.inc")
    declared = set(re.findall(r"%define\s+(AF_E_UP_\w+)", errors))
    classifier = read("src/providers/provider_error.asm")
    unmapped = sorted(name for name in declared if name not in classifier)
    if unmapped:
        fail("upstream failure codes nothing classifies: " + ", ".join(unmapped))
        return
    ok(f"all {len(declared)} upstream failure classes are accounted for")


# --- the engine's own invariants -------------------------------------------


def check_ordinals_are_asserted_at_startup() -> None:
    source = read("src/providers/provider_engine.asm")
    if "call    af_prov_check_ordinals" not in source:
        fail("the mirrored libcurl ordinals are never checked against the library")
        return
    init = source[source.index("af_prov_engine_init:") :]
    init = init[: init.index("af_prov_engine_shutdown:")]
    if "af_prov_check_ordinals" not in init:
        fail("the ordinal check does not run during engine startup")
        return
    ok("the mirrored libcurl ordinals are asserted before any handle exists")


def check_upstream_descriptors_are_not_closed_by_us() -> None:
    """libcurl owns the sockets it hands us; closing one would take a
    connection out from under a live transfer, and the fault would surface on
    whichever request later reused the descriptor number."""
    source = read("src/providers/provider_engine.asm")
    socket_callback = source[
        source.index("af_prov_on_socket:") : source.index("af_prov_on_timer:")
    ]
    if "af_sys_close" in socket_callback:
        fail("the socket callback closes a descriptor libcurl owns")
        return
    ok("upstream descriptors are deregistered, never closed")


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

    check_no_second_event_loop()
    check_shim_is_an_adapter()
    check_every_transfer_option_is_stated()
    check_tls_verification_is_not_configurable_off()
    check_no_client_header_is_forwarded()
    check_commit_point_is_recorded()
    check_contract_documents_every_code()
    check_upstream_classes_are_documented()
    check_ordinals_are_asserted_at_startup()
    check_upstream_descriptors_are_not_closed_by_us()

    if not arguments.skip_suites:
        for name, module in (
            ("provider contract", "tests.test_provider_contract"),
            ("streaming corpus", "tests.test_provider_streaming"),
            ("provider faults", "tests.test_provider_faults"),
            ("stream soak", "tests.test_provider_soak"),
        ):
            run_suite(name, module, build_dir)

    if FAILED:
        print("M6 gate failed", file=sys.stderr)
        return 1
    print("M6 gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
