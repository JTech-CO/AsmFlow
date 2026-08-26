"""Ten thousand requests without growth (HARNESS.md M5 DoD 9).

A leak of one allocation per request is invisible in a unit test and fatal in a
long-running daemon, which is what this one is meant to be. The measurement is
resident set size rather than an allocator counter, because the allocator's own
bookkeeping is exactly what would be wrong if the bookkeeping were wrong.

RSS is noisy — the allocator keeps freed pages, the kernel accounts lazily — so
the test compares a settled baseline taken after a warm-up against the figure
after the full run, and allows a fixed headroom rather than demanding equality.
A per-request leak of even a hundred bytes would be a megabyte over ten thousand
requests and would fail this comfortably.
"""
from __future__ import annotations

import json
import unittest

from tests.http_harness import Gateway, parse_responses, read_until_quiet

REQUESTS = 10_000
WARMUP = 500
HEADROOM_KB = 512


def resident_kb(pid: int) -> int:
    with open(f"/proc/{pid}/status", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    raise AssertionError("VmRSS is not reported for this process")


class SoakTests(unittest.TestCase):
    def _drive(self, gateway, sock, count: int) -> None:
        request = b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n"
        pending = b""
        for _ in range(count):
            sock.sendall(request)
            while True:
                pending += sock.recv(65536)
                responses = parse_responses(pending)
                if responses:
                    break
            self.assertEqual(200, responses[0].status)
            pending = b""

    def test_ten_thousand_requests_leave_the_resident_set_flat(self) -> None:
        with Gateway() as gateway:
            sock = gateway.connect(timeout=30.0)
            try:
                # Warm up first. The first requests populate buffers that are
                # then reused, and counting that growth as a leak would be
                # measuring startup rather than steady state.
                self._drive(gateway, sock, WARMUP)
                baseline = resident_kb(gateway.process.pid)

                self._drive(gateway, sock, REQUESTS)
                after = resident_kb(gateway.process.pid)
            finally:
                sock.close()

            growth = after - baseline
            self.assertLess(
                growth,
                HEADROOM_KB,
                f"the resident set grew {growth} KiB over {REQUESTS} requests "
                f"({baseline} KiB to {after} KiB)",
            )
            self.assertTrue(gateway.alive())
            self.assertEqual(200, gateway.get("/healthz").status)

    def test_a_thousand_fresh_connections_leave_it_flat_too(self) -> None:
        """The other shape: a client that never reuses a connection."""
        with Gateway() as gateway:
            baseline_fds = gateway.descriptor_count()
            for _ in range(100):
                self.assertEqual(200, gateway.get("/healthz").status)
            baseline = resident_kb(gateway.process.pid)

            for _ in range(1000):
                self.assertEqual(200, gateway.get("/healthz").status)

            growth = resident_kb(gateway.process.pid) - baseline
            self.assertLess(growth, HEADROOM_KB, f"grew {growth} KiB")
            self.assertLessEqual(gateway.descriptor_count(), baseline_fds)

    def test_a_mixed_workload_leaves_it_flat(self) -> None:
        """Refusals allocate too, and are the paths least likely to be tidy."""
        payload = json.dumps({"model": "general"})
        with Gateway() as gateway:
            for _ in range(50):
                gateway.get("/healthz")
            baseline = resident_kb(gateway.process.pid)

            for _ in range(500):
                gateway.get("/readyz")
                gateway.get("/v1/models")
                gateway.get("/no-such-path")
                gateway.post_json("/v1/responses", payload)
                gateway.post_json("/v1/responses", "{bad")
                gateway.send_raw(
                    b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
                    b"Content-Length: 1\r\nContent-Length: 2\r\n\r\n{}"
                )

            growth = resident_kb(gateway.process.pid) - baseline
            self.assertLess(growth, HEADROOM_KB, f"grew {growth} KiB")
            self.assertTrue(gateway.alive())


if __name__ == "__main__":
    unittest.main()
