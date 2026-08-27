"""Provider concurrency, and the counter that has to come back (M7 DoD 9).

`max_concurrency` is enforced by comparing a live counter against a configured
ceiling. That makes the counter's accounting the whole of the feature: a
counter that is not decremented on some exit path does not fail visibly, it
just makes the provider look progressively busier until it is permanently
ineligible — and the symptom is a provider that stopped receiving traffic for
no reason anybody can see in a log.

So every way an attempt can end gets its own test here, and each one ends by
asserting the counter is back where it started. `providers.list` reports it, so
the assertion is on the daemon's own accounting rather than on a proxy for it.
"""
from __future__ import annotations

import json
import threading
import time
import unittest

from tests.http_harness import Gateway, request_bytes
from tests.mock_provider import MockProvider, sse_event
from tests.provider_harness import ProviderGateway, chat_request, provider_config


def stream_request(alias="general"):
    body = chat_request(alias, stream=True).encode()
    return request_bytes(
        method="POST",
        target="/v1/chat/completions",
        headers=[
            ("Content-Type", "application/json"),
            ("Content-Length", str(len(body))),
        ],
        body=body,
    )


class ConcurrencyTests(unittest.TestCase):
    def state(self, fixture, provider_id="mock-provider") -> dict:
        with fixture.gateway.daemon.connect() as client:
            for entry in client.call("providers.list"):
                if entry["id"] == provider_id:
                    return entry
        raise AssertionError("provider not reported")

    def wait_until_idle(self, fixture, timeout=10.0) -> int:
        deadline = time.monotonic() + timeout
        active = -1
        while time.monotonic() < deadline:
            active = self.state(fixture)["active_requests"]
            if active == 0:
                return 0
            time.sleep(0.05)
        return active

    # --- the ceiling itself -------------------------------------------------

    def test_the_ceiling_refuses_rather_than_queues(self) -> None:
        gate = threading.Event()

        def hold(request, writer):
            gate.wait(15.0)
            writer.json_response({"id": "ok"})

        with ProviderGateway(hold, max_concurrency=1, request_ms=30000) as fixture:
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
                deadline = time.monotonic() + 10.0
                while not fixture.requests and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(fixture.requests, "the first request never went out")
                self.assertEqual(1, self.state(fixture)["active_requests"])

                second = fixture.post_json("/v1/chat/completions", chat_request())
                self.assertEqual(503, second.status)
                self.assertEqual(
                    "no_eligible_target", second.json()["error"]["code"]
                )
            finally:
                gate.set()
                first.close()

    # --- every way an attempt can end --------------------------------------

    def test_the_counter_returns_after_a_success(self) -> None:
        from tests.mock_provider import json_handler

        with ProviderGateway(json_handler({"id": "ok"}), max_concurrency=4) as fixture:
            for _ in range(25):
                self.assertEqual(
                    200,
                    fixture.post_json("/v1/chat/completions", chat_request()).status,
                )
            self.assertEqual(0, self.wait_until_idle(fixture))

    def test_the_counter_returns_after_an_upstream_failure(self) -> None:
        def die(request, writer):
            writer.head(200, {"Content-Type": "application/json", "Content-Length": "9"})
            writer.raw(b"{")
            try:
                writer.conn.close()
            except OSError:
                pass

        def tolerant(document):
            # A high threshold, so the circuit does not open and take the
            # provider out of the picture before the counter can be observed.
            document["providers"][0]["health"]["failure_threshold"] = 100

        with ProviderGateway(die, max_concurrency=4, mutate=tolerant) as fixture:
            for _ in range(25):
                fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(0, self.wait_until_idle(fixture))

    def test_the_counter_returns_after_a_client_cancels(self) -> None:
        def endless(request, writer):
            writer.sse_head()
            index = 0
            while writer.raw(sse_event(json.dumps({"i": index}))):
                index += 1
                time.sleep(0.002)

        with ProviderGateway(endless, max_concurrency=4) as fixture:
            for _ in range(10):
                sock = fixture.connect()
                sock.sendall(stream_request())
                time.sleep(0.08)
                sock.close()
            self.assertEqual(0, self.wait_until_idle(fixture))
            self.assertTrue(fixture.alive())

    def test_the_counter_returns_after_a_timeout(self) -> None:
        def silence(request, writer):
            writer.wait_for_disconnect(20.0)

        def tolerant(document):
            document["providers"][0]["health"]["failure_threshold"] = 100

        with ProviderGateway(
            silence, max_concurrency=4, request_ms=1200, mutate=tolerant
        ) as fixture:
            for _ in range(6):
                response = fixture.post_json("/v1/chat/completions", chat_request())
                self.assertEqual(504, response.status)
            self.assertEqual(0, self.wait_until_idle(fixture))

    def test_the_counter_returns_after_a_refused_connection(self) -> None:
        import socket as _socket

        probe = _socket.socket()
        probe.bind(("127.0.0.1", 0))
        dead = probe.getsockname()[1]
        probe.close()

        configure = provider_config(f"http://127.0.0.1:{dead}/v1", max_concurrency=4)

        def tolerant(document):
            configure(document)
            document["providers"][0]["health"]["failure_threshold"] = 100

        with Gateway(mutate=tolerant) as gateway:
            for _ in range(10):
                gateway.post_json("/v1/chat/completions", chat_request())
            deadline = time.monotonic() + 10.0
            active = -1
            while time.monotonic() < deadline:
                with gateway.daemon.connect() as client:
                    entry = client.call("providers.list")[0]
                active = entry["active_requests"]
                if active == 0:
                    break
                time.sleep(0.05)
            self.assertEqual(0, active)

    def test_the_counter_returns_after_a_fallback(self) -> None:
        """A fallback ends one attempt and begins another. Both are counted."""
        import copy

        def busy(request, writer):
            body = json.dumps({"error": {"message": "busy"}}).encode()
            writer.head(
                503,
                {
                    "Content-Type": "application/json",
                    "Content-Length": str(len(body)),
                },
                reason="Service Unavailable",
            )
            writer.raw(body)

        first = MockProvider(busy)
        second = MockProvider(lambda r, w: w.json_response({"id": "ok"}))
        try:
            base = provider_config(first.base_url, max_concurrency=4)

            def configure(document):
                base(document)
                provider = document["providers"][0]
                provider["health"]["failure_threshold"] = 100
                other = copy.deepcopy(provider)
                other["id"] = "second-provider"
                other["display_name"] = "Second"
                other["base_url"] = second.base_url
                document["providers"].append(other)
                document["routes"][0]["targets"].append(
                    {
                        "provider_id": "second-provider",
                        "upstream_model": "second-model",
                        "priority": 20,
                        "weight": 1,
                    }
                )
                document["routes"][0]["fallback"] = {
                    "enabled": True,
                    "max_attempts": 2,
                    "retryable": ["http_503"],
                }

            with Gateway(mutate=configure) as gateway:
                for _ in range(10):
                    response = gateway.post_json(
                        "/v1/chat/completions", chat_request()
                    )
                    self.assertEqual(200, response.status)

                deadline = time.monotonic() + 10.0
                counts = None
                while time.monotonic() < deadline:
                    with gateway.daemon.connect() as client:
                        listed = client.call("providers.list")
                    counts = {row["id"]: row["active_requests"] for row in listed}
                    if set(counts.values()) == {0}:
                        break
                    time.sleep(0.05)
                self.assertEqual({"mock-provider": 0, "second-provider": 0}, counts)
                self.assertEqual(10, len(first.requests), "the first was not tried")
                self.assertEqual(10, len(second.requests), "the second was not tried")
        finally:
            first.close()
            second.close()

    def test_the_counter_returns_after_shutdown_with_work_in_flight(self) -> None:
        """Not observable afterwards, so what is asserted is a clean exit."""
        import signal

        def slow(request, writer):
            writer.wait_for_disconnect(20.0)

        with ProviderGateway(slow, max_concurrency=4, request_ms=30000) as fixture:
            sock = fixture.connect()
            sock.sendall(stream_request())
            deadline = time.monotonic() + 10.0
            while not fixture.requests and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(fixture.requests)
            self.assertEqual(
                0, fixture.gateway.daemon.terminate(signal.SIGTERM)
            )
            sock.close()


if __name__ == "__main__":
    unittest.main()
