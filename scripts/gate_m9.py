#!/usr/bin/env python3
"""M9 gate: MCP Streamable HTTP and version adapters (HARNESS.md M9).

The five Python suites own the wire-level claims.  This audit checks properties
that a mock cannot prove on its own: the HTTP transport is linked into the
daemon, modern and legacy code remain physically separate, libcurl stays under
the one epoll reactor, every byte store is bounded, security-relevant curl
options are explicit, and cache identity includes the authorization context.
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FAILED = False

SUITES = (
    ("modern HTTP", "tests.test_mcp_http_modern", 3),
    ("legacy HTTP", "tests.test_mcp_http_legacy", 2),
    ("version matrix", "tests.test_mcp_version_matrix", 3),
    ("HTTP stream", "tests.test_mcp_http_stream", 3),
    ("HTTP security", "tests.test_mcp_http_security", 6),
)

HTTP_EXPORTS = {
    "src/mcp/mcp_http_engine.asm": (
        "af_mcp_http_engine_init",
        "af_mcp_http_engine_shutdown",
        "af_mcp_http_slot_alloc",
        "af_mcp_http_slot_release",
        "af_mcp_http_transfer_cancel",
        "af_mcp_http_reap",
    ),
    "src/mcp/mcp_http_adapter.asm": (
        "af_mcp_http_start",
        "af_mcp_http_stop",
        "af_mcp_http_request",
        "af_mcp_http_notify",
        "af_mcp_http_cancel_call",
        "af_mcp_http_complete",
        "af_mcp_http_advance_inventory",
    ),
    "src/mcp/mcp_http_modern.asm": (
        "af_mcp_http_modern_headers",
    ),
    "src/mcp/mcp_http_legacy.asm": (
        "af_mcp_http_legacy_headers",
        "af_mcp_http_legacy_start_get",
        "af_mcp_http_legacy_cancel_notification",
    ),
}

FIXTURES = {
    "header_mismatch_error.json",
    "legacy_initialize_result.json",
    "legacy_tools_list_result.json",
    "method_not_found_error.json",
    "modern_discover_result.json",
    "modern_tool_call_result.json",
    "modern_tools_list_result.json",
    "progress_notification.json",
    "unsupported_version_error.json",
}


def fail(message: str) -> None:
    global FAILED
    FAILED = True
    print(f"[fail] {message}", file=sys.stderr)


def ok(label: str) -> None:
    print(f"[ok] {label}")


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def strip_asm_comments(text: str) -> str:
    lines = []
    for line in text.splitlines():
        quote = None
        escaped = False
        kept = []
        for char in line:
            if escaped:
                kept.append(char)
                escaped = False
                continue
            if quote is not None and char == "\\":
                kept.append(char)
                escaped = True
                continue
            if char in ("'", '"'):
                if quote == char:
                    quote = None
                elif quote is None:
                    quote = char
                kept.append(char)
                continue
            if char == ";" and quote is None:
                break
            kept.append(char)
        stripped = "".join(kept)
        if stripped.strip():
            lines.append(stripped)
    return "\n".join(lines)


def strip_c_comments(text: str) -> str:
    out = []
    index = 0
    state = "code"
    quote = ""
    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""
        if state == "line":
            if char == "\n":
                out.append(char)
                state = "code"
            index += 1
            continue
        if state == "block":
            if char == "*" and next_char == "/":
                state = "code"
                index += 2
            else:
                if char == "\n":
                    out.append(char)
                index += 1
            continue
        if state == "string":
            out.append(char)
            if char == "\\" and index + 1 < len(text):
                out.append(text[index + 1])
                index += 2
                continue
            if char == quote:
                state = "code"
            index += 1
            continue
        if char == "/" and next_char == "/":
            state = "line"
            index += 2
        elif char == "/" and next_char == "*":
            state = "block"
            index += 2
        else:
            out.append(char)
            if char in ("'", '"'):
                state = "string"
                quote = char
            index += 1
    return "".join(out)


def code_of(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        return ""
    text = path.read_text(encoding="utf-8")
    if path.suffix in (".asm", ".inc"):
        return strip_asm_comments(text)
    if path.suffix in (".c", ".h"):
        return strip_c_comments(text)
    raise ValueError(f"no comment stripper for {path}")


def function_body(source: str, name: str) -> str:
    start = source.find(f"{name}:")
    if start < 0:
        return ""
    tail = source[start + len(name) + 1 :]
    match = re.search(r"(?m)^\s*global\s+", tail)
    if match is None:
        return source[start:]
    return source[start : start + len(name) + 1 + match.start()]


def http_code() -> str:
    return "\n".join(
        code_of(str(path.relative_to(ROOT)).replace("\\", "/"))
        for path in sorted((ROOT / "src/mcp").glob("mcp_http*.asm"))
    )


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        **kwargs,
    )


def check_sources_and_build(build_dir: Path) -> None:
    missing_files = [
        relative for relative in HTTP_EXPORTS if not (ROOT / relative).is_file()
    ]
    if missing_files:
        fail("missing M9 assembly modules: " + ", ".join(missing_files))

    required_symbols = set()
    for relative, expected in HTTP_EXPORTS.items():
        source = code_of(relative)
        globals_found = set(re.findall(r"(?m)^\s*global\s+(af_mcp_http_\w+)", source))
        absent = sorted(set(expected) - globals_found)
        if absent:
            fail(f"{relative} is missing exports: " + ", ".join(absent))
        required_symbols.update(expected)

    daemon = build_dir / "debug" / "asmflowd"
    if not daemon.is_file():
        fail(f"missing M9 debug daemon: {daemon}")
        return
    try:
        result = run(["nm", "--defined-only", str(daemon)])
    except OSError as error:
        fail(f"nm could not inspect {daemon}: {error}")
        return
    if result.returncode != 0:
        fail(f"nm could not inspect {daemon}: {result.stderr}")
        return
    built_symbols = {
        line.split()[-1] for line in result.stdout.splitlines() if line.strip()
    }
    absent = sorted(required_symbols - built_symbols)
    if absent:
        fail("asmflowd is missing M9 HTTP symbols: " + ", ".join(absent))
        return
    ok(f"debug daemon contains all {len(required_symbols)} M9 HTTP anchors")


def check_transport_dispatch() -> None:
    source = code_of("src/mcp/mcp_transport.asm")
    request = function_body(source, "af_mcp_transport_request")
    notify = function_body(source, "af_mcp_transport_notify")
    checks = (
        (
            "request",
            request,
            ("AF_TRANSPORT_STDIO", "AF_TRANSPORT_STREAMABLE_HTTP",
             "af_mcp_send", "af_mcp_http_request"),
        ),
        (
            "notification",
            notify,
            ("AF_TRANSPORT_STDIO", "AF_TRANSPORT_STREAMABLE_HTTP",
             "af_mcp_send", "af_mcp_http_notify"),
        ),
    )
    for label, body, tokens in checks:
        missing = [token for token in tokens if token not in body]
        if missing:
            fail(f"MCP {label} dispatch is incomplete: " + ", ".join(missing))
            return
    ok("common JSON-RPC dispatch selects stdio or Streamable HTTP explicitly")


def check_modern_and_legacy_are_isolated() -> None:
    modern = code_of("src/mcp/mcp_http_modern.asm")
    legacy = code_of("src/mcp/mcp_http_legacy.asm")
    era = code_of("src/mcp/mcp_era.asm")

    modern_required = (
        "af_mcp_http_modern_headers",
        "MCP-Protocol-Version",
        "Mcp-Method",
        "Mcp-Name",
        "Mcp-Param-",
        "Accept",
        "application/json",
        "text/event-stream",
        "AF_MCP_MODERN_VERSION",
    )
    missing = [token for token in modern_required if token not in modern]
    if missing:
        fail("modern HTTP request construction lacks: " + ", ".join(missing))
        return

    forbidden_modern = re.search(
        r"Mcp-Session-Id|Last-Event-Id|AF_MCP_HTTP_METHOD_GET|"
        r"af_curl_set_http_get|af_mcp_http_legacy|2025-11-25",
        modern,
        re.IGNORECASE,
    )
    if forbidden_modern:
        fail(f"legacy state leaked into the modern adapter: {forbidden_modern.group(0)}")
        return

    legacy_required = (
        "af_mcp_http_legacy_headers",
        "af_mcp_http_legacy_start_get",
        "af_mcp_http_legacy_cancel_notification",
        "Mcp-Session-Id",
        "AF_MCP_HTTP_METHOD_GET",
        "af_curl_set_http_get",
        "AF_MCP_LEGACY_VERSION",
    )
    missing = [token for token in legacy_required if token not in legacy]
    if missing:
        fail("legacy HTTP adapter lacks: " + ", ".join(missing))
        return

    metadata = (
        "io.modelcontextprotocol/protocolVersion",
        "io.modelcontextprotocol/clientInfo",
        "io.modelcontextprotocol/clientCapabilities",
        "2026-07-28",
    )
    missing = [token for token in metadata if token not in era]
    if missing:
        fail("modern HTTP bodies lack matching metadata: " + ", ".join(missing))
        return
    ok("modern POST metadata/headers and legacy session/GET state are isolated")


def check_version_and_fallback_classification() -> None:
    adapter = code_of("src/mcp/mcp_http_adapter.asm")
    era = function_body(code_of("src/mcp/mcp_era.asm"), "af_mcp_advance")
    flags = (
        "AF_MCP_CL_F_RECOGNIZED",
        "AF_MCP_CL_F_BARE_REFUSAL",
        "AF_MCP_CL_F_VERSION_ERROR",
        "AF_MCP_CL_F_HEADER_MISMATCH",
    )
    missing = [token for token in flags if token not in adapter]
    if missing:
        fail("HTTP response classification lacks: " + ", ".join(missing))
        return
    required_era = (
        "AF_TRANSPORT_STREAMABLE_HTTP",
        "AF_MCP_CL_F_BARE_REFUSAL",
        "AF_MCP_LEGACY_2025_11_25",
        "AF_E_MCP_TIMEOUT",
        ".no_legacy",
    )
    missing = [token for token in required_era if token not in era]
    if missing:
        fail("HTTP era selection lacks: " + ", ".join(missing))
        return
    if era.count("AF_MCP_CL_F_BARE_REFUSAL") != 1:
        fail("HTTP legacy fallback has more than one bare-refusal decision point")
        return
    ok("only an unrecognized bare refusal enters legacy era selection")


BLOCKING_CURL_CALLS = (
    "curl_easy_perform",
    "curl_multi_perform",
    "curl_multi_wait",
    "curl_multi_poll",
    "curl_multi_fdset",
)


def check_one_epoll_driven_curl_engine() -> None:
    engine = code_of("src/mcp/mcp_http_engine.asm")
    shim = code_of("src/ffi/curl_shim.c")
    required = (
        "af_curl_mcp_multi_new",
        "af_curl_multi_socket_action",
        "af_curl_multi_socket_timeout",
        "af_loop_add",
        "af_sys_timerfd_create",
        "CLOCK_MONOTONIC",
        "af_mcp_http_reap",
    )
    missing = [token for token in required if token not in engine]
    if missing:
        fail("MCP HTTP reactor lacks: " + ", ".join(missing))
        return
    forbidden = [token for token in BLOCKING_CURL_CALLS if token in shim]
    if forbidden:
        fail("libcurl can own a second event loop: " + ", ".join(forbidden))
        return
    if "pthread_create" in shim or "pthread_create" in engine:
        fail("MCP HTTP introduced a worker thread")
        return
    socket_callback = function_body(engine, "af_mcp_http_on_socket")
    if "af_sys_close" in socket_callback:
        fail("the MCP curl socket callback closes a libcurl-owned descriptor")
        return
    ok("MCP curl multi is driven by the daemon's epoll/timerfd reactor")


def check_buffers_and_stream_cancellation() -> None:
    public = code_of("include/mcp_http.inc")
    engine = code_of("src/mcp/mcp_http_engine.asm")
    policy = http_code()
    expected_defines = {
        "AF_MCP_HTTP_MAX_SERVERS": "256",
        "AF_MCP_HTTP_XFERS_PER_SERVER": "2",
        "AF_MCP_HTTP_HEADER_DEFAULT": "(64*1024)",
        "AF_MCP_HTTP_BODY_DEFAULT": "(4*1024*1024)",
        "AF_MCP_HTTP_EVENT_DEFAULT": "(1024*1024)",
        "AF_MCP_HTTP_HEADER_HARD_MAX": "(1024*1024)",
        "AF_MCP_HTTP_BODY_HARD_MAX": "(64*1024*1024)",
        "AF_MCP_HTTP_EVENT_HARD_MAX": "(16*1024*1024)",
        "AF_MCP_HTTP_EVENT_COUNT_MAX": "1024",
        "AF_MCP_HTTP_URL_MAX": "4096",
        "AF_MCP_HTTP_SESSION_MAX": "4096",
    }
    wrong = []
    for name, expected in expected_defines.items():
        match = re.search(rf"(?m)^\s*%define\s+{name}\s+(.+?)\s*$", public)
        actual = re.sub(r"\s+", "", match.group(1)) if match else "<missing>"
        if actual != expected:
            wrong.append(f"{name}={actual}")
    if wrong:
        fail("MCP HTTP public bounds changed: " + ", ".join(wrong))
        return

    engine_limits = (
        "AF_MCP_HTTP_MAX_TRANSFERS",
        "AF_MCP_HTTP_HEADER_HARD_MAX",
        "AF_MCP_HTTP_BODY_HARD_MAX",
        "AF_MCP_HTTP_EVENT_HARD_MAX",
        "HX_HEADER_BYTES",
        "HX_BODY_BYTES",
        "HX_HEADER_LIMIT",
        "HX_BODY_LIMIT",
        "AF_MCP_HTTP_F_DUP_HEADER",
        "AF_CURL_TAKE_ABORT",
        "af_buf_free_secure",
    )
    missing = [token for token in engine_limits if token not in engine]
    if missing:
        fail("MCP HTTP engine does not enforce: " + ", ".join(missing))
        return

    stream_contract = (
        "AF_MCP_HTTP_F_CONTENT_SSE",
        "AF_MCP_HTTP_F_FINAL_SEEN",
        "AF_MCP_HTTP_EVENT_COUNT_MAX",
        "HX_EVENT_LIMIT",
        "AF_E_MCP_PROTOCOL",
        "af_mcp_http_sse_consume",
        "af_mcp_http_transfer_cancel",
    )
    missing = [token for token in stream_contract if token not in policy]
    if missing:
        fail("request-scoped SSE/cancellation lacks: " + ", ".join(missing))
        return
    rpc = function_body(code_of("src/mcp/mcp_rpc.asm"), "af_mcp_cancel_timed_out")
    if "af_mcp_http_cancel_call" not in rpc:
        fail("an expired HTTP call is not cancelled through the HTTP adapter")
        return
    ok("HTTP tables, headers, bodies, SSE events, and cancellation are bounded")


def check_security_options_and_c_boundary() -> None:
    policy = http_code()
    required_setters = (
        "af_curl_set_url",
        "af_curl_set_protocols",
        "af_curl_disable_proxy",
        "af_curl_set_tls_verify",
        "af_curl_set_follow_location",
        "af_curl_set_nosignal",
        "af_curl_set_connect_timeout_ms",
        "af_curl_set_timeout_ms",
        "af_curl_set_low_speed",
        "af_curl_set_accept_encoding",
        "af_curl_set_headers",
    )
    missing = [
        name for name in required_setters
        if not re.search(rf"\bcall\s+{name}\b", policy)
    ]
    if missing:
        fail("MCP HTTP leaves curl security options implicit: " + ", ".join(missing))
        return

    tls_call = re.search(r"\bcall\s+af_curl_set_tls_verify\b", policy)
    assert tls_call is not None
    tls_window = policy[max(0, tls_call.start() - 500) : tls_call.start()]
    if "MCP_ALLOW_INSECURE" in tls_window:
        fail("allow_insecure_private_http can disable TLS certificate verification")
        return

    config = code_of("src/config/config_mcp.asm")
    config_required = (
        "af_cfg_url_check",
        "MCP_ALLOW_INSECURE",
        "af_cfg_load_auth",
    )
    missing = [token for token in config_required if token not in config]
    if missing:
        fail("MCP HTTP config security validation lacks: " + ", ".join(missing))
        return
    if "af_cfg_getenv" not in policy or "AUTH_ENV" not in policy:
        fail("MCP HTTP credentials are not resolved from their SecretRef at use time")
        return

    shim = code_of("src/ffi/curl_shim.c")
    policy_tokens = (
        "server/discover",
        "2026-07-28",
        "2025-11-25",
        "MCP-Protocol-Version",
        "Mcp-Session-Id",
        "ttlMs",
        "cacheScope",
    )
    leaked = [token for token in policy_tokens if token in shim]
    if leaked:
        fail("MCP protocol policy migrated into the C shim: " + ", ".join(leaked))
        return
    ok("plaintext/redirect/proxy/TLS/auth policy stays explicit in assembly")


def check_cache_ttl_and_partitioning() -> None:
    public = code_of("include/mcp.inc")
    era = code_of("src/mcp/mcp_era.asm")
    supervisor = code_of("src/mcp/mcp_supervisor.asm")
    declared = (
        "MC_CACHE_SCOPE",
        "MC_CACHE_AUTH_HASH",
        "MC_CACHE_KEY_HASH",
        "AF_MCP_CACHE_TTL_MAX_MS",
    )
    missing = [token for token in declared if token not in public]
    if missing:
        fail("MCP cache layout lacks: " + ", ".join(missing))
        return
    partition_uses = era + "\n" + supervisor + "\n" + http_code()
    for token in ("MC_CACHE_AUTH_HASH", "MC_CACHE_KEY_HASH"):
        if partition_uses.count(token) < 2:
            fail(f"{token} is not both committed and compared")
            return
    ttl_tokens = (
        "AF_MCP_CACHE_TTL_MAX_MS",
        "MC_CACHE_SCOPE",
        "MC_FETCHED_NS",
        "MC_EXPIRES_NS",
        "af_monotonic_now",
        "af_mul_size",
        "af_add_size",
    )
    missing = [token for token in ttl_tokens if token not in era]
    if missing:
        fail("transactional cache TTL commit lacks: " + ", ".join(missing))
        return
    refresh = function_body(supervisor, "af_mcp_sweep_child")
    for token in ("MC_FETCHED_NS", "MC_EXPIRES_NS", "af_mcp_refresh_inventory"):
        if token not in refresh:
            fail(f"lazy cache expiry does not use {token}")
            return
    if "CLOCK_REALTIME" in partition_uses or "af_realtime" in partition_uses:
        fail("MCP cache expiry uses the wall clock")
        return
    control = code_of("src/control/control_methods.asm")
    if "MC_CACHE_AUTH_HASH" in control or "MC_CACHE_KEY_HASH" in control:
        fail("internal authorization cache fingerprints reach the control plane")
        return
    ok("cache TTL is monotonic and cache identity includes server/auth context")


def check_fixture_and_test_matrix() -> None:
    fixture_dir = ROOT / "tests/fixtures/mcp/http"
    found = {path.name for path in fixture_dir.glob("*.json")}
    missing = sorted(FIXTURES - found)
    if missing:
        fail("M9 fixture matrix is missing: " + ", ".join(missing))
        return
    documents = {}
    try:
        for name in FIXTURES:
            documents[name] = json.loads((fixture_dir / name).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"M9 fixture is not valid UTF-8 JSON: {error}")
        return

    expected_codes = {
        "header_mismatch_error.json": -32020,
        "unsupported_version_error.json": -32022,
        "method_not_found_error.json": -32601,
    }
    for name, expected in expected_codes.items():
        actual = documents[name].get("error", {}).get("code")
        if actual != expected:
            fail(f"{name} has error code {actual!r}, expected {expected}")
            return
    modern_versions = documents["modern_discover_result.json"].get(
        "result", {}
    ).get("supportedVersions", [])
    legacy_version = documents["legacy_initialize_result.json"].get(
        "result", {}
    ).get("protocolVersion")
    if "2026-07-28" not in modern_versions or legacy_version != "2025-11-25":
        fail("fixture protocol versions do not cover both supported eras")
        return
    if "id" in documents["progress_notification.json"]:
        fail("the progress notification fixture is incorrectly correlated")
        return

    markers = {
        "tests/test_mcp_http_modern.py": (
            "mcp-protocol-version", "accept", "mcp-session-id", "last-event-id",
        ),
        "tests/test_mcp_http_legacy.py": (
            'mode="legacy"', "mcp-session-id", "notifications/cancelled",
        ),
        "tests/test_mcp_version_matrix.py": (
            "unsupported", "header-mismatch", "method-not-found", "transient",
        ),
        "tests/test_mcp_http_stream.py": (
            "fragment_size=1", "eof_methods", "hang_methods",
        ),
        "tests/test_mcp_http_security.py": (
            "authorization", "redirect", "ALL_PROXY",
            "allow_insecure_private_http", "cache_scope", "ttl",
        ),
    }
    minimums = {f"tests/{module.rsplit('.', 1)[-1]}.py": count
                for _, module, count in SUITES}
    for relative, required_markers in markers.items():
        source = read(relative)
        try:
            tree = ast.parse(source, filename=relative)
        except SyntaxError as error:
            fail(f"{relative} does not parse: {error}")
            return
        tests = [
            node for node in ast.walk(tree)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name.startswith("test_")
        ]
        if len(tests) < minimums[relative]:
            fail(
                f"{relative} has {len(tests)} tests; "
                f"the M9 floor is {minimums[relative]}"
            )
            return
        missing_markers = [token for token in required_markers if token not in source]
        if missing_markers:
            fail(f"{relative} lacks matrix cases: " + ", ".join(missing_markers))
            return
    ok(f"all five suites and {len(FIXTURES)} protocol fixtures cover the M9 matrix")


def make_recipe(target: str) -> str:
    lines = read("Makefile").splitlines()
    start = None
    for index, line in enumerate(lines):
        if re.match(rf"^{re.escape(target)}\s*:", line):
            start = index + 1
            break
    if start is None:
        return ""
    recipe = []
    for line in lines[start:]:
        if line.startswith("\t"):
            recipe.append(line)
            continue
        if not line.strip():
            if recipe:
                break
            continue
        if recipe:
            break
    return "\n".join(recipe)


def logical_make_lines(source: str) -> list[str]:
    logical = []
    current = ""
    for line in source.splitlines():
        stripped = line.strip()
        current = f"{current} {stripped}".strip()
        if current.endswith("\\"):
            current = current[:-1].rstrip()
            continue
        if current:
            logical.append(current)
        current = ""
    if current:
        logical.append(current)
    return logical


def check_make_wiring() -> None:
    makefile = read("Makefile")
    targets = (
        "test-mcp-http-modern",
        "test-mcp-http-legacy",
        "test-mcp-version-matrix",
        "test-mcp-http-stream",
        "test-mcp-http-security",
    )
    modules = tuple(module for _, module, _ in SUITES)
    recipes = {target: make_recipe(target) for target in (*targets, "gate-m9")}
    missing = [target for target, recipe in recipes.items() if not recipe]
    if missing:
        fail("Makefile is missing M9 recipes: " + ", ".join(missing))
        return
    focused = [recipes[target] for target in targets]
    if len(set(focused)) != len(focused):
        fail("two M9 behavioural targets alias the same broad suite")
        return
    for target, module in zip(targets, modules):
        recipe = recipes[target]
        if module not in recipe or "unittest discover" in recipe:
            fail(f"{target} is not focused on {module}")
            return

    gate_line = next(
        (line for line in logical_make_lines(makefile) if line.startswith("gate-m9:")),
        "",
    )
    required_dependencies = {"gate-m8", "valgrind-mcp", *targets}
    dependencies = set(gate_line.partition(":")[2].split())
    absent = sorted(required_dependencies - dependencies)
    if absent:
        fail("gate-m9 dependencies are incomplete: " + ", ".join(absent))
        return
    if "scripts/gate_m9.py" not in recipes["gate-m9"] or "--skip-suites" not in recipes["gate-m9"]:
        fail("gate-m9 does not run its static audit after the focused suites")
        return

    phony = next(
        (line for line in logical_make_lines(makefile) if line.startswith(".PHONY:")),
        "",
    )
    missing_phony = [target for target in (*targets, "gate-m9") if target not in phony]
    if missing_phony:
        fail("M9 targets are not phony: " + ", ".join(missing_phony))
        return
    help_recipe = make_recipe("help")
    if any(target not in help_recipe for target in (*targets, "gate-m9")):
        fail("Makefile help omits an M9 target")
        return
    ok("all five HARNESS targets and gate-m9 are distinct and fully wired")


def run_suite(name: str, module: str, minimum: int, build_dir: Path) -> None:
    try:
        result = run(
            [sys.executable, "-m", "unittest", "-v", module],
            env={**os.environ, "BUILD_DIR": str(build_dir)},
            timeout=900,
        )
    except subprocess.TimeoutExpired:
        fail(f"{name} exceeded the 900 second gate budget")
        return
    output = result.stdout + result.stderr
    if result.returncode != 0:
        fail(f"{name} failed:\n{output}")
        return
    count = re.search(r"Ran (\d+) tests?", output)
    skipped = re.search(r"skipped=(\d+)", output)
    if count is None or int(count.group(1)) < minimum:
        fail(f"{name} ran fewer than {minimum} tests:\n{output}")
        return
    if skipped is not None and int(skipped.group(1)) != 0:
        fail(f"{name} skipped tests under the gate:\n{output}")
        return
    ok(f"{name} ({count.group(1)} tests)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default="build")
    parser.add_argument(
        "--skip-suites",
        action="store_true",
        help="check static/build properties only (Makefile already ran suites)",
    )
    arguments = parser.parse_args()
    build_dir = Path(arguments.build_dir)
    if not build_dir.is_absolute():
        build_dir = ROOT / build_dir

    check_sources_and_build(build_dir)
    check_transport_dispatch()
    check_modern_and_legacy_are_isolated()
    check_version_and_fallback_classification()
    check_one_epoll_driven_curl_engine()
    check_buffers_and_stream_cancellation()
    check_security_options_and_c_boundary()
    check_cache_ttl_and_partitioning()
    check_fixture_and_test_matrix()
    check_make_wiring()

    if not arguments.skip_suites:
        for name, module, minimum in SUITES:
            run_suite(name, module, minimum, build_dir)

    if FAILED:
        print("M9 gate failed", file=sys.stderr)
        return 1
    print("M9 gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
