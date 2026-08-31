"""Deterministic bounded M11 parser/framer fuzz smoke.

This is intentionally a smoke campaign, not a replacement for a coverage-guided
fuzzer.  Every case is run in a fresh native test process so a signal, timeout,
or the assembly runner's allocation-leak verdict is attributable to one seed.
The native wrapper receives hex rather than text, preserving NUL and malformed
UTF-8 without teaching Python any parser policy.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import random
import resource
import subprocess
import unittest
from pathlib import Path

from tests import config_corpus


ROOT = Path(__file__).resolve().parents[1]
SEED_MANIFEST = ROOT / "tests" / "fixtures" / "fuzz" / "seeds.json"
FUZZ_SEED = int(os.environ.get("ASMFLOW_FUZZ_SEED", "679696"), 0)
CASES_PER_TARGET = int(os.environ.get("ASMFLOW_FUZZ_CASES", "18"), 0)
CASE_TIMEOUT_SECONDS = float(os.environ.get("ASMFLOW_FUZZ_TIMEOUT", "4.0"))
MAX_INPUT_BYTES = 8192
MAX_CAPTURE_BYTES = 128 * 1024
MAX_ADDRESS_SPACE = 384 * 1024 * 1024
TARGETS = (
    "json",
    "config",
    "http",
    "url",
    "sse",
    "mcp",
    "control",
    "redaction",
)


def _test_binary() -> Path:
    build_dir = Path(os.environ.get("BUILD_DIR", ROOT / "build"))
    return build_dir / "debug" / "asmflow-tests"


def _manifest() -> dict[str, list[dict[str, str]]]:
    return json.loads(SEED_MANIFEST.read_text(encoding="utf-8"))


def _entry_bytes(entry: dict[str, str]) -> bytes:
    if "utf8" in entry:
        return entry["utf8"].encode("utf-8")
    if "hex" in entry:
        return bytes.fromhex(entry["hex"])
    raise AssertionError(f"fuzz seed {entry!r} has neither utf8 nor hex data")


def _target_seeds(target: str) -> list[tuple[str, bytes]]:
    entries = [
        (entry["name"], _entry_bytes(entry)) for entry in _manifest()[target]
    ]
    if target == "config":
        valid = json.dumps(
            config_corpus.base_document(),
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        entries.insert(0, ("valid-minimal-config", valid))
    return entries


def _cases(target: str) -> list[tuple[str, bytes]]:
    """Return a stable, de-duplicated prefix of the deterministic campaign."""
    seeds = _target_seeds(target)
    rng = random.Random(FUZZ_SEED + sum((i + 1) * ord(c) for i, c in enumerate(target)))
    candidates: list[tuple[str, bytes]] = [("empty", b"")]
    candidates.extend((f"seed/{name}", value) for name, value in seeds)

    interesting = (b"\x00", b"\xff", b"\r", b"\n", b"{}[]:\\\"", b"A" * 257)
    for name, seed in seeds:
        if seed:
            candidates.append((f"truncate-half/{name}", seed[: len(seed) // 2]))
            candidates.append((f"truncate-last/{name}", seed[:-1]))
            at = rng.randrange(len(seed))
            flipped = bytearray(seed)
            flipped[at] ^= 1 << rng.randrange(8)
            candidates.append((f"bitflip-{at}/{name}", bytes(flipped)))
        token = interesting[rng.randrange(len(interesting))]
        at = rng.randrange(len(seed) + 1)
        candidates.append((f"insert-{len(token)}-{at}/{name}", seed[:at] + token + seed[at:]))

    for length in (1, 7, 31, 127, 511, 1023):
        candidates.append(
            (f"random-{length}", bytes(rng.randrange(256) for _ in range(length)))
        )

    unique: list[tuple[str, bytes]] = []
    seen: set[bytes] = set()
    for name, value in candidates:
        value = value[:MAX_INPUT_BYTES]
        if value in seen:
            continue
        seen.add(value)
        unique.append((name, value))
        if len(unique) >= CASES_PER_TARGET:
            break
    return unique


def _limit_child() -> None:
    cpu_seconds = max(1, int(math.ceil(CASE_TIMEOUT_SECONDS)))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CPU, (cpu_seconds, cpu_seconds))
    resource.setrlimit(
        resource.RLIMIT_AS, (MAX_ADDRESS_SPACE, MAX_ADDRESS_SPACE)
    )


class FuzzFixtureContractTests(unittest.TestCase):
    def test_seed_manifest_is_complete_and_bounded(self) -> None:
        manifest = _manifest()
        self.assertEqual(set(TARGETS), set(manifest))
        for target in TARGETS:
            self.assertTrue(manifest[target], f"{target} has no committed seed")
            names: set[str] = set()
            for entry in manifest[target]:
                self.assertNotIn(entry["name"], names)
                names.add(entry["name"])
                self.assertLessEqual(len(_entry_bytes(entry)), MAX_INPUT_BYTES)

    def test_fixed_seed_generation_is_reproducible(self) -> None:
        first = {target: _cases(target) for target in TARGETS}
        second = {target: _cases(target) for target in TARGETS}
        self.assertEqual(first, second)
        for target, cases in first.items():
            self.assertTrue(cases, f"{target} generated no cases")
            self.assertLessEqual(len(cases), CASES_PER_TARGET)


class FuzzSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not _test_binary().is_file():
            raise unittest.SkipTest(
                f"{_test_binary()} is not built; run `make build-tests` first"
            )

    def test_native_parser_and_framer_campaign(self) -> None:
        for target in TARGETS:
            for case_name, payload in _cases(target):
                with self.subTest(target=target, case=case_name):
                    self._run_case(target, case_name, payload)

    def _run_case(self, target: str, case_name: str, payload: bytes) -> None:
        self.assertLessEqual(len(payload), MAX_INPUT_BYTES)
        environment = os.environ.copy()
        environment.update(
            {
                "ASMFLOW_FUZZ_HEX": payload.hex(),
                "ASMFLOW_FUZZ_SEED": str(FUZZ_SEED),
                "ASMFLOW_FUZZ_TARGET": target,
                "PYTHONHASHSEED": "0",
            }
        )
        command = [
            str(_test_binary()),
            "--filter",
            f"m11/fuzz/{target}/input",
            "--verbose",
        ]
        try:
            completed = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                timeout=CASE_TIMEOUT_SECONDS,
                check=False,
                preexec_fn=_limit_child if os.name == "posix" else None,
            )
        except subprocess.TimeoutExpired as error:
            self.fail(self._failure(target, case_name, payload, f"timeout: {error}"))

        captured = len(completed.stdout) + len(completed.stderr)
        self.assertLessEqual(
            captured,
            MAX_CAPTURE_BYTES,
            self._failure(target, case_name, payload, f"output bytes={captured}"),
        )
        if completed.returncode != 0:
            detail = (
                f"returncode={completed.returncode}\n"
                f"stdout={completed.stdout[-4096:].decode('utf-8', 'replace')}\n"
                f"stderr={completed.stderr[-4096:].decode('utf-8', 'replace')}"
            )
            self.fail(self._failure(target, case_name, payload, detail))

    @staticmethod
    def _failure(target: str, case_name: str, payload: bytes, detail: str) -> str:
        digest = hashlib.sha256(payload).hexdigest()
        prefix = payload[:128].hex()
        return (
            f"native fuzz-smoke failure target={target} case={case_name} "
            f"seed={FUZZ_SEED} len={len(payload)} sha256={digest} "
            f"hex_prefix={prefix}\n{detail}"
        )


if __name__ == "__main__":
    unittest.main()
