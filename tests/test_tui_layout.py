"""Responsive and deterministic TUI layout contract (HARNESS M10 DoD 1-2)."""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import unittest
from pathlib import Path

from tests.mock_control_server import ScriptedControlServer, load_scenario
from tests.tui_harness import (
    FIXTURES,
    ROOT,
    assert_layout_bounds,
    canonical_layout,
    controlled_env,
    require_binary,
    run_layout_dump,
)


SCENARIO = FIXTURES / "control_scenario.json"
ESCAPE_SCENARIO = FIXTURES / "escape_scenario.json"
GOLDENS = FIXTURES / "goldens"


class TuiLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = require_binary("asmflow-tui")

    def dump(
        self,
        screen: str,
        width: int,
        height: int,
        *,
        scenario: Path = SCENARIO,
    ) -> str:
        with ScriptedControlServer(load_scenario(scenario)) as server:
            result = run_layout_dump(
                self.binary,
                server.socket_path,
                screen=screen,
                width=width,
                height=height,
            )
        self.assertEqual(
            0,
            result.returncode,
            f"layout dump failed:\nstdout={result.stdout!r}\nstderr={result.stderr!r}",
        )
        self.assertEqual(b"", result.stderr, "diagnostic output must not decorate stderr")
        self.assertNotIn(b"\x1b", result.stdout, "plain layout dump contains terminal escapes")
        text = canonical_layout(result.stdout)
        assert_layout_bounds(text, width, height)
        return text

    def run_tui(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        runner = shlex.split(os.environ.get("ASMFLOW_TUI_RUNNER", ""))
        return subprocess.run(
            [*runner, str(self.binary), *arguments],
            cwd=ROOT,
            env=controlled_env(),
            capture_output=True,
            timeout=10.0,
            check=False,
        )

    def test_help_and_version_exit_without_a_control_socket(self) -> None:
        for arguments in (("--help",), ("-h",), ("--mono", "--help")):
            with self.subTest(arguments=arguments):
                result = self.run_tui(*arguments)
                self.assertEqual(0, result.returncode)
                self.assertEqual(b"", result.stderr)
                self.assertIn(b"Usage:", result.stdout)
                self.assertIn(b"--dump-layout WxH", result.stdout)

        version = (ROOT / "VERSION").read_text(encoding="utf-8").strip().encode()
        for flag in ("--version", "-V"):
            with self.subTest(flag=flag):
                result = self.run_tui(flag)
                self.assertEqual(0, result.returncode)
                self.assertEqual(b"", result.stderr)
                self.assertTrue(result.stdout.startswith(b"asmflow-tui " + version + b" ("))
                self.assertTrue(result.stdout.endswith(b")\n"))

    def test_local_argument_errors_are_single_cause_usage_failures(self) -> None:
        cases = (
            (("--unknown",), b"unknown option"),
            (("--socket",), b"--socket requires"),
            (("--screen",), b"--screen requires"),
            (("--screen", "unknown"), b"--screen requires"),
            (("--dump-layout",), b"--dump-layout requires"),
            (("--dump-layout", "bad"), b"--dump-layout requires"),
            (("--dump-layout", "0x24"), b"--dump-layout requires"),
            (("--dump-layout", "513x24"), b"--dump-layout requires"),
        )
        for arguments, reason in cases:
            with self.subTest(arguments=arguments):
                result = self.run_tui(*arguments)
                self.assertEqual(2, result.returncode)
                self.assertEqual(b"", result.stdout)
                self.assertEqual(1, result.stderr.count(reason), result.stderr)
                if reason != b"--socket requires":
                    self.assertNotIn(b"--socket requires", result.stderr)
                self.assertIn(b"--help", result.stderr)

    def test_argument_diagnostics_do_not_echo_terminal_control_bytes(self) -> None:
        result = self.run_tui("--unknown\x1b[31m")
        self.assertEqual(2, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertIn(b"unknown option", result.stderr)
        self.assertNotIn(b"\x1b", result.stderr)

    def test_overview_matches_all_three_required_goldens(self) -> None:
        manifest = json.loads(
            (FIXTURES / "golden_manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual({80, 100, 140}, {entry["width"] for entry in manifest})
        for entry in manifest:
            with self.subTest(size=f"{entry['width']}x{entry['height']}"):
                actual = self.dump(
                    entry["screen"], entry["width"], entry["height"]
                )
                expected = canonical_layout(
                    (GOLDENS / entry["file"]).read_text(encoding="utf-8")
                )
                self.assertEqual(expected, actual)

    def test_every_screen_has_its_contract_anchors_at_standard_size(self) -> None:
        expectations = json.loads(
            (FIXTURES / "screen_expectations.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            {"overview", "providers", "routes", "requests", "mcp", "logs", "settings"},
            set(expectations),
        )
        for screen, anchors in expectations.items():
            with self.subTest(screen=screen):
                output = self.dump(screen, 100, 30)
                for anchor in anchors:
                    self.assertIn(anchor, output)

    def test_screens_do_not_advertise_unimplemented_enter_actions(self) -> None:
        for screen in (
            "overview",
            "providers",
            "routes",
            "requests",
            "mcp",
            "logs",
            "settings",
        ):
            with self.subTest(screen=screen):
                output = self.dump(screen, 140, 40)
                self.assertNotIn("Press Enter", output)
                self.assertNotIn("Enter opens", output)

    def test_provider_columns_collapse_by_priority_without_horizontal_scroll(self) -> None:
        wide = self.dump("providers", 140, 40)
        standard = self.dump("providers", 100, 30)
        compact = self.dump("providers", 80, 24)

        for required in ("STATUS", "NAME"):
            self.assertIn(required, wide)
            self.assertIn(required, standard)
            self.assertIn(required, compact)
        for required in ("ADAPTER", "ACTIVE/MAX", "LATENCY", "CIRCUIT"):
            self.assertIn(required, wide)
        self.assertIn("ACTIVE/MAX", standard)
        self.assertNotIn("LAST_ERROR", standard)
        self.assertNotIn("LAST_ERROR", compact)
        self.assertNotIn("LATENCY_P95", compact)

    def test_narrow_and_too_small_modes_are_actionable_and_bounded(self) -> None:
        narrow = self.dump("providers", 79, 19)
        self.assertIn("PROVIDERS", narrow)
        self.assertIn("r refresh", narrow)
        self.assertIn("? help", narrow)
        self.assertIn("q quit", narrow)
        self.assertNotIn("/ filter", narrow)
        self.assertNotIn("Enter open", narrow)

        too_small = self.dump("overview", 59, 15)
        lowered = too_small.lower()
        self.assertIn("terminal", lowered)
        self.assertIn("asmflowctl", lowered)

    def test_remote_control_sequences_are_rendered_as_text_not_executed(self) -> None:
        output = self.dump("providers", 100, 30, scenario=ESCAPE_SCENARIO)
        self.assertNotIn("\x1b", output)
        self.assertIn("한글", output)
        self.assertTrue(
            "[ESC]" in output or "^[" in output or "\\x1b" in output,
            "remote escape bytes must be visibly escaped rather than interpreted",
        )


if __name__ == "__main__":
    unittest.main()
