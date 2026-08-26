"""Assembly and reference validators must agree on every corpus document.

HARNESS.md M3 DoD 8: zero accept/reject disagreements between the contract and
the runtime. The corpus in tests/config_corpus.py carries, for each document,
the outcome the schema demands; this test drives the same documents through
`asmflowd --check-config` and compares three ways:

  reference vs expectation   catches a corpus entry whose stated outcome is
                             wrong, or a bug in the reference validator
  assembly  vs expectation   the actual gate
  assembly  vs reference     names the disagreement when the two differ

Running all three means a failure says which of the three descriptions of the
contract is out of step, instead of only that something is.
"""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from tests import config_corpus

ROOT = Path(__file__).resolve().parents[1]


def daemon_path() -> Path:
    build_dir = Path(os.environ.get("BUILD_DIR", ROOT / "build"))
    return build_dir / "debug" / "asmflowd"


class ConfigParityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.daemon = daemon_path()
        if not cls.daemon.is_file():
            raise unittest.SkipTest(
                f"{cls.daemon} is not built; run `make build-debug` first"
            )
        cls.cases = config_corpus.corpus()

    def run_assembly(self, document, env: dict[str, str]) -> tuple[bool, str]:
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / "asmflow.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            # A minimal environment plus whatever the case declares: inheriting
            # the caller's environment would let a stray OPENAI_API_KEY make a
            # missing-secret case pass on one machine and fail on another.
            child_env = {
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": work,
                "XDG_CONFIG_HOME": f"{work}/config",
                "XDG_STATE_HOME": f"{work}/state",
                "XDG_RUNTIME_DIR": f"{work}/run",
            }
            child_env.update(env)
            result = subprocess.run(
                [str(self.daemon), "--check-config", "--config", str(path)],
                capture_output=True,
                text=True,
                timeout=60,
                env=child_env,
            )
        if result.returncode == 0:
            return True, ""
        return False, (result.stdout + result.stderr).strip()

    def test_corpus_is_not_trivially_one_sided(self) -> None:
        accepted = sum(1 for case in self.cases if case.accepted)
        rejected = len(self.cases) - accepted
        self.assertGreaterEqual(accepted, 10, "the corpus needs accepting cases")
        self.assertGreaterEqual(rejected, 30, "the corpus needs rejecting cases")

    def test_reference_validator_matches_expectations(self) -> None:
        mismatches = []
        for case in self.cases:
            got, why = config_corpus.accepts(case.document)
            if got != case.accepted:
                mismatches.append(
                    f"{case.name}: expected "
                    f"{'accept' if case.accepted else 'reject'} ({case.reason}), "
                    f"reference said {'accept' if got else 'reject'}"
                    + (f" [{why}]" if why else "")
                )
        self.assertEqual([], mismatches, "\n".join(mismatches))

    def test_assembly_matches_expectations(self) -> None:
        mismatches = []
        for case in self.cases:
            got, output = self.run_assembly(case.document, case.env)
            if got != case.accepted:
                mismatches.append(
                    f"{case.name}: expected "
                    f"{'accept' if case.accepted else 'reject'} ({case.reason}), "
                    f"assembly said {'accept' if got else 'reject'}\n"
                    f"    {output}"
                )
        self.assertEqual([], mismatches, "\n".join(mismatches))

    def test_assembly_matches_the_reference(self) -> None:
        mismatches = []
        for case in self.cases:
            reference, _ = config_corpus.accepts(case.document)
            assembly, output = self.run_assembly(case.document, case.env)
            if reference != assembly:
                mismatches.append(
                    f"{case.name}: reference "
                    f"{'accept' if reference else 'reject'} vs assembly "
                    f"{'accept' if assembly else 'reject'}\n    {output}"
                )
        self.assertEqual([], mismatches, "\n".join(mismatches))

    def test_rejections_name_a_location_and_a_rule(self) -> None:
        """A rejection that says only 'invalid' is not actionable."""
        missing = []
        for case in self.cases:
            if case.accepted:
                continue
            _, output = self.run_assembly(case.document, case.env)
            if "  at: " not in output or "  rule: " not in output:
                missing.append(f"{case.name}: {output}")
        self.assertEqual([], missing, "\n".join(missing))

    def test_rejection_output_carries_no_configuration_values(self) -> None:
        """Diagnostics name rules and locations, never values.

        A rejection is logged before the file's own redaction policy is
        available, so it must not echo anything the operator put in the file.
        """
        marker = "sentinel-value-must-not-appear"
        document = config_corpus.base_document()
        document["providers"][0]["display_name"] = marker
        document["providers"][0]["max_concurrency"] = 0  # forces a rejection
        accepted, output = self.run_assembly(document, {})
        self.assertFalse(accepted)
        self.assertNotIn(marker, output)


if __name__ == "__main__":
    unittest.main()
