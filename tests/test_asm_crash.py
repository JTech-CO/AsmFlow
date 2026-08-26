"""Scenarios that are supposed to end the process.

Some invariants are enforced by refusing to continue: allocating from a
finalized arena, dereferencing a pointer that outlived one, freeing a block
twice, freeing something that never came from the allocator. None of those can
be asserted from inside the test binary they kill, so each one runs as a child
process here and the signal is the assertion.

A scenario that exits normally is a failure. It means the guard is gone and the
next real defect of that shape will corrupt memory quietly instead.
"""
from __future__ import annotations

import os
import signal
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# SIGILL comes from the `ud2` at the end of af_panic; SIGSEGV comes from the
# revoked guard-mode mapping. Either proves the process refused to continue.
FATAL_SIGNALS = {signal.SIGILL, signal.SIGSEGV, signal.SIGABRT, signal.SIGBUS}


def test_binary() -> Path:
    build_dir = Path(os.environ.get("BUILD_DIR", ROOT / "build"))
    return build_dir / "debug" / "asmflow-tests"


class CrashScenarioTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = test_binary()
        if not cls.binary.is_file():
            raise unittest.SkipTest(
                f"{cls.binary} is not built; run `make build-tests` first"
            )

    def run_scenario(self, scenario: int) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(self.binary), "--crash", str(scenario)],
            capture_output=True,
            text=True,
            timeout=60,
        )

    def assert_died(self, scenario: int, description: str) -> None:
        result = self.run_scenario(scenario)
        self.assertLess(
            result.returncode,
            0,
            msg=(
                f"{description}: expected the process to be killed by a signal, "
                f"but it exited with {result.returncode}. "
                f"stderr={result.stderr!r}"
            ),
        )
        received = signal.Signals(-result.returncode)
        self.assertIn(
            received,
            FATAL_SIGNALS,
            msg=f"{description}: died from unexpected signal {received.name}",
        )

    def test_arena_allocation_after_finalize_is_fatal(self) -> None:
        self.assert_died(1, "allocating from a finalized arena")

    def test_arena_read_after_finalize_faults_under_guard_mode(self) -> None:
        self.assert_died(2, "dereferencing a pointer that outlived its arena")

    def test_double_free_is_fatal(self) -> None:
        self.assert_died(3, "freeing the same block twice")

    def test_freeing_a_foreign_pointer_is_fatal(self) -> None:
        self.assert_died(4, "freeing a pointer the allocator never produced")

    def test_unknown_scenario_reports_an_error_instead_of_crashing(self) -> None:
        result = self.run_scenario(99)
        self.assertEqual(21, result.returncode)


if __name__ == "__main__":
    unittest.main()
