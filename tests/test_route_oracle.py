from __future__ import annotations

import unittest

from route_oracle import (
    Candidate,
    eligible_candidates,
    fallback_allowed,
    select_least_latency,
    select_priority,
    select_round_robin,
)


class RouteOracleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.candidates = [
            Candidate(
                provider_id="b",
                configured_index=1,
                priority=10,
                max_concurrency=2,
                latency_us=9000,
                endpoint_families=frozenset({"responses", "chat_completions"}),
                capabilities=frozenset({"streaming", "tools"}),
            ),
            Candidate(
                provider_id="a",
                configured_index=0,
                priority=10,
                max_concurrency=2,
                latency_us=12000,
                endpoint_families=frozenset({"responses", "chat_completions"}),
                capabilities=frozenset({"streaming", "tools", "vision"}),
            ),
            Candidate(
                provider_id="disabled",
                configured_index=2,
                priority=0,
                state="disabled",
                max_concurrency=1,
                endpoint_families=frozenset({"responses"}),
            ),
        ]

    def test_filter_preserves_configured_order(self) -> None:
        result = eligible_candidates(
            self.candidates,
            endpoint_family="responses",
            required_capabilities=frozenset({"streaming"}),
        )
        self.assertEqual(["b", "a"], [candidate.provider_id for candidate in result])

    def test_capability_filter(self) -> None:
        result = eligible_candidates(
            self.candidates,
            endpoint_family="responses",
            required_capabilities=frozenset({"vision"}),
        )
        self.assertEqual(["a"], [candidate.provider_id for candidate in result])

    def test_priority_uses_configured_index_for_tie(self) -> None:
        self.assertEqual("a", select_priority(self.candidates[:2]).provider_id)

    def test_round_robin_is_stable(self) -> None:
        eligible = self.candidates[:2]
        sequence = [select_round_robin(eligible, cursor).provider_id for cursor in range(5)]
        self.assertEqual(["a", "b", "a", "b", "a"], sequence)

    def test_least_latency(self) -> None:
        self.assertEqual("b", select_least_latency(self.candidates[:2]).provider_id)

    def test_half_open_ranks_after_healthy(self) -> None:
        candidates = [
            Candidate("probe", 0, state="half_open", latency_us=1, max_concurrency=1),
            Candidate("healthy", 1, state="healthy", latency_us=100, max_concurrency=1),
        ]
        self.assertEqual("healthy", select_least_latency(candidates).provider_id)

    def test_fallback_allowed_before_commit(self) -> None:
        self.assertTrue(
            fallback_allowed(
                committed=False,
                cancelled=False,
                fallback_enabled=True,
                attempt_no=1,
                max_attempts=2,
                error_class="connect_timeout",
                next_candidate_exists=True,
            )
        )

    def test_fallback_forbidden_after_commit(self) -> None:
        self.assertFalse(
            fallback_allowed(
                committed=True,
                cancelled=False,
                fallback_enabled=True,
                attempt_no=1,
                max_attempts=2,
                error_class="http_503",
                next_candidate_exists=True,
            )
        )


if __name__ == "__main__":
    unittest.main()
