"""Limit boundaries on the data plane (HARNESS.md M5 DoD 4).

Each limit is checked on both sides of its boundary. A limit that only ever
gets tested with an obviously oversized input proves the refusal path works but
says nothing about whether a legitimate request at the edge still succeeds, and
that is the failure an operator actually meets.
"""
from __future__ import annotations

import json
import socket
import time
import unittest

from tests.http_harness import Gateway, parse_responses, request_bytes

HEADER_MAX = 8192
BODY_MAX = 4096


def limits(document):
    document["listener"]["request_header_max_bytes"] = HEADER_MAX
    document["listener"]["request_body_max_bytes"] = BODY_MAX


class HeaderLimitTests(unittest.TestCase):
    def _padded_request(self, padding: int) -> bytes:
        return request_bytes(
            target="/healthz",
            headers=[("X-Pad", "p" * padding)],
        )

    def test_a_header_section_under_the_ceiling_is_served(self) -> None:
        with Gateway(mutate=limits) as gateway:
            raw = gateway.send_raw(self._padded_request(HEADER_MAX // 2))
            self.assertEqual(200, parse_responses(raw)[0].status)

    def test_a_header_section_over_the_ceiling_is_431(self) -> None:
        with Gateway(mutate=limits) as gateway:
            raw = gateway.send_raw(self._padded_request(HEADER_MAX * 2))
            response = parse_responses(raw)[0]
            self.assertEqual(431, response.status)
            self.assertEqual("headers_too_large", response.json()["error"]["code"])

    def test_many_small_headers_also_reach_the_ceiling(self) -> None:
        """The limit is on the section, not on any one field."""
        headers = [(f"X-Pad-{n}", "p" * 200) for n in range(200)]
        with Gateway(mutate=limits) as gateway:
            raw = gateway.send_raw(request_bytes(target="/healthz", headers=headers))
            self.assertEqual(431, parse_responses(raw)[0].status)

    def test_an_endless_header_stream_is_refused_rather_than_absorbed(self) -> None:
        """A peer that never sends the blank line must still be bounded."""
        with Gateway(mutate=limits) as gateway:
            sock = gateway.connect(timeout=10.0)
            try:
                sock.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n")
                sent = 0
                refused = False
                while sent < HEADER_MAX * 8:
                    try:
                        sock.sendall(b"X-Pad: " + b"p" * 500 + b"\r\n")
                        sent += 512
                    except OSError:
                        refused = True
                        break
                sock.settimeout(5.0)
                try:
                    reply = sock.recv(65536)
                except OSError:
                    reply = b""
                if reply:
                    self.assertEqual(431, parse_responses(reply)[0].status)
                else:
                    self.assertTrue(
                        refused, "the daemon absorbed an unbounded header stream"
                    )
            finally:
                sock.close()
            self.assertTrue(gateway.alive())


class BodyLimitTests(unittest.TestCase):
    def test_a_body_under_the_ceiling_is_accepted(self) -> None:
        payload = json.dumps({"model": "general", "pad": "x" * (BODY_MAX // 2)})
        with Gateway(mutate=limits) as gateway:
            response = gateway.post_json("/v1/responses", payload)
            self.assertEqual(503, response.status)
            self.assertEqual(
                "unsupported_in_this_build", response.json()["error"]["code"]
            )

    def test_a_declared_body_over_the_ceiling_is_413(self) -> None:
        payload = json.dumps({"model": "general", "pad": "x" * (BODY_MAX * 4)})
        with Gateway(mutate=limits) as gateway:
            response = gateway.post_json("/v1/responses", payload)
            self.assertEqual(413, response.status)
            self.assertEqual("body_too_large", response.json()["error"]["code"])

    def test_an_oversized_body_is_refused_before_it_is_sent(self) -> None:
        """The declaration is enough; reading it all to say so is the attack."""
        body = b"x" * (BODY_MAX * 4)
        with Gateway(mutate=limits) as gateway:
            sock = gateway.connect(timeout=10.0)
            try:
                sock.sendall(
                    b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
                    b"Content-Type: application/json\r\n"
                    b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                    b"Connection: close\r\n\r\n"
                )
                sock.settimeout(5.0)
                reply = sock.recv(65536)
            finally:
                sock.close()
            self.assertEqual(413, parse_responses(reply)[0].status)

    def test_a_chunked_body_over_the_ceiling_is_413(self) -> None:
        """Chunked declares nothing, so the running total is the only measure."""
        chunk = b"x" * 1024
        framed = b""
        for _ in range((BODY_MAX * 4) // len(chunk)):
            framed += f"{len(chunk):x}".encode() + b"\r\n" + chunk + b"\r\n"
        framed += b"0\r\n\r\n"
        with Gateway(mutate=limits) as gateway:
            raw = gateway.send_raw(
                b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
                b"Content-Type: application/json\r\n"
                b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n" + framed
            )
            self.assertEqual(413, parse_responses(raw)[0].status)

    def test_a_chunked_body_under_the_ceiling_is_accepted(self) -> None:
        payload = json.dumps({"model": "general"}).encode()
        framed = f"{len(payload):x}".encode() + b"\r\n" + payload + b"\r\n0\r\n\r\n"
        with Gateway(mutate=limits) as gateway:
            raw = gateway.send_raw(
                b"POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\n"
                b"Content-Type: application/json\r\n"
                b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n" + framed
            )
            self.assertEqual(503, parse_responses(raw)[0].status)


class JsonLimitTests(unittest.TestCase):
    """The configured JSON ceilings apply to a request body, not just the file."""

    def test_a_body_deeper_than_the_limit_is_refused(self) -> None:
        def shallow(document):
            limits(document)
            document["limits"]["json_max_depth"] = 8

        nested = []
        for _ in range(40):
            nested = [nested]
        payload = json.dumps({"model": "general", "deep": nested})
        with Gateway(mutate=shallow) as gateway:
            response = gateway.post_json("/v1/responses", payload)
            self.assertEqual(400, response.status)
            self.assertEqual("invalid_json", response.json()["error"]["code"])

    def test_a_body_within_the_depth_limit_is_accepted(self) -> None:
        def shallow(document):
            limits(document)
            document["limits"]["json_max_depth"] = 8

        payload = json.dumps({"model": "general", "deep": [[["ok"]]]})
        with Gateway(mutate=shallow) as gateway:
            self.assertEqual(503, gateway.post_json("/v1/responses", payload).status)

    def test_a_string_longer_than_the_limit_is_refused(self) -> None:
        def short_strings(document):
            document["listener"]["request_body_max_bytes"] = 65536
            document["limits"]["json_string_max_bytes"] = 1024

        payload = json.dumps({"model": "general", "pad": "x" * 4096})
        with Gateway(mutate=short_strings) as gateway:
            response = gateway.post_json("/v1/responses", payload)
            self.assertEqual(400, response.status)


class IdleTimeoutTests(unittest.TestCase):
    """M5 DoD 4 and 7: an inactive connection does not sit there forever."""

    @staticmethod
    def brief(document):
        document["listener"]["idle_timeout_ms"] = 1000

    def test_a_half_sent_request_times_out(self) -> None:
        with Gateway(mutate=self.brief) as gateway:
            sock = gateway.connect(timeout=15.0)
            try:
                sock.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n")
                sock.settimeout(15.0)
                started = time.monotonic()
                reply = sock.recv(65536)
                elapsed = time.monotonic() - started
            finally:
                sock.close()
            self.assertLess(elapsed, 10.0, "the timeout took far longer than asked")
            self.assertTrue(reply, "the connection was dropped without an explanation")
            response = parse_responses(reply)[0]
            self.assertEqual(408, response.status)
            self.assertEqual("request_timeout", response.json()["error"]["code"])
            self.assertTrue(gateway.alive())

    def test_an_idle_connection_that_sent_nothing_is_closed(self) -> None:
        with Gateway(mutate=self.brief) as gateway:
            before = gateway.descriptor_count()
            sock = gateway.connect(timeout=15.0)
            try:
                sock.settimeout(15.0)
                self.assertEqual(b"", sock.recv(65536), "expected a clean close")
            finally:
                sock.close()
            deadline = time.monotonic() + 10.0
            while time.monotonic() < deadline:
                if gateway.descriptor_count() <= before:
                    break
                time.sleep(0.05)
            self.assertLessEqual(gateway.descriptor_count(), before)
            self.assertTrue(gateway.alive())

    def test_activity_postpones_the_timeout(self) -> None:
        """A working client on a keep-alive connection is not disconnected."""
        with Gateway(mutate=self.brief) as gateway:
            sock = gateway.connect(timeout=15.0)
            try:
                for _ in range(4):
                    sock.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
                    sock.settimeout(5.0)
                    reply = sock.recv(65536)
                    self.assertEqual(200, parse_responses(reply)[0].status)
                    time.sleep(0.6)
            finally:
                sock.close()


if __name__ == "__main__":
    unittest.main()
