"""M11 authentication and outbound credential hardening integration tests."""
from __future__ import annotations

import json
import os
import sqlite3
import time
import unittest

from tests.http_harness import Gateway
from tests.mock_provider import MockProvider, json_handler
from tests.provider_harness import provider_config
from tests.test_control_protocol import DaemonUnderTest


class NonLoopbackAuthenticationTests(unittest.TestCase):
    TOKEN = "m11-live-listener-token"

    @staticmethod
    def _auth(document: dict) -> None:
        document["listener"]["auth"] = {
            "type": "header_env",
            "header": "X-AsmFlow-Key",
            "value": {"source": "env", "name": "ASMFLOW_M11_LISTENER_TOKEN"},
        }

    def test_non_loopback_without_auth_never_starts(self) -> None:
        def expose(document: dict) -> None:
            document["listener"]["host"] = "0.0.0.0"
            document["listener"]["auth"] = {"type": "none"}

        daemon = None
        try:
            with self.assertRaises(RuntimeError):
                daemon = DaemonUnderTest(mutate=expose)
        finally:
            if daemon is not None:
                daemon.close()

    def test_every_non_loopback_endpoint_authenticates_before_dispatch(self) -> None:
        with Gateway(
            mutate=self._auth,
            extra_env={"ASMFLOW_M11_LISTENER_TOKEN": self.TOKEN},
            host="0.0.0.0",
            connect_host="127.0.0.1",
        ) as gateway:
            cases = [
                ("GET", "/healthz", None),
                ("GET", "/readyz", None),
                ("GET", "/v1/models", None),
                ("POST", "/v1/responses", {"model": "general", "input": "x"}),
                (
                    "POST",
                    "/v1/chat/completions",
                    {"model": "general", "messages": [{"role": "user", "content": "x"}]},
                ),
            ]
            for method, target, body in cases:
                with self.subTest(method=method, target=target, credential="missing"):
                    response = gateway.get(target) if method == "GET" else gateway.post_json(target, json.dumps(body))
                    self.assertEqual(401, response.status)
                with self.subTest(method=method, target=target, credential="wrong"):
                    headers = [("X-AsmFlow-Key", "wrong-token")]
                    response = gateway.get(target, headers=headers) if method == "GET" else gateway.post_json(target, json.dumps(body), headers=headers)
                    self.assertEqual(401, response.status)
                with self.subTest(method=method, target=target, credential="correct"):
                    headers = [("X-AsmFlow-Key", self.TOKEN)]
                    response = gateway.get(target, headers=headers) if method == "GET" else gateway.post_json(target, json.dumps(body), headers=headers)
                    self.assertNotEqual(401, response.status)


class ProviderCredentialValueTests(unittest.TestCase):
    def test_empty_or_control_character_provider_secret_is_never_dispatched(self) -> None:
        canned = {"id": "x", "object": "chat.completion", "choices": []}
        for secret in ("", "safe-prefix\r\nX-Injected: yes", "bad\x7fvalue"):
            with self.subTest(secret=repr(secret)):
                provider = MockProvider(json_handler(canned))
                try:
                    base = provider_config(provider.base_url)

                    def configure(document: dict) -> None:
                        base(document)
                        document["providers"][0]["auth"] = {
                            "type": "bearer_env",
                            "env": "ASMFLOW_M11_PROVIDER_SECRET",
                        }

                    with Gateway(
                        mutate=configure,
                        extra_env={"ASMFLOW_M11_PROVIDER_SECRET": secret},
                    ) as gateway:
                        response = gateway.post_json(
                            "/v1/chat/completions",
                            json.dumps(
                                {
                                    "model": "general",
                                    "messages": [{"role": "user", "content": "x"}],
                                }
                            ),
                        )
                        self.assertGreaterEqual(response.status, 400)
                        time.sleep(0.05)
                        self.assertEqual([], provider.requests)
                        self.assertTrue(gateway.alive())
                finally:
                    provider.close()


class AuditEventTests(unittest.TestCase):
    def test_mutations_record_only_static_action_peer_and_outcome(self) -> None:
        secret = "m11-audit-secret-must-not-persist"
        with DaemonUnderTest(extra_env={"UNRELATED_SECRET": secret}) as daemon:
            with daemon.connect() as client:
                client.call("provider.disable", {"provider_id": "local-ollama"})
                failure = client.call_expect_error(
                    "provider.enable", {"provider_id": "missing-provider"}
                )
                self.assertEqual("not_found", failure["error"]["code"])

            database_path = daemon.root / "state" / "asmflow.db"
            connection = sqlite3.connect(
                f"file:{database_path}?mode=ro", uri=True, timeout=5.0
            )
            try:
                connection.execute("PRAGMA query_only = ON")
                rows = connection.execute(
                    "SELECT peer_uid, peer_pid, action, outcome, status "
                    "FROM audit_events ORDER BY id"
                ).fetchall()
            finally:
                connection.close()
            self.assertEqual(2, len(rows))
            self.assertEqual(os.getuid(), rows[0][0])
            self.assertGreater(rows[0][1], 0)
            self.assertEqual(("provider.disable", "success", 0), rows[0][2:])
            self.assertEqual("provider.enable", rows[1][2])
            self.assertEqual("failure", rows[1][3])
            self.assertLess(rows[1][4], 0)
            self.assertNotIn(secret.encode(), (daemon.root / "state" / "asmflow.db").read_bytes())


if __name__ == "__main__":
    unittest.main()
