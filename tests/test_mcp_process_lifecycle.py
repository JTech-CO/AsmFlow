"""MCP stdio process integration (HARNESS.md M8 DoD 1-5 and 8).

These tests observe a real child through a report written by the stdio mock.
The report stays outside MCP stdout, so the assertions do not change the wire
protocol they are intended to verify.
"""
from __future__ import annotations

import json
import os
import signal
import tempfile
import time
import unittest
from pathlib import Path

from tests.test_control_protocol import DaemonUnderTest

ROOT = Path(__file__).resolve().parents[1]
MOCK = (ROOT / "tests" / "mock_mcp_stdio.py").resolve()
PYTHON = "/usr/bin/python3"
REPORT_TIMEOUT = 15.0


def mcp_configuration(
    report_path: Path,
    *,
    legacy: bool = False,
    literal_args: list[str] | None = None,
    cwd: Path | None = None,
    env_allow: list[str] | None = None,
    env: dict | None = None,
    report_environment: list[str] | None = None,
    invalid_modern_version: bool = False,
    invalid_legacy_version: bool = False,
    legacy_versions: list[str] | None = None,
):
    """Return a DaemonUnderTest mutation for one enabled stdio child."""
    arguments = [str(MOCK)]
    if legacy:
        arguments.append("--legacy")
    if invalid_modern_version:
        arguments.append("--invalid-modern-version")
    if invalid_legacy_version:
        arguments.append("--invalid-legacy-version")
    arguments.extend(["--report", str(report_path)])
    for name in report_environment or []:
        arguments.extend(["--report-env", name])
    if literal_args:
        arguments.append("--")
        arguments.extend(literal_args)

    server = {
        "id": "stdio-mock",
        "display_name": "stdio lifecycle mock",
        "transport": "stdio",
        "enabled": True,
        "required": False,
        "command": PYTHON,
        "args": arguments,
        "cwd": str((cwd or ROOT).resolve()),
        "env_allow": list(env_allow or ["PATH"]),
        "env": dict(env or {}),
        "protocol": {
            "preferred": "2026-07-28",
            "legacy": (
                ["2025-11-25"]
                if legacy_versions is None
                else list(legacy_versions)
            ),
        },
        "restart": {
            "mode": "never",
            "max_restarts": 0,
            "window_ms": 1000,
            "backoff_ms": 0,
            "max_backoff_ms": 0,
        },
        "startup_timeout_ms": 5000,
        "shutdown_grace_ms": 2000,
    }

    def mutate(document: dict) -> None:
        document["mcp_servers"] = [server]

    return mutate


def expected_modern_params() -> dict:
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    return {
        "_meta": {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": {
                "name": "AsmFlow",
                "version": version,
            },
            "io.modelcontextprotocol/clientCapabilities": {},
        }
    }


def message_for(report: dict, method: str) -> dict:
    matches = [
        message
        for message in report["messages"]
        if message.get("method") == method
    ]
    if len(matches) != 1:
        raise AssertionError(f"expected one {method!r} message, got {matches!r}")
    return matches[0]


