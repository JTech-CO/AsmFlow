"""Delivery shape must not change the answer (HARNESS.md M5 DoD 6).

TCP is a byte stream, so a request can arrive as one segment, as one byte per
segment, or split at any point in between — including in the middle of a header
name, a header value, or a chunk size. A parser that is right only when tokens
arrive whole is a parser that works in testing and fails against a real network,
and the failure mode is a security one: whether a header is recognised should
not depend on how it was fragmented.

The comparison ignores the two fields that are supposed to differ between two
identical requests — the correlation id and the uptime — and requires the rest
of the response to be byte-identical.
"""
from __future__ import annotations

import json
import random
import unittest

from tests.http_harness import Gateway, parse_responses

VOLATILE = ("x-asmflow-request-id",)


def normalise(response) -> tuple:
    """Everything about a response except what is meant to vary."""
    headers = {
        name: value
        for name, value in response.headers.items()
        if name not in VOLATILE
    }
    body = response.body
    try:
        payload = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return (response.status, response.reason, tuple(sorted(headers.items())), body)
    if isinstance(payload, dict):
        payload.pop("uptime_ms", None)
        payload.get("asmflow", {}).pop("request_id", None)
    # Content-Length still differs when uptime_ms has a different digit count,
    # and that difference is not what this suite is about.
    headers.pop("content-length", None)
    return (
        response.status,
        response.reason,
        tuple(sorted(headers.items())),
        json.dumps(payload, sort_keys=True),
    )


REQUESTS = {
    "health": b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    "models": b"GET /v1/models HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    "unknown_path": b"GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    "post_known_alias": (
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\nContent-Length: 20\r\n"
        b"Connection: close\r\n\r\n" + json.dumps({"model": "general"}).encode()
    ),
    "post_unknown_alias": (
        b"POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\nContent-Length: 17\r\n"
        b"Connection: close\r\n\r\n" + json.dumps({"model": "gone"}).encode()
    ),
    "duplicate_content_length": (
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: 2\r\nContent-Length: 2\r\n"
        b"Connection: close\r\n\r\n{}"
    ),
}


class FragmentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.gateway = Gateway()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.gateway.close()

    def _send_in_pieces(self, payload: bytes, pieces) -> bytes:
        from tests.http_harness import read_until_quiet

        sock = self.gateway.connect(timeout=10.0)
        try:
            for piece in pieces:
                try:
                    sock.sendall(piece)
                except OSError:
                    # The daemon answered and shut down its write side while we
                    # were still transmitting. Stop writing and read the answer.
                    break
            return read_until_quiet(sock, timeout=5.0)
        finally:
            sock.close()

    def test_one_byte_at_a_time_gives_the_same_answer(self) -> None:
        for name, payload in REQUESTS.items():
            with self.subTest(request=name):
                whole = parse_responses(self.gateway.send_raw(payload))
                pieces = [payload[i : i + 1] for i in range(len(payload))]
                fragmented = parse_responses(self._send_in_pieces(payload, pieces))
                self.assertEqual(len(whole), len(fragmented))
                self.assertTrue(whole, f"{name} produced no response")
                self.assertEqual(normalise(whole[0]), normalise(fragmented[0]))

    def test_arbitrary_split_points_give_the_same_answer(self) -> None:
        """Splits chosen by seed, so a failure is reproducible."""
        rng = random.Random(20260827)
        for name, payload in REQUESTS.items():
            expected = normalise(parse_responses(self.gateway.send_raw(payload))[0])
            for attempt in range(4):
                with self.subTest(request=name, attempt=attempt):
                    cuts = sorted(
                        rng.sample(range(1, len(payload)), min(5, len(payload) - 1))
                    )
                    pieces, previous = [], 0
                    for cut in cuts:
                        pieces.append(payload[previous:cut])
                        previous = cut
                    pieces.append(payload[previous:])
                    got = parse_responses(self._send_in_pieces(payload, pieces))
                    self.assertTrue(got, f"{name} produced no response when split")
                    self.assertEqual(expected, normalise(got[0]))

    def test_a_split_inside_a_header_name_is_still_that_header(self) -> None:
        """The case that catches a parser holding on to a borrowed pointer."""
        pieces = [
            b"POST /v1/responses HTTP/1.1\r\nHost: x\r\nCon",
            b"tent-Ty",
            b"pe: applica",
            b"tion/js",
            b"on\r\nContent-Len",
            b"gth: 20\r\nConnection: close\r\n\r\n",
            b'{"model": ',
            b'"general"}',
        ]
        raw = self._send_in_pieces(b"", pieces)
        response = parse_responses(raw)[0]
        # The base fixture's route serves chat completions only, so this is a
        # routing answer. What matters here is that it is the SAME routing
        # answer a whole request gets: the split changed nothing.
        self.assertEqual(503, response.status)
        self.assertEqual("no_eligible_target", response.json()["error"]["code"])

    def test_a_split_inside_a_chunk_size_is_still_that_size(self) -> None:
        body = json.dumps({"model": "general"}).encode()
        framed = f"{len(body):x}".encode() + b"\r\n" + body + b"\r\n0\r\n\r\n"
        head = (
            b"POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\n"
            b"Content-Type: application/json\r\n"
            b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        )
        whole = parse_responses(self.gateway.send_raw(head + framed))[0]
        pieces = [head] + [
            (head + framed)[i : i + 1] for i in range(len(head), len(head + framed))
        ]
        split = parse_responses(self._send_in_pieces(b"", pieces))[0]
        self.assertEqual(normalise(whole), normalise(split))


class EncodingEquivalenceTests(unittest.TestCase):
    """The same body, framed two ways, is the same request."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.gateway = Gateway()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.gateway.close()

    def _both_framings(self, payload: str):
        body = payload.encode("utf-8")
        declared = (
            b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
            b"Content-Type: application/json\r\n"
            b"Content-Length: " + str(len(body)).encode() + b"\r\n"
            b"Connection: close\r\n\r\n" + body
        )
        chunked = (
            b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
            b"Content-Type: application/json\r\n"
            b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        )
        for start in range(0, len(body), 7):
            piece = body[start : start + 7]
            chunked += f"{len(piece):x}".encode() + b"\r\n" + piece + b"\r\n"
        chunked += b"0\r\n\r\n"
        return (
            parse_responses(self.gateway.send_raw(declared))[0],
            parse_responses(self.gateway.send_raw(chunked))[0],
        )

    def test_chunked_and_declared_bodies_normalise_alike(self) -> None:
        for payload in (
            json.dumps({"model": "general"}),
            json.dumps({"model": "gone"}),
            json.dumps({"model": 7}),
            "{not json",
        ):
            with self.subTest(payload=payload[:24]):
                declared, chunked = self._both_framings(payload)
                self.assertEqual(normalise(declared), normalise(chunked))


if __name__ == "__main__":
    unittest.main()
