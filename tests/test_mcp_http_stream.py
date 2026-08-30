"""Request-scoped MCP SSE framing and cancellation (HARNESS.md M9)."""
from __future__ import annotations

import unittest

from tests.mcp_http_harness import (
    SERVER_ID,
    http_configuration,
    http_server,
    wait_for_http_server,
    wait_for_method,
    wait_for_request,
    wait_for_tool_test,
)
from tests.mock_mcp_http import MockMcpHttp
from tests.test_mcp_process_supervision import StartupDaemonUnderTest


class McpHttpStreamTests(unittest.TestCase):
    def test_one_byte_fragmented_notification_precedes_final_inventory(self) -> None:
        with MockMcpHttp(
            stream_methods={"tools/list"}, fragment_size=1
        ) as mock, StartupDaemonUnderTest(
            mutate=http_configuration(http_server(mock.endpoint))
        ) as daemon, daemon.connect() as client:
            ready = wait_for_http_server(
                client,
                lambda value: value["state"] == "ready"
                and value["tool_count"] == 1
                and value["notifications"] >= 1,
            )
            self.assertEqual("modern_2026", ready["era"])
            inventory = client.call("mcp.inventory", {"server_id": SERVER_ID})
            self.assertEqual(["echo"], [tool["name"] for tool in inventory["tools"]])
            self.assertEqual(1, len(wait_for_method(mock, "tools/list")))

    def test_eof_before_final_response_completes_call_as_protocol_error(self) -> None:
        with MockMcpHttp(eof_methods={"tools/call"}) as mock, StartupDaemonUnderTest(
            mutate=http_configuration(http_server(mock.endpoint))
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
                    "arguments": {"text": "missing-final"},
                    "confirmed": True,
                },
            )
            completed = wait_for_tool_test(client, queued["request_id"])
            self.assertEqual(-171, completed["status"])
            self.assertIsNone(completed["result"])
            self.assertEqual(1, len(wait_for_method(mock, "tools/call")))
            self.assertNotIn("notifications/cancelled", mock.methods())

    def test_modern_timeout_closes_only_its_request_stream(self) -> None:
        with MockMcpHttp(hang_methods={"tools/call"}) as mock:
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
                        "arguments": {"text": "close-this-sse"},
                        "confirmed": True,
                    },
                )
                call = wait_for_method(mock, "tools/call")[0]
                completed = wait_for_tool_test(client, queued["request_id"])
                self.assertEqual(-175, completed["status"])
                wait_for_request(mock, lambda request: request is call and request.disconnected)
                self.assertNotIn("notifications/cancelled", mock.methods())
                still_ready = client.call("mcp.get", {"server_id": SERVER_ID})
                self.assertEqual("ready", still_ready["state"])
                self.assertEqual(1, still_ready["tool_count"])


if __name__ == "__main__":
    unittest.main()
