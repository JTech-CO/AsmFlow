"""The selector against the oracle, over the whole corpus (HARNESS.md M7 DoD 1-3).

A routing defect does not announce itself. The request still gets an answer,
the answer still looks right, and the only trace is that traffic went somewhere
the operator did not intend. There is nothing to assert about a single
selection that would catch it — so what is asserted instead is agreement with
an independent statement of the rules.

`tests/route_oracle.py` is that statement, written in Python and never linked
into the product. This module generates scenarios, runs both implementations
over each, and fails on any disagreement in either the candidate set or the
selection.

Two rules are stated here rather than in the oracle, and it is worth being
explicit about which:

  * whether a provider serves an endpoint family, which AsmFlow derives from
    its adapter and its capability bits; and
  * that an open circuit whose cooldown has elapsed is half-open.

The oracle takes both as given — its `Candidate` carries `endpoint_families`
and a `state` outright. Each is covered separately by the assembly unit tests
in `tests/asm/test_routing.asm`, so neither is unchecked; they are simply
checked somewhere other than here.
"""
from __future__ import annotations

import json
import os
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tests import route_oracle
from tests.route_oracle import Candidate

ROOT = Path(__file__).resolve().parents[1]

POLICIES = ("priority", "round_robin", "least_latency")
STATES = ("healthy", "degraded", "open", "half_open", "disabled")
ADAPTERS = ("openai_responses", "openai_chat", "openai_dual")
FAMILIES = ("responses", "chat_completions")
ALL_CAPABILITIES = (
    "responses",
    "chat_completions",
    "streaming",
    "tools",
    "vision",
    "json_schema",
)


def tests_binary() -> Path:
    build_dir = Path(os.environ.get("BUILD_DIR", ROOT / "build"))
    return build_dir / "debug" / "asmflow-tests"


def serves_family(adapter: str, capabilities: frozenset[str], family: str) -> bool:
    """AsmFlow's rule for whether a provider speaks an endpoint family.

    The capability bit says the provider supports the API; the adapter says
    which shape it speaks. `openai_dual` speaks both, and the other two speak
    one each — a provider advertising `responses` behind a chat adapter would
    be sent a body in the wrong shape.
    """
    if family not in capabilities:
        return False
    if adapter == "openai_dual":
        return True
    if family == "responses":
        return adapter == "openai_responses"
    return adapter == "openai_chat"


def effective_state(state: str, now_ns: int, open_until_ns: int) -> str:
    """The one state transition time makes on its own."""
    if state == "open" and now_ns >= open_until_ns:
        return "half_open"
    return state


def to_oracle(scenario: dict) -> list[Candidate]:
    family = scenario["endpoint_family"]
    now_ns = scenario["now_ns"]
    result = []
    for index, entry in enumerate(scenario["candidates"]):
        capabilities = frozenset(entry["capabilities"])
        adapter = entry["adapter"]
        families = frozenset(
            name for name in FAMILIES if serves_family(adapter, capabilities, name)
        )
        latency = entry["latency_us"]
        result.append(
            Candidate(
                provider_id=entry["provider_id"],
                configured_index=index,
                priority=entry["priority"],
                weight=entry["weight"],
                state=effective_state(entry["state"], now_ns, entry["open_until_ns"]),
                active=entry["active"],
                max_concurrency=entry["max_concurrency"],
                latency_us=None if latency == 0 else latency,
                endpoint_families=families,
                capabilities=capabilities,
                already_tried=entry["already_tried"],
                enabled=entry["enabled"],
            )
        )
    _ = family
    return result


def oracle_answer(scenario: dict) -> dict:
    candidates = to_oracle(scenario)
    eligible = route_oracle.eligible_candidates(
        candidates,
        endpoint_family=scenario["endpoint_family"],
        required_capabilities=frozenset(scenario["required_capabilities"]),
    )
    chosen = route_oracle.select(
        scenario["policy"], eligible, cursor=scenario["cursor"]
    )
    return {
        "candidates": [candidate.provider_id for candidate in eligible],
        "selected": chosen.provider_id if chosen is not None else None,
    }


