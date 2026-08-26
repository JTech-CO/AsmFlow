"""Faults, exposure, and credentials (HARNESS.md M5 DoD 7 and 8).

The property under test is not that these cases produce a nice error. It is that
none of them damages the daemon: it stays alive, it gets its descriptors back,
and the next well-formed request is served normally. A gateway on loopback still
faces every misbehaving client on the machine, and a slot lost to a half-open
connection is a slot lost until restart.
"""
from __future__ import annotations

import json
import socket
import struct
import time
import unittest

from tests.http_harness import Gateway, parse_responses, read_until_quiet
from tests.test_control_protocol import DaemonUnderTest, daemon_path


def settle(gateway, baseline: int, timeout: float = 15.0) -> int:
    """Wait for the descriptor count to come back down, then report it."""
    deadline = time.monotonic() + timeout
    count = gateway.descriptor_count()
    while time.monotonic() < deadline and count > baseline:
        time.sleep(0.05)
        count = gateway.descriptor_count()
    return count


class ConnectionFaultTests(unittest.TestCase):
    @staticmethod
    def brief(document):
        document["listener"]["idle_timeout_ms"] = 1000

    def test_a_slowloris_fleet_does_not_hold_the_daemon(self) -> None:
        """Sixty half-open requests, all reclaimed by the idle sweep."""
        with Gateway(mutate=self.brief) as gateway:
            baseline = gateway.descriptor_count()
            socks = []
            try:
                for index in range(60):
                    sock = gateway.connect(timeout=10.0)
                    sock.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n")
                    sock.sendall(f"X-Slow-{index}: ".encode())
                    socks.append(sock)
                self.assertTrue(gateway.alive())
                # Still serving while they hang there.
                self.assertEqual(200, gateway.get("/healthz").status)
            finally:
                for sock in socks:
                    sock.close()
            self.assertLessEqual(settle(gateway, baseline), baseline)
            self.assertTrue(gateway.alive())
            self.assertEqual(200, gateway.get("/healthz").status)

    def test_a_partial_request_then_a_close_leaks_nothing(self) -> None:
        with Gateway() as gateway:
            baseline = gateway.descriptor_count()
            for _ in range(100):
                sock = gateway.connect()
                sock.sendall(b"POST /v1/responses HTTP/1.1\r\nHost: x\r\nContent-Len")
                sock.close()
            self.assertLessEqual(settle(gateway, baseline), baseline)
            self.assertTrue(gateway.alive())

    def test_a_client_reset_mid_response_leaks_nothing(self) -> None:
        """RST rather than FIN, which is what a killed client sends."""
        with Gateway() as gateway:
            baseline = gateway.descriptor_count()
            for _ in range(100):
                sock = gateway.connect()
                sock.setsockopt(
                    socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
                )
                sock.sendall(b"GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n")
                sock.close()
            self.assertLessEqual(settle(gateway, baseline), baseline)
            self.assertTrue(gateway.alive())
            self.assertEqual(200, gateway.get("/healthz").status)

    def test_a_connection_that_never_sends_leaks_nothing(self) -> None:
        with Gateway() as gateway:
            baseline = gateway.descriptor_count()
            socks = [gateway.connect() for _ in range(100)]
            for sock in socks:
                sock.close()
            self.assertLessEqual(settle(gateway, baseline), baseline)
            self.assertTrue(gateway.alive())

    def test_more_connections_than_the_table_holds_are_refused_not_leaked(self) -> None:
        """Bounded means bounded: past the table, a connection is closed at once."""
        with Gateway(mutate=self.brief) as gateway:
            baseline = gateway.descriptor_count()
            socks = []
            try:
                for _ in range(200):
                    try:
                        sock = gateway.connect(timeout=5.0)
                        sock.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n")
                        socks.append(sock)
                    except OSError:
                        break
                self.assertTrue(gateway.alive())
                peak = gateway.descriptor_count()
                self.assertLess(
                    peak,
                    baseline + 200,
                    "the connection table did not bound the descriptor count",
                )
            finally:
                for sock in socks:
                    sock.close()
            self.assertLessEqual(settle(gateway, baseline), baseline)
            self.assertEqual(200, gateway.get("/healthz").status)

    def test_a_pipelined_batch_is_answered_in_order(self) -> None:
        batch = b"".join(
            f"GET /healthz HTTP/1.1\r\nHost: x\r\nX-N: {n}\r\n\r\n".encode()
            for n in range(16)
        )
        batch += b"GET /v1/models HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        with Gateway() as gateway:
            responses = parse_responses(gateway.send_raw(batch))
            self.assertEqual(17, len(responses))
            self.assertTrue(all(r.status == 200 for r in responses))
            self.assertIn(b'"object":"list"', responses[-1].body)
            self.assertTrue(gateway.alive())

    def test_the_daemon_still_shuts_down_cleanly_after_all_of_it(self) -> None:
        with Gateway() as gateway:
            gateway.get("/healthz")
            sock = gateway.connect()
            sock.sendall(b"GET /healthz HTTP/1.1\r\n")
            self.assertEqual(0, gateway.daemon.terminate())
            sock.close()


