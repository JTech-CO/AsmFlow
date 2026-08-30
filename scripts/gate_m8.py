#!/usr/bin/env python3
"""M8 gate: MCP stdio process supervision (HARNESS.md M8).

The integration suites own the process-level claims.  This script checks the
properties that a successful run cannot prove by itself: execve receives
literal argv/envp vectors, M8 instantiates only stdio transports, protocol eras
remain separate, every deadline is monotonic, all process-facing storage is
bounded, and no lifecycle policy migrated into a C shim.
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

MODERN_TESTS = (
    "tests.test_mcp_process_lifecycle.McpProcessLifecycleTests."
    "test_modern_startup_method_sequence",
    "tests.test_mcp_process_lifecycle.McpProcessLifecycleTests."
    "test_invalid_modern_success_without_legacy_fails_before_inventory",
)
LEGACY_TESTS = (
    "tests.test_mcp_process_lifecycle.McpProcessLifecycleTests."
    "test_legacy_startup_method_sequence",
    "tests.test_mcp_process_lifecycle.McpProcessLifecycleTests."
    "test_invalid_modern_success_falls_back_without_era_interleave",
    "tests.test_mcp_process_lifecycle.McpProcessLifecycleTests."
    "test_invalid_legacy_success_fails_before_initialized",
    "tests.test_mcp_process_supervision.McpLegacyProcessResetTests",
)
MALFORMED_TESTS = (
    "tests.test_mcp_process_supervision.McpMalformedStdioTests",
    "tests.test_mcp_process_supervision.McpRequiredReadinessTests",
)
LIFECYCLE_TESTS = (
    "tests.test_mcp_process_lifecycle.McpProcessLifecycleTests."
    "test_arguments_are_literal_and_never_reach_a_shell",
    "tests.test_mcp_process_lifecycle.McpProcessLifecycleTests."
    "test_environment_is_allowlisted_and_secret_sources_do_not_leak",
    "tests.test_mcp_process_lifecycle.McpProcessLifecycleTests."
    "test_configured_working_directory_is_applied",
    "tests.test_mcp_process_lifecycle.McpProcessLifecycleTests."
    "test_child_is_gone_after_daemon_shutdown",
    "tests.test_mcp_process_supervision.McpRequestTimeoutTests",
)
CRASH_LOOP_TESTS = (
    "tests.test_mcp_process_supervision.McpCrashLoopTests",
)
ZOMBIE_SOAK_TESTS = (
    "tests.test_mcp_process_supervision.McpZombieSoakTests",
)

SUITES = (
    ("modern stdio", MODERN_TESTS),
    ("legacy stdio", LEGACY_TESTS),
    ("malformed stdio", MALFORMED_TESTS),
    ("process lifecycle", LIFECYCLE_TESTS),
    ("crash loop", CRASH_LOOP_TESTS),
    ("zombie soak", ZOMBIE_SOAK_TESTS),
)


def fail(message: str) -> None:
    global FAILED
    FAILED = True
    print(f"[fail] {message}", file=sys.stderr)


def ok(label: str) -> None:
    print(f"[ok] {label}")


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def strip_asm_comments(text: str) -> str:
    """Remove semicolon comments without treating semicolons in strings as code."""
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
    """Remove C comments while preserving strings and line boundaries."""
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
    match = re.search(r"(?m)^\s*global\s+", source[start + len(name) + 1 :])
    if match is None:
        return source[start:]
    return source[start : start + len(name) + 1 + match.start()]


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        **kwargs,
    )


def check_build_contains_the_supervisor(build_dir: Path) -> None:
    daemon = build_dir / "debug" / "asmflowd"
    tests = build_dir / "debug" / "asmflow-tests"
    missing = [str(path) for path in (daemon, tests) if not path.is_file()]
    if missing:
        fail("missing M8 build products: " + ", ".join(missing))
        return
    result = run(["nm", "--defined-only", str(daemon)])
    if result.returncode != 0:
        fail(f"nm could not inspect {daemon}: {result.stderr}")
        return
    symbols = {
        line.split()[-1] for line in result.stdout.splitlines() if line.strip()
    }
    required = {
        "af_mcp_sup_init",
        "af_mcp_spawn",
        "af_mcp_frame_lines",
        "af_mcp_request",
        "af_mcp_advance",
        "af_mcp_manual_restart",
        "af_mcp_reset",
    }
    absent = sorted(required - symbols)
    if absent:
        fail("asmflowd is missing MCP supervisor symbols: " + ", ".join(absent))
        return
    ok(f"debug daemon contains the assembly MCP supervisor ({len(required)} anchors)")


def check_direct_argv_exec_without_a_shell() -> None:
    source = code_of("src/mcp/mcp_process.asm")
    if len(re.findall(r"\bcall\s+af_sys_execve\b", source)) != 1:
        fail("MCP process spawning must have exactly one direct execve call")
        return
    required = ("af_sys_fork", "af_mcp_build_argv", "af_mcp_build_env")
    missing = [name for name in required if not re.search(rf"\bcall\s+{name}\b", source)]
    if missing:
        fail("the direct spawn path is missing: " + ", ".join(missing))
        return
    forbidden = re.search(
        r"/bin/(?:ba)?sh|\bcall\s+(?:system|popen|execlp?|execvp|posix_spawn)\b",
        source,
    )
    if forbidden:
        fail(f"the MCP spawn path can invoke a shell: {forbidden.group(0)}")
        return
    exec_at = source.find("call    af_sys_execve")
    window = source[max(0, exec_at - 500) : exec_at]
    for token in ("MCP_COMMAND", "SP_ARGV", "SP_ENVP"):
        if token not in window:
            fail(f"execve is not visibly fed from the direct {token} vector")
            return
    ok("MCP children use one direct fork/execve path with literal argv")


def check_environment_is_constructed_from_the_allowlist() -> None:
    source = code_of("src/mcp/mcp_process.asm")
    body = function_body(source, "af_mcp_build_env")
    required = (
        "MCP_ENV_ALLOW_COUNT",
        "MCP_ENV_PAIR_COUNT",
        "af_add_size",
        "af_mul_size",
    )
    missing = [token for token in required if token not in body]
    if missing:
        fail("the environment builder lacks: " + ", ".join(missing))
        return
    if "af_cfg_getenv" not in source:
        fail("the environment entry helpers do not resolve named variables")
        return
    if re.search(r"\benviron\b|\bclearenv\b|\bsetenv\b", source):
        fail("the child environment is derived from ambient environ")
        return
    ok("child envp is built only from env_allow and mapped secret references")


def check_m8_is_stdio_only() -> None:
    supervisor = code_of("src/mcp/mcp_supervisor.asm")
    # M9 legitimately adds curl calls below mcp_http*.asm and the shared
    # supervisor/table owns both transport engines. M8 isolation is the narrower
    # invariant: the stdio framing/process implementation itself may never
    # acquire an HTTP dependency. Include any future explicitly named stdio
    # module in that audit while deliberately excluding mcp_http*.asm.
    stdio_paths = [
        ROOT / "src/mcp/mcp_process.asm",
        ROOT / "src/mcp/mcp_frame.asm",
        *sorted((ROOT / "src" / "mcp").glob("mcp_stdio*.asm")),
    ]
    stdio_code = "\n".join(
        code_of(str(path.relative_to(ROOT)).replace("\\", "/"))
        for path in stdio_paths
    )
    # The M8 table originally contained only stdio entries. M9 deliberately
    # makes it transport-neutral, so preserve the isolation property at the
    # start dispatcher: an HTTP slot must be routed to its adapter before the
    # process-only af_mcp_spawn path can be selected.
    start = function_body(supervisor, "af_mcp_start")
    dispatch_tokens = (
        "MC_TRANSPORT",
        "AF_TRANSPORT_STREAMABLE_HTTP",
        "af_mcp_http_start",
        "af_mcp_spawn",
    )
    missing = [token for token in dispatch_tokens if token not in start]
    if missing:
        fail("the shared MCP start path lacks transport isolation: " + ", ".join(missing))
        return
    if re.search(
        r"\b(?:call|extern)\s+(?:af_curl|af_mcp_http|af_http|curl_)",
        stdio_code,
    ):
        fail("an MCP stdio/process/frame module reaches the HTTP adapter")
        return
    ok("MCP start dispatch is explicit; stdio/process/frame import no HTTP transport")


def check_modern_and_legacy_adapters_are_separate() -> None:
    source = code_of("src/mcp/mcp_era.asm")
    modern = function_body(source, "af_mcp_validate_modern_discover")
    legacy = function_body(source, "af_mcp_validate_legacy_initialize")
    modern_required = (
        "CL_RESULT",
        "af_json_parse",
        "af_json_get_array",
        "af_json_array_at",
        "af_json_string_of",
        "v_modern2",
    )
    legacy_required = (
        "CL_RESULT",
        "af_json_parse",
        "af_json_get_string",
        "v_legacy2",
    )
    missing_modern = [token for token in modern_required if token not in modern]
    missing_legacy = [token for token in legacy_required if token not in legacy]
    if missing_modern or missing_legacy:
        fail(
            "era validators are incomplete: modern="
            + ",".join(missing_modern)
            + " legacy="
            + ",".join(missing_legacy)
        )
        return
    if "v_legacy2" in modern or "v_modern2" in legacy:
        fail("modern and legacy version state is interleaved")
        return
    inventory = function_body(source, "af_mcp_begin_inventory")
    modern_meta = (
        "io.modelcontextprotocol/protocolVersion",
        "io.modelcontextprotocol/clientInfo",
        "io.modelcontextprotocol/clientCapabilities",
    )
    if not all(token in source for token in modern_meta):
        fail("modern inventory does not carry the required metadata shape")
        return
    if "xor     r13d, r13d" not in inventory:
        fail("legacy inventory does not explicitly omit modern params")
        return
    collect = function_body(source, "af_mcp_collect_list")
    canonical_inventory = (
        "af_json_parse",
        "af_json_get_array",
        "af_jsonc_dump",
        "AF_MCP_INVENTORY_MAX",
        "AF_MC_F_TOOLS_CURRENT",
        "AF_MCP_S_DEGRADED",
    )
    missing_inventory = [
        token for token in canonical_inventory if token not in collect
    ]
    if missing_inventory:
        fail(
            "inventory arrays are not bounded/transactional: "
            + ", ".join(missing_inventory)
        )
        return
    if "af_mcp_count_entries" in source:
        fail("inventory count still relies on a permissive JSON text scan")
        return
    ok("modern discovery and legacy initialize use distinct bounded adapters")


def check_all_deadlines_are_monotonic() -> None:
    supervisor = code_of("src/mcp/mcp_supervisor.asm")
    rpc = code_of("src/mcp/mcp_rpc.asm")
    all_mcp = supervisor + "\n" + rpc + "\n" + code_of("src/mcp/mcp_era.asm")
    if "af_realtime" in all_mcp or "CLOCK_REALTIME" in all_mcp:
        fail("an MCP deadline reads the realtime clock")
        return
    request = function_body(rpc, "af_mcp_request")
    sweep = function_body(rpc, "af_mcp_sweep_calls")
    restart = function_body(supervisor, "af_mcp_schedule_restart")
    shutdown = function_body(supervisor, "af_mcp_arm_shutdown_grace")
    checks = (
        (
            "request deadline",
            request,
            ("af_monotonic_now", "af_mcp_call_alloc", "af_mul_size", "af_add_size"),
        ),
        ("call timeout sweep", sweep, ("CL_DEADLINE",)),
        ("restart/backoff deadline", restart, ("af_monotonic_now", "MC_NEXT_START")),
        ("shutdown deadline", shutdown, ("af_monotonic_now", "MC_NEXT_START")),
    )
    for label, body, tokens in checks:
        missing = [token for token in tokens if token not in body]
        if missing:
            fail(f"{label} is missing monotonic state: {', '.join(missing)}")
            return
    allocation = function_body(rpc, "af_mcp_call_alloc")
    if "CL_DEADLINE" not in allocation:
        fail("the computed request deadline is not stored in the call record")
        return
    if "CLOCK_MONOTONIC" not in supervisor:
        fail("the MCP supervisor timerfd is not monotonic")
        return
    ok("request, restart, and shutdown deadlines are monotonic")


def check_buffers_and_tables_are_bounded() -> None:
    public = code_of("include/mcp.inc")
    required_limits = (
        "AF_MCP_MAX_CHILDREN",
        "AF_MCP_MAX_CALLS",
        "AF_MCP_INVENTORY_MAX",
        "AF_MCP_STDERR_KEEP",
        "AF_MCP_FRAME_HARD_MAX",
        "AF_MCP_INBOX_MAX",
        "AF_MCP_STDERR_LINE_HARD_MAX",
    )
    missing = [
        name
        for name in required_limits
        if not re.search(rf"(?m)^\s*%define\s+{name}\s+\S+", public)
    ]
    if missing:
        fail("MCP public bounds are missing: " + ", ".join(missing))
        return
    supervisor = code_of("src/mcp/mcp_supervisor.asm")
    frame = code_of("src/mcp/mcp_frame.asm")
    rpc = code_of("src/mcp/mcp_rpc.asm")
    process = code_of("src/mcp/mcp_process.asm")
    anchors = (
        ("child table capacity", supervisor, "AF_MCP_MAX_CHILDREN"),
        ("call table capacity", function_body(rpc, "af_mcp_call_alloc"), "AF_MCP_MAX_CALLS"),
        ("stdout frame ceiling", frame, "MC_FRAME_MAX"),
        ("stdout accumulation ceiling", supervisor, "AF_MCP_INBOX_MAX"),
        ("stderr line ceiling", frame, "MC_STDERR_MAX"),
        ("stderr retained tail", frame, "AF_MCP_STDERR_KEEP"),
        ("checked argv/env arithmetic", process, "af_mul_size"),
    )
    for label, source, token in anchors:
        if token not in source:
            fail(f"{label} is not enforced ({token} absent)")
            return
    ok(f"MCP buffers/tables expose and enforce {len(required_limits)} hard bounds")


def check_no_mcp_policy_lives_in_c() -> None:
    forbidden_policy = re.compile(
        r"\b(?:mcp|restart|backoff|crash_loop|supervisor|fallback|routing)\b",
        re.IGNORECASE,
    )
    forbidden_calls = re.compile(
        r"\b(?:system|popen|fork|execve|waitpid|kill|setenv|unsetenv)\s*\("
    )
    offenders = []
    for path in sorted((ROOT / "src").rglob("*.c")):
        source = strip_c_comments(path.read_text(encoding="utf-8"))
        match = forbidden_policy.search(source) or forbidden_calls.search(source)
        if match:
            offenders.append(f"{path.relative_to(ROOT)}:{match.group(0)}")
    if offenders:
        fail("MCP/process policy appears in C: " + ", ".join(offenders))
        return
    ok("production C shims contain no MCP/process supervision policy")


def check_readiness_and_tool_confirmation_are_wired() -> None:
    endpoints = code_of("src/http/http_endpoints.asm")
    control = code_of("src/control/control_methods.asm")
    supervisor = code_of("src/mcp/mcp_supervisor.asm")
    if "af_mcp_required_ready" not in endpoints:
        fail("/readyz does not consult required MCP readiness")
        return
    required_counts = function_body(supervisor, "af_mcp_required_counts")
    if "AF_MC_F_TOOLS_CURRENT" not in required_counts:
        fail("required MCP readiness accepts an uncommitted or stale tools cache")
        return
    tool_test = function_body(control, "af_ctl_m_mcp_tool_test")
    if not tool_test:
        fail("the mcp.tool_test control method is missing")
        return
    for token in ("k_confirmed", "AF_E_MCP_UNCONFIRMED"):
        if token not in tool_test:
            fail(f"mcp.tool_test does not enforce {token}")
            return
    ok("required MCP readiness and explicit tool-test confirmation are wired")


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


def check_named_make_targets_are_focused() -> None:
    targets = (
        "test-mcp-stdio-modern",
        "test-mcp-stdio-legacy",
        "test-mcp-stdio-malformed",
        "test-mcp-process-lifecycle",
        "test-mcp-crash-loop",
        "test-mcp-zombie-soak",
        "valgrind-mcp",
        "gate-m8",
    )
    recipes = {target: make_recipe(target) for target in targets}
    missing = [target for target, recipe in recipes.items() if not recipe]
    if missing:
        fail("Makefile is missing M8 recipes: " + ", ".join(missing))
        return
    focused = [recipes[target] for target in targets[:6]]
    if len(set(focused)) != len(focused):
        fail("two M8 behavioural targets alias the same broad suite")
        return
    if any("unittest discover" in recipe for recipe in focused):
        fail("an M8 focused target runs unittest discovery")
        return
    ok("all six HARNESS M8 targets have distinct focused recipes")


def run_suite(name: str, tests: tuple[str, ...], build_dir: Path) -> None:
    result = subprocess.run(
        [sys.executable, "-m", "unittest", "-v", *tests],
        cwd=ROOT,
        env={**os.environ, "BUILD_DIR": str(build_dir)},
        capture_output=True,
        text=True,
        check=False,
        timeout=900,
    )
    output = result.stdout + result.stderr
    if result.returncode != 0:
        fail(f"{name} failed:\n{output}")
        return
    count = re.search(r"Ran (\d+) tests?", output)
    skipped = re.search(r"skipped=(\d+)", output)
    if count is None or int(count.group(1)) == 0:
        fail(f"{name} ran zero or an uncountable number of tests:\n{output}")
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

    check_build_contains_the_supervisor(build_dir)
    check_direct_argv_exec_without_a_shell()
    check_environment_is_constructed_from_the_allowlist()
    check_m8_is_stdio_only()
    check_modern_and_legacy_adapters_are_separate()
    check_all_deadlines_are_monotonic()
    check_buffers_and_tables_are_bounded()
    check_no_mcp_policy_lives_in_c()
    check_readiness_and_tool_confirmation_are_wired()
    check_named_make_targets_are_focused()

    if not arguments.skip_suites:
        for name, tests in SUITES:
            run_suite(name, tests, build_dir)

    if FAILED:
        print("M8 gate failed", file=sys.stderr)
        return 1
    print("M8 gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
