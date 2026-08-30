"""Raw-socket MCP Streamable HTTP peer for the M9 integration suites.

The daemon, not this mock, owns transport policy.  The mock only records the
wire request and emits one deliberately selected response shape.  It builds on
the M6 raw HTTP peer so fragmentation, early EOF, redirects, and disconnects
remain observable instead of being normalized by ``http.server``.
"""
from __future__ import annotations

import copy
import json
import socket
import threading
import time
from pathlib import Path

from tests.mock_provider import MockProvider, RecordedRequest, Writer

FIXTURE_ROOT = Path(__file__).resolve().parent / "fixtures" / "mcp" / "http"


def load_fixture(name: str) -> dict:
    return json.loads((FIXTURE_ROOT / name).read_text(encoding="utf-8"))


def correlated_fixture(name: str, request_id) -> dict:
    payload = copy.deepcopy(load_fixture(name))
    payload["id"] = request_id
    return payload


def compact_json(payload: dict) -> bytes:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
        "utf-8"
    )


def sse_message(payload: dict, *, newline: bytes = b"\n") -> bytes:
    return b"data: " + compact_json(payload) + newline + newline


def request_message(request: RecordedRequest) -> dict | None:
    if not request.body:
        return None
    try:
        value = json.loads(request.body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


class MockMcpHttp:
    """Stateful MCP endpoint with modern, legacy, and failure modes.

    ``mode`` controls only the era probe:

    - ``modern`` answers a valid discovery request;
    - ``legacy`` returns a bare 400, then accepts the 2025 initialize flow;
    - recognized modern error modes return JSON-RPC errors and must never lead
      to legacy initialization;
    - ``transient`` and ``redirect`` exercise non-era HTTP failures.

    All other knobs affect method responses without making policy decisions on
    the daemon's behalf.
    """

    def __init__(
        self,
        *,
        mode: str = "modern",
        session_id: str = "asmflow-test-session",
        stream_methods: set[str] | None = None,
        eof_methods: set[str] | None = None,
        hang_methods: set[str] | None = None,
        fragment_size: int = 0,
        response_delay: dict[str, float] | None = None,
        ttl_ms: int = 60000,
        cache_scope: str = "private",
        tools_sequence: list[list[str]] | None = None,
        tools_by_authorization: dict[str | None, list[str]] | None = None,
        redirect_location: str | None = None,
    ) -> None:
        self.mode = mode
        self.session_id = session_id
        self.stream_methods = set(stream_methods or ())
        self.eof_methods = set(eof_methods or ())
        self.hang_methods = set(hang_methods or ())
        self.fragment_size = fragment_size
        self.response_delay = dict(response_delay or {})
        self.ttl_ms = ttl_ms
        self.cache_scope = cache_scope
        self.tools_sequence = copy.deepcopy(tools_sequence)
        self.tools_by_authorization = copy.deepcopy(tools_by_authorization)
        self.redirect_location = redirect_location
        self._counts: dict[str, int] = {}
        self._count_lock = threading.Lock()
        self._server = MockProvider(self._handle)

    @property
    def endpoint(self) -> str:
        return f"http://127.0.0.1:{self._server.port}/mcp"

    @property
    def requests(self) -> list[RecordedRequest]:
        return self._server.requests

    def request_messages(self) -> list[dict]:
        return [
            message
            for request in self.requests
            if (message := request_message(request)) is not None
        ]

    def methods(self) -> list[str]:
        return [
            message.get("method")
            for message in self.request_messages()
            if isinstance(message.get("method"), str)
        ]

    def method_requests(self, method: str) -> list[RecordedRequest]:
        return [
            request
            for request in self.requests
            if (message := request_message(request)) is not None
            and message.get("method") == method
        ]

    def _next_count(self, method: str) -> int:
        with self._count_lock:
            value = self._counts.get(method, 0)
            self._counts[method] = value + 1
            return value

    @staticmethod
    def _empty(writer: Writer, status: int, reason: str) -> None:
        writer.head(status, {"Content-Length": "0"}, reason=reason)

    @staticmethod
    def _json(
        writer: Writer,
        payload: dict,
        *,
        status: int = 200,
        reason: str = "OK",
        headers: dict[str, str] | None = None,
    ) -> None:
        body = compact_json(payload)
        response_headers = {
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
        }
        response_headers.update(headers or {})
        writer.head(status, response_headers, reason=reason)
        writer.raw(body)

    def _tool_names(self, request: RecordedRequest, invocation: int) -> list[str]:
        if self.tools_by_authorization is not None:
            authorization = request.header("authorization")
            return list(self.tools_by_authorization.get(authorization, []))
        if self.tools_sequence:
            index = min(invocation, len(self.tools_sequence) - 1)
            return list(self.tools_sequence[index])
        return ["echo"]

    @staticmethod
    def _tool(name: str, *, custom_header: bool = False) -> dict:
        properties: dict[str, dict] = {"text": {"type": "string"}}
        if custom_header:
            properties["tenant"] = {
                "type": "string",
                "x-mcp-header": "Tenant",
            }
        return {
            "name": name,
            "description": f"{name} supplied by the M9 HTTP mock",
            "inputSchema": {
                "type": "object",
                "properties": properties,
                "required": ["text"],
            },
        }

    def _modern_response(
        self, request: RecordedRequest, message: dict, invocation: int
    ) -> dict:
        method = message.get("method")
        request_id = message.get("id")
        if method == "server/discover":
            payload = correlated_fixture("modern_discover_result.json", request_id)
        elif method == "tools/list":
            payload = correlated_fixture("modern_tools_list_result.json", request_id)
            names = self._tool_names(request, invocation)
            payload["result"]["tools"] = [
                self._tool(name, custom_header=name == "echo") for name in names
            ]
        elif method == "resources/list":
            payload = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "resultType": "complete",
                    "resources": [],
                    "ttlMs": self.ttl_ms,
                    "cacheScope": self.cache_scope,
                },
            }
        elif method == "prompts/list":
            payload = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "resultType": "complete",
                    "prompts": [],
                    "ttlMs": self.ttl_ms,
                    "cacheScope": self.cache_scope,
                },
            }
        elif method == "tools/call":
            payload = correlated_fixture("modern_tool_call_result.json", request_id)
            text = message.get("params", {}).get("arguments", {}).get("text", "")
            payload["result"]["content"][0]["text"] = text
        else:
            payload = correlated_fixture("method_not_found_error.json", request_id)

        result = payload.get("result")
        if isinstance(result, dict) and "ttlMs" in result:
            result["ttlMs"] = self.ttl_ms
            result["cacheScope"] = self.cache_scope
        return payload

    def _legacy_response(
        self, request: RecordedRequest, message: dict, invocation: int
    ) -> dict:
        method = message.get("method")
        request_id = message.get("id")
        if method == "initialize":
            return correlated_fixture("legacy_initialize_result.json", request_id)
        if method == "tools/list":
            payload = correlated_fixture("legacy_tools_list_result.json", request_id)
            payload["result"]["tools"] = [
                self._tool(name) for name in self._tool_names(request, invocation)
            ]
            return payload
        if method == "resources/list":
            return {"jsonrpc": "2.0", "id": request_id, "result": {"resources": []}}
        if method == "prompts/list":
            return {"jsonrpc": "2.0", "id": request_id, "result": {"prompts": []}}
        if method == "tools/call":
            text = message.get("params", {}).get("arguments", {}).get("text", "")
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "content": [{"type": "text", "text": text}],
                    "isError": False,
                },
            }
        return correlated_fixture("method_not_found_error.json", request_id)

    def _stream(self, writer: Writer, final: dict, *, eof: bool) -> None:
        writer.sse_head()
        progress = load_fixture("progress_notification.json")
        payload = sse_message(progress)
        if not eof:
            payload += sse_message(final)
        writer.chunks(payload, size=self.fragment_size)
        try:
            writer.conn.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    def _handle_get(self, request: RecordedRequest, writer: Writer) -> None:
        invocation = self._next_count("<GET>")
        if self.mode != "legacy" or invocation > 0:
            self._empty(writer, 405, "Method Not Allowed")
            return
        writer.sse_head()
        writer.raw(b": legacy stream established\n\n")

    def _handle(self, request: RecordedRequest, writer: Writer) -> None:
        if request.method == "GET":
            self._handle_get(request, writer)
            return
        if request.method == "DELETE":
            self._empty(writer, 200, "OK")
            return

        message = request_message(request)
        if message is None:
            self._empty(writer, 400, "Bad Request")
            return
        method = message.get("method", "")
        invocation = self._next_count(str(method))
        delay = self.response_delay.get(str(method), 0.0)
        if delay:
            time.sleep(delay)

        if method == "server/discover":
            if self.mode == "legacy":
                self._empty(writer, 400, "Bad Request")
                return
            if self.mode == "unsupported":
                self._json(
                    writer,
                    correlated_fixture("unsupported_version_error.json", message.get("id")),
                    status=400,
                    reason="Bad Request",
                )
                return
            if self.mode == "header-mismatch":
                self._json(
                    writer,
                    correlated_fixture("header_mismatch_error.json", message.get("id")),
                    status=400,
                    reason="Bad Request",
                )
                return
            if self.mode == "method-not-found":
                self._json(
                    writer,
                    correlated_fixture("method_not_found_error.json", message.get("id")),
                    status=404,
                    reason="Not Found",
                )
                return
            if self.mode == "transient":
                self._empty(writer, 503, "Service Unavailable")
                return
            if self.mode == "redirect":
                writer.head(
                    302,
                    {
                        "Content-Length": "0",
                        "Location": self.redirect_location or self.endpoint,
                    },
                    reason="Found",
                )
                return

        if method in {"notifications/initialized", "notifications/cancelled"}:
            self._empty(writer, 202, "Accepted")
            return

        if method in self.hang_methods:
            writer.sse_head()
            writer.wait_for_disconnect(10.0)
            return

        if self.mode == "legacy":
            final = self._legacy_response(request, message, invocation)
        else:
            final = self._modern_response(request, message, invocation)

        if method == "initialize" and self.mode == "legacy":
            self._json(
                writer,
                final,
                headers={"Mcp-Session-Id": self.session_id},
            )
            return

        if method in self.stream_methods or method in self.eof_methods:
            self._stream(writer, final, eof=method in self.eof_methods)
            return
        self._json(writer, final)

    def close(self) -> None:
        self._server.close()

    def __enter__(self) -> "MockMcpHttp":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
