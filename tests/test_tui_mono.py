"""Monochrome, NO_COLOR, and ASCII fallback behavior for M10."""
from __future__ import annotations

import json
import unittest

from tests.mock_control_server import ScriptedControlServer, load_scenario
from tests.tui_harness import (
    FIXTURES,
    PtySession,
    canonical_layout,
    color_sgr_sequences,
    require_binary,
    run_layout_dump,
)


SCENARIO = FIXTURES / "control_scenario.json"


class TuiMonochromeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = require_binary("asmflow-tui")
        cls.statuses = json.loads(
            (FIXTURES / "status_catalog.json").read_text(encoding="utf-8")
        )

    def dump(self, screen: str, *, args=(), env=None) -> str:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            result = run_layout_dump(
                self.binary,
                server.socket_path,
                screen=screen,
                width=140,
                height=40,
                extra_args=args,
                env=env,
            )
        self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
        self.assertEqual(b"", result.stderr)
        return canonical_layout(result.stdout)

    def test_mono_flag_and_no_color_preserve_the_same_text_semantics(self) -> None:
        regular = self.dump("overview")
        forced = self.dump("overview", args=("--mono",))
        no_color = self.dump("overview", env={"NO_COLOR": "1"})
        self.assertEqual(regular, forced)
        self.assertEqual(regular, no_color)

    def test_all_semantic_states_have_required_text_labels(self) -> None:
        output = self.dump("providers", args=("--mono",)) + self.dump(
            "mcp", args=("--mono",)
        )
        for label in sorted(set(self.statuses.values())):
            with self.subTest(label=label):
                self.assertIn(label, output)

    def test_interactive_mono_emits_no_foreground_or_background_color_sgr(self) -> None:
        for extra_args, extra_env in (
            (("--mono",), {}),
            ((), {"NO_COLOR": "1"}),
        ):
            with self.subTest(args=extra_args, env=extra_env):
                with ScriptedControlServer(load_scenario(SCENARIO)) as server:
                    with PtySession(
                        [self.binary, "--socket", server.socket_path, *extra_args],
                        env=extra_env,
                    ) as terminal:
                        server.wait_for_request("system.snapshot")
                        terminal.wait_for_output("AsmFlow")
                        terminal.send("q")
                        self.assertEqual(0, terminal.wait())
                        self.assertEqual([], color_sgr_sequences(bytes(terminal.output)))

    def test_zero_color_terminal_and_c_locale_use_ascii_fallback(self) -> None:
        output = self.dump(
            "overview",
            env={"TERM": "vt100", "LC_ALL": "C", "LANG": "C"},
        )
        self.assertTrue(output.isascii(), repr(output))
        self.assertIn("[OK]", output)
        self.assertNotIn("┌", output)
        self.assertNotIn("│", output)


if __name__ == "__main__":
    unittest.main()
