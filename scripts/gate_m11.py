#!/usr/bin/env python3
"""M11 gate: security, observability, and recovery (HARNESS.md M11).

The focused suites own process-level behavior: listener authentication, secret
corpus non-disclosure, owner-only filesystem state, bounded fuzz campaigns,
SQLite backup/restore, SIGKILL recovery, and ordered SIGTERM draining.  This
audit checks the structural claims those runs cannot prove alone: all M11
runtime code is linked into the daemon, redaction stays structured, authority
files and peer credentials fail closed, diagnostics cannot opt into payloads,
backup/restore uses SQLite's coherent API, shutdown keeps one reactor alive,
audit rows have no payload column, and Make cannot silently omit a suite.
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
    ("security", "tests.test_security", 4),
    ("redaction", "tests.test_redaction", 3),
    ("permissions", "tests.test_permissions", 7),
    ("fuzz smoke", "tests.test_fuzz_smoke", 3),
    ("crash recovery", "tests.test_crash_recovery", 1),
    ("graceful shutdown", "tests.test_graceful_shutdown", 2),
)

TARGETS = (
    "test-security",
    "test-redaction",
    "test-permissions",
    "fuzz-smoke",
    "test-backup-restore",
    "test-crash-recovery",
    "test-graceful-shutdown",
)

FUZZ_TARGETS = {
    "json",
    "config",
    "http",
    "url",
    "sse",
    "mcp",
    "control",
    "redaction",
}

REQUIRED_FILES = {
    "src/config/redaction.asm",
    "src/platform/linux_x86_64/file_security.asm",
    "src/storage/backup.asm",
    "tests/asm/test_m11_security.asm",
    "tests/asm/test_m11_fuzz.asm",
    "tests/asm/test_m11_backup.asm",
    "tests/test_security.py",
    "tests/test_redaction.py",
    "tests/test_permissions.py",
    "tests/test_fuzz_smoke.py",
    "tests/test_crash_recovery.py",
    "tests/test_graceful_shutdown.py",
    "tests/fixtures/fuzz/seeds.json",
}

DAEMON_SYMBOLS = {
    "af_buf_clear_secure",
    "af_buf_consume_secure",
    "af_redact_header_sensitive",
    "af_redact_header_value",
    "af_fs_check_private_dir",
    "af_fs_check_private_file",
    "af_fs_check_config_path",
    "af_fs_prepare_database_path",
    "af_ctl_validate_peer_credentials",
    "af_ctl_m_diagnostics_export",
    "af_repo_record_audit",
    "af_db_backup_to_path",
    "af_db_backup_open_verified",
    "af_db_backup_verify_path",
    "af_db_restore_to_path",
    "af_http_server_stop_accepting",
    "af_http_server_inflight_count",
}


def fail(message: str) -> None:
    global FAILED
    FAILED = True
    print(f"[fail] {message}", file=sys.stderr)


def ok(label: str) -> None:
    print(f"[ok] {label}")


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        **kwargs,
    )


def strip_asm_comments(text: str) -> str:
    lines: list[str] = []
    for line in text.splitlines():
        quote: str | None = None
        escaped = False
        kept: list[str] = []
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
        value = "".join(kept)
        if value.strip():
            lines.append(value)
    return "\n".join(lines)


def strip_c_comments(text: str) -> str:
    output: list[str] = []
    index = 0
    state = "code"
    quote = ""
    while index < len(text):
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "line":
            if char == "\n":
                output.append(char)
                state = "code"
            index += 1
            continue
        if state == "block":
            if char == "*" and following == "/":
                state = "code"
                index += 2
            else:
                if char == "\n":
                    output.append(char)
                index += 1
            continue
        if state == "string":
            output.append(char)
            if char == "\\" and index + 1 < len(text):
                output.append(text[index + 1])
                index += 2
                continue
            if char == quote:
                state = "code"
            index += 1
            continue
        if char == "/" and following == "/":
            state = "line"
            index += 2
        elif char == "/" and following == "*":
            state = "block"
            index += 2
        else:
            output.append(char)
            if char in ("'", '"'):
                state = "string"
                quote = char
            index += 1
    return "".join(output)


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


def check_required_assets_and_build(build_dir: Path) -> None:
    missing = sorted(path for path in REQUIRED_FILES if not (ROOT / path).is_file())
    if missing:
        fail("missing M11 implementation/test assets: " + ", ".join(missing))
        return

    daemon = build_dir / "debug" / "asmflowd"
    tests = build_dir / "debug" / "asmflow-tests"
    missing_build = [str(path) for path in (daemon, tests) if not path.is_file()]
    if missing_build:
        fail("missing M11 debug build products: " + ", ".join(missing_build))
        return
    try:
        result = run(["nm", "--defined-only", str(daemon)])
    except OSError as error:
        fail(f"nm could not inspect {daemon}: {error}")
        return
    if result.returncode != 0:
        fail(f"nm could not inspect {daemon}: {result.stderr}")
        return
    symbols = {
        line.split()[-1] for line in result.stdout.splitlines() if line.strip()
    }
    absent = sorted(DAEMON_SYMBOLS - symbols)
    if absent:
        fail("asmflowd is missing M11 runtime symbols: " + ", ".join(absent))
        return
    ok(f"debug daemon contains all {len(DAEMON_SYMBOLS)} M11 runtime anchors")


def check_structured_redaction_and_diagnostics() -> None:
    redaction = code_of("src/config/redaction.asm")
    required_redaction = (
        "[REDACTED]",
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "af_mem_eq_ci",
        "CFG_LOG_REDACT_COUNT",
        "CFG_LST_AUTH",
        "CFG_PROVIDER_COUNT",
        "CFG_MCP_COUNT",
        "AUTH_HEADER",
        "af_buf_append",
    )
    missing = [token for token in required_redaction if token not in redaction]
    if missing:
        fail("structured redaction registry lacks: " + ", ".join(missing))
        return

    methods = code_of("src/control/control_methods.asm")
    diagnostics = function_body(methods, "af_ctl_m_diagnostics_export")
    required_diagnostics = (
        "k_format_version",
        "k_generated_at_ms",
        "k_version",
        "k_target",
        "k_build",
        "k_protocol_ver",
        "af_ctl_write_config_hash",
        "k_last_error",
        "RT_LAST_ERROR_AT_MS",
        "k_dependencies",
        "af_ctl_m_config_current",
        "af_ctl_m_providers_list",
        "af_ctl_m_routes_list",
        "af_ctl_m_mcp_list",
        "k_redacted",
        "k_payloads_included",
        "k_secrets_included",
    )
    missing = [token for token in required_diagnostics if token not in diagnostics]
    if missing:
        fail("diagnostics.export lacks required redacted metadata: " + ", ".join(missing))
        return
    if "k_config_hash" not in methods:
        fail("diagnostics.export has no canonical config_hash output key")
        return
    forbidden = (
        "k_prompt",
        "k_response_body",
        "k_arguments",
        "k_tool_result",
        "MC_STDERR",
    )
    leaked = [token for token in forbidden if token in diagnostics]
    if leaked:
        fail("diagnostics.export can include payload material: " + ", ".join(leaked))
        return
    if diagnostics.count("xor     edx, edx") < 2:
        fail("diagnostics.export does not hard-code payloads/secrets as false")
        return

    secret_memory = "\n".join(
        code_of(path)
        for path in (
            "src/memory/buffer.asm",
            "src/http/http_parse.asm",
            "src/http/http_server.asm",
            "src/providers/provider_adapter.asm",
        )
    )
    required_wipes = (
        "af_buf_clear_secure",
        "af_buf_consume_secure",
        "af_buf_free_secure",
    )
    missing = [token for token in required_wipes if token not in secret_memory]
    if missing:
        fail("credential/request buffer wiping lacks: " + ", ".join(missing))
        return
    ok("redaction is structured and diagnostics hard-code payload/secret exclusion")


def check_auth_permissions_and_audit() -> None:
    files = code_of("src/platform/linux_x86_64/file_security.asm")
    required_files = (
        "AT_SYMLINK_NOFOLLOW",
        "S_IFREG",
        "S_IFDIR",
        "GROUP_WORLD_MASK",
        "cmp     eax, 0o700",
        "test    eax, 0o400",
        "test    eax, 0o200",
        "af_sys_getuid",
    )
    missing = [token for token in required_files if token not in files]
    if missing:
        fail("owner-only file policy lacks: " + ", ".join(missing))
        return

    config = code_of("src/config/config_top.asm")
    required_config = ("O_NOFOLLOW", "O_NONBLOCK", "af_sys_fstat", "CFG_S_IFREG")
    missing = [token for token in required_config if token not in config]
    if missing:
        fail("config open/type validation lacks: " + ", ".join(missing))
        return

    socket_policy = code_of("src/control/control_socket.asm")
    if "0o700" not in socket_policy or "0o600" not in socket_policy:
        fail("control socket does not enforce parent 0700 and socket 0600")
        return
    daemon = code_of("src/platform/linux_x86_64/daemon.asm")
    if "af_sys_umask" not in daemon or "0o077" not in daemon:
        fail("daemon does not establish an owner-only creation umask")
        return

    control = code_of("src/control/control_server.asm")
    peer = function_body(control, "af_ctl_validate_peer_credentials")
    for token in ("SO_PEERCRED", "af_sys_geteuid"):
        if token not in control:
            fail(f"control peer authentication does not use {token}")
            return
    for token in ("cmp     rdx, 12", "AF_E_PERM", "CONN_PEER_UID", "CONN_PEER_PID"):
        if token not in peer:
            fail(f"control peer validation does not fail closed on {token}")
            return

    migrations = code_of("src/storage/migrations.asm")
    audit = migrations[
        migrations.find("m2_audit_events:") : migrations.find("sql_select_version:")
    ]
    required_columns = (
        "occurred_at_ms",
        "peer_uid",
        "peer_pid",
        "action",
        "outcome",
        "status",
    )
    missing = [column for column in required_columns if column not in audit]
    if missing:
        fail("audit_events schema lacks: " + ", ".join(missing))
        return
    forbidden_columns = ("payload", "params", "credential", "secret", "environment")
    leaked = [column for column in forbidden_columns if column in audit.lower()]
    if leaked:
        fail("audit_events schema persists sensitive input: " + ", ".join(leaked))
        return
    methods = code_of("src/control/control_methods.asm")
    if "af_ctl_record_audit" not in methods or "af_repo_record_audit" not in methods:
        fail("mutating control dispatch is not connected to the audit repository")
        return
    ok("auth, SO_PEERCRED, local file modes, and payload-free audit rows fail closed")


def check_backup_restore_and_policy_boundary() -> None:
    backup = code_of("src/storage/backup.asm")
    required = (
        "sqlite3_backup_init",
        "sqlite3_backup_step",
        "sqlite3_backup_finish",
        "sqlite3_backup_pagecount",
        "AF_BK_O_EXCL",
        "AF_BK_O_NOFOLLOW",
        "AF_BK_SQLITE_OPEN_NOFOLLOW",
        "af_db_integrity_check",
        "af_sys_fsync",
        "af_db_backup_open_verified",
        "af_db_backup_to_path",
        "af_db_restore_to_path",
    )
    missing = [token for token in required if token not in backup]
    if missing:
        fail("coherent bounded backup/restore lacks: " + ", ".join(missing))
        return

    c_code = "\n".join(
        strip_c_comments(path.read_text(encoding="utf-8"))
        for path in sorted((ROOT / "src/ffi").glob("*.c"))
    )
    policy_tokens = (
        "diagnostics.export",
        "audit_events",
        "shutdown.accepts_stopped",
        "AF_SHUTDOWN_GRACE_NS",
        "[REDACTED]",
    )
    leaked = [token for token in policy_tokens if token in c_code]
    if leaked:
        fail("M11 domain policy migrated into a C shim: " + ", ".join(leaked))
        return
    ok("backup/restore is coherent, no-overwrite, no-follow, verified, and Assembly-owned")


def check_shutdown_and_crash_contracts() -> None:
    daemon = code_of("src/platform/linux_x86_64/daemon.asm")
    required = (
        "AF_SHUTDOWN_GRACE_NS",
        "RT_SHUTDOWN_DEADLINE_NS",
        "RT_TERM_SIGNALS",
        "af_http_server_stop_accepting",
        "af_http_server_inflight_count",
        "af_loop_step",
        "shutdown.accepts_stopped",
        "shutdown.inflight_drained",
        "shutdown.inflight_deadline",
        "shutdown.mcp_stopped",
        "shutdown.db_closed",
    )
    missing = [token for token in required if token not in daemon]
    if missing:
        fail("bounded graceful shutdown lacks: " + ", ".join(missing))
        return
    run_body = function_body(daemon, "af_daemon_run")
    mcp_stop = run_body.find("call    af_mcp_sup_shutdown")
    db_close = run_body.find("call    af_db_close")
    if mcp_stop < 0 or db_close < 0 or mcp_stop >= db_close:
        fail("daemon teardown does not stop MCP before closing SQLite")
        return

    http = code_of("src/http/http_server.asm")
    stop = function_body(http, "af_http_server_stop_accepting")
    for token in ("af_loop_del", "af_sys_close", "HC_F_CLOSING", "HC_F_UPSTREAM"):
        if token not in stop:
            fail(f"HTTP drain does not enforce {token}")
            return

    crash = read("tests/test_crash_recovery.py")
    for token in ("SIGKILL", "schema_migrations", "wal", "stale", "socket", "integrity_check"):
        if token.lower() not in crash.lower():
            fail(f"SIGKILL recovery drill does not cover {token}")
            return
    graceful = read("tests/test_graceful_shutdown.py")
    for token in (
        "shutdown.accepts_stopped",
        "shutdown.inflight_drained",
        "shutdown.inflight_deadline",
        "shutdown.mcp_stopped",
        "shutdown.db_closed",
    ):
        if token not in graceful:
            fail(f"SIGTERM drill does not assert {token}")
            return
    ok("one reactor drains in flight work, then stops MCP before DB close; SIGKILL is drilled")


def _test_count(relative: str) -> int:
    source = read(relative)
    tree = ast.parse(source, filename=relative)
    return sum(
        1
        for node in ast.walk(tree)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name.startswith("test_")
    )


def _seed_bytes(entry: dict[str, object]) -> bytes:
    has_utf8 = "utf8" in entry
    has_hex = "hex" in entry
    if has_utf8 == has_hex:
        raise ValueError("each seed must have exactly one of utf8 or hex")
    if has_utf8:
        value = entry["utf8"]
        if not isinstance(value, str):
            raise ValueError("utf8 seed value is not a string")
        return value.encode("utf-8")
    value = entry["hex"]
    if not isinstance(value, str):
        raise ValueError("hex seed value is not a string")
    return bytes.fromhex(value)


def check_test_and_fuzz_matrix() -> None:
    suite_markers = {
        "tests/test_security.py": (
            '"0.0.0.0"',
            '"/healthz"',
            '"/readyz"',
            '"/v1/models"',
            '"/v1/responses"',
            '"/v1/chat/completions"',
            "X-Injected",
            "audit_events",
        ),
        "tests/test_redaction.py": (
            "diagnostics.export",
            "asmflow.db-wal",
            "asmflowctl",
            "payloads_included",
            "secrets_included",
            "stdout",
            "stderr",
        ),
        "tests/test_permissions.py": (
            "os.mkfifo",
            "symlink_to",
            "0o644",
            "0o755",
            "0o700",
            "0o600",
            '"-wal"',
            '"-shm"',
        ),
    }
    for _, module, minimum in SUITES:
        relative = module.replace(".", "/") + ".py"
        try:
            count = _test_count(relative)
        except (OSError, UnicodeError, SyntaxError) as error:
            fail(f"{relative} does not parse: {error}")
            return
        if count < minimum:
            fail(f"{relative} has {count} tests; the M11 floor is {minimum}")
            return
        missing = [
            marker
            for marker in suite_markers.get(relative, ())
            if marker not in read(relative)
        ]
        if missing:
            fail(f"{relative} lacks M11 matrix cases: " + ", ".join(missing))
            return

    try:
        manifest = json.loads(read("tests/fixtures/fuzz/seeds.json"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"M11 fuzz seed manifest is invalid UTF-8 JSON: {error}")
        return
    if set(manifest) != FUZZ_TARGETS:
        fail(
            "fuzz target matrix is "
            + ", ".join(sorted(manifest))
            + "; expected "
            + ", ".join(sorted(FUZZ_TARGETS))
        )
        return
    try:
        for target in sorted(FUZZ_TARGETS):
            entries = manifest[target]
            if not isinstance(entries, list) or not entries:
                raise ValueError(f"{target} has no committed seed")
            names: set[str] = set()
            for entry in entries:
                if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
                    raise ValueError(f"{target} has a seed without a string name")
                name = entry["name"]
                if name in names:
                    raise ValueError(f"{target} repeats seed name {name!r}")
                names.add(name)
                if len(_seed_bytes(entry)) > 8192:
                    raise ValueError(f"{target}/{name} exceeds 8192 bytes")
    except (TypeError, ValueError) as error:
        fail(f"M11 fuzz seed contract failed: {error}")
        return

    driver = read("tests/test_fuzz_smoke.py")
    for token in (
        "RLIMIT_CORE",
        "RLIMIT_CPU",
        "RLIMIT_AS",
        "subprocess.run",
        "timeout=CASE_TIMEOUT_SECONDS",
        "MAX_INPUT_BYTES",
        "m11/fuzz/",
        "FUZZ_SEED",
    ):
        if token not in driver:
            fail(f"bounded deterministic fuzz driver lacks {token}")
            return
    try:
        driver_tree = ast.parse(driver, filename="tests/test_fuzz_smoke.py")
        driver_targets: set[str] | None = None
        for node in driver_tree.body:
            if not isinstance(node, ast.Assign):
                continue
            if not any(isinstance(target, ast.Name) and target.id == "TARGETS" for target in node.targets):
                continue
            value = ast.literal_eval(node.value)
            driver_targets = set(value)
            break
    except (SyntaxError, ValueError, TypeError) as error:
        fail(f"could not read fuzz driver TARGETS: {error}")
        return
    if driver_targets != FUZZ_TARGETS:
        fail("fuzz driver TARGETS do not exactly match the HARNESS/seed matrix")
        return

    native_fuzz = read("tests/asm/test_m11_fuzz.asm")
    native_targets = set(
        re.findall(r'AF_TEST\s+"m11/fuzz/([a-z_]+)/input"', native_fuzz)
    )
    if native_targets != FUZZ_TARGETS:
        fail("native fuzz registrations do not exactly match the seed manifest")
        return
    if len(re.findall(r'AF_TEST\s+"backup/', read("tests/asm/test_m11_backup.asm"))) < 5:
        fail("native backup/restore regression matrix has fewer than five tests")
        return
    native_security = read("tests/asm/test_m11_security.asm")
    required_security_prefixes = {
        "m11/security": 2,
        "m11/control_peer": 1,
        "m11/provider_header": 2,
    }
    for prefix, minimum in required_security_prefixes.items():
        count = len(re.findall(rf'AF_TEST\s+"{re.escape(prefix)}', native_security))
        if count < minimum:
            fail(
                f"native security regression matrix has {count} {prefix} tests; "
                f"expected at least {minimum}"
            )
            return
    ok("six focused suites and eight bounded deterministic fuzz targets are present")


def logical_make_lines(source: str) -> list[str]:
    logical: list[str] = []
    current = ""
    for line in source.splitlines():
        current = f"{current} {line.strip()}".strip()
        if current.endswith("\\"):
            current = current[:-1].rstrip()
            continue
        if current:
            logical.append(current)
        current = ""
    if current:
        logical.append(current)
    return logical


def make_recipe(target: str) -> str:
    lines = read("Makefile").splitlines()
    start: int | None = None
    for index, line in enumerate(lines):
        if re.match(rf"^{re.escape(target)}\s*:", line):
            start = index + 1
            break
    if start is None:
        return ""
    recipe: list[str] = []
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


def check_make_wiring() -> None:
    makefile = read("Makefile")
    recipes = {target: make_recipe(target) for target in (*TARGETS, "gate-m11")}
    missing = [target for target, recipe in recipes.items() if not recipe]
    if missing:
        fail("Makefile is missing M11 recipes: " + ", ".join(missing))
        return
    if any("unittest discover" in recipes[target] for target in TARGETS):
        fail("an M11 focused target runs broad unittest discovery")
        return

    expected = {
        "test-security": (
            "m11/security",
            "m11/control_peer",
            "m11/provider_header",
            "tests.test_security",
        ),
        "test-redaction": ("tests.test_redaction",),
        "test-permissions": ("tests.test_permissions",),
        "fuzz-smoke": ("tests.test_fuzz_smoke",),
        "test-backup-restore": ("--filter backup/",),
        "test-crash-recovery": ("tests.test_crash_recovery",),
        "test-graceful-shutdown": ("tests.test_graceful_shutdown",),
    }
    for target, tokens in expected.items():
        absent = [token for token in tokens if token not in recipes[target]]
        if absent:
            fail(f"{target} is not focused on: " + ", ".join(absent))
            return

    gate_line = next(
        (line for line in logical_make_lines(makefile) if line.startswith("gate-m11:")),
        "",
    )
    dependencies = set(gate_line.partition(":")[2].split())
    absent = sorted({"gate-m10", *TARGETS} - dependencies)
    if absent:
        fail("gate-m11 dependencies are incomplete: " + ", ".join(absent))
        return
    gate_recipe = recipes["gate-m11"]
    if "scripts/gate_m11.py" not in gate_recipe or "--skip-suites" not in gate_recipe:
        fail("gate-m11 must run its static audit after all focused suites")
        return

    phony = next(
        (line for line in logical_make_lines(makefile) if line.startswith(".PHONY:")),
        "",
    )
    missing_phony = [target for target in (*TARGETS, "gate-m11") if target not in phony]
    if missing_phony:
        fail("M11 targets are not phony: " + ", ".join(missing_phony))
        return
    help_recipe = make_recipe("help")
    missing_help = [target for target in (*TARGETS, "gate-m11") if target not in help_recipe]
    if missing_help:
        fail("Makefile help omits M11 targets: " + ", ".join(missing_help))
        return
    ok("all seven HARNESS targets and gate-m11 are focused and fully wired")


def run_python_suite(name: str, module: str, minimum: int, build_dir: Path) -> None:
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


def run_native_suite(name: str, prefix: str, minimum: int, build_dir: Path) -> None:
    binary = build_dir / "debug" / "asmflow-tests"
    try:
        result = run([str(binary), "--filter", prefix, "--verbose"], timeout=300)
    except subprocess.TimeoutExpired:
        fail(f"{name} exceeded the 300 second gate budget")
        return
    output = result.stdout + result.stderr
    if result.returncode != 0:
        fail(f"{name} failed:\n{output}")
        return
    count = re.search(r"(?m)^tests:\s*(\d+)\s+run\b", output)
    if count is None or int(count.group(1)) < minimum:
        fail(f"{name} ran fewer than {minimum} native tests:\n{output}")
        return
    ok(f"{name} ({count.group(1)} native tests)")


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

    check_required_assets_and_build(build_dir)
    check_structured_redaction_and_diagnostics()
    check_auth_permissions_and_audit()
    check_backup_restore_and_policy_boundary()
    check_shutdown_and_crash_contracts()
    check_test_and_fuzz_matrix()
    check_make_wiring()

    if not arguments.skip_suites:
        run_native_suite("secure buffer regressions", "m11/security", 2, build_dir)
        run_native_suite("control peer regression", "m11/control_peer", 1, build_dir)
        run_native_suite("provider header regressions", "m11/provider_header", 2, build_dir)
        run_native_suite("backup/restore regressions", "backup/", 5, build_dir)
        for name, module, minimum in SUITES:
            run_python_suite(name, module, minimum, build_dir)

    if FAILED:
        print("M11 gate failed", file=sys.stderr)
        return 1
    print("M11 gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
