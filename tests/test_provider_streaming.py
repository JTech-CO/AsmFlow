"""Server-Sent Events through the gateway (HARNESS.md M6 DoD 2 and 3).

The corpus below exists because one libcurl callback is not one event. A
provider's bytes arrive in whatever sizes the network produced, and the same
stream delivered in different sizes must produce the same response — byte for
byte, event for event, in order.

The strongest statement here is `test_every_chunk_size_gives_identical_bytes`:
the same events are streamed at eleven different write granularities, including
one byte at a time, and every resulting response body has to be the same
object. If AsmFlow ever split an event, merged two, dropped a terminator, or
corrupted a character on a buffer boundary, that test is where it shows.
"""
from __future__ import annotations

import json
import unittest

from tests.mock_provider import sse_event, sse_handler
from tests.provider_harness import ProviderGateway, chat_request

# A stream shaped like a real one: several deltas and a sentinel.
EVENTS = [
    sse_event(json.dumps({"choices": [{"delta": {"content": "Hel"}}]})),
    sse_event(json.dumps({"choices": [{"delta": {"content": "lo,"}}]})),
    sse_event(json.dumps({"choices": [{"delta": {"content": " world"}}]})),
    sse_event("[DONE]"),
]

# Characters that occupy two, three, and four bytes, so a one-byte-at-a-time
# stream necessarily splits several of them.
WIDE = "é ☃ \U0001f600 안녕"
WIDE_EVENTS = [
    sse_event(json.dumps({"text": WIDE}, ensure_ascii=False)),
    sse_event("[DONE]"),
]


def stream(fixture, target="/v1/chat/completions", **kwargs):
    """POST a streaming request and return the response."""
    return fixture.post_json(target, chat_request(stream=True, **kwargs))


class StreamShapeTests(unittest.TestCase):
    """M6 DoD 2: what a streamed response looks like from the client side."""

    def test_a_streamed_response_is_an_event_stream(self) -> None:
        with ProviderGateway(sse_handler(EVENTS)) as fixture:
            response = stream(fixture)
            self.assertEqual(200, response.status)
            self.assertEqual("text/event-stream", response.header("content-type"))

    def test_a_streamed_response_is_chunked(self) -> None:
        """It has no length to state when its head is written."""
        with ProviderGateway(sse_handler(EVENTS)) as fixture:
            response = stream(fixture)
            self.assertEqual("chunked", response.header("transfer-encoding"))
            self.assertIsNone(response.header("content-length"))

    def test_the_events_arrive_unchanged(self) -> None:
        with ProviderGateway(sse_handler(EVENTS)) as fixture:
            response = stream(fixture)
            self.assertEqual(b"".join(EVENTS), response.body)

    def test_a_streamed_response_is_not_to_be_stored(self) -> None:
        with ProviderGateway(sse_handler(EVENTS)) as fixture:
            response = stream(fixture)
            self.assertEqual("no-store", response.header("cache-control"))

    def test_the_upstream_was_told_to_stream(self) -> None:
        with ProviderGateway(sse_handler(EVENTS)) as fixture:
            stream(fixture)
            forwarded = fixture.requests[0]
            self.assertEqual("text/event-stream", forwarded.header("accept"))
            self.assertTrue(forwarded.json()["stream"])

    def test_a_non_stream_request_asks_for_json(self) -> None:
        from tests.mock_provider import json_handler

        with ProviderGateway(json_handler({"ok": True})) as fixture:
            fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual("application/json", fixture.requests[0].header("accept"))


