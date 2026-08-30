"""MCP stdio failure and supervision integration (HARNESS.md M8).

Every test drives a real asmflowd and a real child process.  The control
socket is the observer: crash accounting, state transitions, and PIDs belong
to the assembly supervisor, not to the Python mock.
"""
from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path
from typing import Callable

from tests.control_client import ControlClient
from tests.http_harness import free_port, get
from tests.test_control_protocol import DaemonUnderTest
from tests.test_mcp_process_lifecycle import (
    kill_leftover_mock,
    mcp_configuration,
    wait_for_process_exit,
    wait_for_report,
)

SERVER_ID = "stdio-mock"
SERVER_PARAMS = {"server_id": SERVER_ID}
POLL_INTERVAL = 0.02
SUPERVISION_TIMEOUT = 20.0
REPO_VERSION = (
    Path(__file__).resolve().parents[1] / "VERSION"
).read_text(encoding="utf-8").strip()


def supervision_configuration(
    report_path: Path,
    *,
    mock_arguments: list[str] | None = None,
    restart: dict | None = None,
    frame_max_bytes: int | None = None,
    stderr_line_max_bytes: int | None = None,
    required: bool = False,
    listener_port: int | None = None,
):
    """Wrap the lifecycle fixture with failure-mode and supervision settings."""
    base_mutation = mcp_configuration(report_path)

    def mutate(document: dict) -> None:
        base_mutation(document)
        server = document["mcp_servers"][0]
        server["args"][1:1] = list(mock_arguments or [])
        server["shutdown_grace_ms"] = 100
        server["required"] = required
        if restart is not None:
            server["restart"] = dict(restart)
        if frame_max_bytes is not None:
            document["limits"]["mcp_frame_max_bytes"] = frame_max_bytes
        if stderr_line_max_bytes is not None:
            document["limits"]["stderr_line_max_bytes"] = stderr_line_max_bytes
        if listener_port is not None:
            document["listener"]["host"] = "127.0.0.1"
            document["listener"]["port"] = listener_port

    return mutate


def two_server_configuration(
    first_report: Path,
    second_report: Path,
    *,
    second_arguments: list[str],
    second_restart: dict,
):
    """Configure two independent real stdio children for index regressions."""
    first_mutation = mcp_configuration(first_report)
    second_mutation = mcp_configuration(second_report)

    def mutate(document: dict) -> None:
        first_mutation(document)
        first = document["mcp_servers"][0]
        first["id"] = "stdio-first"
        first["display_name"] = "first stdio mock"

        second_document: dict = {}
        second_mutation(second_document)
        second = second_document["mcp_servers"][0]
        second["id"] = "stdio-second"
        second["display_name"] = "second stdio mock"
        second["args"][1:1] = list(second_arguments)
        second["restart"] = dict(second_restart)
        document["mcp_servers"] = [first, second]

    return mutate


def streamable_http_configuration(listener_port: int):
    """Configure one required HTTP transport whose endpoint cannot resolve."""
    server = {
        "id": "http-future",
        "display_name": "future HTTP MCP",
        "transport": "streamable_http",
        "enabled": True,
        "required": True,
        "url": "https://mcp.example.invalid/mcp",
        "auth": {"type": "none"},
        "protocol": {
            "preferred": "2026-07-28",
            "legacy": [],
        },
        "timeouts": {
            "connect_ms": 1000,
            "request_ms": 1000,
            "idle_stream_ms": 1000,
        },
    }

    def mutate(document: dict) -> None:
        document["listener"]["host"] = "127.0.0.1"
        document["listener"]["port"] = listener_port
        document["mcp_servers"] = [server]

    return mutate


class StartupDaemonUnderTest(DaemonUnderTest):
    """Wait for startup completion without requiring dependency readiness."""

    def _is_ready(self) -> bool:
        try:
            with ControlClient(self.socket_path) as client:
                client.call("system.version")
            return True
        except (OSError, EOFError, ValueError):
            return False


