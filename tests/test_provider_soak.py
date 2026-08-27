"""Sustained streaming (HARNESS.md M6 DoD 8).

The Definition of Done asks for a one-hour stream soak with zero event-order or
byte-count mismatches. An hour is not a CI step, so the volume is a parameter:
`ASMFLOW_SOAK_SECONDS` extends the run, and the default is sized to finish in
seconds while still crossing every boundary that matters — many streams, many
events per stream, buffers reused, slots recycled, several clients at once.

What is asserted does not change with the volume. Every stream's bytes must be
exactly the bytes its provider sent, in order; the resident set must be flat at
the end; and no descriptor may be left behind. A soak that only checked "it did
not crash" would pass with events silently reordered between concurrent
streams, which is the failure this is actually looking for.
"""
from __future__ import annotations

import json
import os
import threading
import time
import unittest

from tests.http_harness import parse_responses, request_bytes
from tests.mock_provider import sse_event, sse_handler
from tests.provider_harness import ProviderGateway, chat_request

SOAK_SECONDS = float(os.environ.get("ASMFLOW_SOAK_SECONDS", "0"))


def stream_request(marker: int) -> bytes:
    body = chat_request(stream=True, client_marker=marker).encode()
    return request_bytes(
        method="POST",
        target="/v1/chat/completions",
        headers=[
            ("Content-Type", "application/json"),
            ("Content-Length", str(len(body))),
        ],
        body=body,
    )


def rss_kib(pid: int) -> int:
    with open(f"/proc/{pid}/status", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    return 0


EVENTS = [sse_event(json.dumps({"i": i, "pad": "p" * 200})) for i in range(200)]
EVENTS.append(sse_event("[DONE]"))
EXPECTED = b"".join(EVENTS)


class StreamSoakTests(unittest.TestCase):
    def drive_one(self, fixture) -> bytes:
        sock = fixture.connect(timeout=30.0)
        sock.settimeout(30.0)
        try:
            sock.sendall(stream_request(0))
            received = b""
            while True:
                piece = sock.recv(65536)
                if not piece:
                    break
                received += piece
            return received
        finally:
            sock.close()

    def test_sequential_streams_never_drift(self) -> None:
        rounds = 200
        deadline = time.monotonic() + SOAK_SECONDS if SOAK_SECONDS else None
        with ProviderGateway(sse_handler(EVENTS)) as fixture:
            pid = fixture.gateway.daemon.process.pid
            # Warm up first: the first few requests allocate buffers that every
            # later one reuses, and counting those as growth would make the
            # measurement about start-up rather than about the soak.
            for _ in range(10):
                self.drive_one(fixture)
            baseline = rss_kib(pid)
            descriptors = fixture.descriptor_count()

            completed = 0
            while True:
                for _ in range(rounds):
                    responses = parse_responses(self.drive_one(fixture))
                    self.assertEqual(1, len(responses))
                    self.assertEqual(200, responses[0].status)
                    self.assertEqual(EXPECTED, responses[0].body)
                    completed += 1
                if deadline is None or time.monotonic() >= deadline:
                    break

            time.sleep(0.5)
            growth = rss_kib(pid) - baseline
            self.assertLess(
                growth, 2048, f"the resident set grew {growth} KiB over {completed} streams"
            )
            self.assertLessEqual(fixture.descriptor_count(), descriptors + 2)
            self.assertTrue(fixture.alive())

    def test_concurrent_streams_keep_their_own_order(self) -> None:
        """Interleaving is where a shared buffer would show itself."""
        workers = 8
        per_worker = 12
        results: list = [None] * workers
        errors: list = []

        with ProviderGateway(sse_handler(EVENTS, chunk_size=997)) as fixture:

            def run(index: int) -> None:
                try:
                    for _ in range(per_worker):
                        responses = parse_responses(self.drive_one(fixture))
                        if len(responses) != 1 or responses[0].body != EXPECTED:
                            errors.append(
                                f"worker {index} got {len(responses)} responses, "
                                f"{len(responses[0].body) if responses else 0} bytes"
                            )
                            return
                    results[index] = True
                except Exception as exc:  # surfaced below, not swallowed
                    errors.append(f"worker {index}: {exc!r}")

            threads = [threading.Thread(target=run, args=(i,)) for i in range(workers)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(120.0)

            self.assertEqual([], errors)
            self.assertEqual([True] * workers, results)
            self.assertTrue(fixture.alive())

    def test_many_short_non_streaming_exchanges_are_flat(self) -> None:
        from tests.mock_provider import json_handler

        payload = {"id": "soak", "object": "chat.completion", "choices": []}
        with ProviderGateway(json_handler(payload)) as fixture:
            pid = fixture.gateway.daemon.process.pid
            for _ in range(50):
                fixture.post_json("/v1/chat/completions", chat_request())
            baseline = rss_kib(pid)
            descriptors = fixture.descriptor_count()
            for _ in range(2000):
                response = fixture.post_json("/v1/chat/completions", chat_request())
                self.assertEqual(200, response.status)
            time.sleep(0.5)
            growth = rss_kib(pid) - baseline
            self.assertLess(growth, 1024, f"the resident set grew {growth} KiB")
            self.assertLessEqual(fixture.descriptor_count(), descriptors + 2)


if __name__ == "__main__":
    unittest.main()