def wait_for_report(path: Path, predicate=lambda report: True) -> dict:
    """Poll an atomically replaced report until it satisfies the predicate."""
    deadline = time.monotonic() + REPORT_TIMEOUT
    last_report = None
    last_error = None
    while time.monotonic() < deadline:
        try:
            candidate = json.loads(path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError, OSError) as exc:
            last_error = exc
        else:
            last_report = candidate
            if predicate(candidate):
                return candidate
        time.sleep(0.02)
    raise AssertionError(
        f"mock report did not reach the expected state: "
        f"path={path}, last_report={last_report!r}, last_error={last_error!r}"
    )


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for_process_exit(pid: int, timeout: float = 10.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_exists(pid):
            return True
        time.sleep(0.02)
    return not process_exists(pid)


def kill_leftover_mock(pid: int) -> None:
    """Best-effort cleanup without signalling a reused, unrelated PID."""
    try:
        command_line = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return
    if os.fsencode(str(MOCK)) not in command_line:
        return
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


class McpProcessLifecycleTests(unittest.TestCase):
    def test_modern_startup_method_sequence(self) -> None:
        expected = [
            "server/discover",
            "tools/list",
            "resources/list",
            "prompts/list",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "modern.json"
            with DaemonUnderTest(
                mutate=mcp_configuration(report_path)
            ):
                report = wait_for_report(
                    report_path,
                    lambda value: len(value.get("methods", [])) >= len(expected),
                )
                self.assertEqual(expected, report["methods"])
                for method in expected:
                    self.assertEqual(
                        expected_modern_params(),
                        message_for(report, method).get("params"),
                        f"{method} must carry the modern metadata fixture",
                    )

    def test_legacy_startup_method_sequence(self) -> None:
        expected = [
            "server/discover",
            "initialize",
            "notifications/initialized",
            "tools/list",
            "resources/list",
            "prompts/list",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "legacy.json"
            with DaemonUnderTest(
                mutate=mcp_configuration(report_path, legacy=True)
            ):
                report = wait_for_report(
                    report_path,
                    lambda value: len(value.get("methods", [])) >= len(expected),
                )
                self.assertEqual(expected, report["methods"])
                for method in expected[3:]:
                    self.assertNotIn(
                        "params",
                        message_for(report, method),
                        f"legacy {method} must not carry modern metadata",
                    )

    def test_invalid_modern_success_falls_back_without_era_interleave(self) -> None:
        expected = [
            "server/discover",
            "initialize",
            "notifications/initialized",
            "tools/list",
            "resources/list",
            "prompts/list",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "modern-fallback.json"
            with DaemonUnderTest(
                mutate=mcp_configuration(
                    report_path,
                    legacy=True,
                    invalid_modern_version=True,
                )
            ):
                report = wait_for_report(
                    report_path,
                    lambda value: len(value.get("methods", [])) >= len(expected),
                )
                self.assertEqual(expected, report["methods"])
                for method in expected[3:]:
                    self.assertNotIn("params", message_for(report, method))

    def test_invalid_modern_success_without_legacy_fails_before_inventory(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "modern-invalid.json"
            daemon = DaemonUnderTest(
                mutate=mcp_configuration(
                    report_path,
                    invalid_modern_version=True,
                    legacy_versions=[],
                )
            )
            child_pid = None
            try:
                report = wait_for_report(
                    report_path,
                    lambda value: len(value.get("methods", [])) >= 1,
                )
                child_pid = report["pid"]
                self.assertTrue(
                    wait_for_process_exit(child_pid),
                    "unsupported modern success did not fail the child",
                )
                final_report = json.loads(
                    report_path.read_text(encoding="utf-8")
                )
                self.assertEqual(
                    ["server/discover"],
                    final_report["methods"],
                    "modern inventory must not start without a mutual version",
                )
            finally:
                daemon.close()
                if child_pid is not None:
                    kill_leftover_mock(child_pid)

    def test_invalid_legacy_success_fails_before_initialized(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "legacy-invalid.json"
            daemon = DaemonUnderTest(
                mutate=mcp_configuration(
                    report_path,
                    legacy=True,
                    invalid_legacy_version=True,
                )
            )
            child_pid = None
            try:
                report = wait_for_report(
                    report_path,
                    lambda value: len(value.get("methods", [])) >= 2,
                )
                child_pid = report["pid"]
                self.assertTrue(
                    wait_for_process_exit(child_pid),
                    "wrong legacy protocolVersion did not fail the child",
                )
                final_report = json.loads(
                    report_path.read_text(encoding="utf-8")
                )
                self.assertEqual(
                    ["server/discover", "initialize"],
                    final_report["methods"],
                    "initialized/inventory must wait for a valid legacy version",
                )
            finally:
                daemon.close()
                if child_pid is not None:
                    kill_leftover_mock(child_pid)

    def test_arguments_are_literal_and_never_reach_a_shell(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report_path = root / "argv.json"
            marker = root / "shell-marker"
            literal_args = [
                f"$(/usr/bin/touch {marker})",
                "semi;colon",
                "star*question?",
                "pipe|amp&",
            ]
            with DaemonUnderTest(
                mutate=mcp_configuration(
                    report_path,
                    literal_args=literal_args,
                )
            ):
                report = wait_for_report(report_path)
                self.assertEqual(literal_args, report["literal_args"])
                self.assertEqual(literal_args, report["argv"][-len(literal_args) :])
                self.assertFalse(
                    marker.exists(),
                    "shell command substitution executed instead of staying literal",
                )
            self.assertFalse(
                marker.exists(),
                "a shell executed the marker command during child shutdown",
            )

    def test_environment_is_allowlisted_and_secret_sources_do_not_leak(self) -> None:
        long_child_name = "A_VERY_LONG_CHILD_VARIABLE"
        selected_names = ["MCP_ALLOWED", "MCP_MAPPED", long_child_name]
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "environment.json"
            with DaemonUnderTest(
                mutate=mcp_configuration(
                    report_path,
                    env_allow=["PATH", "MCP_ALLOWED"],
                    env={
                        "MCP_MAPPED": {
                            "source": "env",
                            "name": "MCP_SOURCE",
                        },
                        long_child_name: {
                            "source": "env",
                            "name": "X",
                        },
                    },
                    report_environment=selected_names,
                ),
                extra_env={
                    "MCP_ALLOWED": "allowlisted-value",
                    "MCP_SOURCE": "mapped-value",
                    "MCP_LEAK": "must-not-leak",
                    "X": "v",
                },
            ):
                report = wait_for_report(report_path)
                keys = set(report["environment"]["keys"])
                values = report["environment"]["selected"]
                self.assertIn("PATH", keys)
                self.assertIn("MCP_ALLOWED", keys)
                self.assertIn("MCP_MAPPED", keys)
                self.assertIn(long_child_name, keys)
                self.assertNotIn("MCP_LEAK", keys)
                self.assertNotIn("MCP_SOURCE", keys)
                self.assertNotIn("X", keys)
                self.assertEqual("allowlisted-value", values["MCP_ALLOWED"])
                self.assertEqual("mapped-value", values["MCP_MAPPED"])
                self.assertEqual("v", values[long_child_name])

    def test_configured_working_directory_is_applied(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            configured_cwd = root / "configured-cwd"
            configured_cwd.mkdir()
            report_path = root / "cwd.json"
            with DaemonUnderTest(
                mutate=mcp_configuration(
                    report_path,
                    cwd=configured_cwd,
                )
            ):
                report = wait_for_report(report_path)
                self.assertTrue(
                    os.path.samefile(configured_cwd, report["cwd"]),
                    f"child cwd was {report['cwd']!r}",
                )

    def test_child_is_gone_after_daemon_shutdown(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "shutdown.json"
            daemon = DaemonUnderTest(mutate=mcp_configuration(report_path))
            child_pid = None
            try:
                report = wait_for_report(report_path)
                child_pid = report["pid"]
                self.assertTrue(process_exists(child_pid))
                self.assertEqual(0, daemon.terminate())
                self.assertTrue(
                    wait_for_process_exit(child_pid),
                    f"MCP child {child_pid} survived daemon shutdown",
                )
            finally:
                daemon.close()
                if child_pid is not None:
                    kill_leftover_mock(child_pid)


if __name__ == "__main__":
    unittest.main()