class ExposureTests(unittest.TestCase):
    """M5 DoD 8: a listener beyond this host needs a credential policy."""

    def test_a_non_loopback_listener_without_auth_refuses_to_start(self) -> None:
        def exposed(document):
            document["listener"]["host"] = "0.0.0.0"
            document["listener"]["port"] = 18081
            document["listener"]["auth"] = {"type": "none"}

        daemon = None
        try:
            daemon = DaemonUnderTest(mutate=exposed)
        except RuntimeError as exc:
            self.assertIn("exited during startup", str(exc))
            return
        finally:
            if daemon is not None:
                daemon.close()
        self.fail("an exposed listener with no authentication policy started")

    def test_a_non_loopback_listener_with_auth_is_allowed(self) -> None:
        """The rule is about the missing policy, not about the address."""

        def exposed_with_auth(document):
            document["listener"]["host"] = "127.0.0.2"
            document["listener"]["auth"] = {
                "type": "bearer_env",
                "env": "ASMFLOW_TEST_TOKEN",
            }

        with Gateway(
            mutate=exposed_with_auth,
            extra_env={"ASMFLOW_TEST_TOKEN": "a-token-value"},
            host="127.0.0.2",
            connect_host="127.0.0.2",
        ) as gateway:
            self.assertTrue(gateway.alive())

    def test_a_host_that_is_not_an_address_literal_is_refused(self) -> None:
        """No resolver decides what this daemon binds."""

        def named(document):
            document["listener"]["host"] = "gateway.example.test"
            document["listener"]["auth"] = {
                "type": "bearer_env",
                "env": "ASMFLOW_TEST_TOKEN",
            }

        daemon = None
        try:
            daemon = DaemonUnderTest(
                mutate=named, extra_env={"ASMFLOW_TEST_TOKEN": "a-token-value"}
            )
        except RuntimeError as exc:
            self.assertIn("exited during startup", str(exc))
            return
        finally:
            if daemon is not None:
                daemon.close()
        self.fail("a hostname was accepted as a listen address")


class CredentialTests(unittest.TestCase):
    """The credential policy applies to the listener, not to a subset of it."""

    TOKEN = "correct-horse-battery-staple"

    @staticmethod
    def with_bearer(document):
        document["listener"]["auth"] = {
            "type": "bearer_env",
            "env": "ASMFLOW_TEST_TOKEN",
        }

    def gateway(self):
        return Gateway(
            mutate=self.with_bearer,
            extra_env={"ASMFLOW_TEST_TOKEN": self.TOKEN},
        )

    def test_no_credential_is_401_missing_token(self) -> None:
        with self.gateway() as gateway:
            for target in ("/healthz", "/readyz", "/v1/models"):
                with self.subTest(target=target):
                    response = gateway.get(target)
                    self.assertEqual(401, response.status)
                    error = response.json()["error"]
                    self.assertEqual("asmflow_auth_error", error["type"])
                    self.assertEqual("missing_token", error["code"])

    def test_a_wrong_credential_is_401_invalid_token(self) -> None:
        with self.gateway() as gateway:
            response = gateway.get(
                "/healthz", headers=[("Authorization", "Bearer not-the-token")]
            )
            self.assertEqual(401, response.status)
            self.assertEqual("invalid_token", response.json()["error"]["code"])

    def test_the_right_credential_is_served(self) -> None:
        with self.gateway() as gateway:
            response = gateway.get(
                "/healthz", headers=[("Authorization", f"Bearer {self.TOKEN}")]
            )
            self.assertEqual(200, response.status)

    def test_the_scheme_is_case_insensitive_and_the_token_is_not(self) -> None:
        with self.gateway() as gateway:
            self.assertEqual(
                200,
                gateway.get(
                    "/healthz", headers=[("Authorization", f"bEaReR {self.TOKEN}")]
                ).status,
            )
            self.assertEqual(
                401,
                gateway.get(
                    "/healthz",
                    headers=[("Authorization", f"Bearer {self.TOKEN.upper()}")],
                ).status,
            )

    def test_a_malformed_authorization_header_is_401(self) -> None:
        with self.gateway() as gateway:
            for value in (
                self.TOKEN,
                f"Basic {self.TOKEN}",
                f"Bearer  {self.TOKEN}",
                "Bearer",
                "Bearer ",
                f"Bearer {self.TOKEN}extra",
                f"Bearer {self.TOKEN[:-1]}",
            ):
                with self.subTest(value=value):
                    self.assertEqual(
                        401,
                        gateway.get(
                            "/healthz", headers=[("Authorization", value)]
                        ).status,
                    )

    def test_a_refusal_never_echoes_the_credential(self) -> None:
        with self.gateway() as gateway:
            response = gateway.get(
                "/healthz", headers=[("Authorization", "Bearer leaked-guess-value")]
            )
            whole = response.raw + response.body
            self.assertNotIn(b"leaked-guess-value", whole)
            self.assertNotIn(self.TOKEN.encode(), whole)
            self.assertNotIn(b"ASMFLOW_TEST_TOKEN", whole)

    def test_a_named_header_policy_works_the_same_way(self) -> None:
        def with_header(document):
            document["listener"]["auth"] = {
                "type": "header_env",
                "header": "X-AsmFlow-Key",
                "value": {"source": "env", "name": "ASMFLOW_TEST_TOKEN"},
            }

        with Gateway(
            mutate=with_header, extra_env={"ASMFLOW_TEST_TOKEN": self.TOKEN}
        ) as gateway:
            self.assertEqual(401, gateway.get("/healthz").status)
            self.assertEqual(
                200,
                gateway.get(
                    "/healthz", headers=[("X-AsmFlow-Key", self.TOKEN)]
                ).status,
            )
            self.assertEqual(
                401,
                gateway.get(
                    "/healthz", headers=[("Authorization", f"Bearer {self.TOKEN}")]
                ).status,
            )

    def test_a_missing_environment_secret_stops_startup(self) -> None:
        daemon = None
        try:
            daemon = DaemonUnderTest(mutate=self.with_bearer)
        except RuntimeError as exc:
            self.assertIn("exited during startup", str(exc))
            return
        finally:
            if daemon is not None:
                daemon.close()
        self.fail("a listener started with an unresolvable credential")


if __name__ == "__main__":
    unittest.main()