class FragmentCorpusTests(unittest.TestCase):
    """M6 DoD 3: the same stream, delivered every way it can be delivered."""

    CHUNK_SIZES = [0, 1, 2, 3, 5, 7, 11, 16, 32, 64, 4096]

    def test_every_chunk_size_gives_identical_bytes(self) -> None:
        expected = b"".join(EVENTS)
        for size in self.CHUNK_SIZES:
            with self.subTest(chunk_size=size):
                with ProviderGateway(sse_handler(EVENTS, chunk_size=size)) as fixture:
                    response = stream(fixture)
                    self.assertEqual(200, response.status)
                    self.assertEqual(expected, response.body)

    def test_one_byte_at_a_time_does_not_split_a_character(self) -> None:
        with ProviderGateway(sse_handler(WIDE_EVENTS, chunk_size=1)) as fixture:
            response = stream(fixture)
            self.assertEqual(b"".join(WIDE_EVENTS), response.body)
            first = response.body.split(b"\n\n")[0]
            payload = json.loads(first.split(b"data: ", 1)[1].decode("utf-8"))
            self.assertEqual(WIDE, payload["text"])

    def test_crlf_terminated_events_are_forwarded_as_sent(self) -> None:
        """SSE allows CRLF, LF, and a bare CR. None of them is rewritten."""
        events = [
            sse_event('{"n":1}', newline="\r\n"),
            sse_event('{"n":2}', newline="\r\n"),
            sse_event("[DONE]", newline="\r\n"),
        ]
        with ProviderGateway(sse_handler(events, chunk_size=1)) as fixture:
            response = stream(fixture)
            self.assertEqual(b"".join(events), response.body)

    def test_bare_cr_terminated_events_are_forwarded_as_sent(self) -> None:
        events = [sse_event('{"n":1}', newline="\r"), sse_event("[DONE]", newline="\r")]
        with ProviderGateway(sse_handler(events, chunk_size=1)) as fixture:
            response = stream(fixture)
            self.assertEqual(b"".join(events), response.body)

    def test_a_split_between_cr_and_lf_does_not_invent_a_boundary(self) -> None:
        """The one genuinely ambiguous split.

        A buffer ending in CR could be a bare-CR line ending or the first half
        of a CRLF. Deciding early would turn one event into two. Every split
        point in the stream is tried, on one daemon: the cut moves with each
        connection rather than with each process.
        """
        events = [
            sse_event('{"n":1}', newline="\r\n"),
            sse_event("[DONE]", newline="\r\n"),
        ]
        payload = b"".join(events)
        state = {"cut": 0}

        def handler(request, writer):
            import socket as _socket

            cut = state["cut"]
            writer.sse_head()
            writer.raw(payload[:cut])
            writer.raw(payload[cut:])
            try:
                writer.conn.shutdown(_socket.SHUT_WR)
            except OSError:
                pass

        with ProviderGateway(handler) as fixture:
            for cut in range(1, len(payload)):
                with self.subTest(cut=cut):
                    state["cut"] = cut
                    response = stream(fixture)
                    self.assertEqual(payload, response.body)

    def test_many_events_in_one_write_are_all_forwarded(self) -> None:
        events = [sse_event(json.dumps({"i": i})) for i in range(64)]
        events.append(sse_event("[DONE]"))
        with ProviderGateway(sse_handler(events, chunk_size=0)) as fixture:
            response = stream(fixture)
            self.assertEqual(b"".join(events), response.body)
            self.assertEqual(65, response.body.count(b"\n\n"))

    def test_an_event_with_a_comment_and_a_name_survives(self) -> None:
        raw = b": keep-alive\n\nevent: delta\ndata: {\"a\":1}\n\ndata: [DONE]\n\n"
        with ProviderGateway(sse_handler([raw], chunk_size=1)) as fixture:
            response = stream(fixture)
            self.assertEqual(raw, response.body)

    def test_a_stream_ending_without_a_blank_line_loses_nothing(self) -> None:
        """A provider that stops mid-event has still said those bytes."""
        raw = b"data: {\"a\":1}\n\ndata: unterminat"
        with ProviderGateway(sse_handler([raw])) as fixture:
            response = stream(fixture)
            self.assertEqual(raw, response.body)


class StreamLimitTests(unittest.TestCase):
    """`limits.sse_event_max_bytes` is why an event is a unit at all."""

    def small_limit(self, size):
        def mutate(document):
            document["limits"]["sse_event_max_bytes"] = size

        return mutate

    def test_an_event_at_the_limit_is_delivered(self) -> None:
        limit = 2048
        event = sse_event("x" * (limit - len("data: ") - 2))
        self.assertEqual(limit, len(event))
        with ProviderGateway(
            sse_handler([event, sse_event("[DONE]")]),
            mutate=self.small_limit(limit),
        ) as fixture:
            response = stream(fixture)
            self.assertIn(event, response.body)

    def test_an_event_past_the_limit_reaches_the_client_at_all(self) -> None:
        """Not one byte of a refused event, not at the end either.

        The first version of this passed the refused event to the client
        anyway: the ceiling stopped the stream correctly, and then the
        end-of-stream flush handed back the carry buffer — which held exactly
        the event that had just been refused.
        """
        limit = 2048
        oversized = sse_event("x" * (limit * 4))
        with ProviderGateway(
            sse_handler([oversized, sse_event("[DONE]")]),
            mutate=self.small_limit(limit),
        ) as fixture:
            response = stream(fixture)
            # The head was already sent, so the status cannot change; what the
            # client must not receive is any part of the oversized event.
            self.assertEqual(200, response.status)
            self.assertNotIn(b"x", response.body)
            self.assertEqual(b"", response.body)

    def test_a_stream_that_never_ends_an_event_is_bounded(self) -> None:
        """Without a per-event bound this buffer would grow forever."""
        limit = 4096
        endless = b"data: " + b"y" * (limit * 8)
        with ProviderGateway(
            sse_handler([endless]), mutate=self.small_limit(limit)
        ) as fixture:
            response = stream(fixture)
            self.assertEqual(200, response.status)
            self.assertEqual(b"", response.body)

    def test_the_events_before_an_oversized_one_are_kept(self) -> None:
        """The refusal is of one event, not of everything already delivered."""
        limit = 2048
        good = sse_event("fine")
        with ProviderGateway(
            sse_handler([good, sse_event("z" * (limit * 4))]),
            mutate=self.small_limit(limit),
        ) as fixture:
            response = stream(fixture)
            self.assertEqual(good, response.body)


class NonStreamingUpstreamTests(unittest.TestCase):
    """A provider that answers a stream request with a plain body."""

    def test_a_json_answer_to_a_stream_request_is_relayed_as_json(self) -> None:
        """Framing follows what arrived, not what was asked for.

        Wrapping a JSON body in event framing AsmFlow invented would hand the
        client a stream the provider never sent.
        """
        from tests.mock_provider import json_handler

        payload = {"id": "not-a-stream", "object": "chat.completion"}
        with ProviderGateway(json_handler(payload)) as fixture:
            response = stream(fixture)
            self.assertEqual(200, response.status)
            self.assertEqual("application/json", response.header("content-type"))
            self.assertEqual(payload, response.json())


if __name__ == "__main__":
    unittest.main()