def candidate(
    rng: random.Random, index: int, *, family: str, force: dict | None = None
) -> dict:
    capabilities = [name for name in ALL_CAPABILITIES if rng.random() < 0.6]
    # Half the time, guarantee the family bit so the corpus is not dominated by
    # candidates filtered out before anything interesting happens.
    if rng.random() < 0.5 and family not in capabilities:
        capabilities.append(family)
    entry = {
        "provider_id": f"p{index:02d}",
        "adapter": rng.choice(ADAPTERS),
        "capabilities": capabilities,
        "enabled": rng.random() < 0.85,
        "priority": rng.choice([-5, 0, 1, 1, 10, 10, 100]),
        "weight": rng.choice([1, 1, 2, 7]),
        "state": rng.choice(STATES),
        "active": rng.choice([0, 0, 1, 2, 4]),
        "max_concurrency": rng.choice([1, 2, 4, 16]),
        "latency_us": rng.choice([0, 0, 500, 1500, 1500, 90000]),
        "open_until_ns": rng.choice([0, 500, 1_000_000, 10_000_000_000]),
        "already_tried": rng.random() < 0.15,
        "upstream_model": f"m{index}",
        "failure_threshold": rng.choice([1, 2, 3]),
        "success_threshold": rng.choice([1, 2]),
        "open_cooldown_ms": rng.choice([1000, 5000]),
    }
    if force:
        entry.update(force)
    return entry


def build_corpus(seed: int = 20260827) -> list[dict]:
    rng = random.Random(seed)
    corpus: list[dict] = []

    # --- systematic: every policy against every candidate count -------------
    for policy in POLICIES:
        for count in range(0, 6):
            for family in FAMILIES:
                for cursor in (0, 1, 3, 7):
                    corpus.append(
                        {
                            "route_id": f"r{len(corpus)}",
                            "policy": policy,
                            "endpoint_family": family,
                            "required_capabilities": [],
                            "cursor": cursor,
                            "now_ns": 1_000_000_000,
                            "candidates": [
                                candidate(rng, i, family=family) for i in range(count)
                            ],
                        }
                    )

    # --- every state, on its own, so no combination hides one ---------------
    for policy in POLICIES:
        for state in STATES:
            for now_ns, open_until in ((0, 10_000_000_000), (10_000_000_000, 500)):
                corpus.append(
                    {
                        "route_id": f"r{len(corpus)}",
                        "policy": policy,
                        "endpoint_family": "chat_completions",
                        "required_capabilities": [],
                        "cursor": 0,
                        "now_ns": now_ns,
                        "candidates": [
                            candidate(
                                rng,
                                0,
                                family="chat_completions",
                                force={
                                    "state": state,
                                    "open_until_ns": open_until,
                                    "adapter": "openai_dual",
                                    "capabilities": list(ALL_CAPABILITIES),
                                    "enabled": True,
                                    "active": 0,
                                    "max_concurrency": 4,
                                    "already_tried": False,
                                },
                            )
                        ],
                    }
                )

    # --- ties, which is where a missing tie-break shows ---------------------
    for policy in POLICIES:
        for cursor in range(0, 5):
            corpus.append(
                {
                    "route_id": f"r{len(corpus)}",
                    "policy": policy,
                    "endpoint_family": "chat_completions",
                    "required_capabilities": [],
                    "cursor": cursor,
                    "now_ns": 1_000_000_000,
                    "candidates": [
                        candidate(
                            rng,
                            i,
                            family="chat_completions",
                            force={
                                "priority": 10,
                                "latency_us": 1500,
                                "state": "healthy",
                                "adapter": "openai_dual",
                                "capabilities": list(ALL_CAPABILITIES),
                                "enabled": True,
                                "active": 0,
                                "max_concurrency": 8,
                                "already_tried": False,
                            },
                        )
                        for i in range(4)
                    ],
                }
            )

    # --- concurrency exactly at, below, and above the ceiling ---------------
    for active, ceiling in ((0, 1), (1, 1), (2, 1), (3, 4), (4, 4), (5, 4)):
        corpus.append(
            {
                "route_id": f"r{len(corpus)}",
                "policy": "priority",
                "endpoint_family": "chat_completions",
                "required_capabilities": [],
                "cursor": 0,
                "now_ns": 1_000_000_000,
                "candidates": [
                    candidate(
                        rng,
                        0,
                        family="chat_completions",
                        force={
                            "active": active,
                            "max_concurrency": ceiling,
                            "state": "healthy",
                            "adapter": "openai_dual",
                            "capabilities": list(ALL_CAPABILITIES),
                            "enabled": True,
                            "already_tried": False,
                        },
                    )
                ],
            }
        )

    # --- required capabilities ----------------------------------------------
    for required in ([], ["tools"], ["vision"], ["tools", "vision"], ["json_schema"]):
        for held in ([], ["tools"], ["tools", "vision"], list(ALL_CAPABILITIES)):
            corpus.append(
                {
                    "route_id": f"r{len(corpus)}",
                    "policy": "priority",
                    "endpoint_family": "chat_completions",
                    "required_capabilities": required,
                    "cursor": 0,
                    "now_ns": 1_000_000_000,
                    "candidates": [
                        candidate(
                            rng,
                            0,
                            family="chat_completions",
                            force={
                                "capabilities": sorted(
                                    set(held) | {"chat_completions"}
                                ),
                                "adapter": "openai_dual",
                                "state": "healthy",
                                "enabled": True,
                                "active": 0,
                                "max_concurrency": 4,
                                "already_tried": False,
                            },
                        )
                    ],
                }
            )

    # --- a broad random sweep ------------------------------------------------
    for _ in range(1200):
        family = rng.choice(FAMILIES)
        count = rng.randint(0, 8)
        corpus.append(
            {
                "route_id": f"r{len(corpus)}",
                "policy": rng.choice(POLICIES),
                "endpoint_family": family,
                "required_capabilities": [
                    name for name in ("tools", "vision", "streaming") if rng.random() < 0.2
                ],
                "cursor": rng.randint(0, 40),
                "now_ns": rng.choice([0, 1_000_000_000, 10_000_000_000]),
                "candidates": [candidate(rng, i, family=family) for i in range(count)],
            }
        )

    return corpus


