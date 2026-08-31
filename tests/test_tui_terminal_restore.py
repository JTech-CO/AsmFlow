"""Terminal recovery after every M10 exit path named by the harness."""
from __future__ import annotations

import signal
import unittest

from tests.mock_control_server import ScriptedControlServer, load_scenario
from tests.tui_harness import (
    FIXTURES,
    PtySession,
    assert_cursor_and_screen_restored,
    require_binary,
)


SCENARIO = FIXTURES / "control_scenario.json"


class TuiTerminalRestoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = require_binary("asmflow-tui")

    def assert_restored(self, terminal: PtySession) -> None:
        terminal.assert_terminal_restored()
        assert_cursor_and_screen_restored(bytes(terminal.output))

    def test_normal_quit_restores_termios_cursor_and_screen(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with PtySession([self.binary, "--socket", server.socket_path]) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.wait_for_output("AsmFlow")
                terminal.send("q")
                self.assertEqual(0, terminal.wait())
                self.assert_restored(terminal)

    def test_sigint_uses_the_same_restore_path(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with PtySession([self.binary, "--socket", server.socket_path]) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.wait_for_output("AsmFlow")
                terminal.signal(signal.SIGINT)
                code = terminal.wait()
                self.assertIn(code, (0, 128 + signal.SIGINT, -signal.SIGINT))
                self.assert_restored(terminal)

    def test_sighup_uses_the_same_restore_path(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with PtySession([self.binary, "--socket", server.socket_path]) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.wait_for_output("AsmFlow")
                terminal.signal(signal.SIGHUP)
                code = terminal.wait(timeout=3.0)
                self.assertIn(code, (0, 128 + signal.SIGHUP, -signal.SIGHUP))
                self.assert_restored(terminal)

    def test_present_error_exits_through_the_restore_path(self) -> None:
        # A 1x1 stdscr makes ncurses report ERR when the canonical first cell
        # reaches the lower-right corner.  The writer must not turn that error
        # into a healthy interactive loop.
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with PtySession(
                [self.binary, "--socket", server.socket_path], width=1, height=1
            ) as terminal:
                server.wait_for_request("system.snapshot")
                self.assertEqual(1, terminal.wait(timeout=3.0))
                self.assert_restored(terminal)

    def test_daemon_disconnect_is_actionable_then_quit_restores_terminal(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            with PtySession([self.binary, "--socket", server.socket_path]) as terminal:
                server.wait_for_request("system.snapshot")
                terminal.wait_for_output("AsmFlow")
                server.disconnect_clients()
                try:
                    terminal.wait_for_output("DISCONNECTED", timeout=3.0)
                except AssertionError:
                    terminal.wait_for_output("STALE", timeout=3.0)
                if terminal.process.poll() is None:
                    terminal.send("q")
                code = terminal.wait()
                self.assertIn(code, (0, 1))
                self.assert_restored(terminal)


if __name__ == "__main__":
    unittest.main()
