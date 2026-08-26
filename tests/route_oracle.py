"""Test-only routing oracle for AsmFlow.

This module defines expected decisions for parity tests. It must never become a runtime
dependency or be called by the product binaries.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Sequence

ELIGIBLE_STATES = {"healthy", "degraded", "half_open"}
RETRYABLE_ERRORS = {
    "connect_failed",
    "dns_failed",
    "connect_timeout",
    "http_502",
    "http_503",
    "http_504",
}


@dataclass(frozen=True)
class Candidate:
    provider_id: str
    configured_index: int
    priority: int = 0
    weight: int = 1
    state: str = "healthy"
    active: int = 0
    max_concurrency: int = 1
    latency_us: int | None = None
    endpoint_families: frozenset[str] = frozenset({"chat_completions"})
    capabilities: frozenset[str] = frozenset()
    already_tried: bool = False
    enabled: bool = True


def eligible_candidates(
    candidates: Iterable[Candidate],
    *,
    endpoint_family: str,
    required_capabilities: frozenset[str] = frozenset(),
) -> list[Candidate]:
    result: list[Candidate] = []
    for candidate in candidates:
        if not candidate.enabled or candidate.already_tried:
            continue
        if candidate.state not in ELIGIBLE_STATES:
            continue
        if candidate.active >= candidate.max_concurrency:
            continue
        if endpoint_family not in candidate.endpoint_families:
            continue
        if not required_capabilities.issubset(candidate.capabilities):
            continue
        result.append(candidate)
    return result


def select_priority(candidates: Sequence[Candidate]) -> Candidate | None:
    if not candidates:
        return None
    return min(candidates, key=lambda c: (c.priority, c.configured_index, c.provider_id))


def select_round_robin(candidates: Sequence[Candidate], cursor: int) -> Candidate | None:
    if not candidates:
        return None
    ordered = sorted(candidates, key=lambda c: (c.configured_index, c.provider_id))
    return ordered[cursor % len(ordered)]


def select_least_latency(candidates: Sequence[Candidate]) -> Candidate | None:
    if not candidates:
        return None

    def key(candidate: Candidate) -> tuple[int, int, int, int, str]:
        # Measured healthy/degraded targets rank first. Unknown latency ranks after
        # measured targets. Half-open targets are probes and rank last by default.
        half_open_rank = 1 if candidate.state == "half_open" else 0
        unknown_rank = 1 if candidate.latency_us is None else 0
        latency = candidate.latency_us if candidate.latency_us is not None else 2**63 - 1
        return (half_open_rank, unknown_rank, latency, candidate.configured_index, candidate.provider_id)

    return min(candidates, key=key)


def select(
    policy: str,
    candidates: Sequence[Candidate],
    *,
    cursor: int = 0,
) -> Candidate | None:
    if policy == "priority":
        return select_priority(candidates)
    if policy == "round_robin":
        return select_round_robin(candidates, cursor)
    if policy == "least_latency":
        return select_least_latency(candidates)
    raise ValueError(f"unknown policy: {policy}")


def fallback_allowed(
    *,
    committed: bool,
    cancelled: bool,
    fallback_enabled: bool,
    attempt_no: int,
    max_attempts: int,
    error_class: str,
    next_candidate_exists: bool,
) -> bool:
    return (
        not committed
        and not cancelled
        and fallback_enabled
        and attempt_no < max_attempts
        and error_class in RETRYABLE_ERRORS
        and next_candidate_exists
    )
