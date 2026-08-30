"""MCP HTTP URL, credential, redirect, proxy, and cache security (M9)."""
from __future__ import annotations

import json
import time
import unittest

from tests.mcp_http_harness import (
    http_configuration,
    http_server,
    wait_for_http_server,
    wait_for_method,
)
from tests.mock_mcp_http import MockMcpHttp
from tests.test_mcp_process_supervision import StartupDaemonUnderTest


class McpHttpSecurityTests(unittest.TestCase):
    def test_bearer_secret_is_sent_but_never_exposed_by_control(self) -> None:
        secret = "m9-bearer-secret"
        auth = {"type": "bearer_env", "env": "MCP_HTTP_TOKEN"}
        with MockMcpHttp() as mock, StartupDaemonUnderTest(
            mutate=http_configuration(http_server(mock.endpoint, auth=auth)),
            extra_env={"MCP_HTTP_TOKEN": secret},
        ) as daemon, daemon.connect() as client:
            wait_for_http_server(
                client,
                lambda value: value["state"] == "ready"
                and value["tool_count"] == 1,
            )
            for method in (
                "server/discover",
                "tools/list",
                "resources/list",
                "prompts/list",
            ):
                wait_for_method(mock, method)
            for request in mock.requests:
                self.assertEqual(
                    f"Bearer {secret}", request.header("authorization")
                )
                self.assertNotIn(secret.encode(), request.body)

            snapshots = {
                "get": client.call("mcp.get", {"server_id": "http-mock"}),
                "inventory": client.call(
                    "mcp.inventory", {"server_id": "http-mock"}
                ),
                "list": client.call("mcp.list"),
            }
            self.assertNotIn(secret, json.dumps(snapshots, sort_keys=True))

    def test_redirect_is_not_followed_and_is_not_legacy_evidence(self) -> None:
        with MockMcpHttp() as destination:
            with MockMcpHttp(
                mode="redirect", redirect_location=destination.endpoint
            ) as origin, StartupDaemonUnderTest(
                mutate=http_configuration(http_server(origin.endpoint))
            ) as daemon, daemon.connect() as client:
                wait_for_method(origin, "server/discover")
                failed = wait_for_http_server(
                    client,
                    lambda value: value["state"] in {"failed", "degraded"},
                )
                time.sleep(0.2)
                self.assertEqual([], destination.requests)
                self.assertNotIn("initialize", origin.methods())
                self.assertEqual("unknown", failed["era"])

    def test_proxy_environment_is_ignored_for_mcp_credentials(self) -> None:
        with MockMcpHttp() as target, MockMcpHttp(mode="transient") as proxy:
            proxy_url = proxy.endpoint.rsplit("/", 1)[0]
            environment = {
                "ALL_PROXY": proxy_url,
                "HTTP_PROXY": proxy_url,
                "http_proxy": proxy_url,
                "NO_PROXY": "",
            }
            with StartupDaemonUnderTest(
                mutate=http_configuration(http_server(target.endpoint)),
                extra_env=environment,
            ) as daemon, daemon.connect() as client:
                wait_for_http_server(
                    client,
                    lambda value: value["state"] == "ready"
                    and value["tool_count"] == 1,
                )
                wait_for_method(target, "tools/list")
                time.sleep(0.2)
                self.assertEqual([], proxy.requests)

    def test_public_plaintext_is_rejected_even_with_private_http_flag(self) -> None:
        configured = http_server(
            "http://example.invalid/mcp",
            allow_insecure_private_http=True,
            connect_ms=500,
            request_ms=500,
        )
        daemon = None
        try:
            with self.assertRaises(RuntimeError):
                daemon = StartupDaemonUnderTest(
                    mutate=http_configuration(configured)
                )
        finally:
            if daemon is not None:
                daemon.close()

    def test_private_cache_is_partitioned_by_authorization_context(self) -> None:
        tools_by_auth = {
            "Bearer token-a": ["tool-a"],
            "Bearer token-b": ["tool-b"],
        }
        with MockMcpHttp(tools_by_authorization=tools_by_auth) as mock:
            first = http_server(
                mock.endpoint,
                server_id="http-auth-a",
                auth={"type": "bearer_env", "env": "MCP_TOKEN_A"},
            )
            second = http_server(
                mock.endpoint,
                server_id="http-auth-b",
                auth={"type": "bearer_env", "env": "MCP_TOKEN_B"},
            )
            with StartupDaemonUnderTest(
                mutate=http_configuration(first, second),
                extra_env={"MCP_TOKEN_A": "token-a", "MCP_TOKEN_B": "token-b"},
            ) as daemon, daemon.connect() as client:
                for server_id in ("http-auth-a", "http-auth-b"):
                    wait_for_http_server(
                        client,
                        lambda value: value["state"] == "ready"
                        and value["tool_count"] == 1,
                        server_id=server_id,
                    )
                inventory_a = client.call(
                    "mcp.inventory", {"server_id": "http-auth-a"}
                )
                inventory_b = client.call(
                    "mcp.inventory", {"server_id": "http-auth-b"}
                )
                self.assertEqual(
                    ["tool-a"], [tool["name"] for tool in inventory_a["tools"]]
                )
                self.assertEqual(
                    ["tool-b"], [tool["name"] for tool in inventory_b["tools"]]
                )
                tools_requests = wait_for_method(mock, "tools/list", count=2)
                self.assertEqual(
                    {"Bearer token-a", "Bearer token-b"},
                    {request.header("authorization") for request in tools_requests},
                )

    def test_expired_ttl_is_refreshed_lazily_and_transactionally(self) -> None:
        with MockMcpHttp(
            ttl_ms=100,
            tools_sequence=[["echo-v1"], ["echo-v2"]],
        ) as mock, StartupDaemonUnderTest(
            mutate=http_configuration(http_server(mock.endpoint))
        ) as daemon, daemon.connect() as client:
            wait_for_http_server(
                client,
                lambda value: value["state"] == "ready"
                and value["tool_count"] == 1,
            )
            first = client.call("mcp.inventory", {"server_id": "http-mock"})
            self.assertEqual(
                ["echo-v1"], [tool["name"] for tool in first["tools"]]
            )
            self.assertEqual("private", first["cache_scope"])
            self.assertGreater(
                first["expires_at_monotonic_ns"],
                first["fetched_at_monotonic_ns"],
            )

            # Keep the refreshed value stable while allowing the already
            # committed 100 ms entry to expire.
            mock.ttl_ms = 60000
            delay = max(
                0.0,
                (
                    first["expires_at_monotonic_ns"] - time.monotonic_ns()
                )
                / 1e9,
            )
            time.sleep(delay + 0.05)

            deadline = time.monotonic() + 5.0
            refreshed = first
            while time.monotonic() < deadline:
                refreshed = client.call(
                    "mcp.inventory", {"server_id": "http-mock"}
                )
                if [tool["name"] for tool in refreshed["tools"]] == ["echo-v2"]:
                    break
                time.sleep(0.02)
            self.assertEqual(
                ["echo-v2"], [tool["name"] for tool in refreshed["tools"]]
            )
            self.assertGreater(
                refreshed["fetched_at_monotonic_ns"],
                first["fetched_at_monotonic_ns"],
            )
            self.assertEqual(2, len(wait_for_method(mock, "tools/list", count=2)))


if __name__ == "__main__":
    unittest.main()
