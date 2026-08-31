#!/usr/bin/env python3
"""M10 gate: ncursesw TUI and non-interactive control CLI.

The five focused Python suites own interactive behavior.  This script checks
the structural claims those suites cannot prove alone: both clients are built,
their dynamic dependencies preserve process boundaries, all documented TUI
sources reach the link, signal cleanup does not call unsafe terminal code, the
fixture/confirmation matrix remains complete, and Make/CI cannot silently omit
an M10 suite.
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FAILED = False

SUITES = (
    ("TUI layout", "tests.test_tui_layout", 9),
    ("TUI keyboard", "tests.test_tui_keyboard", 13),
    ("TUI monochrome", "tests.test_tui_mono", 4),
    ("TUI terminal restore", "tests.test_tui_terminal_restore", 5),
    ("CLI contract", "tests.test_cli_contract", 10),
)

TARGETS = (
    "test-tui-layout",
    "test-tui-keyboard",
    "test-tui-mono",
    "test-tui-terminal-restore",
    "test-cli-contract",
)

REQUIRED_FILES = {
    "tests/tui_harness.py",
    "tests/mock_control_server.py",
    "tests/test_tui_layout.py",
    "tests/test_tui_keyboard.py",
    "tests/test_tui_mono.py",
    "tests/test_tui_terminal_restore.py",
    "tests/test_cli_contract.py",
    "tests/fixtures/tui/control_scenario.json",
    "tests/fixtures/tui/escape_scenario.json",
    "tests/fixtures/tui/golden_manifest.json",
    "tests/fixtures/tui/screen_expectations.json",
    "tests/fixtures/tui/keyboard_tasks.json",
    "tests/fixtures/tui/status_catalog.json",
    "tests/fixtures/cli/control_cases.json",
    "tests/fixtures/cli/providers_table.txt",
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
        kept: list[str] = []
        for char in line:
            if char in ("'", '"'):
                quote = None if quote == char else (char if quote is None else quote)
            if char == ";" and quote is None:
                break
            kept.append(char)
        if "".join(kept).strip():
            lines.append("".join(kept))
    return "\n".join(lines)


def canonical(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"\b\d{2}:\d{2}:\d{2} UTC\b", "<TIME UTC>", text)
    lines = [line.rstrip(" ") for line in text.split("\n")]
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines) + ("\n" if lines else "")


def display_width(text: str) -> int:
    width = 0
    for char in text:
        if unicodedata.combining(char):
            continue
        if unicodedata.category(char).startswith("C"):
            raise ValueError(f"control U+{ord(char):04X}")
        width += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return width


def check_test_and_fixture_matrix() -> None:
    missing = sorted(path for path in REQUIRED_FILES if not (ROOT / path).is_file())
    if missing:
        fail("missing M10 test assets: " + ", ".join(missing))
        return

    for _, module, minimum in SUITES:
        relative = module.replace(".", "/") + ".py"
        source = read(relative)
        try:
            tree = ast.parse(source, filename=relative)
        except SyntaxError as error:
            fail(f"{relative} does not parse: {error}")
            return
        tests = [
            node
            for node in ast.walk(tree)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name.startswith("test_")
        ]
        if len(tests) < minimum:
            fail(f"{relative} has {len(tests)} tests; M10 floor is {minimum}")
            return

    json_files = sorted((ROOT / "tests/fixtures/tui").glob("*.json"))
    json_files += sorted((ROOT / "tests/fixtures/cli").glob("*.json"))
    try:
        documents = {
            path.name: json.loads(path.read_text(encoding="utf-8"))
            for path in json_files
        }
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"M10 fixture is not valid UTF-8 JSON: {error}")
        return

    manifest = documents["golden_manifest.json"]
    sizes = {(entry["width"], entry["height"]) for entry in manifest}
    if sizes != {(80, 24), (100, 30), (140, 40)}:
        fail(f"golden size matrix is {sorted(sizes)}, expected 80x24/100x30/140x40")
        return
    for entry in manifest:
        golden = ROOT / "tests/fixtures/tui/goldens" / entry["file"]
        if not golden.is_file():
            fail(f"missing layout golden: {golden.relative_to(ROOT)}")
            return
        text = canonical(golden.read_text(encoding="utf-8"))
        if "\x1b" in text:
            fail(f"layout golden contains a terminal escape: {golden.name}")
            return
        lines = text.splitlines()
        if len(lines) > entry["height"]:
            fail(f"{golden.name} exceeds {entry['height']} rows")
            return
        try:
            too_wide = [line for line in lines if display_width(line) > entry["width"]]
        except ValueError as error:
            fail(f"{golden.name} contains {error}")
            return
        if too_wide:
            fail(f"{golden.name} contains a row wider than {entry['width']} columns")
            return

    screens = set(documents["screen_expectations.json"])
    expected_screens = {
        "overview", "providers", "routes", "requests", "mcp", "logs", "settings"
    }
    if screens != expected_screens:
        fail("screen fixture matrix is incomplete: " + ", ".join(sorted(screens)))
        return

    actions = documents["keyboard_tasks.json"].get("risk_actions", [])
    uncovered = [
        action.get("id", "<unnamed>")
        for action in actions
        if action.get("level") in (2, 3, 4)
        and action.get("confirmation") in (None, "", "none")
    ]
    levels = {action.get("level") for action in actions}
    if uncovered or not {2, 3, 4}.issubset(levels):
        fail("Level 2-4 confirmation fixture is incomplete: " + ", ".join(uncovered))
        return
    source_names = {
        "AF_TUI_ACTION_PROVIDER_ENABLE": "provider.enable",
        "AF_TUI_ACTION_PROVIDER_DISABLE": "provider.disable",
        "AF_TUI_ACTION_MCP_START": "mcp.start",
        "AF_TUI_ACTION_MCP_STOP": "mcp.stop",
        "AF_TUI_ACTION_MCP_RESTART": "mcp.restart",
        "AF_TUI_ACTION_MCP_RESET_CRASH_LOOP": "mcp.reset_crash_loop",
        "AF_TUI_ACTION_CONFIG_RELOAD": "config.reload",
        "AF_TUI_ACTION_MCP_TOOL_TEST": "mcp.tool_test",
        "AF_TUI_ACTION_ROUTE_MUTATE": "route.mutate",
        "AF_TUI_ACTION_LISTENER_NONLOOPBACK": "listener.non_loopback",
        "AF_TUI_ACTION_MULTI_SERVER_STOP": "mcp.stop_many",
        "AF_TUI_ACTION_DB_RESET": "database.reset",
    }
    action_source = read("src/tui/actions.asm")
    source_rows = re.findall(
        r"(?m)^\s*TUI_ACTION\s+(AF_TUI_ACTION_[A-Z0-9_]+),\s*"
        r"AF_TUI_RISK_([234]),\s*([01]),",
        action_source,
    )
    if set(source_names) != {name for name, _, _ in source_rows}:
        fail("Level 2-4 action source catalogue drifted from the fixture mapping")
        return
    source_matrix = {
        source_names[name]: (int(level), available == "1")
        for name, level, available in source_rows
    }
    try:
        fixture_matrix = {
            action["id"]: (action["level"], action["available"])
            for action in actions
        }
    except KeyError as error:
        fail(f"risk action fixture is missing {error.args[0]!r}")
        return
    if len(fixture_matrix) != len(actions) or fixture_matrix != source_matrix:
        fail("risk action fixture does not exactly match source ID/level/availability")
        return

    fixture_blob = "\n".join(path.read_text(encoding="utf-8") for path in json_files)
    secret_shapes = re.findall(r"sk-[A-Za-z0-9_-]{12,}|Bearer\s+[A-Za-z0-9._-]+", fixture_blob)
    if secret_shapes:
        fail("M10 fixtures contain credential-shaped values")
        return
    ok("five focused suites and deterministic M10 fixture matrix")


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
        elif not recipe and (not line.strip() or line.startswith(" ")):
            # A dependency list may continue on indented, non-recipe lines.
            # Do not mistake those for a missing recipe.
            continue
        elif recipe:
            break
        else:
            break
    return "\n".join(recipe)


def check_make_and_ci_wiring() -> None:
    makefile = read("Makefile")
    recipes = {target: make_recipe(target) for target in (*TARGETS, "gate-m10")}
    missing = [target for target, recipe in recipes.items() if not recipe]
    if missing:
        fail("Makefile is missing M10 recipes: " + ", ".join(missing))
        return
    modules = tuple(module for _, module, _ in SUITES)
    for target, module in zip(TARGETS, modules):
        if module not in recipes[target] or "unittest discover" in recipes[target]:
            fail(f"{target} is not focused on {module}")
            return
    gate_line = next(
        (line for line in logical_make_lines(makefile) if line.startswith("gate-m10:")),
        "",
    )
    dependencies = set(gate_line.partition(":")[2].split())
    absent = sorted({"gate-m9", *TARGETS} - dependencies)
    if absent:
        fail("gate-m10 dependencies are incomplete: " + ", ".join(absent))
        return
    if "scripts/gate_m10.py" not in recipes["gate-m10"] or "--skip-suites" not in recipes["gate-m10"]:
        fail("gate-m10 must run its static audit after the focused suites")
        return
    phony = next(
        (line for line in logical_make_lines(makefile) if line.startswith(".PHONY:")),
        "",
    )
    if any(target not in phony for target in (*TARGETS, "gate-m10")):
        fail("one or more M10 Make targets are not phony")
        return
    help_recipe = make_recipe("help")
    if any(target not in help_recipe for target in (*TARGETS, "gate-m10")):
        fail("Makefile help omits an M10 target")
        return
    if "asmflowctl" not in makefile:
        fail("Makefile does not build the separate asmflowctl binary")
        return
    ci = read(".github/workflows/ci.yml")
    if "make gate-m10" not in ci:
        fail("CI does not run make gate-m10")
        return
    ok("five HARNESS targets, gate-m10, asmflowctl, and CI are wired")


def all_console_assembly() -> tuple[list[Path], str]:
    paths = sorted((ROOT / "src/tui").rglob("*.asm"))
    paths += sorted((ROOT / "src/cli").rglob("*.asm")) if (ROOT / "src/cli").exists() else []
    code = "\n".join(strip_asm_comments(path.read_text(encoding="utf-8")) for path in paths)
    return paths, code


def check_source_invariants(build_dir: Path) -> None:
    paths, code = all_console_assembly()
    if len(paths) < 3:
        fail("M10 console implementation has no substantive assembly modules")
        return
    required_tokens = (
        "--dump-layout",
        "--screen",
        "--mono",
        "NO_COLOR",
        "mcp.restart",
        "mcp.tool_test",
    )
    missing = [token for token in required_tokens if token not in code]
    if missing:
        fail("M10 console source lacks contract anchors: " + ", ".join(missing))
        return
    if not any(token in code for token in ("endwin", "af_tui_terminal_restore")):
        fail("TUI source has no terminal cleanup/endwin anchor")
        return
    if not any(token in code for token in ("curs_set", "af_tui_cursor_restore")):
        fail("TUI source has no cursor restore anchor")
        return
    if not any(token in code for token in ("af_sys_connect", "connect")):
        fail("console source has no Unix control-socket client path")
        return
    daemon_source = read("src/platform/linux_x86_64/daemon.asm").lower()
    if "console is not wired" in daemon_source:
        fail("daemon still reports the now-wired M10 console as unavailable")
        return

    runtime_source = strip_asm_comments(read("src/tui/tui_run.asm"))
    handler_start = runtime_source.find("_af_tuir_handle_key:")
    handler_end = runtime_source.find("_af_tuir_poll_connection:", handler_start)
    if handler_start < 0 or handler_end < 0:
        fail("TUI key handler boundaries are missing")
        return
    handler = runtime_source[handler_start:handler_end]
    keymap_calls = list(
        re.finditer(r"(?mi)^\s*call\s+af_tui_keymap\b", handler)
    )
    if len(keymap_calls) != 1:
        fail("normal TUI input must have exactly one af_tui_keymap dispatch")
        return
    keymap_at = keymap_calls[0].start()
    confirmation_at = handler.find("cmp     qword [tui_confirmation]")
    command_at = handler.find("cmp     qword [tui_command_active]")
    if not (0 <= confirmation_at < keymap_at and 0 <= command_at < keymap_at):
        fail("confirmation/command modal intercepts must precede normal key mapping")
        return
    submit = handler.find(".submit_command:")
    if submit < 0:
        fail("TUI command submit path is missing")
        return
    ordered_calls = (
        "af_tui_action_descriptor",
        "af_tui_action_available",
        "af_tui_action_requires_confirmation",
        "_af_tuir_prepare_confirmation",
    )
    cursor = submit
    for symbol in ordered_calls:
        match = re.search(rf"(?mi)^\s*call\s+{re.escape(symbol)}\b", handler[cursor:])
        if match is None:
            fail(f"mcp-restart confirmation path omits {symbol}")
            return
        cursor += match.end()

    action_source = strip_asm_comments(read("src/tui/actions.asm"))
    if "%if %3" not in action_source or "%if %2 < AF_TUI_RISK_4" in action_source:
        fail("TUI action availability is not an explicit catalogue field")
        return

    model_source = strip_asm_comments(read("src/tui/model.asm"))
    prev_start = model_source.find("af_tui_model_select_prev:")
    prev_end = model_source.find("af_tui_model_selected_id:", prev_start)
    if prev_start < 0 or prev_end < 0:
        fail("model has no bounded select-prev implementation")
        return
    prev_body = model_source[prev_start:prev_end]
    clamp = prev_body.find("cmp     r14, r13")
    normalize = prev_body.find("xor     r14d, r14d", clamp)
    decrement = prev_body.find("dec     r14", normalize)
    row_offset = prev_body.find("imul    rax, TR_SIZE", decrement)
    if not (0 <= clamp < normalize < decrement < row_offset):
        fail("select-prev does not clamp an invalid index before row arithmetic")
        return

    forbidden_boundary = re.compile(r"\bsqlite3\w*\b|\baf_(?:db|repo|storage)_\w+", re.I)
    boundary_hits = forbidden_boundary.findall(code)
    if boundary_hits:
        fail("TUI/CLI source reaches storage directly: " + ", ".join(sorted(set(boundary_hits))))
        return

    unbounded_calls = re.findall(
        r"(?mi)^\s*call\s+(?:mvw?|w)?(?:addstr|printw)\b", code
    )
    if unbounded_calls:
        fail("untrusted terminal text can use an unbounded curses writer")
        return
    if not re.search(r"(?mi)^\s*call\s+\w*(?:waddnstr|waddnwstr|addnstr)\b", code):
        fail("TUI source has no length-bounded curses text writer")
        return

    # A real async handler may record a flag/write a self-pipe only.  Terminal,
    # allocation, JSON, and socket work belongs to the next ordinary loop turn.
    for match in re.finditer(r"(?mi)^\s*global\s+(\w*(?:signal|sigint|sigwinch)\w*)", code):
        start = code.find(match.group(1) + ":", match.end())
        tail = code[start:] if start >= 0 else ""
        next_global = re.search(r"(?mi)^\s*global\s+", tail[1:])
        body = tail if next_global is None else tail[: next_global.start() + 1]
        unsafe = re.findall(
            r"(?mi)^\s*call\s+(\w*(?:endwin|curs|wadd|malloc|alloc|json|connect|recv|send)\w*)",
            body,
        )
        if unsafe:
            fail(f"async handler {match.group(1)} calls unsafe code: " + ", ".join(unsafe))
            return

    tui_map_path = build_dir / "debug" / "asmflow-tui.map"
    cli_map_path = build_dir / "debug" / "asmflowctl.map"
    if not tui_map_path.is_file() or not cli_map_path.is_file():
        fail(f"missing M10 link maps: tui={tui_map_path.is_file()} cli={cli_map_path.is_file()}")
        return
    tui_map = tui_map_path.read_text(encoding="utf-8", errors="ignore").replace("\\", "/")
    cli_map = cli_map_path.read_text(encoding="utf-8", errors="ignore").replace("\\", "/")
    cli_only = {
        "src/tui/entry_ctl.asm",
        "src/tui/ctl_run.asm",
        "src/tui/table_output.asm",
    }
    missing_objects = []
    for path in sorted((ROOT / "src/tui").rglob("*.asm")):
        relative_source = path.relative_to(ROOT).as_posix()
        if relative_source in cli_only:
            continue
        relative_object = path.relative_to(ROOT).with_suffix(".o").as_posix()
        if relative_object not in tui_map:
            missing_objects.append(relative_source)
    if missing_objects:
        fail("TUI assembly omitted from its link map: " + ", ".join(missing_objects))
        return
    missing_cli = []
    for relative_source in sorted(cli_only):
        source_path = ROOT / relative_source
        relative_object = source_path.relative_to(ROOT).with_suffix(".o").as_posix()
        if not source_path.is_file() or relative_object not in cli_map:
            missing_cli.append(relative_source)
        if relative_object in tui_map:
            fail(f"CLI-only object leaked into asmflow-tui: {relative_source}")
            return
    if missing_cli:
        fail("CLI assembly omitted from asmflowctl link map: " + ", ".join(missing_cli))
        return
    ok("terminal cleanup, confirmation, bounded rendering, and source boundaries")


def dynamic_needed(binary: Path) -> str | None:
    try:
        result = run(["readelf", "-Wd", str(binary)], timeout=60)
    except OSError as error:
        fail(f"readelf could not inspect {binary}: {error}")
        return None
    if result.returncode != 0:
        fail(f"readelf could not inspect {binary}: {result.stderr}")
        return None
    return result.stdout.lower()


def check_binaries_and_link_boundaries(build_dir: Path) -> None:
    tui = build_dir / "debug" / "asmflow-tui"
    cli = build_dir / "debug" / "asmflowctl"
    if not tui.is_file() or not cli.is_file():
        fail(f"missing M10 debug artifacts: tui={tui.is_file()} cli={cli.is_file()}")
        return
    tui_needed = dynamic_needed(tui)
    cli_needed = dynamic_needed(cli)
    if tui_needed is None or cli_needed is None:
        return
    for name, needed in (("asmflow-tui", tui_needed), ("asmflowctl", cli_needed)):
        forbidden = [token for token in ("sqlite", "libcurl", "llhttp") if token in needed]
        if forbidden:
            fail(f"{name} links forbidden daemon libraries: " + ", ".join(forbidden))
            return
    if "ncursesw" not in tui_needed:
        fail("asmflow-tui does not link ncursesw")
        return
    if "ncurses" in cli_needed:
        fail("asmflowctl links ncurses even though it is non-interactive")
        return
    for mode in ("debug", "release"):
        for name in ("asmflow-tui", "asmflowctl"):
            path = build_dir / mode / name
            if not path.is_file() or not os.access(path, os.X_OK):
                fail(f"missing executable M10 artifact: {path}")
                return
    ok("TUI/CLI dynamic dependencies and debug/release artifacts")


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
        fail(f"{name} skipped tests under gate-m10:\n{output}")
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

    check_test_and_fixture_matrix()
    check_make_and_ci_wiring()
    check_binaries_and_link_boundaries(build_dir)
    check_source_invariants(build_dir)

    if not arguments.skip_suites:
        for name, module, minimum in SUITES:
            run_suite(name, module, minimum, build_dir)

    if FAILED:
        print("M10 gate failed", file=sys.stderr)
        return 1
    print("M10 gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
