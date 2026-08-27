"""When a request may try a second target, and when it may not.

HARNESS.md M7 DoD 5, 6, and 7. The third of those is the one that keeps the
other two honest: an attempt loop that could revisit a target it has already
tried would satisfy "fallback happens" and "fallback stops after N" while
sending every one of those N attempts to the same broken provider.

DoD 6 — zero fallback attempts once a byte has reached the client — is the
invariant with the worst failure mode. A fallback after the commit point does
not produce an error; it produces a second response on a connection that
already has one, which a client will read as a corrupt stream or as an answer
to a question it did not ask.
"""
from __future__ import annotations

import copy
import json
import threading
import unittest

from tests.http_harness import Gateway, request_bytes
from tests.mock_provider import MockProvider, sse_event
from tests.provider_harness import chat_request, provider_config

OK_BODY = {"id": "ok", "object": "chat.completion", "choices": []}


class Target:
    """One mock provider that a route can be pointed at."""

    def __init__(self, name: str, handler) -> None:
        self.name = name
        self.attempts = 0
        self.lock = threading.Lock()
        self._handler = handler
        self.mock = MockProvider(self._count)

    def _count(self, request, writer):
        with self.lock:
            self.attempts += 1
        self._handler(request, writer)

    def close(self) -> None:
        self.mock.close()


def refuse(request, writer):
    """A transport failure: the response starts and the connection dies."""
    writer.head(200, {"Content-Type": "application/json", "Content-Length": "64"})
    writer.raw(b"{")
    try:
        writer.conn.close()
    except OSError:
        pass


def succeed(request, writer):
    writer.json_response(OK_BODY)


def http_503(request, writer):
    body = json.dumps({"error": {"message": "busy"}}).encode()
    writer.head(
        503,
        {"Content-Type": "application/json", "Content-Length": str(len(body))},
        reason="Service Unavailable",
    )
    writer.raw(body)


def stream_then_die(request, writer):
    """Commit the response, then fail. Nothing may be retried after this."""
    writer.sse_head()
    writer.raw(sse_event('{"delta":"partial"}'))
    try:
        writer.conn.close()
    except OSError:
        pass


class FallbackFixture:
    """A route over several mock providers, with a chosen fallback policy."""

    def __init__(self, targets, *, max_attempts=None, retryable=None, enabled=True,
                 failure_threshold=100):
        # The configuration refuses a budget larger than the target count, so
        # "as many attempts as there are targets" is the useful default and the
        # tests that care about the bound state it themselves.
        if max_attempts is None:
            max_attempts = len(targets)
        self.targets = targets
        base = provider_config(targets[0].mock.base_url)

        def configure(document):
            base(document)
            first = document["providers"][0]
            first["id"] = targets[0].name
            first["health"]["failure_threshold"] = failure_threshold
            document["routes"][0]["targets"] = [
                {
                    "provider_id": targets[0].name,
                    "upstream_model": "m0",
                    "priority": 10,
                    "weight": 1,
                }
            ]
            for index, target in enumerate(targets[1:], start=1):
                provider = copy.deepcopy(first)
                provider["id"] = target.name
                provider["display_name"] = target.name
                provider["base_url"] = target.mock.base_url
                document["providers"].append(provider)
                document["routes"][0]["targets"].append(
                    {
                        "provider_id": target.name,
                        "upstream_model": f"m{index}",
                        "priority": 10 + index,
                        "weight": 1,
                    }
                )
            document["routes"][0]["fallback"] = {
                "enabled": enabled,
                "max_attempts": max_attempts,
                "retryable": (
                    ["connect_failed", "dns_failed", "connect_timeout",
                     "http_502", "http_503", "http_504"]
                    if retryable is None
                    else retryable
                ),
            }

        self.gateway = Gateway(mutate=configure)

    def post(self, payload=None):
        return self.gateway.post_json(
            "/v1/chat/completions", payload or chat_request()
        )

    def close(self) -> None:
        try:
            self.gateway.close()
        finally:
            for target in self.targets:
                target.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def targets(*handlers):
    return [Target(f"p{i}", handler) for i, handler in enumerate(handlers)]


