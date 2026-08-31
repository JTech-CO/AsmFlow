"""Keyboard-only TUI workflows and confirmation coverage (HARNESS M10)."""
from __future__ import annotations

import json
import re
import time
import unittest

from tests.mock_control_server import ScriptedControlServer, load_scenario
from tests.tui_harness import FIXTURES, ROOT, PtySession, require_binary


SCENARIO = FIXTURES / "control_scenario.json"


class TuiKeyboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = require_binary("asmflow-tui")
        cls.tasks = json.loads(
            (FIXTURES / "keyboard_tasks.json").read_text(encoding="utf-8")
        )

    def session(self, server: ScriptedControlServer, width: int = 100, height: int = 30):
        return PtySession(
            [self.binary, "--socket", server.socket_path],
            width=width,
            height=height,
        )

    def test_documented_keyboard_only_operator_workflow(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with self.session(server) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.wait_for_output("AsmFlow")
                method_counts: dict[str, int] = {}
                for step in self.tasks["workflow"]:
                    terminal.send(step["keys"])
                    if "expect_screen" in step:
                        terminal.wait_for_output(step["expect_screen"])
                    expected = step.get("expect_request")
                    if expected is not None:
                        method = expected["method"]
                        method_counts[method] = method_counts.get(method, 0) + 1
                        request = server.wait_for_request(
                            method, count=method_counts[method]
                        )
                        self.assertEqual(expected.get("params", {}), request.get("params", {}))
                self.assertEqual(0, terminal.wait())
                terminal.assert_terminal_restored()

    def test_refresh_preserves_provider_selection_by_stable_id_after_reorder(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with self.session(server) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.send("2")
                terminal.wait_for_output("PROVIDERS")
                terminal.send("j")
                first = server.wait_for_request(
                    "providers.get",
                    predicate=lambda frame: frame.get("params", {}).get("provider_id")
                    == "p-code",
                )
                self.assertEqual("p-code", first["params"]["provider_id"])

                terminal.send("r")
                server.wait_for_request("providers.list", count=2)
                refreshed = server.wait_for_request(
                    "providers.get",
                    count=2,
                    predicate=lambda frame: frame.get("params", {}).get("provider_id")
                    == "p-code",
                )
                self.assertEqual("p-code", refreshed["params"]["provider_id"])
                terminal.send("q")
                self.assertEqual(0, terminal.wait())

    def test_refresh_rebinds_selection_before_get_when_selected_provider_was_removed(self) -> None:
        scenario = load_scenario(SCENARIO)
        sequence = scenario["methods"]["providers.list"]["sequence"]
        sequence[1]["result"] = [
            provider
            for provider in sequence[1]["result"]
            if provider["id"] != "p-code"
        ]
        expected_fallback = sequence[1]["result"][1]["id"]

        with ScriptedControlServer(scenario) as server:
            with self.session(server) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.send("2")
                terminal.wait_for_output("PROVIDERS")
                terminal.send("j")
                server.wait_for_request(
                    "providers.get",
                    predicate=lambda frame: frame.get("params", {}).get("provider_id")
                    == "p-code",
                )

                terminal.send("r")
                server.wait_for_request("providers.list", count=2)
                rebound = server.wait_for_request("providers.get", count=2)
                self.assertEqual(
                    expected_fallback,
                    rebound.get("params", {}).get("provider_id"),
                    "refresh must not issue providers.get for a removed stable ID",
                )
                terminal.send("q")
                self.assertEqual(0, terminal.wait())

    def test_provider_reverse_and_arrow_navigation_are_symmetric(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with self.session(server) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.send("2")
                terminal.wait_for_output("PROVIDERS")

                terminal.send("j")
                moved_down = server.wait_for_request("providers.get", count=1)
                self.assertEqual("p-code", moved_down.get("params", {}).get("provider_id"))

                terminal.send("k")
                moved_up = server.wait_for_request("providers.get", count=2)
                self.assertEqual("p-local", moved_up.get("params", {}).get("provider_id"))

                # xterm-256color keypad mode advertises kcud1/kcuu1 as
                # ESC-O-B / ESC-O-A; ncurses translates these to KEY_DOWN/UP.
                terminal.send("\x1bOB")
                arrow_down = server.wait_for_request("providers.get", count=3)
                self.assertEqual("p-code", arrow_down.get("params", {}).get("provider_id"))

                terminal.send("\x1bOA")
                arrow_up = server.wait_for_request("providers.get", count=4)
                self.assertEqual("p-local", arrow_up.get("params", {}).get("provider_id"))
                terminal.send("q")
                self.assertEqual(0, terminal.wait())

    def test_overview_refresh_requests_a_fresh_snapshot(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with self.session(server) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.wait_for_output("OVERVIEW")
                terminal.send("r")
                server.wait_for_request("system.snapshot", count=2)
                terminal.send("q")
                self.assertEqual(0, terminal.wait())

    def test_overview_refresh_failure_keeps_every_previous_frame(self) -> None:
        scenario = load_scenario(SCENARIO)
        snapshot = scenario["methods"]["system.snapshot"].pop("reply")
        refreshed_snapshot = json.loads(json.dumps(snapshot))
        refreshed_snapshot["result"]["revision"] = 99
        scenario["methods"]["system.snapshot"]["sequence"] = [
            snapshot,
            refreshed_snapshot,
        ]

        refreshed_providers = scenario["methods"]["providers.list"]["sequence"][1]
        refreshed_providers["result"][0]["health"] = "open"
        refreshed_providers["result"] = [
            provider
            for provider in refreshed_providers["result"]
            if provider["id"] != "p-code"
        ]
        routes = scenario["methods"]["routes.list"].pop("reply")
        refreshed_routes = json.loads(json.dumps(routes))
        refreshed_routes["result"] = [
            route for route in refreshed_routes["result"] if route["id"] != "r-code"
        ]
        scenario["methods"]["routes.list"]["sequence"] = [
            routes,
            refreshed_routes,
        ]
        mcp = scenario["methods"]["mcp.list"].pop("reply")
        scenario["methods"]["mcp.list"]["sequence"] = [
            mcp,
            {"ok": True, "result": {}},
        ]

        with ScriptedControlServer(scenario) as server:
            with self.session(server) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.send("2")
                terminal.wait_for_output("PROVIDERS")
                terminal.send("j")
                selected_provider = server.wait_for_request("providers.get", count=1)
                self.assertEqual(
                    "p-code", selected_provider.get("params", {}).get("provider_id")
                )
                terminal.send("3")
                terminal.wait_for_output("ROUTES")
                terminal.send("j")
                terminal.send("1")
                terminal.wait_for_output("OVERVIEW")
                terminal.read_available(0.2)
                marker = len(terminal.output)
                terminal.send("r")
                server.wait_for_request("mcp.list", count=2)
                terminal.wait_for_output("STALE")
                failed_redraw = bytes(terminal.output[marker:])
                self.assertIn(b"cfg:42", failed_redraw)
                self.assertNotIn(b"cfg:99", failed_redraw)

                # ncurses emits only changed cells. Switch away and back so the
                # retained Overview documents are painted into different rows
                # and therefore observable as a complete view.
                terminal.send("2")
                terminal.read_available(0.3)
                marker = len(terminal.output)
                terminal.send("1")
                terminal.read_available(0.3)
                redraw = bytes(terminal.output[marker:])
                self.assertIn(b"cfg:42", redraw)
                self.assertNotIn(b"cfg:99", redraw)
                self.assertIn(
                    b"1 healthy / 2 warning / 1 open / 1 disabled", redraw
                )

                terminal.send("2")
                terminal.read_available(0.3)
                provider_redraw = bytes(terminal.output[marker:])
                provider_visible = re.sub(
                    rb"\x1b(?:\[[0-?]*[ -/]*[@-~]|\([A-Z0-9])",
                    b"",
                    provider_redraw,
                )
                self.assertRegex(
                    provider_visible,
                    rb">\s*\[WARN\]\s*Code Fast",
                    "Overview rollback did not restore the provider stable-ID focus",
                )

                terminal.send("3")
                terminal.read_available(0.3)
                marker = len(terminal.output)
                terminal.resize(101, 30)
                terminal.read_available(0.5)
                route_redraw = bytes(terminal.output[marker:])
                route_visible = re.sub(
                    rb"\x1b(?:\[[0-?]*[ -/]*[@-~]|\([A-Z0-9])",
                    b"",
                    route_redraw,
                )
                self.assertRegex(
                    route_visible,
                    rb"(?:^|\r)>\s*code-fast",
                    "Overview rollback did not restore the route stable-ID focus",
                )
                terminal.send("q")
                self.assertEqual(0, terminal.wait())

    def test_provider_refresh_get_failure_keeps_previous_list_frame(self) -> None:
        scenario = load_scenario(SCENARIO)
        refreshed = scenario["methods"]["providers.list"]["sequence"][1]
        refreshed["result"][1]["display_name"] = "NEW Code Fast"
        provider_get = scenario["methods"]["providers.get"].pop("reply")
        scenario["methods"]["providers.get"]["sequence"] = [
            provider_get,
            {"_raw": "not-json"},
        ]

        with ScriptedControlServer(scenario) as server:
            with self.session(server) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.send("2")
                terminal.wait_for_output("PROVIDERS")
                terminal.send("j")
                server.wait_for_request("providers.get", count=1)
                terminal.read_available(0.2)
                marker = len(terminal.output)
                terminal.send("r")
                server.wait_for_request("providers.get", count=2)
                terminal.wait_for_output("STALE")
                terminal.send("3")
                terminal.read_available(0.3)
                marker = len(terminal.output)
                terminal.send("2")
                terminal.read_available(0.3)
                redraw = bytes(terminal.output[marker:])
                self.assertIn(b"Code Fast", redraw)
                self.assertNotIn(b"NEW Code Fast", redraw)
                terminal.send("q")
                self.assertEqual(0, terminal.wait())

    def test_mcp_move_then_restart_uses_the_new_stable_id(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with self.session(server) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.send("5")
                terminal.wait_for_output("MCP")
                terminal.send("j")
                terminal.send(":mcp-restart\n")
                terminal.wait_for_output("CONFIRM")
                terminal.send("\n")
                request = server.wait_for_request("mcp.restart")
                self.assertEqual({"server_id": "m-git"}, request.get("params"))
                terminal.send("q")
                self.assertEqual(0, terminal.wait())

    def test_escape_closes_help_overlay(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with self.session(server) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.send("?")
                terminal.wait_for_output("HELP")
                marker = len(terminal.output)
                terminal.send("\x1b")
                deadline = time.monotonic() + 2.0
                while len(terminal.output) == marker and time.monotonic() < deadline:
                    terminal.read_available(0.1)
                redraw = bytes(terminal.output[marker:])
                self.assertTrue(redraw, "Escape produced no redraw")
                self.assertNotIn(b"HELP  ", redraw)
                terminal.send("q")
                self.assertEqual(0, terminal.wait())

    def test_level_two_action_cancel_and_confirm_paths_are_distinct(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with self.session(server) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.send("5")
                terminal.wait_for_output("MCP")
                terminal.send(":mcp-restart\n")
                terminal.wait_for_output("CONFIRM")
                terminal.send("\x1b")
                terminal.send("q")
                self.assertEqual(0, terminal.wait())
                self.assertEqual(0, server.request_count("mcp.restart"))

        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with self.session(server) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.send("5")
                terminal.wait_for_output("MCP")
                terminal.send(":mcp-restart\n")
                terminal.wait_for_output("CONFIRM")
                terminal.send("\n")
                request = server.wait_for_request("mcp.restart")
                self.assertEqual({"server_id": "m-files"}, request.get("params"))
                terminal.send("q")
                self.assertEqual(0, terminal.wait())
                self.assertEqual(1, server.request_count("mcp.restart"))

    def test_every_level_two_through_four_action_has_confirmation_policy(self) -> None:
        actions = self.tasks["risk_actions"]
        self.assertGreaterEqual(len(actions), 10)
        for action in actions:
            with self.subTest(action=action["id"]):
                self.assertIn(action["level"], (2, 3, 4))
                self.assertNotIn(action["confirmation"], (None, "", "none"))
                if action["level"] == 4:
                    self.assertIn(
                        action["confirmation"],
                        ("typed_phrase_or_unavailable", "unavailable"),
                    )

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
        action_source = (ROOT / "src/tui/actions.asm").read_text(encoding="utf-8")
        source_rows = re.findall(
            r"^\s*TUI_ACTION\s+(AF_TUI_ACTION_[A-Z0-9_]+),\s*"
            r"AF_TUI_RISK_([234]),\s*([01]),",
            action_source,
            re.MULTILINE,
        )
        self.assertEqual(set(source_names), {name for name, _, _ in source_rows})
        source_matrix = {
            source_names[name]: (int(level), available == "1")
            for name, level, available in source_rows
        }
        fixture_matrix = {
            action["id"]: (action["level"], action["available"]) for action in actions
        }
        self.assertEqual(source_matrix, fixture_matrix)

        runtime_source = (ROOT / "src/tui/tui_run.asm").read_text(encoding="utf-8")
        submit = runtime_source.index(".submit_command:")
        descriptor = runtime_source.index("call    af_tui_action_descriptor", submit)
        available = runtime_source.index("call    af_tui_action_available", descriptor)
        confirm = runtime_source.index(
            "call    af_tui_action_requires_confirmation", available
        )
        prepare = runtime_source.index("call    _af_tuir_prepare_confirmation", confirm)
        self.assertLess(descriptor, available)
        self.assertLess(available, confirm)
        self.assertLess(confirm, prepare)

    def test_select_prev_clamps_invalid_index_before_row_pointer_arithmetic(self) -> None:
        source = (ROOT / "src/tui/model.asm").read_text(encoding="utf-8")
        start = source.index("af_tui_model_select_prev:")
        end = source.index("; af_tui_model_selected_id", start)
        body = source[start:end]
        clamp = body.index("cmp     r14, r13")
        normalize = body.index("xor     r14d, r14d", clamp)
        decrement = body.index("dec     r14", normalize)
        row_offset = body.index("imul    rax, TR_SIZE", decrement)
        self.assertLess(clamp, normalize)
        self.assertLess(normalize, decrement)
        self.assertLess(decrement, row_offset)

    def test_resize_reflows_on_the_next_loop_and_remains_interactive(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with self.session(server, width=80, height=24) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.wait_for_output("AsmFlow")
                before = len(terminal.output)
                terminal.resize(140, 40)
                deadline = time.monotonic() + 3.0
                while len(terminal.output) == before and time.monotonic() < deadline:
                    terminal.read_available(0.1)
                self.assertIsNone(terminal.process.poll(), "SIGWINCH terminated the TUI")
                self.assertGreater(len(terminal.output), before, "resize produced no redraw")
                terminal.send("?")
                terminal.wait_for_output("HELP")
                terminal.send("q")
                self.assertEqual(0, terminal.wait())


if __name__ == "__main__":
    unittest.main()
