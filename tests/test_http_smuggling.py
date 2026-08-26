"""Request-smuggling corpus (HARNESS.md M5 DoD 5).

Smuggling is what happens when two things that both claim to parse HTTP
disagree about where one message ends and the next begins. The defence is not to
resolve the ambiguity cleverly; it is to refuse the ambiguity and close the
connection, so that nothing downstream ever receives a second interpretation.

Every case below asserts three things: the request is refused, the connection
is closed rather than reused, and no second response follows. That last one is
the actual property — a smuggled request that produced a second response would
be the attack succeeding. The status is 4xx except where an unsupported HTTP
version makes 505 the accurate answer.
"""
from __future__ import annotations

import unittest

from tests.http_harness import Gateway, parse_responses

CRLF = b"\r\n"

# Each entry is (name, raw bytes). The comment on each says what a permissive
# parser somewhere else would have made of it.
CORPUS = [
    (
        "content_length_with_transfer_encoding",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: 6\r\nTransfer-Encoding: chunked\r\n\r\n"
        b"0\r\n\r\nGET /healthz HTTP/1.1\r\nHost: x\r\n\r\n",
    ),
    (
        "transfer_encoding_before_content_length",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\n"
        b"Transfer-Encoding: chunked\r\nContent-Length: 6\r\n\r\n"
        b"0\r\n\r\n",
    ),
    (
        "duplicate_content_length_same_value",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
    ),
    (
        "duplicate_content_length_different_values",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: 2\r\nContent-Length: 44\r\n\r\n{}",
    ),
    (
        "content_length_list",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: 2, 2\r\n\r\n{}",
    ),
    (
        "content_length_with_leading_plus",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\nContent-Length: +2\r\n\r\n{}",
    ),
    (
        "content_length_in_hex",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\nContent-Length: 0x2\r\n\r\n{}",
    ),
    (
        "transfer_encoding_identity",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\nTransfer-Encoding: identity\r\n\r\n{}",
    ),
    (
        "transfer_encoding_gzip_chunked",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\n"
        b"Transfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n",
    ),
    (
        "duplicate_transfer_encoding",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\n"
        b"Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    ),
    (
        "obfuscated_transfer_encoding_header_name",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\n"
        b"Transfer-Encoding\t: chunked\r\nContent-Length: 2\r\n\r\n{}",
    ),
    (
        "space_before_colon",
        b"GET /healthz HTTP/1.1\r\nHost : x\r\n\r\n",
    ),
    (
        "invalid_header_name_token",
        b"GET /healthz HTTP/1.1\r\nHost: x\r\nX-Bad(Name): y\r\n\r\n",
    ),
    (
        "bare_lf_line_endings",
        b"GET /healthz HTTP/1.1\nHost: x\n\n",
    ),
    (
        "bare_cr_in_a_header_value",
        b"GET /healthz HTTP/1.1\r\nHost: x\rY: z\r\n\r\n",
    ),
    (
        "null_byte_in_a_header_value",
        b"GET /healthz HTTP/1.1\r\nHost: x\x00y\r\n\r\n",
    ),
    (
        "absolute_form_target",
        b"GET http://evil.example/healthz HTTP/1.1\r\nHost: x\r\n\r\n",
    ),
    (
        "http_0_9_request_line",
        b"GET /healthz\r\n\r\n",
    ),
    (
        "unknown_http_version",
        b"GET /healthz HTTP/3.5\r\nHost: x\r\n\r\n",
    ),
    (
        "chunk_size_with_a_trailing_space",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
        b"2 \r\n{}\r\n0\r\n\r\n",
    ),
    (
        "chunk_size_with_a_negative_sign",
        b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
        b"Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
        b"-2\r\n{}\r\n0\r\n\r\n",
    ),
]


class SmugglingCorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.gateway = Gateway()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.gateway.close()

    def test_every_ambiguous_message_is_refused(self) -> None:
        for name, payload in CORPUS:
            with self.subTest(case=name):
                raw = self.gateway.send_raw(payload)
                responses = parse_responses(raw)
                self.assertLessEqual(
                    len(responses),
                    1,
                    f"{name} produced {len(responses)} responses; a second one is "
                    f"a smuggled request being answered",
                )
                if responses:
                    status = responses[0].status
                    self.assertGreaterEqual(
                        status,
                        400,
                        f"{name} was answered with {status} rather than refused",
                    )
                    self.assertEqual(
                        "close",
                        responses[0].header("connection"),
                        f"{name} left the connection reusable",
                    )

    def test_the_daemon_survives_the_whole_corpus(self) -> None:
        for _, payload in CORPUS:
            self.gateway.send_raw(payload)
        self.assertTrue(self.gateway.alive())
        self.assertEqual(200, self.gateway.get("/healthz").status)

    def test_a_smuggled_second_request_is_never_served(self) -> None:
        """The specific attack: hide a request in a body the front end skips."""
        payload = (
            b"POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
            b"Content-Type: application/json\r\n"
            b"Content-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n"
            b"0\r\n\r\nGET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        raw = self.gateway.send_raw(payload)
        self.assertNotIn(b'"object":"list"', raw)
        responses = parse_responses(raw)
        self.assertEqual(1, len(responses))
        self.assertEqual(400, responses[0].status)
        self.assertEqual("conflicting_framing", responses[0].json()["error"]["code"])


class DuplicateCredentialTests(unittest.TestCase):
    """Two credential headers is one intermediary disagreeing with another."""

    @staticmethod
    def with_bearer(document):
        document["listener"]["auth"] = {
            "type": "bearer_env",
            "env": "ASMFLOW_TEST_TOKEN",
        }

    def test_a_repeated_credential_header_is_refused(self) -> None:
        with Gateway(
            mutate=self.with_bearer,
            extra_env={"ASMFLOW_TEST_TOKEN": "s3cret-token-value"},
        ) as gateway:
            raw = gateway.send_raw(
                b"GET /healthz HTTP/1.1\r\nHost: x\r\n"
                b"Authorization: Bearer s3cret-token-value\r\n"
                b"Authorization: Bearer s3cret-token-value\r\n"
                b"Connection: close\r\n\r\n"
            )
            response = parse_responses(raw)[0]
            self.assertEqual(400, response.status)
            self.assertEqual("conflicting_framing", response.json()["error"]["code"])


if __name__ == "__main__":
    unittest.main()
