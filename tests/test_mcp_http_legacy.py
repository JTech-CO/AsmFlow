"""Legacy 2025-11-25 HTTP adapter integration (HARNESS.md M9)."""
from __future__ import annotations

import unittest

from tests.mcp_http_harness import (
    SERVER_ID,
    http_configuration,
    http_server,
    message_for,
    wait_for_http_server,
    wait_for_method,
    wait_for_request,
    wait_for_tool_test,
)
from tests.mock_mcp_http import MockMcpHttp, request_message
from tests.test_mcp_process_supervision import StartupDaemonUnderTest


class McpHttpLegacyTests(unittest.TestCase):
    def test_bare_400_falls_back_to_isolated_session_and_get_stream(self) -> None:
        with MockMcpHttp(mode="legacy") as mock, StartupDaemonUnderTest(
            mutate=http_configuration(http_server(mock.endpoint))
        ) as daemon, daemon.connect() as client:
            server = wait_for_http_server(
                client,
                lambda value: value["state"] == "ready"
                and value["tool_count"] == 1,
            )
            self.assertEqual("legacy_2025", server["era"])
            self.assertEqual("2025-11-25", server["protocol_version"])

            discover = wait_for_method(mock, "server/discover")[0]
            initialize = wait_for_method(mock, "initialize")[0]
            initialized = wait_for_method(mock, "notifications/initialized")[0]
            tools = wait_for_method(mock, "tools/list")[0]
            get_stream = wait_for_request(mock, lambda request: request.method == "GET")

            self.assertIsNone(discover.header("mcp-session-id"))
            self.assertIsNone(initialize.header("mcp-session-id"))
            initialize_message = message_for(initialize)
            self.assertEqual(
                "2025-11-25",
                initialize_message["params"]["protocolVersion"],
            )
            self.assertNotIn("_meta", initialize_message["params"])
            self.assertIsNone(initialize.header("mcp-method"))

            for request in (initialized, tools, get_stream):
                self.assertEqual(
                    mock.session_id,
                    request.header("mcp-session-id"),
                    f"session was not echoed on {request.method} {request.target}",
                )
                self.assertIsNone(request.header("mcp-method"))
                self.assertIsNone(request.header("mcp-name"))

            for request in mock.requests:
                message = request_message(request)
                if message is not None and message.get("method") in {
                    "notifications/initialized",
                    "tools/list",
                    "resources/list",
                    "prompts/list",
                }:
                    self.assertNotIn("_meta", message.get("params", {}))

    def test_legacy_timeout_disconnects_and_posts_explicit_cancellation(self) -> None:
        with MockMcpHttp(mode="legacy", hang_methods={"tools/call"}) as mock:
            configured = http_server(
                mock.endpoint,
                request_ms=1000,
                idle_stream_ms=1000,
            )
            with StartupDaemonUnderTest(
                mutate=http_configuration(configured)
            ) as daemon, daemon.connect() as client:
                wait_for_http_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1,
                )
                queued = client.call(
                    "mcp.tool_test",
                    {
                        "server_id": SERVER_ID,
                        "tool": "echo",
                        "arguments": {"text": "legacy-timeout"},
                        "confirmed": True,
                    },
                )
                call = wait_for_method(mock, "tools/call")[0]
                completed = wait_for_tool_test(client, queued["request_id"])
                self.assertEqual(-175, completed["status"])
                self.assertIsNone(completed["result"])

                cancellation = wait_for_method(mock, "notifications/cancelled")[0]
                cancelled_message = message_for(cancellation)
                self.assertEqual(
                    {
                        "requestId": queued["request_id"],
                        "reason": "request timeout",
                    },
                    cancelled_message["params"],
                )
                self.assertEqual(
                    mock.session_id, cancellation.header("mcp-session-id")
                )
                wait_for_request(mock, lambda request: request is call and request.disconnected)


if __name__ == "__main__":
    unittest.main()
