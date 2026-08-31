"""M11 SIGTERM ordering: stop accepts, drain, stop MCP, close DB."""
from __future__ import annotations

import json
import signal
import socket
import threading
import time
import unittest

from tests.http_harness import Gateway, parse_responses, request_bytes
from tests.mock_provider import MockProvider
from tests.provider_harness import chat_request, provider_config


def _chat_wire(*, close: bool = False) -> bytes:
    body = chat_request().encode()
    return request_bytes(
        method="POST",
        target="/v1/chat/completions",
        headers=[("Content-Type", "application/json"), ("Content-Length", str(len(body)))],
        body=body,
        close=close,
    )


def _read_to_eof(sock: socket.socket, timeout: float = 12.0) -> bytes:
    sock.settimeout(timeout)
    chunks: list[bytes] = []
    while True:
        piece = sock.recv(65536)
        if not piece:
            return b"".join(chunks)
        chunks.append(piece)


def _wait_listener_closed(host: str, port: int, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            probe = socket.create_connection((host, port), timeout=0.2)
        except OSError:
            return
        else:
            probe.close()
            time.sleep(0.02)
    raise AssertionError("listener still accepted new connections after SIGTERM")


class GracefulShutdownTests(unittest.TestCase):
    def test_inflight_response_finishes_and_pipelined_request_is_not_dispatched(self) -> None:
        received = threading.Event()
        release = threading.Event()
        canned = {"id": "m11", "object": "chat.completion", "choices": []}

        def gated(request, writer):
            received.set()
            release.wait(10.0)
            writer.json_response(canned)

        with MockProvider(gated) as provider, Gateway(
            mutate=provider_config(provider.base_url)
        ) as gateway:
            sock = gateway.connect()
            try:
                # The parser suspends after request one. Request two must remain
                # undispatched once shutdown starts.
                sock.sendall(_chat_wire(close=False) + _chat_wire(close=True))
                self.assertTrue(received.wait(5.0), "first request never reached provider")
                gateway.process.send_signal(signal.SIGTERM)
                _wait_listener_closed(gateway.host, gateway.port)
                release.set()
                raw = _read_to_eof(sock)
                gateway.process.wait(timeout=12.0)
                self.assertEqual(0, gateway.process.returncode)
                responses = parse_responses(raw)
                self.assertEqual(1, len(responses), raw[:500])
                self.assertEqual(200, responses[0].status)
                self.assertEqual(canned, responses[0].json())
                time.sleep(0.1)
                self.assertEqual(1, len(provider.requests))

                trace = gateway.process.stderr.read().decode(errors="replace")
                markers = [
                    "shutdown.accepts_stopped",
                    "shutdown.inflight_drained",
                    "shutdown.mcp_stopped",
                    "shutdown.db_closed",
                ]
                positions = [trace.index(marker) for marker in markers]
                self.assertEqual(positions, sorted(positions), trace)
            finally:
                release.set()
                sock.close()

    def test_grace_deadline_cancels_a_stalled_exchange_and_exits_bounded(self) -> None:
        received = threading.Event()
        disconnected = threading.Event()

        def stalled(request, writer):
            received.set()
            if writer.wait_for_disconnect(15.0):
                disconnected.set()

        with MockProvider(stalled) as provider, Gateway(
            mutate=provider_config(provider.base_url)
        ) as gateway:
            sock = gateway.connect()
            try:
                sock.sendall(_chat_wire(close=False))
                self.assertTrue(received.wait(5.0))
                started = time.monotonic()
                gateway.process.send_signal(signal.SIGTERM)
                _wait_listener_closed(gateway.host, gateway.port)
                gateway.process.wait(timeout=10.0)
                elapsed = time.monotonic() - started
                self.assertEqual(0, gateway.process.returncode)
                self.assertLess(elapsed, 8.0)
                self.assertTrue(disconnected.wait(2.0))
                trace = gateway.process.stderr.read().decode(errors="replace")
                self.assertIn("shutdown.inflight_deadline", trace)
                self.assertLess(trace.index("shutdown.accepts_stopped"), trace.index("shutdown.mcp_stopped"))
                self.assertLess(trace.index("shutdown.mcp_stopped"), trace.index("shutdown.db_closed"))
            finally:
                sock.close()


if __name__ == "__main__":
    unittest.main()