def wait_for_server(
    client: ControlClient,
    predicate: Callable[[dict], bool],
    *,
    timeout: float = SUPERVISION_TIMEOUT,
    server_id: str = SERVER_ID,
) -> dict:
    """Poll mcp.get using a monotonic, bounded deadline."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = client.call("mcp.get", {"server_id": server_id})
        if predicate(last):
            return last
        time.sleep(POLL_INTERVAL)
    raise AssertionError(f"MCP server did not reach the expected state: {last!r}")


def direct_children(parent_pid: int) -> list[int]:
    """Return Linux's direct-child snapshot for the daemon's main task."""
    path = Path(f"/proc/{parent_pid}/task/{parent_pid}/children")
    try:
        text = path.read_text(encoding="ascii").strip()
    except FileNotFoundError:
        return []
    return [int(value) for value in text.split()] if text else []


def process_state(pid: int) -> str | None:
    """Read one /proc state without being confused by spaces in comm."""
    try:
        stat_line = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except FileNotFoundError:
        return None
    closing_paren = stat_line.rfind(")")
    return stat_line[closing_paren + 2 :].split(" ", 1)[0]


def wait_for_no_children(parent_pid: int, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    last: list[tuple[int, str | None]] = []
    while time.monotonic() < deadline:
        last = [(pid, process_state(pid)) for pid in direct_children(parent_pid)]
        if not last:
            return
        time.sleep(POLL_INTERVAL)
    raise AssertionError(f"daemon retained child processes: {last!r}")


def wait_for_readyz(
    port: int,
    expected_status: int,
    *,
    timeout: float = SUPERVISION_TIMEOUT,
):
    deadline = time.monotonic() + timeout
    last_response = None
    last_error = None
    while time.monotonic() < deadline:
        try:
            last_response = get(port, "/readyz")
            last_error = None
        except (OSError, AssertionError, ValueError) as error:
            last_error = error
        else:
            if last_response.status == expected_status:
                return last_response
        time.sleep(POLL_INTERVAL)
    raise AssertionError(
        f"/readyz did not become {expected_status}: "
        f"last_response={last_response!r}, last_error={last_error!r}"
    )


class McpMalformedStdioTests(unittest.TestCase):
    def assert_protocol_failure(
        self,
        mode: str,
        *,
        frame_max_bytes: int | None = None,
        counter: str = "contaminated",
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / f"{mode}.json"
            arguments = ["--stdout-malformed", mode]
            if mode == "oversized":
                arguments.extend(["--oversized-bytes", "8192"])
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=arguments,
                    frame_max_bytes=frame_max_bytes,
                )
            ) as daemon, daemon.connect() as client:
                server = wait_for_server(
                    client,
                    lambda value: (
                        value["state"] == "failed"
                        and value["pid"] == 0
                        and value[counter] >= 1
                    ),
                )
                self.assertEqual("unknown", server["era"])
                self.assertIsNone(server["protocol_version"])

    def test_stdout_noise_is_protocol_contamination(self) -> None:
        self.assert_protocol_failure("noise")

    def test_invalid_utf8_json_is_protocol_contamination(self) -> None:
        self.assert_protocol_failure("invalid-utf8")

    def test_oversized_stdout_line_is_rejected_at_the_configured_limit(self) -> None:
        self.assert_protocol_failure(
            "oversized",
            frame_max_bytes=1024,
            counter="oversized",
        )

    def test_stderr_flood_is_drained_and_truncated_without_blocking_stdout(
        self,
    ) -> None:
        flood_bytes = 128 * 1024
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "stderr-flood.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=["--stderr-bytes", str(flood_bytes)],
                    stderr_line_max_bytes=256,
                )
            ) as daemon, daemon.connect() as client:
                server = wait_for_server(
                    client,
                    lambda value: (
                        value["state"] == "ready"
                        and value["stderr_bytes"] >= flood_bytes
                        and value["stderr_truncated"] >= 1
                    ),
                )
                self.assertEqual("modern_2026", server["era"])
                self.assertGreaterEqual(server["frames_in"], 1)
                self.assertGreaterEqual(server["frames_out"], 1)

    def test_stderr_eof_source_is_dropped_while_protocol_stays_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "stderr-eof.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=["--close-stderr-at-start"],
                )
            ) as daemon, daemon.connect() as client:
                server = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1,
                )
                self.assertGreater(server["pid"], 0)
                self.assertEqual(REPO_VERSION, client.call("system.version")["version"])

    def test_stdout_eof_from_live_child_is_bounded_and_reaped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "stdout-eof.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=[
                        "--stdout-eof-after",
                        "1",
                        "--resist-shutdown",
                    ],
                )
            ) as daemon, daemon.connect() as client:
                failed = wait_for_server(
                    client,
                    lambda value: value["state"] == "failed"
                    and value["pid"] == 0,
                )
                self.assertEqual(9, failed["last_signal"])
                self.assertEqual(REPO_VERSION, client.call("system.version")["version"])
                wait_for_no_children(daemon.process.pid)

    def test_server_initiated_request_is_recorded_without_contamination(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "server-request.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=["--server-request-after-inventory"],
                )
            ) as daemon, daemon.connect() as client:
                emitted = wait_for_report(
                    report_path,
                    lambda value: len(
                        value.get("lifecycle", {}).get(
                            "server_request_history_monotonic_ns", []
                        )
                    )
                    == 1,
                )
                self.assertEqual(
                    1,
                    len(
                        emitted["lifecycle"][
                            "server_request_history_monotonic_ns"
                        ]
                    ),
                )
                ready = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1
                    and value["notifications"] == 1,
                )
                child_pid = ready["pid"]
                self.assertEqual("2026-07-28", ready["protocol_version"])
                self.assertEqual(0, ready["contaminated"])
                time.sleep(0.2)
                still_ready = client.call("mcp.get", SERVER_PARAMS)
                self.assertEqual("ready", still_ready["state"])
                self.assertEqual(child_pid, still_ready["pid"])
                self.assertEqual(1, still_ready["notifications"])
                self.assertEqual(0, still_ready["contaminated"])
                final_report = wait_for_report(report_path)
                unexpected_replies = [
                    message
                    for message in final_report["messages"]
                    if message.get("id") == 9001
                    and "method" not in message
                ]
                self.assertEqual([], unexpected_replies)


class McpRequiredReadinessTests(unittest.TestCase):
    def test_required_server_waits_for_complete_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "required-delayed.json"
            port = free_port()
            with StartupDaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=["--tools-delay-ms", "750"],
                    required=True,
                    listener_port=port,
                )
            ) as daemon, daemon.connect() as client:
                pending = wait_for_readyz(port, 503)
                self.assertEqual("not_ready", pending.json()["status"])
                ready = wait_for_readyz(port, 200)
                self.assertEqual("ready", ready.json()["status"])
                wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1,
                )
                inventory = client.call("mcp.inventory", SERVER_PARAMS)
                self.assertEqual(
                    ["echo"], [tool["name"] for tool in inventory["tools"]]
                )
                self.assertEqual([], inventory["resources"])
                self.assertEqual([], inventory["prompts"])
                self.assertEqual(1, inventory["tool_count"])
                self.assertEqual(0, inventory["resource_count"])
                self.assertEqual(0, inventory["prompt_count"])

    def test_required_server_stays_not_ready_on_inventory_failures(self) -> None:
        cases = (
            ("error", ["--tools-error"]),
            ("invalid", ["--tools-invalid-shape"]),
            (
                "invalid-scalar-element",
                ["--tools-invalid-element", "scalar"],
            ),
            (
                "invalid-object-element",
                ["--tools-invalid-element", "object"],
            ),
            ("timeout", ["--tools-timeout"]),
        )
        for name, arguments in cases:
            with self.subTest(mode=name), tempfile.TemporaryDirectory() as temporary:
                report_path = Path(temporary) / f"required-{name}.json"
                port = free_port()
                with StartupDaemonUnderTest(
                    mutate=supervision_configuration(
                        report_path,
                        mock_arguments=arguments,
                        required=True,
                        listener_port=port,
                    )
                ) as daemon, daemon.connect() as client:
                    server = wait_for_server(
                        client,
                        lambda value: value["state"] == "degraded",
                    )
                    self.assertEqual(SERVER_ID, server["id"])
                    self.assertEqual(
                        "2026-07-28",
                        server["protocol_version"],
                    )
                    self.assertEqual(0, server["tool_count"])
                    response = wait_for_readyz(port, 503)
                    self.assertEqual("not_ready", response.json()["status"])
                    inventory = client.call("mcp.inventory", SERVER_PARAMS)
                    self.assertIsNone(inventory["tools"])

    def test_optional_inventory_failures_do_not_degrade_tools(self) -> None:
        cases = (
            ("resources-error", "--resources-error", "resources"),
            (
                "resources-invalid-element",
                "--resources-invalid-element",
                "resources",
            ),
            ("prompts-invalid", "--prompts-invalid-shape", "prompts"),
            (
                "prompts-invalid-element",
                "--prompts-invalid-element",
                "prompts",
            ),
        )
        for name, flag, missing_key in cases:
            with self.subTest(mode=name), tempfile.TemporaryDirectory() as temporary:
                report_path = Path(temporary) / f"optional-{name}.json"
                port = free_port()
                with StartupDaemonUnderTest(
                    mutate=supervision_configuration(
                        report_path,
                        mock_arguments=[flag],
                        required=True,
                        listener_port=port,
                    )
                ) as daemon, daemon.connect() as client:
                    server = wait_for_server(
                        client,
                        lambda value: value["state"] == "ready"
                        and value["tool_count"] == 1
                        and value["frames_in"] >= 4,
                    )
                    self.assertEqual("ready", server["state"])
                    self.assertEqual(200, wait_for_readyz(port, 200).status)
                    inventory = client.call("mcp.inventory", SERVER_PARAMS)
                    self.assertIsNone(inventory[missing_key])

    def test_optional_failed_child_does_not_lower_global_readiness(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "optional-failed-child.json"
            port = free_port()
            with StartupDaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=["--tools-invalid-shape"],
                    required=False,
                    listener_port=port,
                )
            ) as daemon, daemon.connect() as client:
                wait_for_server(
                    client,
                    lambda value: value["state"] == "degraded",
                )
                snapshot = client.call("system.snapshot")
                self.assertTrue(snapshot["ready"])
                response = wait_for_readyz(port, 200)
                self.assertEqual(
                    {"required": 0, "ready": 0},
                    response.json()["mcp"],
                )

    def test_required_streamable_http_failure_lowers_readiness(self) -> None:
        port = free_port()
        with StartupDaemonUnderTest(
            mutate=streamable_http_configuration(port)
        ) as daemon, daemon.connect() as client:
            server = wait_for_server(
                client,
                lambda value: value["state"] == "failed",
                server_id="http-future",
            )
            snapshot = client.call("system.snapshot")
            self.assertFalse(snapshot["ready"])
            response = wait_for_readyz(port, 503)
            self.assertEqual("not_ready", response.json()["status"])
            self.assertEqual(
                {"required": 1, "ready": 0},
                response.json()["mcp"],
            )
            self.assertEqual("http-future", server["id"])
            self.assertEqual("unknown", server["era"])
            self.assertEqual(0, server["pid"])

    def test_failed_refresh_preserves_cache_then_manual_retry_recovers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "refresh-recovery.json"
            port = free_port()
            with StartupDaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=["--tools-invalid-on", "2"],
                    required=True,
                    listener_port=port,
                )
            ) as daemon, daemon.connect() as client:
                wait_for_readyz(port, 200)
                wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1,
                )
                original = client.call("mcp.inventory", SERVER_PARAMS)
                self.assertEqual(
                    ["echo"], [tool["name"] for tool in original["tools"]]
                )

                client.call("mcp.discover", SERVER_PARAMS)
                wait_for_server(
                    client,
                    lambda value: value["state"] == "degraded",
                )
                self.assertEqual(503, wait_for_readyz(port, 503).status)
                stale = client.call("mcp.inventory", SERVER_PARAMS)
                self.assertEqual(original["tools"], stale["tools"])
                self.assertEqual(original["tool_count"], stale["tool_count"])

                client.call("mcp.discover", SERVER_PARAMS)
                recovered = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1,
                )
                self.assertEqual("ready", recovered["state"])
                self.assertEqual(200, wait_for_readyz(port, 200).status)


class McpLegacyProcessResetTests(unittest.TestCase):
    def test_discover_timeout_restarts_fresh_into_legacy_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "legacy-process-reset.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=[
                        "--legacy",
                        "--discover-timeout-first-process",
                    ],
                )
            ) as daemon, daemon.connect() as client:
                ready = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["era"] == "legacy_2025"
                    and value["tool_count"] == 1
                    and value["starts"] >= 2,
                )
                first_fallback_report = wait_for_report(
                    report_path,
                    lambda value: (
                        len(
                            value.get("lifecycle", {}).get(
                                "process_pid_history", []
                            )
                        )
                        >= 2
                        and len(
                            value.get("lifecycle", {}).get(
                                "cancel_pid_history", []
                            )
                        )
                        >= 1
                        and len(
                            value.get("lifecycle", {}).get(
                                "initialize_pid_history", []
                            )
                        )
                        >= 1
                    ),
                )
                lifecycle = first_fallback_report["lifecycle"]
                first_pid, second_pid = lifecycle["process_pid_history"][:2]
                self.assertNotEqual(first_pid, second_pid)
                self.assertEqual(second_pid, ready["pid"])
                self.assertEqual([first_pid], lifecycle["discover_pid_history"])
                self.assertEqual([first_pid], lifecycle["cancel_pid_history"])
                self.assertNotIn(first_pid, lifecycle["initialize_pid_history"])
                self.assertEqual(
                    second_pid,
                    lifecycle["initialize_pid_history"][0],
                )
                self.assertEqual("initialize", first_fallback_report["methods"][0])
                self.assertNotIn(
                    "server/discover",
                    first_fallback_report["methods"],
                )
                self.assertEqual("2025-11-25", ready["protocol_version"])
                self.assertEqual(0, ready["restarts"])
                self.assertTrue(wait_for_process_exit(first_pid))

                restart_queued = client.call("mcp.restart", SERVER_PARAMS)
                self.assertEqual("restarting", restart_queued["state"])
                self.assertIsNone(restart_queued["protocol_version"])
                restarted = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["era"] == "legacy_2025"
                    and value["pid"] > 0
                    and value["pid"] != second_pid
                    and value["starts"] >= 3,
                )
                third_pid = restarted["pid"]
                self.assertEqual(
                    "2025-11-25",
                    restarted["protocol_version"],
                )
                final_report = wait_for_report(
                    report_path,
                    lambda value: (
                        len(
                            value.get("lifecycle", {}).get(
                                "process_pid_history", []
                            )
                        )
                        >= 3
                        and third_pid
                        in value.get("lifecycle", {}).get(
                            "discover_pid_history", []
                        )
                        and third_pid
                        in value.get("lifecycle", {}).get(
                            "initialize_pid_history", []
                        )
                    ),
                )
                final_lifecycle = final_report["lifecycle"]
                self.assertEqual(
                    [first_pid, third_pid],
                    final_lifecycle["discover_pid_history"],
                )
                self.assertEqual(
                    [second_pid, third_pid],
                    final_lifecycle["initialize_pid_history"],
                )
                self.assertEqual(
                    [first_pid],
                    final_lifecycle["cancel_pid_history"],
                )
                self.assertEqual("server/discover", final_report["methods"][0])
                self.assertTrue(wait_for_process_exit(second_pid))
                self.assertIsNone(daemon.process.poll())


class McpRequestTimeoutTests(unittest.TestCase):
    def assert_timeout_cancellation(self, *, legacy: bool) -> None:
        era = "legacy_2025" if legacy else "modern_2026"
        mock_arguments = ["--tool-call-timeout"]
        if legacy:
            mock_arguments.insert(0, "--legacy")
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / f"{era}-tool-timeout-cancel.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=mock_arguments,
                )
            ) as daemon, daemon.connect() as client:
                wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1
                    and value["era"] == era,
                )
                queued = client.call(
                    "mcp.tool_test",
                    {
                        "server_id": SERVER_ID,
                        "tool": "echo",
                        "arguments": {"text": "time-out"},
                        "confirmed": True,
                    },
                )
                request_id = queued["request_id"]
                wait_for_server(
                    client,
                    lambda value: value.get("tool_test", {}).get(
                        "request_id"
                    )
                    == request_id
                    and value["tool_test"]["state"] == "pending",
                )

                report = wait_for_report(
                    report_path,
                    lambda value: any(
                        message.get("method") == "notifications/cancelled"
                        for message in value.get("messages", [])
                    ),
                )
                cancellations = [
                    message
                    for message in report["messages"]
                    if message.get("method") == "notifications/cancelled"
                ]
                self.assertEqual(
                    [
                        {
                            "jsonrpc": "2.0",
                            "method": "notifications/cancelled",
                            "params": {
                                "requestId": request_id,
                                "reason": "request timeout",
                            },
                        }
                    ],
                    cancellations,
                )
                completed = wait_for_server(
                    client,
                    lambda value: value.get("tool_test", {}).get(
                        "request_id"
                    )
                    == request_id
                    and value["tool_test"]["state"] == "done",
                )
                self.assertEqual(-175, completed["tool_test"]["status"])
                self.assertIsNone(completed["tool_test"]["result"])

    def test_modern_timed_out_tool_call_emits_cancellation(self) -> None:
        self.assert_timeout_cancellation(legacy=False)

    def test_legacy_timed_out_tool_call_emits_cancellation(self) -> None:
        self.assert_timeout_cancellation(legacy=True)


class McpCrashLoopTests(unittest.TestCase):
    def test_second_child_restarts_on_tick_without_corrupting_first(self) -> None:
        restart = {
            "mode": "on_failure",
            "max_restarts": 1,
            "window_ms": 5000,
            "backoff_ms": 0,
            "max_backoff_ms": 0,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first_report = root / "first.json"
            second_report = root / "second.json"
            with DaemonUnderTest(
                mutate=two_server_configuration(
                    first_report,
                    second_report,
                    second_arguments=[
                        "--exit-after",
                        "4",
                        "--exit-first-process-only",
                    ],
                    second_restart=restart,
                )
            ) as daemon, daemon.connect() as client:
                first = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1,
                    server_id="stdio-first",
                )
                second = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1
                    and value["starts"] >= 2,
                    server_id="stdio-second",
                )
                self.assertEqual(1, first["starts"])
                self.assertEqual(0, first["exits"])
                self.assertEqual(2, second["starts"])
                self.assertEqual(1, second["exits"])
                self.assertEqual(1, second["restarts"])
                for server_id in ("stdio-first", "stdio-second"):
                    inventory = client.call(
                        "mcp.inventory",
                        {"server_id": server_id},
                    )
                    self.assertEqual(1, inventory["tool_count"])
                    self.assertEqual("echo", inventory["tools"][0]["name"])
                client.call("system.version")
                self.assertIsNone(daemon.process.poll())

    def test_disabled_child_rejects_lifecycle_actions_without_losing_latch(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "disabled.json"
            base_mutation = supervision_configuration(report_path)

            def disabled_configuration(document: dict) -> None:
                base_mutation(document)
                document["mcp_servers"][0]["enabled"] = False

            with DaemonUnderTest(
                mutate=disabled_configuration
            ) as daemon, daemon.connect() as client:
                disabled = wait_for_server(
                    client,
                    lambda value: value["state"] == "disabled"
                    and value["pid"] == 0,
                )
                self.assertEqual(0, disabled["starts"])
                for method in (
                    "mcp.stop",
                    "mcp.start",
                    "mcp.reset_crash_loop",
                ):
                    with self.subTest(method=method):
                        rejected = client.call_expect_error(method, SERVER_PARAMS)
                        self.assertEqual(
                            "invalid_state", rejected["error"]["code"]
                        )
                preserved = client.call("mcp.get", SERVER_PARAMS)
                self.assertEqual("disabled", preserved["state"])
                self.assertEqual(0, preserved["pid"])
                self.assertEqual(0, preserved["starts"])

    def test_on_failure_does_not_restart_a_clean_exit(self) -> None:
        restart = {
            "mode": "on_failure",
            "max_restarts": 2,
            "window_ms": 5000,
            "backoff_ms": 10,
            "max_backoff_ms": 20,
        }
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "clean-on-failure.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=[
                        "--exit-after",
                        "1",
                        "--exit-code",
                        "0",
                    ],
                    restart=restart,
                )
            ) as daemon, daemon.connect() as client:
                stopped = wait_for_server(
                    client,
                    lambda value: value["state"] == "stopped"
                    and value["pid"] == 0
                    and value["exits"] == 1,
                )
                self.assertEqual(1, stopped["starts"])
                self.assertEqual(0, stopped["restarts"])
                self.assertEqual(0, stopped["last_exit"])
                time.sleep(0.35)
                still_stopped = client.call("mcp.get", SERVER_PARAMS)
                self.assertEqual("stopped", still_stopped["state"])
                self.assertEqual(1, still_stopped["starts"])
                rejected = client.call_expect_error(
                    "mcp.reset_crash_loop", SERVER_PARAMS
                )
                self.assertEqual("invalid_state", rejected["error"]["code"])
                after_rejected_reset = client.call("mcp.get", SERVER_PARAMS)
                self.assertEqual("stopped", after_rejected_reset["state"])
                self.assertEqual(1, after_rejected_reset["starts"])

    def test_always_restarts_a_clean_exit(self) -> None:
        restart = {
            "mode": "always",
            "max_restarts": 2,
            "window_ms": 5000,
            "backoff_ms": 10,
            "max_backoff_ms": 20,
        }
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "clean-always.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=[
                        "--exit-after",
                        "1",
                        "--exit-code",
                        "0",
                        "--exit-first-process-only",
                    ],
                    restart=restart,
                )
            ) as daemon, daemon.connect() as client:
                restarted = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["pid"] > 0
                    and value["starts"] >= 2,
                )
                self.assertEqual(1, restarted["exits"])
                self.assertEqual(1, restarted["restarts"])
                self.assertEqual(0, restarted["last_exit"])

    def test_protocol_failure_restarts_even_when_child_exits_zero(self) -> None:
        restart = {
            "mode": "on_failure",
            "max_restarts": 2,
            "window_ms": 5000,
            "backoff_ms": 10,
            "max_backoff_ms": 20,
        }
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "protocol-exit-zero.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=[
                        "--stdout-malformed",
                        "noise",
                        "--malformed-first-process-only",
                        "--exit-after",
                        "1",
                        "--exit-code",
                        "0",
                        "--exit-first-process-only",
                    ],
                    restart=restart,
                )
            ) as daemon, daemon.connect() as client:
                restarted = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["pid"] > 0
                    and value["starts"] >= 2,
                )
                self.assertEqual(1, restarted["exits"])
                self.assertEqual(1, restarted["restarts"])
                self.assertGreaterEqual(restarted["contaminated"], 1)

    def test_zero_backoff_restarts_on_the_next_supervisor_tick(self) -> None:
        restart = {
            "mode": "on_failure",
            "max_restarts": 1,
            "window_ms": 5000,
            "backoff_ms": 0,
            "max_backoff_ms": 0,
        }
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "zero-backoff.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=[
                        "--exit-after",
                        "1",
                        "--exit-delay-ms",
                        "50",
                        "--exit-first-process-only",
                    ],
                    restart=restart,
                )
            ) as daemon, daemon.connect() as client:
                first = wait_for_server(
                    client,
                    lambda value: value["starts"] == 1 and value["pid"] > 0,
                )
                self.assertEqual(0, first["restarts"])
                restarted = wait_for_server(
                    client,
                    lambda value: value["starts"] >= 2,
                )
                observed_restart_ns = time.monotonic_ns()
                self.assertEqual(1, restarted["restarts"])
                report = wait_for_report(
                    report_path,
                    lambda value: len(
                        value.get("lifecycle", {}).get(
                            "exit_history_monotonic_ns", []
                        )
                    )
                    >= 1,
                )
                first_exit_ns = report["lifecycle"][
                    "exit_history_monotonic_ns"
                ][0]
                restart_latency_ns = observed_restart_ns - first_exit_ns
                self.assertGreaterEqual(restart_latency_ns, 0)
                self.assertLess(
                    restart_latency_ns,
                    500_000_000,
                    "zero backoff waited as though a 500ms fallback were applied",
                )

    def test_crash_budget_latches_until_manual_reset(self) -> None:
        restart = {
            "mode": "on_failure",
            "max_restarts": 2,
            "window_ms": 5000,
            "backoff_ms": 10,
            "max_backoff_ms": 20,
        }
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "crash-loop.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=["--exit-after", "1"],
                    restart=restart,
                )
            ) as daemon, daemon.connect() as client:
                latched = wait_for_server(
                    client,
                    lambda value: value["state"] == "crash_loop"
                    and value["pid"] == 0,
                )
                self.assertEqual(3, latched["starts"])
                self.assertEqual(3, latched["exits"])
                self.assertEqual(2, latched["restarts"])

                starts_before_reset = latched["starts"]
                time.sleep(0.35)
                still_latched = client.call("mcp.get", SERVER_PARAMS)
                self.assertEqual("crash_loop", still_latched["state"])
                self.assertEqual(starts_before_reset, still_latched["starts"])

                for method in ("mcp.stop", "mcp.start"):
                    with self.subTest(method=method):
                        rejected = client.call_expect_error(method, SERVER_PARAMS)
                        self.assertEqual(
                            "invalid_state", rejected["error"]["code"]
                        )
                preserved = client.call("mcp.get", SERVER_PARAMS)
                self.assertEqual("crash_loop", preserved["state"])
                self.assertEqual(starts_before_reset, preserved["starts"])

                reset_result = client.call(
                    "mcp.reset_crash_loop",
                    SERVER_PARAMS,
                )
                self.assertEqual(SERVER_ID, reset_result["id"])
                relatched = wait_for_server(
                    client,
                    lambda value: (
                        value["state"] == "crash_loop"
                        and value["starts"] > starts_before_reset
                        and value["pid"] == 0
                    ),
                )
                self.assertEqual(starts_before_reset + 3, relatched["starts"])
                self.assertEqual(2, relatched["restarts"])


class McpZombieSoakTests(unittest.TestCase):
    def assert_leader_exit_reaps_same_group_helper(
        self,
        mock_arguments: list[str],
        expected_state: str,
    ) -> None:
        helper_pid = None
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "process-group.json"
            try:
                with DaemonUnderTest(
                    mutate=supervision_configuration(
                        report_path,
                        mock_arguments=["--fork-helper", *mock_arguments],
                    )
                ) as daemon, daemon.connect() as client:
                    report = wait_for_report(
                        report_path,
                        lambda value: len(
                            value.get("lifecycle", {}).get(
                                "helper_pid_history", []
                            )
                        )
                        == 1,
                    )
                    leader_pid = report["pid"]
                    helper_pid = report["lifecycle"][
                        "helper_pid_history"
                    ][0]
                    helper_pgid = report["lifecycle"][
                        "helper_pgid_history"
                    ][0]
                    self.assertNotEqual(leader_pid, helper_pid)
                    self.assertEqual(leader_pid, report["pgid"])
                    self.assertEqual(leader_pid, helper_pgid)

                    terminal = wait_for_server(
                        client,
                        lambda value: value["state"] == expected_state
                        and value["pid"] == 0
                        and value["exits"] >= 1,
                    )
                    self.assertEqual(0, terminal["pid"])
                    self.assertTrue(wait_for_process_exit(leader_pid))
                    self.assertTrue(
                        wait_for_process_exit(helper_pid),
                        f"same-PGID helper {helper_pid} survived leader exit",
                    )
                    self.assertIsNone(daemon.process.poll())
            finally:
                if helper_pid is not None and not wait_for_process_exit(
                    helper_pid,
                    timeout=0.1,
                ):
                    kill_leftover_mock(helper_pid)

    def test_clean_leader_exit_reaps_same_group_helper(self) -> None:
        self.assert_leader_exit_reaps_same_group_helper(
            ["--exit-after", "4", "--exit-code", "0"],
            "stopped",
        )

    def test_failed_leader_exit_reaps_same_group_helper(self) -> None:
        self.assert_leader_exit_reaps_same_group_helper(
            ["--exit-after", "1", "--exit-code", "7"],
            "failed",
        )

    def test_stdout_eof_leader_exit_reaps_same_group_helper(self) -> None:
        self.assert_leader_exit_reaps_same_group_helper(
            ["--stdout-eof-after", "1"],
            "stopped",
        )

    def test_stop_escalates_to_sigkill_and_reaps_resistant_child(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "resistant-stop.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=["--resist-shutdown"],
                )
            ) as daemon, daemon.connect() as client:
                current = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1
                    and value["pid"] > 0,
                )
                child_pid = current["pid"]
                started = time.monotonic()
                client.call("mcp.stop", SERVER_PARAMS)
                stopped = wait_for_server(
                    client,
                    lambda value: value["state"] == "stopped"
                    and value["pid"] == 0,
                    timeout=8.0,
                )
                elapsed = time.monotonic() - started
                self.assertEqual(9, stopped["last_signal"])
                self.assertLess(elapsed, 6.0)
                self.assertTrue(wait_for_process_exit(child_pid))
                wait_for_no_children(daemon.process.pid)

    def test_stop_releases_pending_tool_call_and_reaps_child(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "pending-tool-stop.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(
                    report_path,
                    mock_arguments=["--tool-call-delay-ms", "5000"],
                )
            ) as daemon, daemon.connect() as client:
                current = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1
                    and value["pid"] > 0,
                )
                child_pid = current["pid"]
                queued = client.call(
                    "mcp.tool_test",
                    {
                        "server_id": SERVER_ID,
                        "tool": "echo",
                        "arguments": {"text": "cancel-me"},
                        "confirmed": True,
                    },
                )
                pending = wait_for_server(
                    client,
                    lambda value: value.get("tool_test", {}).get(
                        "request_id"
                    )
                    == queued["request_id"]
                    and value["tool_test"]["state"] == "pending",
                )
                self.assertEqual("pending", pending["tool_test"]["state"])

                client.call("mcp.stop", SERVER_PARAMS)
                stopped = wait_for_server(
                    client,
                    lambda value: value["state"] == "stopped"
                    and value["pid"] == 0,
                )
                self.assertNotIn("tool_test", stopped)
                self.assertTrue(wait_for_process_exit(child_pid))
                wait_for_no_children(daemon.process.pid)

    def test_repeated_restart_stop_start_reaps_every_child(self) -> None:
        cycles = 8
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "zombie-soak.json"
            with DaemonUnderTest(
                mutate=supervision_configuration(report_path)
            ) as daemon, daemon.connect() as client:
                current = wait_for_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["pid"] > 0,
                )

                for _ in range(cycles):
                    old_pid = current["pid"]
                    client.call("mcp.restart", SERVER_PARAMS)
                    current = wait_for_server(
                        client,
                        lambda value: (
                            value["state"] == "ready"
                            and value["pid"] > 0
                            and value["pid"] != old_pid
                        ),
                    )
                    self.assertTrue(
                        wait_for_process_exit(old_pid),
                        f"restarted child {old_pid} was not reaped",
                    )
                    self.assertNotEqual("Z", process_state(current["pid"]))

                    old_pid = current["pid"]
                    client.call("mcp.stop", SERVER_PARAMS)
                    stopped = wait_for_server(
                        client,
                        lambda value: value["state"] == "stopped"
                        and value["pid"] == 0,
                    )
                    self.assertTrue(
                        wait_for_process_exit(old_pid),
                        f"stopped child {old_pid} was not reaped",
                    )
                    self.assertEqual(0, stopped["pid"])

                    client.call("mcp.start", SERVER_PARAMS)
                    current = wait_for_server(
                        client,
                        lambda value: value["state"] == "ready"
                        and value["pid"] > 0,
                    )
                    self.assertNotEqual("Z", process_state(current["pid"]))

                final_pid = current["pid"]
                client.call("mcp.stop", SERVER_PARAMS)
                wait_for_server(
                    client,
                    lambda value: value["state"] == "stopped"
                    and value["pid"] == 0,
                )
                self.assertTrue(wait_for_process_exit(final_pid))
                wait_for_no_children(daemon.process.pid)


if __name__ == "__main__":
    unittest.main()
