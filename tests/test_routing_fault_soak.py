"""Routing under injected faults (HARNESS.md M7 DoD 8).

Two properties, both about what a client can observe on one connection:

  * exactly one response, ever. A fallback that fired after the response had
    begun would produce a second one, and the client would read the pair as a
    corrupt stream rather than as an error anybody could act on.

  * one provider per stream. AsmFlow does not merge streams
    (`docs/API_CONTRACT.md` 5), so every event in a response has to have come
    from the same target. A fallback mid-stream would violate this without
    violating anything else — the bytes would all be well-formed SSE.

The second is why each provider stamps its own identity into every event it
sends. Without that the test could only count events, and a stream stitched
from two providers counts exactly the same as one that was not.

Faults are injected deterministically from a seed, so a failure reproduces.
"""
from __future__ import annotations

import copy
import json
import random
import threading
import time
import unittest

from tests.http_harness import Gateway, parse_responses, request_bytes
from tests.mock_provider import MockProvider, sse_event
from tests.provider_harness import chat_request, provider_config

EVENTS_PER_STREAM = 12


class FaultyProvider:
    """A provider that fails on a schedule the test can reproduce."""

    def __init__(self, name: str, seed: int, failure_rate: float) -> None:
        self.name = name
        self.rng = random.Random(seed)
        self.failure_rate = failure_rate
        self.served = 0
        self.failed = 0
        self.lock = threading.Lock()
        self.mock = MockProvider(self.handle)

    def handle(self, request, writer):
        with self.lock:
            self.served += 1
            fail = self.rng.random() < self.failure_rate
            if fail:
                self.failed += 1
        if fail:
            # 503 with a JSON body: a retryable class, so the router is
            # actually exercised rather than the request simply ending.
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
            return

        wants_stream = False
        try:
            wants_stream = bool(request.json().get("stream"))
        except (ValueError, KeyError):
            pass

        if not wants_stream:
            writer.json_response({"id": "ok", "served_by": self.name})
            return

        writer.sse_head()
        for index in range(EVENTS_PER_STREAM):
            if not writer.raw(
                sse_event(json.dumps({"served_by": self.name, "i": index}))
            ):
                return
        writer.raw(sse_event("[DONE]"))
        import socket as _socket

        try:
            writer.conn.shutdown(_socket.SHUT_WR)
        except OSError:
            pass

    def close(self) -> None:
        self.mock.close()


