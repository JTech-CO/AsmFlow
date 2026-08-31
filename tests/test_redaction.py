"""M11 secret corpus and diagnostic-export non-disclosure tests."""
from __future__ import annotations

import json
import os
import signal
import subprocess
import unittest
from pathlib import Path

from tests.test_control_protocol import DaemonUnderTest


SECRETS = {
    "ASMFLOW_M11_GATEWAY_TOKEN": "m11-gateway-Z7x4-secret",
    "ASMFLOW_M11_PROVIDER_TOKEN": "m11-provider-Q9v2-secret",
    "ASMFLOW_M11_MCP_TOKEN": "m11-mcp-H3k8-secret",
}


def secret_configuration(document: dict) -> None:
    document["listener"]["auth"] = {
        "type": "header_env",
        "header": "X-AsmFlow-Private-Key",
        "value": {"source": "env", "name": "ASMFLOW_M11_GATEWAY_TOKEN"},
    }
    document["providers"][0]["auth"] = {
        "type": "bearer_env",
        "env": "ASMFLOW_M11_PROVIDER_TOKEN",
    }
    document["logging"]["redact_headers"] = [
        "X-Operator-Secret",
        "X-AsmFlow-Private-Key",
        "X-Mcp-Private-Key",
    ]
    document["mcp_servers"] = [
        {
            "id": "redaction-http",
            "display_name": "Redaction HTTP fixture",
            "transport": "streamable_http",
            "enabled": True,
            "required": False,
            "url": "http://127.0.0.1:9/mcp",
            "auth": {
                "type": "header_env",
                "header": "X-Mcp-Private-Key",
                "value": {"source": "env", "name": "ASMFLOW_M11_MCP_TOKEN"},
            },
            "protocol": {
                "preferred": "2026-07-28",
                "legacy": ["2025-11-25"],
            },
            "timeouts": {
                "connect_ms": 100,
                "request_ms": 1000,
                "idle_stream_ms": 1000,
            },
            "allow_insecure_private_http": False,
        }
    ]


class RedactionTests(unittest.TestCase):
    def _assert_corpus_absent(self, label: str, blob: bytes) -> None:
        for env_name, secret in SECRETS.items():
            with self.subTest(surface=label, secret=env_name):
                self.assertNotIn(secret.encode(), blob)

    def test_secret_corpus_is_absent_from_control_diagnostics_db_and_logs(self) -> None:
        daemon = DaemonUnderTest(mutate=secret_configuration, extra_env=SECRETS)
        try:
            with daemon.connect() as client:
                surfaces = {
                    "version": client.call("system.version"),
                    "snapshot": client.call("system.snapshot"),
                    "config": client.call("config.current"),
                    "providers": client.call("providers.list"),
                    "routes": client.call("routes.list"),
                    "mcp": client.call("mcp.list"),
                    "diagnostics": client.call("diagnostics.export", {}),
                }
            transcript = json.dumps(surfaces, sort_keys=True).encode()
            self._assert_corpus_absent("control", transcript)
            for env_name in SECRETS:
                self.assertNotIn(env_name.encode(), transcript)

            diagnostics = surfaces["diagnostics"]
            self.assertEqual(1, diagnostics["format_version"])
            self.assertEqual(
                (Path(__file__).resolve().parents[1] / "VERSION")
                .read_text(encoding="utf-8")
                .strip(),
                diagnostics["version"],
            )
            self.assertEqual(surfaces["config"]["config_hash"], diagnostics["config_hash"])
            self.assertRegex(diagnostics["config_hash"], r"^(0|[1-9][0-9]*)$")
            self.assertIn("status", diagnostics["last_error"])
            self.assertIn("at_ms", diagnostics["last_error"])
            self.assertTrue(diagnostics["redacted"])
            self.assertFalse(diagnostics["payloads_included"])
            self.assertFalse(diagnostics["secrets_included"])
            self.assertIn("curl", diagnostics["dependencies"])
            self.assertIn("sqlite", diagnostics["dependencies"])

            state = daemon.root / "state"
            for path in (state / "asmflow.db", state / "asmflow.db-wal", state / "asmflow.db-shm"):
                if path.exists():
                    self._assert_corpus_absent(path.name, path.read_bytes())

            cli = Path(os.environ.get("BUILD_DIR", Path(__file__).resolve().parents[1] / "build")) / "debug" / "asmflowctl"
            if cli.is_file():
                result = subprocess.run(
                    [str(cli), "--socket", daemon.socket_path, "--json", "diagnostics.export", "{}"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=10,
                    check=False,
                )
                self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
                self._assert_corpus_absent("cli", result.stdout + result.stderr)

            self.assertEqual(0, daemon.terminate())
            stdout, stderr = daemon.process.communicate()
            self._assert_corpus_absent("stdout", stdout)
            self._assert_corpus_absent("stderr", stderr)
        finally:
            daemon.close()

    def test_secret_corpus_is_absent_from_sigkill_process_output(self) -> None:
        """An abrupt stop must not turn loaded SecretRefs into crash output."""
        daemon = DaemonUnderTest(mutate=secret_configuration, extra_env=SECRETS)
        try:
            # Exercise the redacted views first so every configured SecretRef
            # has crossed the startup/control boundary before the abrupt stop.
            with daemon.connect() as client:
                client.call("config.current")
                client.call("providers.list")
                client.call("mcp.list")
                client.call("diagnostics.export")

            daemon.process.kill()
            stdout, stderr = daemon.process.communicate(timeout=5)
            self.assertEqual(-signal.SIGKILL, daemon.process.returncode)
            self._assert_corpus_absent("sigkill stdout", stdout)
            self._assert_corpus_absent("sigkill stderr", stderr)
        finally:
            daemon.close()

    def test_diagnostics_contains_metadata_not_payload_fields(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            diagnostics = client.call("diagnostics.export")
            encoded = json.dumps(diagnostics, sort_keys=True).lower()
            self.assertIn("config_hash", diagnostics)
            self.assertIn("providers", diagnostics)
            self.assertIn("routes", diagnostics)
            self.assertIn("mcp_servers", diagnostics)
            for forbidden in ("prompt", "response_body", "arguments", "tool_result", "stderr_text"):
                self.assertNotIn(forbidden, encoded)


if __name__ == "__main__":
    unittest.main()
