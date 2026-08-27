"""The circuit breaker, observed from outside (HARNESS.md M7 DoD 4).

`tests/asm/test_routing.asm` drives the state machine directly with a clock it
controls, which is the only way to assert a transition at the exact nanosecond
of a cooldown. What is left for here is the property that matters to an
operator: that the machine those unit tests describe is the one a running
daemon actually runs, reached by real requests against a real provider.

So this is a golden timeline. A provider fails, the circuit degrades and then
opens, traffic stops reaching it, the cooldown passes, one probe is admitted,
and the outcome of that probe decides what happens next. Each step is asserted
against the state the daemon reports for itself through `providers.list`.
"""
from __future__ import annotations

import threading
import time
import unittest

from tests.mock_provider import json_handler
from tests.provider_harness import ProviderGateway, chat_request

OK_BODY = {"id": "ok", "object": "chat.completion", "choices": []}


class Switchable:
    """A provider that fails or succeeds on command."""

    def __init__(self, failing: bool = True) -> None:
        self.failing = failing
        self.attempts = 0
        self.lock = threading.Lock()

    def handler(self, request, writer):
        with self.lock:
            self.attempts += 1
            failing = self.failing
        if failing:
            # A response that starts and stops: a transport failure rather than
            # an HTTP error, so it is the provider that looks broken and not
            # the request.
            writer.head(200, {"Content-Type": "application/json", "Content-Length": "64"})
            writer.raw(b"{")
            try:
                writer.conn.close()
            except OSError:
                pass
            return
        writer.json_response(OK_BODY)


class CircuitTimelineTests(unittest.TestCase):
    def health(self, fixture, provider_id: str = "mock-provider") -> dict:
        with fixture.gateway.daemon.connect() as client:
            for entry in client.call("providers.list"):
                if entry["id"] == provider_id:
                    return entry
        raise AssertionError(f"{provider_id} is not in providers.list")

    def breaker_config(self, *, failures=3, successes=2, cooldown_ms=1000):
        def mutate(document):
            document["providers"][0]["health"] = {
                "path": "/models",
                "interval_ms": 10000,
                "failure_threshold": failures,
                "success_threshold": successes,
                "open_cooldown_ms": cooldown_ms,
            }

        return mutate

    def test_a_provider_that_has_done_nothing_is_healthy(self) -> None:
        provider = Switchable(failing=False)
        with ProviderGateway(provider.handler, mutate=self.breaker_config()) as fixture:
            state = self.health(fixture)
            self.assertEqual("healthy", state["health"])
            self.assertEqual(0, state["active_requests"])
            self.assertEqual(0, state["observed_latency_us"])
            self.assertEqual(0, state["circuit_opened_count"])

    def test_the_golden_timeline(self) -> None:
        provider = Switchable(failing=True)
        with ProviderGateway(
            provider.handler, mutate=self.breaker_config(failures=3, cooldown_ms=1000)
        ) as fixture:
            # --- one failure: degraded, and still receiving traffic ---------
            fixture.post_json("/v1/chat/completions", chat_request())
            state = self.health(fixture)
            self.assertEqual("degraded", state["health"])
            self.assertEqual(1, state["consecutive_failures"])

            # --- the second: still degraded ---------------------------------
            fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual("degraded", self.health(fixture)["health"])

            # --- the third: the threshold, and the circuit opens ------------
            fixture.post_json("/v1/chat/completions", chat_request())
            state = self.health(fixture)
            self.assertEqual("open", state["health"])
            self.assertEqual(1, state["circuit_opened_count"])

            # --- while open, nothing reaches the provider -------------------
            reached_before = provider.attempts
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(503, response.status)
            self.assertEqual(
                "no_eligible_target", response.json()["error"]["code"]
            )
            self.assertEqual(
                reached_before,
                provider.attempts,
                "an open circuit still sent a request upstream",
            )

            # --- the cooldown passes: one probe is admitted -----------------
            time.sleep(1.2)
            self.assertEqual("half_open", self.health(fixture)["health"])

            provider.failing = False
            fixture.post_json("/v1/chat/completions", chat_request())
            # success_threshold is 2, so one probe is not enough.
            self.assertEqual("half_open", self.health(fixture)["health"])

            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(200, response.status)
            state = self.health(fixture)
            self.assertEqual("healthy", state["health"])
            self.assertEqual(0, state["consecutive_failures"])
            self.assertGreater(
                state["observed_latency_us"], 0, "a success was never measured"
            )

    def test_a_failed_probe_reopens_the_circuit(self) -> None:
        provider = Switchable(failing=True)
        with ProviderGateway(
            provider.handler, mutate=self.breaker_config(failures=1, cooldown_ms=1000)
        ) as fixture:
            fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual("open", self.health(fixture)["health"])

            time.sleep(1.2)
            self.assertEqual("half_open", self.health(fixture)["health"])

            # The probe goes out and fails.
            before = provider.attempts
            fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(before + 1, provider.attempts, "no probe was sent")
            state = self.health(fixture)
            self.assertEqual("open", state["health"])
            self.assertEqual(2, state["circuit_opened_count"])

            # And the second cooldown is longer than the first, so a provider
            # that stays down is probed less and less rather than at a fixed
            # rate. One cooldown's worth of waiting is no longer enough.
            time.sleep(1.2)
            self.assertEqual(
                "open",
                self.health(fixture)["health"],
                "the cooldown did not grow after a failed probe",
            )

    def test_a_success_before_the_threshold_clears_the_run(self) -> None:
        provider = Switchable(failing=True)
        with ProviderGateway(
            provider.handler, mutate=self.breaker_config(failures=3, successes=1)
        ) as fixture:
            fixture.post_json("/v1/chat/completions", chat_request())
            fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(2, self.health(fixture)["consecutive_failures"])

            provider.failing = False
            fixture.post_json("/v1/chat/completions", chat_request())
            state = self.health(fixture)
            self.assertEqual("healthy", state["health"])
            self.assertEqual(0, state["consecutive_failures"])

            # Two more failures therefore do not open it: the run restarted.
            provider.failing = True
            fixture.post_json("/v1/chat/completions", chat_request())
            fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual("degraded", self.health(fixture)["health"])
            self.assertEqual(0, self.health(fixture)["circuit_opened_count"])

    def test_an_open_circuit_does_not_stop_a_second_provider(self) -> None:
        """A breaker is per provider. One being down is not an outage."""
        failing = Switchable(failing=True)
        healthy = Switchable(failing=False)

        from tests.http_harness import Gateway
        from tests.mock_provider import MockProvider
        from tests.provider_harness import provider_config

        second = MockProvider(healthy.handler)
        try:
            base = provider_config("http://127.0.0.1:1/v1")

            def configure(document):
                base(document)
                first = document["providers"][0]
                first["health"] = {
                    "path": "/models",
                    "interval_ms": 10000,
                    "failure_threshold": 1,
                    "success_threshold": 1,
                    "open_cooldown_ms": 60000,
                }
                import copy

                other = copy.deepcopy(first)
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

            with Gateway(mutate=configure) as gateway:
                # The first target is unreachable, so its circuit opens.
                first = gateway.post_json("/v1/chat/completions", chat_request())
                self.assertEqual(502, first.status)

                # The next request skips it and reaches the second, which is
                # lower priority and therefore only chosen because the first
                # is out.
                second_response = gateway.post_json(
                    "/v1/chat/completions", chat_request()
                )
                self.assertEqual(200, second_response.status)
                self.assertEqual(OK_BODY, second_response.json())
                self.assertGreater(healthy.attempts, 0)
        finally:
            second.close()


if __name__ == "__main__":
    unittest.main()