class RoutingFaultSoakTests(unittest.TestCase):
    def build(self, providers, policy="priority"):
        base = provider_config(providers[0].mock.base_url, max_concurrency=32)

        def configure(document):
            base(document)
            first = document["providers"][0]
            first["id"] = providers[0].name
            # A high threshold: this soak is about the router under faults, not
            # about the breaker, and an open circuit would take targets out of
            # the picture and make the run less interesting rather than more.
            first["health"]["failure_threshold"] = 100
            document["routes"][0]["targets"] = [
                {
                    "provider_id": providers[0].name,
                    "upstream_model": "m0",
                    "priority": 10,
                    "weight": 1,
                }
            ]
            for index, provider in enumerate(providers[1:], start=1):
                record = copy.deepcopy(first)
                record["id"] = provider.name
                record["display_name"] = provider.name
                record["base_url"] = provider.mock.base_url
                document["providers"].append(record)
                document["routes"][0]["targets"].append(
                    {
                        "provider_id": provider.name,
                        "upstream_model": f"m{index}",
                        "priority": 10 + index,
                        "weight": 1,
                    }
                )
            document["routes"][0]["policy"] = policy
            document["routes"][0]["fallback"] = {
                "enabled": True,
                "max_attempts": len(providers),
                "retryable": ["http_502", "http_503", "http_504", "connect_failed"],
            }

        return Gateway(mutate=configure)

    def one_exchange(self, gateway, stream: bool) -> bytes:
        body = chat_request(stream=stream).encode()
        return gateway.send_raw(
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

    def check_single_response(self, raw: bytes) -> None:
        self.assertEqual(
            1,
            raw.count(b"HTTP/1.1 "),
            f"more than one response on one connection: {raw[:300]!r}",
        )

    def check_single_provider(self, response) -> None:
        """Every event in a stream came from the same target."""
        stamps = set()
        for line in response.body.split(b"\n"):
            if not line.startswith(b"data: ") or line == b"data: [DONE]":
                continue
            try:
                stamps.add(json.loads(line[6:].decode("utf-8"))["served_by"])
            except (ValueError, KeyError):
                continue
        self.assertLessEqual(
            len(stamps),
            1,
            f"one stream carried events from several providers: {sorted(stamps)}",
        )
        return stamps

    def test_a_soak_of_mixed_requests_under_injected_faults(self) -> None:
        providers = [
            FaultyProvider("p0", seed=1, failure_rate=0.45),
            FaultyProvider("p1", seed=2, failure_rate=0.35),
            FaultyProvider("p2", seed=3, failure_rate=0.0),
        ]
        rounds = 120
        try:
            with self.build(providers) as gateway:
                seen_streams = 0
                seen_bodies = 0
                for index in range(rounds):
                    stream = index % 2 == 0
                    raw = self.one_exchange(gateway, stream)
                    self.check_single_response(raw)
                    responses = parse_responses(raw)
                    self.assertEqual(1, len(responses))
                    response = responses[0]
                    self.assertIn(response.status, (200, 503))
                    if response.status != 200:
                        continue
                    if response.header("content-type") == "text/event-stream":
                        stamps = self.check_single_provider(response)
                        self.assertTrue(stamps, "a stream carried no events")
                        seen_streams += 1
                    else:
                        self.assertIn("served_by", response.json())
                        seen_bodies += 1

                self.assertGreater(seen_streams, 10, "no stream ever completed")
                self.assertGreater(seen_bodies, 10, "no plain response ever completed")
                self.assertTrue(gateway.alive())
                self.assertGreater(
                    providers[0].failed, 0, "no fault was ever injected"
                )
                self.assertGreater(
                    providers[2].served, 0, "the last resort was never reached"
                )
        finally:
            for provider in providers:
                provider.close()

    def test_concurrent_clients_never_see_a_second_response(self) -> None:
        providers = [
            FaultyProvider("p0", seed=11, failure_rate=0.5),
            FaultyProvider("p1", seed=12, failure_rate=0.0),
        ]
        workers = 6
        per_worker = 10
        errors: list = []
        try:
            with self.build(providers) as gateway:

                def run(index: int) -> None:
                    try:
                        for round_index in range(per_worker):
                            raw = self.one_exchange(
                                gateway, stream=(round_index % 2 == 0)
                            )
                            if raw.count(b"HTTP/1.1 ") != 1:
                                errors.append(
                                    f"worker {index}: {raw.count(b'HTTP/1.1 ')} responses"
                                )
                                return
                            responses = parse_responses(raw)
                            if len(responses) != 1:
                                errors.append(f"worker {index}: unparseable")
                                return
                            if responses[0].header("content-type") == "text/event-stream":
                                stamps = set()
                                for line in responses[0].body.split(b"\n"):
                                    if line.startswith(b"data: ") and b"served_by" in line:
                                        stamps.add(
                                            json.loads(line[6:].decode())["served_by"]
                                        )
                                if len(stamps) > 1:
                                    errors.append(
                                        f"worker {index}: mixed stream {sorted(stamps)}"
                                    )
                                    return
                    except Exception as exc:
                        errors.append(f"worker {index}: {exc!r}")

                threads = [
                    threading.Thread(target=run, args=(i,)) for i in range(workers)
                ]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join(180.0)
                self.assertEqual([], errors)
                self.assertTrue(gateway.alive())
        finally:
            for provider in providers:
                provider.close()

    def test_the_daemon_is_flat_after_the_soak(self) -> None:
        providers = [
            FaultyProvider("p0", seed=21, failure_rate=0.6),
            FaultyProvider("p1", seed=22, failure_rate=0.0),
        ]
        try:
            with self.build(providers) as gateway:
                for index in range(20):
                    self.one_exchange(gateway, stream=(index % 2 == 0))
                time.sleep(0.4)
                descriptors = gateway.descriptor_count()

                for index in range(120):
                    self.one_exchange(gateway, stream=(index % 2 == 0))
                time.sleep(1.0)

                self.assertLessEqual(gateway.descriptor_count(), descriptors + 2)
                with gateway.daemon.connect() as client:
                    listed = client.call("providers.list")
                for entry in listed:
                    self.assertEqual(
                        0,
                        entry["active_requests"],
                        f"{entry['id']} still holds {entry['active_requests']} slots",
                    )
        finally:
            for provider in providers:
                provider.close()


if __name__ == "__main__":
    unittest.main()
