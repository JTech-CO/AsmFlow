"""asmflowctl transport, JSON-envelope, table, and exit-code contract."""
from __future__ import annotations

import json
import os
import shlex
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from tests.mock_control_server import ScriptedControlServer, load_scenario
from tests.test_control_protocol import DaemonUnderTest
from tests.tui_harness import ROOT, binary_path, canonical_layout, controlled_env, require_binary


TUI_FIXTURES = ROOT / "tests" / "fixtures" / "tui"
CLI_FIXTURES = ROOT / "tests" / "fixtures" / "cli"
SCENARIO = TUI_FIXTURES / "control_scenario.json"
U64_MASK = (1 << 64) - 1
I64_MAX = (1 << 63) - 1


def fnv1a64(payload: bytes) -> int:
    """Match the non-cryptographic configuration revision hash."""
    value = 0xCBF29CE484222325
    for byte in payload:
        value ^= byte
        value = (value * 0x100000001B3) & U64_MASK
    return value


class CliContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = require_binary("asmflowctl")

    def run_cli(
        self,
        *arguments: str,
        timeout: float = 10.0,
    ) -> subprocess.CompletedProcess[bytes]:
        runner = shlex.split(os.environ.get("ASMFLOW_CLI_RUNNER", ""))
        return subprocess.run(
            [*runner, str(self.binary), *arguments],
            cwd=ROOT,
            env=controlled_env(),
            capture_output=True,
            timeout=timeout,
            check=False,
        )

    def test_help_and_version_exit_zero_without_a_control_socket(self) -> None:
        for flag in ("--help", "-h"):
            with self.subTest(flag=flag):
                result = self.run_cli(flag)
                self.assertEqual(0, result.returncode)
                self.assertEqual(b"", result.stderr)
                self.assertIn(b"Usage:", result.stdout)
                self.assertIn(b"--socket PATH", result.stdout)

        version = (ROOT / "VERSION").read_text(encoding="utf-8").strip().encode()
        for flag in ("--version", "-V"):
            with self.subTest(flag=flag):
                result = self.run_cli(flag)
                self.assertEqual(0, result.returncode)
                self.assertEqual(b"", result.stderr)
                self.assertTrue(result.stdout.startswith(b"asmflowctl " + version + b" ("))
                self.assertTrue(result.stdout.endswith(b")\n"))

    def test_json_mode_maps_methods_and_params_and_preserves_full_envelope(self) -> None:
        cases = json.loads(
            (CLI_FIXTURES / "control_cases.json").read_text(encoding="utf-8")
        )
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            for case in cases:
                with self.subTest(method=case["method"]):
                    command = ["--socket", server.socket_path, "--json", case["method"]]
                    if case["params"] is not None:
                        command.append(
                            json.dumps(case["params"], separators=(",", ":"))
                        )
                    result = self.run_cli(*command)
                    self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
                    self.assertEqual(b"", result.stderr)
                    self.assertTrue(result.stdout.endswith(b"\n"))
                    self.assertEqual(1, result.stdout.count(b"\n"))
                    self.assertNotIn(b"\x1b", result.stdout)
                    envelope = json.loads(result.stdout.decode("utf-8"))
                    self.assertEqual({"id", "ok", "result"}, set(envelope))
                    self.assertTrue(envelope["ok"])
                    request = server.requests[-1]
                    self.assertEqual(case["method"], request["method"])
                    self.assertEqual(case["params"] or {}, request.get("params", {}))
                    if "result_keys" in case:
                        self.assertTrue(
                            set(case["result_keys"]).issubset(envelope["result"])
                        )
                    if case.get("result_type") == "list":
                        self.assertIsInstance(envelope["result"], list)

    def test_json_mode_preserves_additive_top_level_and_result_fields(self) -> None:
        scenario = {
            "methods": {
                "system.snapshot": {
                    "reply": {
                        "ok": True,
                        "result": {"revision": 44, "future_result_field": [1, 2, 3]},
                        "future_envelope_field": {"enabled": True},
                    }
                }
            }
        }
        with ScriptedControlServer(scenario) as server:
            result = self.run_cli(
                "--socket", server.socket_path, "--json", "system.snapshot", "{}"
            )
        self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
        envelope = json.loads(result.stdout.decode("utf-8"))
        self.assertEqual({"enabled": True}, envelope["future_envelope_field"])
        self.assertEqual([1, 2, 3], envelope["result"]["future_result_field"])

    def test_default_table_mode_matches_the_providers_golden(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            result = self.run_cli(
                "--socket", server.socket_path, "providers.list", "{}"
            )
        self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
        self.assertEqual(b"", result.stderr)
        self.assertNotIn(b"\x1b", result.stdout)
        expected = canonical_layout(
            (CLI_FIXTURES / "providers_table.txt").read_text(encoding="utf-8")
        )
        self.assertEqual(expected, canonical_layout(result.stdout))

    def test_daemon_error_is_full_json_envelope_and_exit_one(self) -> None:
        with ScriptedControlServer(load_scenario(SCENARIO)) as server:
            result = self.run_cli(
                "--socket", server.socket_path, "--json", "requests.list", "{}"
            )
        self.assertEqual(1, result.returncode)
        envelope = json.loads(result.stdout.decode("utf-8"))
        self.assertFalse(envelope["ok"])
        self.assertEqual("unsupported_in_this_build", envelope["error"]["code"])
        self.assertEqual(b"", result.stderr)

    def test_usage_errors_exit_two_without_contacting_the_daemon(self) -> None:
        cases = (
            (),
            ("--json",),
            ("--json", "--table", "system.version"),
            ("--json", "--json", "system.version"),
            ("--socket", "one.sock", "--socket", "two.sock", "system.version"),
            ("--unknown",),
            ("system.snapshot", "not-json"),
            ("system.snapshot", "[]"),
            ("system.snapshot", "{}", "extra"),
            ("--socket",),
            ("--socket", "", "system.version"),
            ("--socket", "/" + "x" * 108, "system.version"),
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = self.run_cli(*arguments)
                self.assertEqual(2, result.returncode)
                self.assertEqual(b"", result.stdout)
                self.assertIn(b"Usage", result.stderr)

    def test_usage_diagnostics_do_not_echo_terminal_control_bytes(self) -> None:
        result = self.run_cli("--unknown\x1b[31m")
        self.assertEqual(2, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertIn(b"unknown option", result.stderr)
        self.assertNotIn(b"\x1b", result.stderr)

    def test_connect_and_protocol_failures_exit_one(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            missing = str(Path(temporary) / "missing.sock")
            result = self.run_cli("--socket", missing, "--json", "system.version")
            self.assertEqual(1, result.returncode)
            self.assertEqual(b"", result.stdout)
            self.assertTrue(result.stderr)

    def test_peer_that_accepts_without_replying_is_time_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            socket_path = str(Path(temporary) / "stalled.sock")
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(socket_path)
            listener.listen(1)
            release = threading.Event()

            def hold_connection() -> None:
                connection, _ = listener.accept()
                try:
                    release.wait(8.0)
                finally:
                    connection.close()

            worker = threading.Thread(target=hold_connection, daemon=True)
            worker.start()
            started = time.monotonic()
            try:
                result = self.run_cli(
                    "--socket", socket_path, "--json", "system.version", timeout=8.0
                )
            finally:
                release.set()
                listener.close()
                worker.join(timeout=1.0)

        self.assertEqual(1, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertTrue(result.stderr)
        self.assertLess(time.monotonic() - started, 7.0)

        for reply in (
            {"ok": True, "result": {}, "_response_id": "wrong-id"},
            {"_raw": "this is not json"},
        ):
            scenario = {"methods": {"system.version": {"reply": reply}}}
            with ScriptedControlServer(scenario) as server:
                result = self.run_cli(
                    "--socket", server.socket_path, "--json", "system.version"
                )
            self.assertEqual(1, result.returncode)
            self.assertEqual(b"", result.stdout)
            self.assertTrue(result.stderr)

    def test_json_mode_round_trips_against_the_real_daemon(self) -> None:
        # DaemonUnderTest owns the one centralized buildless skip for asmflowd.
        with DaemonUnderTest() as daemon:
            result = self.run_cli(
                "--socket", daemon.socket_path, "--json", "system.version"
            )
        self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
        envelope = json.loads(result.stdout.decode("utf-8"))
        self.assertTrue(envelope["ok"])
        self.assertEqual(
            (ROOT / "VERSION").read_text(encoding="utf-8").strip(),
            envelope["result"]["version"],
        )

    def test_high_bit_config_hash_round_trips_through_the_cli_parser(self) -> None:
        """The full unsigned hash domain stays exact on the control wire.

        Jansson's integer domain is signed 64-bit. Before config hashes became
        canonical decimal strings, a perfectly valid configuration whose FNV
        hash had bit 63 set made asmflowctl reject the daemon's whole response.
        The fixture is constructed deterministically rather than waiting for a
        temporary path to make the failure appear by chance.
        """
        forced_hash: list[int] = []

        def force_high_bit_hash(document: dict) -> None:
            base = document["providers"][0]["display_name"]
            for nonce in range(256):
                document["providers"][0]["display_name"] = f"{base} {nonce}"
                candidate = fnv1a64(json.dumps(document).encode("utf-8"))
                if candidate > I64_MAX:
                    forced_hash.append(candidate)
                    return
            raise AssertionError("could not construct a high-bit config hash")

        with DaemonUnderTest(mutate=force_high_bit_hash) as daemon:
            with daemon.connect() as client:
                current = client.call("config.current")
                diagnostics = client.call("diagnostics.export")
            result = self.run_cli(
                "--socket",
                daemon.socket_path,
                "--json",
                "diagnostics.export",
                "{}",
            )

        self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
        expected = str(forced_hash[0])
        self.assertEqual(expected, current["config_hash"])
        self.assertEqual(expected, diagnostics["config_hash"])
        self.assertEqual(expected, diagnostics["config"]["config_hash"])
        envelope = json.loads(result.stdout.decode("utf-8"))
        self.assertEqual(expected, envelope["result"]["config_hash"])


if __name__ == "__main__":
    unittest.main()