class FallbackHappensTests(unittest.TestCase):
    """M7 DoD 5: on a pre-commit retryable failure, and only then."""

    def test_a_failing_target_falls_back_to_the_next(self) -> None:
        made = targets(http_503, succeed)
        with FallbackFixture(made) as fixture:
            response = fixture.post()
            self.assertEqual(200, response.status)
            self.assertEqual(OK_BODY, response.json())
            self.assertEqual(1, made[0].attempts, "the first target was not tried")
            self.assertEqual(1, made[1].attempts, "the second target was not tried")

    def test_a_failure_class_the_route_does_not_name_is_not_retried(self) -> None:
        made = targets(http_503, succeed)
        with FallbackFixture(made, retryable=["connect_failed"]) as fixture:
            response = fixture.post()
            # 503 from the provider is relayed, because the body is JSON.
            self.assertEqual(503, response.status)
            self.assertEqual(1, made[0].attempts)
            self.assertEqual(0, made[1].attempts, "an unnamed class was retried")

    def test_fallback_disabled_means_one_attempt(self) -> None:
        made = targets(http_503, succeed)
        with FallbackFixture(made, max_attempts=1, enabled=False) as fixture:
            fixture.post()
            self.assertEqual(1, made[0].attempts)
            self.assertEqual(0, made[1].attempts)

    def test_an_invalid_request_is_never_retried(self) -> None:
        """A body the gateway itself refused never reaches a provider at all."""
        made = targets(succeed, succeed)
        with FallbackFixture(made) as fixture:
            response = fixture.post("{not json")
            self.assertEqual(400, response.status)
            self.assertEqual(0, made[0].attempts)
            self.assertEqual(0, made[1].attempts)


class AttemptBudgetTests(unittest.TestCase):
    """M7 DoD 7: bounded by max_attempts and by what has been tried."""

    def test_attempts_stop_at_max_attempts(self) -> None:
        made = targets(http_503, http_503, http_503, succeed)
        with FallbackFixture(made, max_attempts=2) as fixture:
            response = fixture.post()
            self.assertEqual(503, response.status)
            attempted = [target.attempts for target in made]
            self.assertEqual([1, 1, 0, 0], attempted, f"attempts were {attempted}")

    def test_one_attempt_means_one_attempt(self) -> None:
        made = targets(http_503, succeed)
        with FallbackFixture(made, max_attempts=1) as fixture:
            fixture.post()
            self.assertEqual([1, 0], [target.attempts for target in made])

    def test_no_target_is_tried_twice(self) -> None:
        """Every attempt goes somewhere new.

        The configuration already refuses a budget larger than the target
        count, so a loop that revisited a target could not exceed the budget —
        it would just send every attempt to the same broken provider while
        looking entirely correct from the outside. What is asserted is that
        each target was tried exactly once.
        """
        made = targets(http_503, http_503, http_503)
        with FallbackFixture(made, max_attempts=3) as fixture:
            response = fixture.post()
            self.assertEqual(503, response.status)
            self.assertEqual([1, 1, 1], [target.attempts for target in made])

    def test_every_target_is_tried_before_giving_up(self) -> None:
        made = targets(http_503, http_503, succeed)
        with FallbackFixture(made, max_attempts=3) as fixture:
            response = fixture.post()
            self.assertEqual(200, response.status)
            self.assertEqual([1, 1, 1], [target.attempts for target in made])


class CommitBarrierTests(unittest.TestCase):
    """M7 DoD 6: zero fallback attempts once a byte has reached the client.

    These assert the property, not the mechanism, and the difference matters.
    Every failure class reachable *after* a response head has gone out is a
    transport failure, and none of those is retryable — so a build with the
    barrier deleted passes this class unchanged. That was measured, by deleting
    it.

    The barrier itself is asserted in `tests/asm/test_provider.asm`, against an
    exchange built to be the case that cannot arise here: committed, and
    failing with a class the route does name as retryable.
    """

    def stream(self, fixture):
        body = chat_request(stream=True).encode()
        return fixture.gateway.send_raw(
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

    def test_a_committed_stream_is_never_retried(self) -> None:
        made = targets(stream_then_die, succeed)
        with FallbackFixture(made, max_attempts=2) as fixture:
            raw = self.stream(fixture)
            self.assertIn(b"text/event-stream", raw)
            self.assertIn(b"partial", raw)
            self.assertEqual(1, made[0].attempts)
            self.assertEqual(
                0,
                made[1].attempts,
                "a second target was tried after the response had begun",
            )

    def test_a_committed_stream_produces_exactly_one_response(self) -> None:
        """The failure mode a late fallback would produce, asserted directly."""
        made = targets(stream_then_die, succeed)
        with FallbackFixture(made, max_attempts=2) as fixture:
            raw = self.stream(fixture)
            self.assertEqual(
                1,
                raw.count(b"HTTP/1.1 "),
                f"more than one response on one connection: {raw[:400]!r}",
            )

    def test_an_uncommitted_failure_of_the_same_shape_does_fall_back(self) -> None:
        """The control: the same provider failure, without a stream.

        Without this, `test_a_committed_stream_is_never_retried` would pass
        just as well against a build that had no fallback at all.
        """
        made = targets(http_503, succeed)
        with FallbackFixture(made, max_attempts=2) as fixture:
            response = fixture.post()
            self.assertEqual(200, response.status)
            self.assertEqual(1, made[1].attempts)


if __name__ == "__main__":
    unittest.main()
