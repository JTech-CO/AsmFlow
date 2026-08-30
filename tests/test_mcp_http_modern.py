"""Modern 2026-07-28 Streamable HTTP integration (HARNESS.md M9)."""
from __future__ import annotations

import unittest

from tests.http_harness import free_port
from tests.mcp_http_harness import (
    SERVER_ID,
    expected_modern_meta,
    http_configuration,
    http_server,
    message_for,
    wait_for_http_server,
    wait_for_method,
    wait_for_tool_test,
)
from tests.mock_mcp_http import MockMcpHttp
from tests.test_mcp_process_supervision import (
    StartupDaemonUnderTest,
    wait_for_readyz,
)


class McpHttpModernTests(unittest.TestCase):
    def test_startup_posts_modern_metadata_and_never_leaks_legacy_state(self) -> None:
        with MockMcpHttp() as mock, StartupDaemonUnderTest(
            mutate=http_configuration(http_server(mock.endpoint))
        ) as daemon, daemon.connect() as client:
            server = wait_for_http_server(
                client,
                lambda value: value["state"] == "ready"
                and value["tool_count"] == 1,
            )
            self.assertEqual("modern_2026", server["era"])
            self.assertEqual("2026-07-28", server["protocol_version"])

            expected_methods = {
                "server/discover",
                "tools/list",
                "resources/list",
                "prompts/list",
            }
            for method in expected_methods:
                wait_for_method(mock, method)
            self.assertEqual(expected_methods, set(mock.methods()))

            for request in mock.requests:
                message = message_for(request)
                method = message["method"]
                self.assertEqual("POST", request.method)
                self.assertEqual("/mcp", request.target)
                self.assertEqual(
                    "application/json",
                    request.header("content-type").split(";", 1)[0],
                )
                accepted = {
                    value.strip()
                    for value in request.header("accept", "").split(",")
                }
                self.assertTrue(
                    {"application/json", "text/event-stream"} <= accepted,
                    accepted,
                )
                self.assertEqual(
                    "2026-07-28", request.header("mcp-protocol-version")
                )
                self.assertEqual(method, request.header("mcp-method"))
                self.assertEqual(
                    expected_modern_meta(), message["params"]["_meta"]
                )
                self.assertIsNone(request.header("mcp-session-id"))
                self.assertIsNone(request.header("last-event-id"))

            self.assertFalse(
                any(request.method in {"GET", "DELETE"} for request in mock.requests)
            )

    def test_tool_call_mirrors_name_and_annotated_primitive_header(self) -> None:
        with MockMcpHttp() as mock, StartupDaemonUnderTest(
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
                    "arguments": {"text": "modern", "tenant": "alpha"},
                    "confirmed": True,
                },
            )
            completed = wait_for_tool_test(client, queued["request_id"])
            self.assertEqual(0, completed["status"])
            self.assertEqual("modern", completed["result"]["content"][0]["text"])

            call = wait_for_method(mock, "tools/call")[0]
            call_message = message_for(call)
            self.assertEqual("tools/call", call.header("mcp-method"))
            self.assertEqual("echo", call.header("mcp-name"))
            self.assertEqual("alpha", call.header("mcp-param-tenant"))
            self.assertEqual(expected_modern_meta(), call_message["params"]["_meta"])
            self.assertNotIn("notifications/cancelled", mock.methods())

    def test_required_http_becomes_ready_only_after_tools_commit(self) -> None:
        port = free_port()
        with MockMcpHttp(response_delay={"tools/list": 0.5}) as mock:
            configured = http_server(mock.endpoint, required=True)
            with StartupDaemonUnderTest(
                mutate=http_configuration(configured, listener_port=port)
            ) as daemon, daemon.connect() as client:
                pending = wait_for_readyz(port, 503)
                self.assertEqual(
                    {"required": 1, "ready": 0}, pending.json()["mcp"]
                )
                ready = wait_for_readyz(port, 200)
                self.assertEqual(
                    {"required": 1, "ready": 1}, ready.json()["mcp"]
                )
                wait_for_http_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1,
                )


if __name__ == "__main__":
    unittest.main()