def run_selector(corpus: list[dict]) -> list[dict]:
    binary = tests_binary()
    with tempfile.NamedTemporaryFile(
        "w", suffix=".json", delete=False, encoding="utf-8"
    ) as handle:
        json.dump(corpus, handle)
        path = handle.name
    try:
        result = subprocess.run(
            [str(binary), "--routing-corpus", path],
            capture_output=True,
            text=True,
            check=False,
            timeout=300,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"the selector failed: {result.returncode}\n{result.stderr}"
            )
        return json.loads(result.stdout)
    finally:
        os.unlink(path)


class RoutingParityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not tests_binary().is_file():
            raise unittest.SkipTest(
                f"{tests_binary()} is not built; run `make build-tests` first"
            )
        cls.corpus = build_corpus()
        cls.actual = run_selector(cls.corpus)

    def test_the_corpus_is_large_enough_to_mean_something(self) -> None:
        self.assertGreater(len(self.corpus), 1000)
        self.assertEqual(len(self.corpus), len(self.actual))

    def test_the_corpus_reaches_every_policy_and_state(self) -> None:
        """A corpus that never produced a half-open candidate would pass
        trivially and prove nothing about half-open."""
        policies = {scenario["policy"] for scenario in self.corpus}
        self.assertEqual(set(POLICIES), policies)
        states = {
            entry["state"]
            for scenario in self.corpus
            for entry in scenario["candidates"]
        }
        self.assertEqual(set(STATES), states)

    def test_the_corpus_produces_selections_and_refusals(self) -> None:
        selected = sum(1 for row in self.actual if row["selected"] is not None)
        refused = sum(1 for row in self.actual if row["selected"] is None)
        self.assertGreater(selected, 100, "nothing was ever selected")
        self.assertGreater(refused, 20, "nothing was ever refused")

    def test_candidate_sets_agree_with_the_oracle(self) -> None:
        for index, (scenario, actual) in enumerate(zip(self.corpus, self.actual)):
            expected = oracle_answer(scenario)
            if expected["candidates"] != actual["candidates"]:
                self.fail(
                    f"case {index} ({scenario['policy']}): candidate sets differ\n"
                    f"  oracle:   {expected['candidates']}\n"
                    f"  asmflow:  {actual['candidates']}\n"
                    f"  scenario: {json.dumps(scenario, indent=2)}"
                )

    def test_selections_agree_with_the_oracle(self) -> None:
        for index, (scenario, actual) in enumerate(zip(self.corpus, self.actual)):
            expected = oracle_answer(scenario)
            if expected["selected"] != actual["selected"]:
                self.fail(
                    f"case {index} ({scenario['policy']}): selections differ\n"
                    f"  oracle:   {expected['selected']}\n"
                    f"  asmflow:  {actual['selected']}\n"
                    f"  scenario: {json.dumps(scenario, indent=2)}"
                )

    def test_the_same_input_gives_the_same_answer_a_hundred_times(self) -> None:
        """M7 DoD 2. Determinism is a property of the code, not of the run."""
        sample = self.corpus[:40]
        first = run_selector(sample)
        for _ in range(99):
            self.assertEqual(first, run_selector(sample))


if __name__ == "__main__":
    unittest.main()
