"""Shared configuration and polling helpers for HARNESS.md M9."""
from __future__ import annotations

import copy
import time
from pathlib import Path
from typing import Callable

from tests.mock_mcp_http import MockMcpHttp, request_message

ROOT = Path(__file__).resolve().parents[1]
SERVER_ID = "http-mock"
SERVER_PARAMS = {"server_id": SERVER_ID}
POLL_INTERVAL = 0.02
HTTP_TIMEOUT = 15.0
REPO_VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()


def http_server(
    endpoint: str,
    *,
    server_id: str = SERVER_ID,
    required: bool = False,
    auth: dict | None = None,
    legacy: bool = True,
    connect_ms: int = 1000,
    request_ms: int = 3000,
    idle_stream_ms: int = 1000,
    allow_insecure_private_http: bool | None = None,
) -> dict:
    server = {
        "id": server_id,
        "display_name": f"{server_id} Streamable HTTP mock",
        "transport": "streamable_http",
        "enabled": True,
        "required": required,
        "url": endpoint,
        "auth": copy.deepcopy(auth or {"type": "none"}),
        "protocol": {
            "preferred": "2026-07-28",
            "legacy": ["2025-11-25"] if legacy else [],
        },
        "timeouts": {
            "connect_ms": connect_ms,
            "request_ms": request_ms,
            "idle_stream_ms": idle_stream_ms,
        },
    }
    if allow_insecure_private_http is not None:
        server["allow_insecure_private_http"] = allow_insecure_private_http
    return server


def http_configuration(
    *servers: dict,
    listener_port: int | None = None,
) -> Callable[[dict], None]:
    configured = copy.deepcopy(list(servers))

    def mutate(document: dict) -> None:
        document["mcp_servers"] = copy.deepcopy(configured)
        if listener_port is not None:
            document["listener"]["host"] = "127.0.0.1"
            document["listener"]["port"] = listener_port

    return mutate


def expected_modern_meta() -> dict:
    return {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {
            "name": "AsmFlow",
            "version": REPO_VERSION,
        },
        "io.modelcontextprotocol/clientCapabilities": {},
    }


def wait_for_request(
    mock: MockMcpHttp,
    predicate: Callable,
    *,
    timeout: float = HTTP_TIMEOUT,
):
    deadline = time.monotonic() + timeout
    last = []
    while time.monotonic() < deadline:
        last = list(mock.requests)
        for request in last:
            if predicate(request):
                return request
        time.sleep(POLL_INTERVAL)
    raise AssertionError(f"MCP HTTP request did not arrive: {last!r}")


def wait_for_method(
    mock: MockMcpHttp,
    method: str,
    *,
    count: int = 1,
    timeout: float = HTTP_TIMEOUT,
) -> list:
    deadline = time.monotonic() + timeout
    matches = []
    while time.monotonic() < deadline:
        matches = mock.method_requests(method)
        if len(matches) >= count:
            return matches
        time.sleep(POLL_INTERVAL)
    raise AssertionError(
        f"expected {count} {method!r} requests, got {len(matches)}: "
        f"methods={mock.methods()!r}"
    )


def message_for(request) -> dict:
    message = request_message(request)
    if message is None:
        raise AssertionError(f"request has no JSON-RPC object: {request!r}")
    return message


def wait_for_http_server(
    client,
    predicate: Callable[[dict], bool],
    *,
    server_id: str = SERVER_ID,
    timeout: float = HTTP_TIMEOUT,
) -> dict:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = client.call("mcp.get", {"server_id": server_id})
        if predicate(last):
            return last
        time.sleep(POLL_INTERVAL)
    raise AssertionError(f"HTTP MCP state did not converge: {last!r}")


def wait_for_tool_test(
    client,
    request_id,
    *,
    server_id: str = SERVER_ID,
    state: str = "done",
    timeout: float = HTTP_TIMEOUT,
) -> dict:
    server = wait_for_http_server(
        client,
        lambda value: value.get("tool_test", {}).get("request_id") == request_id
        and value["tool_test"].get("state") == state,
        server_id=server_id,
        timeout=timeout,
    )
    return server["tool_test"]
