"""HTTP era/error classification matrix (HARNESS.md M9)."""
from __future__ import annotations

import time
import unittest

from tests.mcp_http_harness import (
    http_configuration,
    http_server,
    wait_for_http_server,
    wait_for_method,
)
from tests.mock_mcp_http import MockMcpHttp
from tests.test_mcp_process_supervision import StartupDaemonUnderTest


class McpHttpVersionMatrixTests(unittest.TestCase):
    def assert_modern_evidence_never_initializes_legacy(self, mode: str) -> None:
        with MockMcpHttp(mode=mode) as mock, StartupDaemonUnderTest(
            mutate=http_configuration(http_server(mock.endpoint))
        ) as daemon, daemon.connect() as client:
            wait_for_method(mock, "server/discover")
            time.sleep(0.5)
            self.assertNotIn(
                "initialize",
                mock.methods(),
                f"{mode} is modern evidence, not a legacy fallback signal",
            )

    def test_recognized_modern_errors_do_not_fall_back(self) -> None:
        for mode in ("unsupported", "header-mismatch", "method-not-found"):
            with self.subTest(mode=mode):
                self.assert_modern_evidence_never_initializes_legacy(mode)

    def test_transient_http_failure_does_not_select_an_era(self) -> None:
        with MockMcpHttp(mode="transient") as mock, StartupDaemonUnderTest(
            mutate=http_configuration(http_server(mock.endpoint))
        ) as daemon, daemon.connect() as client:
            wait_for_method(mock, "server/discover")
            failed = wait_for_http_server(
                client,
                lambda value: value["state"] in {"failed", "degraded"},
            )
            time.sleep(0.2)
            self.assertNotIn("initialize", mock.methods())
            self.assertEqual("unknown", failed["era"])
            self.assertIsNone(failed["protocol_version"])

    def test_unrecognized_bare_400_is_the_legacy_fallback_signal(self) -> None:
        with MockMcpHttp(mode="legacy") as mock, StartupDaemonUnderTest(
            mutate=http_configuration(http_server(mock.endpoint))
        ) as daemon, daemon.connect() as client:
            wait_for_method(mock, "initialize")
            ready = wait_for_http_server(
                client,
                lambda value: value["state"] == "ready"
                and value["tool_count"] == 1,
            )
            self.assertEqual("legacy_2025", ready["era"])
            self.assertEqual("2025-11-25", ready["protocol_version"])
            self.assertEqual("server/discover", mock.methods()[0])


if __name__ == "__main__":
    unittest.main()
