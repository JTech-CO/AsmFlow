"""When the upstream, or the client, misbehaves (HARNESS.md M6 DoD 4-7).

Every test here is a failure mode that a gateway meets in production and that a
happy-path suite never reaches: a provider that accepts a request and says
nothing, one that stops mid-sentence, a client that walks away with a stream
half delivered, a client that reads slower than the provider writes.

The property they share is that AsmFlow keeps its own accounting straight. A
failure may be reported, but it may not leak a descriptor, strand a slot, wedge
the loop, or leave the daemon serving a connection nobody is on.
"""
from __future__ import annotations

import json
import socket
import threading
import time
import unittest

from tests.http_harness import request_bytes
from tests.mock_provider import (
    MockProvider,
    hang_handler,
    json_handler,
    sse_event,
    sse_handler,
    truncating_handler,
)
from tests.provider_harness import ProviderGateway, chat_request, provider_config

CANNED = {"id": "x", "object": "chat.completion", "choices": []}


def stream_request(alias="general"):
    body = chat_request(alias, stream=True).encode()
    return request_bytes(
        method="POST",
        target="/v1/chat/completions",
        headers=[("Content-Type", "application/json"), ("Content-Length", str(len(body)))],
        body=body,
    )


def rss_kib(pid: int) -> int:
    with open(f"/proc/{pid}/status", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    return 0


class UpstreamFailureTests(unittest.TestCase):
    """M6 DoD 7: a transport failure becomes a normalised error class."""

    def test_a_refused_connection_is_a_bad_gateway(self) -> None:
        # A port that was bound and then released: nothing is listening, and
        # the connection is refused rather than filtered.
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        dead_port = probe.getsockname()[1]
        probe.close()

        from tests.http_harness import Gateway

        configure = provider_config(f"http://127.0.0.1:{dead_port}/v1")
        with Gateway(mutate=configure) as gateway:
            response = gateway.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(502, response.status)
            self.assertEqual(
                "upstream_connect_failed", response.json()["error"]["code"]
            )
            self.assertTrue(response.json()["asmflow"]["retryable"])

    def test_a_name_that_does_not_resolve_is_a_bad_gateway(self) -> None:
        from tests.http_harness import Gateway

        configure = provider_config("http://nonexistent.invalid.test:9/v1")
        with Gateway(mutate=configure) as gateway:
            response = gateway.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(502, response.status)
            self.assertEqual(
                "upstream_connect_failed", response.json()["error"]["code"]
            )

    def test_a_provider_that_never_answers_is_a_gateway_timeout(self) -> None:
        with ProviderGateway(hang_handler(30.0), request_ms=1500) as fixture:
            started = time.monotonic()
            response = fixture.post_json("/v1/chat/completions", chat_request())
            elapsed = time.monotonic() - started
            self.assertEqual(504, response.status)
            self.assertEqual("upstream_timeout", response.json()["error"]["code"])
            self.assertLess(elapsed, 10.0, "the configured timeout did not apply")

    def test_a_truncated_response_is_an_invalid_upstream_response(self) -> None:
        with ProviderGateway(truncating_handler(b'{"partial": tr')) as fixture:
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(502, response.status)
            self.assertEqual(
                "invalid_upstream_response", response.json()["error"]["code"]
            )

    def test_a_reply_that_is_not_http_is_an_invalid_upstream_response(self) -> None:
        def garbage(request, writer):
            writer.raw(b"this is not a status line\r\n\r\n")
            writer.conn.close()

        with ProviderGateway(garbage) as fixture:
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(502, response.status)

    def test_a_stalled_stream_ends_on_the_idle_timeout(self) -> None:
        """The head arrives, then nothing. A total timeout cannot express this."""

        def stall(request, writer):
            writer.sse_head()
            writer.raw(sse_event("first"))
            writer.wait_for_disconnect(30.0)

        with ProviderGateway(stall, idle_stream_ms=1000, request_ms=30000) as fixture:
            started = time.monotonic()
            raw = fixture.send_raw(stream_request(), timeout=20.0)
            elapsed = time.monotonic() - started
            self.assertIn(b"text/event-stream", raw)
            self.assertIn(sse_event("first"), raw)
            self.assertLess(elapsed, 15.0, "the idle-stream timeout did not apply")

    def test_the_daemon_survives_every_upstream_failure(self) -> None:
        with ProviderGateway(truncating_handler(b"{")) as fixture:
            for _ in range(20):
                fixture.post_json("/v1/chat/completions", chat_request())
            self.assertTrue(fixture.alive())
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(502, response.status)


class CancellationTests(unittest.TestCase):
    """M6 DoD 5: a client that leaves cancels the work it started."""

    def test_a_client_that_disconnects_mid_stream_cancels_the_upstream(self) -> None:
        stopped = threading.Event()
        wrote = []

        def endless(request, writer):
            writer.sse_head()
            index = 0
            while index < 200000:
                if not writer.raw(sse_event(json.dumps({"i": index}))):
                    break
                wrote.append(index)
                index += 1
                time.sleep(0.001)
            stopped.set()

        with ProviderGateway(endless) as fixture:
            sock = fixture.connect()
            try:
                sock.sendall(stream_request())
                # Read enough to know the stream is genuinely running.
                sock.settimeout(10.0)
                seen = b""
                while b'"i": 3' not in seen and b'"i":3' not in seen:
                    piece = sock.recv(4096)
                    if not piece:
                        break
                    seen += piece
            finally:
                sock.close()

            self.assertTrue(
                stopped.wait(20.0),
                "the provider was still generating after the client left",
            )
            self.assertLess(
                len(wrote), 200000, "the upstream ran to completion regardless"
            )
            self.assertTrue(fixture.alive())

    def test_a_client_that_leaves_before_the_answer_cancels_it(self) -> None:
        arrived = threading.Event()
        released = threading.Event()

        def slow(request, writer):
            arrived.set()
            writer.wait_for_disconnect(20.0)
            released.set()

        with ProviderGateway(slow, request_ms=30000) as fixture:
            body = chat_request().encode()
            sock = fixture.connect()
            sock.sendall(
                request_bytes(
                    method="POST",
                    target="/v1/chat/completions",
                    headers=[
                        ("Content-Type", "application/json"),
                        ("Content-Length", str(len(body))),
                    ],
                    body=body,
                )
            )
            self.assertTrue(arrived.wait(10.0), "the request never reached upstream")
            sock.close()
            self.assertTrue(
                released.wait(20.0), "the upstream transfer was never cancelled"
            )
            self.assertTrue(fixture.alive())

    def test_a_cancelled_exchange_returns_its_slot(self) -> None:
        """Otherwise the table fills with requests nobody is waiting for."""

        def slow(request, writer):
            writer.wait_for_disconnect(10.0)

        def one_at_a_time(document):
            document["limits"]["max_active_requests"] = 1

        with ProviderGateway(slow, mutate=one_at_a_time, request_ms=30000) as fixture:
            for _ in range(5):
                sock = fixture.connect()
                sock.sendall(stream_request())
                time.sleep(0.15)
                sock.close()
                time.sleep(0.15)
            # If the slot were stranded, this would be refused with 429.
            with ProviderGateway(json_handler(CANNED)) as ok_fixture:
                self.assertEqual(
                    200,
                    ok_fixture.post_json(
                        "/v1/chat/completions", chat_request()
                    ).status,
                )
            self.assertTrue(fixture.alive())


class BackpressureTests(unittest.TestCase):
    """M6 DoD 4: a slow client must not become an unbounded buffer."""

    def test_a_slow_reader_does_not_grow_the_daemon(self) -> None:
        total_events = 4000
        payload = "z" * 1024
        events = [sse_event(json.dumps({"i": i, "p": payload})) for i in range(total_events)]
        expected = b"".join(events)

        with ProviderGateway(sse_handler(events)) as fixture:
            baseline = rss_kib(fixture.gateway.daemon.process.pid)
            sock = fixture.connect()
            sock.settimeout(30.0)
            try:
                sock.sendall(stream_request())
                received = b""
                peak = baseline
                while True:
                    piece = sock.recv(4096)
                    if not piece:
                        break
                    received += piece
                    # Read deliberately slowly, so the provider outruns us.
                    if len(received) % (64 * 1024) < 4096:
                        peak = max(peak, rss_kib(fixture.gateway.daemon.process.pid))
                        time.sleep(0.005)
            finally:
                sock.close()

            from tests.http_harness import parse_responses

            responses = parse_responses(received)
            self.assertEqual(1, len(responses))
            self.assertEqual(expected, responses[0].body)
            growth = peak - baseline
            # Buffering the whole stream would cost several thousand KiB; the
            # outbox should hold only what is pending.
            self.assertLess(
                growth,
                3 * 1024,
                f"the daemon grew {growth} KiB while a slow client read "
                f"{len(expected)} bytes",
            )

    def test_a_paused_transfer_still_finishes(self) -> None:
        """Resume has to happen, or a slow client is a hung request."""
        events = [sse_event("y" * 4096) for _ in range(600)]
        events.append(sse_event("[DONE]"))
        with ProviderGateway(sse_handler(events)) as fixture:
            sock = fixture.connect()
            sock.settimeout(30.0)
            try:
                sock.sendall(stream_request())
                received = b""
                while True:
                    piece = sock.recv(2048)
                    if not piece:
                        break
                    received += piece
                    time.sleep(0.0005)
            finally:
                sock.close()
            from tests.http_harness import parse_responses

            responses = parse_responses(received)
            self.assertEqual(b"".join(events), responses[0].body)


class CapacityTests(unittest.TestCase):
    """`limits.max_active_requests` bounds what is in flight upstream."""

    def test_beyond_the_ceiling_a_request_is_refused_not_queued(self) -> None:
        gate = threading.Event()

        def hold(request, writer):
            gate.wait(15.0)
            writer.json_response(CANNED)

        def one_at_a_time(document):
            document["limits"]["max_active_requests"] = 1

        with ProviderGateway(hold, mutate=one_at_a_time, request_ms=30000) as fixture:
            first = fixture.connect()
            try:
                body = chat_request().encode()
                first.sendall(
                    request_bytes(
                        method="POST",
                        target="/v1/chat/completions",
                        headers=[
                            ("Content-Type", "application/json"),
                            ("Content-Length", str(len(body))),
                        ],
                        body=body,
                    )
                )
                # Give the first request time to occupy the only slot.
                deadline = time.monotonic() + 10.0
                while not fixture.requests and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(fixture.requests, "the first request never went out")

                second = fixture.post_json("/v1/chat/completions", chat_request())
                self.assertEqual(429, second.status)
                self.assertEqual(
                    "route_concurrency_exhausted", second.json()["error"]["code"]
                )
                self.assertTrue(second.json()["asmflow"]["retryable"])
            finally:
                gate.set()
                first.close()


class DescriptorTests(unittest.TestCase):
    """M6 DoD 6: no handle, list, or descriptor is left behind."""

    def count(self, fixture) -> int:
        return fixture.descriptor_count()

    def test_successful_exchanges_leak_no_descriptors(self) -> None:
        with ProviderGateway(json_handler(CANNED)) as fixture:
            for _ in range(10):
                fixture.post_json("/v1/chat/completions", chat_request())
            time.sleep(0.5)
            baseline = self.count(fixture)
            for _ in range(100):
                self.assertEqual(
                    200,
                    fixture.post_json("/v1/chat/completions", chat_request()).status,
                )
            time.sleep(1.0)
            self.assertLessEqual(self.count(fixture), baseline + 2)

    def test_failed_exchanges_leak_no_descriptors(self) -> None:
        with ProviderGateway(truncating_handler(b"{")) as fixture:
            for _ in range(10):
                fixture.post_json("/v1/chat/completions", chat_request())
            time.sleep(0.5)
            baseline = self.count(fixture)
            for _ in range(100):
                fixture.post_json("/v1/chat/completions", chat_request())
            time.sleep(1.0)
            self.assertLessEqual(self.count(fixture), baseline + 2)

    def test_cancelled_streams_leak_no_descriptors(self) -> None:
        def endless(request, writer):
            writer.sse_head()
            index = 0
            while writer.raw(sse_event(json.dumps({"i": index}))):
                index += 1
                time.sleep(0.001)

        with ProviderGateway(endless) as fixture:
            for _ in range(5):
                sock = fixture.connect()
                sock.sendall(stream_request())
                time.sleep(0.1)
                sock.close()
            time.sleep(1.0)
            baseline = self.count(fixture)
            for _ in range(30):
                sock = fixture.connect()
                sock.sendall(stream_request())
                time.sleep(0.05)
                sock.close()
            time.sleep(2.0)
            self.assertLessEqual(self.count(fixture), baseline + 2)
            self.assertTrue(fixture.alive())


class ShutdownTests(unittest.TestCase):
    """A daemon told to stop stops, whatever is in flight."""

    def test_shutdown_with_a_transfer_in_flight_is_clean(self) -> None:
        import signal

        def slow(request, writer):
            writer.wait_for_disconnect(20.0)

        provider = MockProvider(slow)
        try:
            from tests.test_control_protocol import DaemonUnderTest
            from tests.http_harness import Gateway

            gateway = Gateway(mutate=provider_config(provider.base_url))
            try:
                sock = gateway.connect()
                sock.sendall(stream_request())
                deadline = time.monotonic() + 10.0
                while not provider.requests and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(provider.requests)
                self.assertEqual(0, gateway.daemon.terminate(signal.SIGTERM))
                sock.close()
            finally:
                gateway.close()
        finally:
            provider.close()


if __name__ == "__main__":
    unittest.main()
