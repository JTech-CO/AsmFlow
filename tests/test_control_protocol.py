"""The control protocol, against a running daemon (HARNESS.md M4).

Everything here starts a real `asmflowd`, connects over its Unix socket, and
speaks NDJSON to it. A mock would test the mock; the properties under test —
socket permissions, frame ceilings, descriptor accounting, graceful shutdown —
only exist in the real process.
"""
from __future__ import annotations

import copy
import json
import os
import signal
import socket
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from tests import config_corpus
from tests.control_client import ControlClient, ControlError

ROOT = Path(__file__).resolve().parents[1]


def daemon_path() -> Path:
    build_dir = Path(os.environ.get("BUILD_DIR", ROOT / "build"))
    return build_dir / "debug" / "asmflowd"


class DaemonUnderTest:
    """A daemon in a private directory, torn down however the test ends."""

    def __init__(self, mutate=None, extra_env=None) -> None:
        # The skip lives here, not in each suite's `setUpClass`, because this
        # constructor is the only path that starts a daemon. `make check` is
        # the buildless M0 gate — Python and Make and nothing else — so a suite
        # that needs a binary must skip rather than error there. Restating that
        # once per test class is a rule the next test class forgets, and the
        # six M5 suites did: seventeen classes, no guard, and `make check` on a
        # clean checkout reported seventy errors instead of seventy skips.
        if not daemon_path().is_file():
            raise unittest.SkipTest(
                f"{daemon_path()} is not built; run `make build-debug` first"
            )
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "run").mkdir()
        (self.root / "state").mkdir()

        document = config_corpus.base_document()
        self.socket_path = str(self.root / "run" / "asmflow" / "control.sock")
        document["control"]["socket_path"] = self.socket_path
        document["storage"]["database_path"] = str(self.root / "state" / "asmflow.db")
        if mutate is not None:
            mutate(document)
        self.config_path = self.root / "asmflow.json"
        self.config_path.write_text(json.dumps(document), encoding="utf-8")

        self.process = subprocess.Popen(
            [str(daemon_path()), "--config", str(self.config_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": str(self.root),
                "XDG_RUNTIME_DIR": str(self.root / "run"),
                "XDG_STATE_HOME": str(self.root / "state"),
                # The environment is built rather than inherited, so a secret a
                # test wants the daemon to resolve has to be passed in on
                # purpose. That is also the property under test wherever a
                # secret reference is involved.
                **(extra_env or {}),
            },
        )
        # A daemon that refuses to start is something several tests assert on
        # purpose, so the failure path has to clean up as thoroughly as the
        # success path: without this the temporary directory outlives the test
        # and the process, if it is somehow still alive, is never reaped.
        try:
            self._wait_for_socket()
        except BaseException:
            self.close()
            raise

    def _wait_for_socket(self, timeout: float = 15.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                out, err = self.process.communicate()
                raise RuntimeError(
                    f"the daemon exited during startup with "
                    f"{self.process.returncode}:\n{out.decode()}{err.decode()}"
                )
            if Path(self.socket_path).exists() and self._is_ready():
                return
            time.sleep(0.02)
        raise RuntimeError("the daemon never became ready")

    def _is_ready(self) -> bool:
        """Connectable is not the same as started.

        The control socket binds partway through startup, several steps before
        the upstream engine and the data-plane listener open their own
        descriptors. A test that took a baseline the moment the socket answered
        was counting a daemon mid-start, and would then see three descriptors
        appear that it had no reason to expect — which is exactly how
        `test_abrupt_disconnects_are_reclaimed` failed, intermittently and only
        on a machine slow enough for the gap to matter.

        `ready` is the daemon's own statement that startup finished, so it is
        what to wait for.
        """
        try:
            with ControlClient(self.socket_path) as client:
                return bool(client.call("system.snapshot").get("ready"))
        except (OSError, ControlError, ValueError):
            return False

    def connect(self) -> ControlClient:
        return ControlClient(self.socket_path)

    def terminate(self, sig: int = signal.SIGTERM, timeout: float = 15.0) -> int:
        if self.process.poll() is None:
            self.process.send_signal(sig)
            try:
                self.process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
                raise AssertionError(f"the daemon ignored signal {sig}")
        return self.process.returncode

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()
        self.tmp.cleanup()

    def __enter__(self) -> "DaemonUnderTest":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


class ControlProtocolTests(unittest.TestCase):
    # --- HARNESS.md M4 DoD 5 ---

    def test_socket_and_directory_permissions(self) -> None:
        with DaemonUnderTest() as daemon:
            info = os.stat(daemon.socket_path)
            self.assertTrue(stat.S_ISSOCK(info.st_mode), "not a socket")
            self.assertEqual(
                0o600, stat.S_IMODE(info.st_mode),
                "the control socket must be mode 0600",
            )
            self.assertEqual(os.getuid(), info.st_uid)

            parent = os.stat(Path(daemon.socket_path).parent)
            self.assertTrue(stat.S_ISDIR(parent.st_mode))
            self.assertEqual(
                0o700, stat.S_IMODE(parent.st_mode),
                "the control directory must be mode 0700",
            )
            self.assertEqual(os.getuid(), parent.st_uid)

    def test_socket_is_removed_on_shutdown(self) -> None:
        with DaemonUnderTest() as daemon:
            self.assertTrue(Path(daemon.socket_path).exists())
            self.assertEqual(0, daemon.terminate())
            self.assertFalse(
                Path(daemon.socket_path).exists(),
                "a clean shutdown must remove its socket",
            )

    # --- request/response envelope ---

    def test_system_version_matches_the_release(self) -> None:
        expected = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            result = client.call("system.version")
            self.assertEqual(expected, result["version"])
            self.assertEqual("linux-x86_64", result["target"])
            self.assertEqual("debug", result["build"])
            self.assertEqual(1, result["protocol_version"])

    def test_ids_correlate_and_survive_pipelining(self) -> None:
        """Several requests in flight at once must come back matched."""
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            payload = b""
            for index in range(20):
                payload += json.dumps(
                    {"id": f"req-{index}", "method": "system.version"}
                ).encode() + b"\n"
            client.send_raw(payload)
            seen = [client.read_frame()["id"] for _ in range(20)]
            self.assertEqual([f"req-{i}" for i in range(20)], seen)

    def test_snapshot_reports_counts_and_readiness(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            result = client.call("system.snapshot")
            self.assertTrue(result["ready"])
            self.assertEqual("open", result["database"])
            self.assertEqual(1, result["counts"]["providers"])
            self.assertEqual(1, result["counts"]["routes"])
            self.assertEqual(0, result["counts"]["mcp_servers"])
            self.assertGreaterEqual(result["uptime_ms"], 0)

    def test_providers_list_describes_the_configuration(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            providers = client.call("providers.list")
            self.assertEqual(1, len(providers))
            provider = providers[0]
            self.assertEqual("local-ollama", provider["id"])
            self.assertEqual("openai_chat", provider["adapter"])
            self.assertEqual("http://127.0.0.1:11434/v1", provider["base_url"])
            self.assertIn("chat_completions", provider["capabilities"])
            self.assertIn("streaming", provider["capabilities"])
            self.assertNotIn("vision", provider["capabilities"])
            self.assertEqual("none", provider["auth"]["type"])
            self.assertFalse(provider["operator_disabled"])

    def test_routes_list_preserves_target_order(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            routes = client.call("routes.list")
            self.assertEqual(1, len(routes))
            route = routes[0]
            self.assertEqual("general", route["model_alias"])
            self.assertEqual("priority", route["policy"])
            self.assertEqual(["chat_completions"], route["endpoint_families"])
            self.assertEqual(1, len(route["targets"]))
            self.assertEqual("local-ollama", route["targets"][0]["provider_id"])
            self.assertEqual(10, route["targets"][0]["priority"])

    def test_every_route_target_is_reported(self) -> None:
        """A route with more than one target reports all of them.

        The single-target fixture cannot see a wrong array stride, because
        index 0 is at offset 0 whatever the stride is. This walks past the
        first element, which is where an incorrect record size shows up.
        """

        def add_second_target(document: dict) -> None:
            second = copy.deepcopy(document["providers"][0])
            second["id"] = "second-provider"
            second["display_name"] = "Second provider"
            document["providers"].append(second)
            document["routes"][0]["targets"].append(
                {
                    "provider_id": "second-provider",
                    "upstream_model": "second-model",
                    "priority": 20,
                    "weight": 7,
                }
            )

        with DaemonUnderTest(mutate=add_second_target) as daemon:
            with daemon.connect() as client:
                route = client.call("routes.get", {"id": "general-route"})
                targets = route["targets"]
                self.assertEqual(2, len(targets))
                self.assertEqual("local-ollama", targets[0]["provider_id"])
                self.assertEqual("second-provider", targets[1]["provider_id"])
                self.assertEqual("second-model", targets[1]["upstream_model"])
                self.assertEqual(20, targets[1]["priority"])
                self.assertEqual(7, targets[1]["weight"])
            self.assertIsNone(
                daemon.process.poll(), "the daemon must survive the request"
            )

    def test_get_by_identifier(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            provider = client.call(
                "providers.get", {"provider_id": "local-ollama"}
            )
            self.assertEqual("local-ollama", provider["id"])
            route = client.call("routes.get", {"id": "general-route"})
            self.assertEqual("general-route", route["id"])

    # --- HARNESS.md M4 DoD 6 ---

    def test_unknown_method_is_rejected(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            payload = client.call_expect_error("no.such.method")
            self.assertEqual("unknown_method", payload["error"]["code"])
            # The connection stays usable: a typo is not a protocol failure.
            self.assertIn("version", client.call("system.version"))

    def test_invalid_json_is_rejected(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            client.send_raw(b'{"id":"x","method":\n')
            response = client.read_frame()
            self.assertFalse(response["ok"])
            self.assertEqual("invalid_json", response["error"]["code"])

    def test_a_non_object_frame_is_rejected(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            client.send_raw(b'["not", "an", "object"]\n')
            response = client.read_frame()
            self.assertFalse(response["ok"])
            self.assertEqual("invalid_json", response["error"]["code"])

    def test_missing_method_is_rejected_with_the_field(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            client.send_raw(b'{"id":"x"}\n')
            response = client.read_frame()
            self.assertFalse(response["ok"])
            self.assertEqual("invalid_params", response["error"]["code"])
            self.assertEqual("method", response["error"]["field"])
            self.assertEqual("x", response["id"], "the id must still be echoed")

    def test_oversized_frame_is_rejected_and_closes(self) -> None:
        """A frame past the ceiling leaves the framer unable to resynchronise."""
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            # Deliberately no newline: the ceiling applies to what accumulates,
            # not to a completed frame, or a peer that never terminates one
            # could grow the buffer without bound.
            blob = b'{"id":"big","method":"system.version","pad":"' + b"x" * (2 << 20)
            try:
                client.send_raw(blob)
            except BrokenPipeError:
                pass
            response = client.read_frame()
            self.assertFalse(response["ok"])
            self.assertEqual("frame_too_large", response["error"]["code"])
            with self.assertRaises((EOFError, ConnectionResetError, OSError)):
                client.read_frame()

    def test_invalid_utf8_is_rejected(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            client.send_raw(b'{"id":"x","method":"\xff\xfe"}\n')
            response = client.read_frame()
            self.assertFalse(response["ok"])

    def test_params_of_the_wrong_type_are_rejected(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            client.send_raw(
                b'{"id":"x","method":"system.version","params":"not-an-object"}\n'
            )
            response = client.read_frame()
            self.assertFalse(response["ok"])
            self.assertEqual("invalid_params", response["error"]["code"])
            self.assertEqual("params", response["error"]["field"])

    def test_unknown_identifier_reports_not_found(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            payload = client.call_expect_error(
                "providers.get", {"provider_id": "absent"}
            )
            self.assertEqual("not_found", payload["error"]["code"])

    def test_unwired_methods_say_so(self) -> None:
        """A method in the contract whose subsystem is not built yet.

        Distinct from `unknown_method`: an empty result would claim there is
        nothing to report, which is a different fact from not being able to
        report.
        """
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            payload = client.call_expect_error("mcp.inventory")
            self.assertEqual("unsupported_in_this_build", payload["error"]["code"])

    # --- HARNESS.md M4 DoD 7 ---

    def test_a_hundred_connections_leak_no_descriptors(self) -> None:
        with DaemonUnderTest() as daemon:
            fd_dir = Path(f"/proc/{daemon.process.pid}/fd")
            before = len(list(fd_dir.iterdir()))
            for _ in range(100):
                with daemon.connect() as client:
                    client.call("system.version")
            # Give the daemon a moment to observe the last close, then confirm
            # it is back where it started.
            deadline = time.monotonic() + 10.0
            while time.monotonic() < deadline:
                after = len(list(fd_dir.iterdir()))
                if after <= before:
                    break
                time.sleep(0.05)
            self.assertLessEqual(
                after, before,
                f"descriptors grew from {before} to {after} over 100 connections",
            )
            with daemon.connect() as client:
                self.assertTrue(client.call("system.snapshot")["ready"])

    def test_abrupt_disconnects_are_reclaimed(self) -> None:
        """A client that vanishes mid-request must not hold a slot."""
        with DaemonUnderTest() as daemon:
            fd_dir = Path(f"/proc/{daemon.process.pid}/fd")
            before = len(list(fd_dir.iterdir()))
            for _ in range(50):
                raw = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                raw.connect(daemon.socket_path)
                raw.sendall(b'{"id":"x","method":"system.ver')  # truncated
                raw.close()
            deadline = time.monotonic() + 10.0
            while time.monotonic() < deadline:
                after = len(list(fd_dir.iterdir()))
                if after <= before:
                    break
                time.sleep(0.05)
            self.assertLessEqual(after, before)
            with daemon.connect() as client:
                client.call("system.version")

    # --- mutations ---

    def test_provider_disable_persists_and_bumps_the_revision(self) -> None:
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            before = client.call("system.snapshot")["revision"]
            result = client.call(
                "provider.disable", {"provider_id": "local-ollama"}
            )
            self.assertTrue(result["operator_disabled"])
            after = client.call("system.snapshot")["revision"]
            self.assertGreater(after, before, "a mutation must bump the revision")

            provider = client.call(
                "providers.get", {"provider_id": "local-ollama"}
            )
            self.assertTrue(provider["operator_disabled"])

            client.call("provider.enable", {"provider_id": "local-ollama"})
            provider = client.call(
                "providers.get", {"provider_id": "local-ollama"}
            )
            self.assertFalse(provider["operator_disabled"])

    def test_operator_disable_survives_a_restart(self) -> None:
        """The decision lives in the database, so it outlives the process."""
        daemon = DaemonUnderTest()
        try:
            with daemon.connect() as client:
                client.call("provider.disable", {"provider_id": "local-ollama"})
            self.assertEqual(0, daemon.terminate())

            restarted = subprocess.Popen(
                [str(daemon_path()), "--config", str(daemon.config_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                    "HOME": str(daemon.root),
                    "XDG_RUNTIME_DIR": str(daemon.root / "run"),
                    "XDG_STATE_HOME": str(daemon.root / "state"),
                },
            )
            daemon.process = restarted
            daemon._wait_for_socket()
            with daemon.connect() as client:
                provider = client.call(
                    "providers.get", {"provider_id": "local-ollama"}
                )
                self.assertTrue(
                    provider["operator_disabled"],
                    "an operator's decision must survive a restart",
                )
        finally:
            daemon.close()

    # --- redaction ---

    def test_no_secret_value_appears_in_any_response(self) -> None:
        """SECURITY_MODEL.md 6: the policy is reported, the value never is."""
        sentinel = "sk-sentinel-must-not-appear-anywhere"

        def use_bearer_auth(document: dict) -> None:
            document["listener"]["host"] = "127.0.0.1"
            document["listener"]["auth"] = {
                "type": "bearer_env",
                "env": "ASMFLOW_GATEWAY_TOKEN",
            }
            document["providers"][0]["auth"] = {
                "type": "bearer_env",
                "env": "OPENAI_API_KEY",
            }

        daemon = DaemonUnderTest(
            mutate=use_bearer_auth,
            extra_env={
                "ASMFLOW_GATEWAY_TOKEN": sentinel,
                "OPENAI_API_KEY": sentinel,
            },
        )
        try:
            with daemon.connect() as client:
                transcript = json.dumps([
                    client.call("system.version"),
                    client.call("system.snapshot"),
                    client.call("config.current"),
                    client.call("providers.list"),
                    client.call("routes.list"),
                    client.call("mcp.list"),
                ])
            self.assertNotIn(sentinel, transcript)
            # The policy and its satisfaction ARE reported: an operator
            # debugging a 401 needs to know the token is present.
            current = json.loads(transcript)[2]
            self.assertEqual("bearer_env", current["listener"]["auth"]["type"])
            self.assertTrue(current["listener"]["auth"]["secret_present"])
            # ...but not which variable it came from.
            self.assertNotIn("OPENAI_API_KEY", transcript)
            self.assertNotIn("ASMFLOW_GATEWAY_TOKEN", transcript)
        finally:
            daemon.close()

    def test_the_database_holds_no_credential(self) -> None:
        sentinel = "sk-sentinel-must-not-be-persisted"
        with DaemonUnderTest() as daemon, daemon.connect() as client:
            client.call("system.snapshot")
            db_path = daemon.root / "state" / "asmflow.db"
            self.assertTrue(db_path.exists())
            blob = db_path.read_bytes()
            self.assertNotIn(sentinel.encode(), blob)
            # Nor the shape of one: no `auth` column exists to hold it.
            self.assertNotIn(b"bearer_env", blob)

    # --- shutdown ---

    def test_sigterm_shuts_down_cleanly(self) -> None:
        with DaemonUnderTest() as daemon:
            with daemon.connect() as client:
                client.call("system.version")
            self.assertEqual(0, daemon.terminate(signal.SIGTERM))

    def test_sigint_shuts_down_cleanly(self) -> None:
        with DaemonUnderTest() as daemon:
            self.assertEqual(0, daemon.terminate(signal.SIGINT))

    def test_a_second_daemon_refuses_to_steal_the_socket(self) -> None:
        """Unlinking whatever is at the path would let one daemon steal it."""
        with DaemonUnderTest() as daemon:
            second = subprocess.run(
                [str(daemon_path()), "--config", str(daemon.config_path)],
                capture_output=True,
                text=True,
                timeout=30,
                env={
                    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                    "HOME": str(daemon.root),
                    "XDG_RUNTIME_DIR": str(daemon.root / "run"),
                    "XDG_STATE_HOME": str(daemon.root / "state"),
                },
            )
            self.assertNotEqual(0, second.returncode)
            # And the first is still serving.
            with daemon.connect() as client:
                client.call("system.version")

    def test_a_stale_socket_is_reclaimed(self) -> None:
        """A node left by a killed daemon must not block the next start."""
        daemon = DaemonUnderTest()
        try:
            daemon.process.kill()
            daemon.process.wait(timeout=5)
            self.assertTrue(
                Path(daemon.socket_path).exists(),
                "SIGKILL leaves the socket node behind, which is the case under test",
            )
            restarted = subprocess.Popen(
                [str(daemon_path()), "--config", str(daemon.config_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                    "HOME": str(daemon.root),
                    "XDG_RUNTIME_DIR": str(daemon.root / "run"),
                    "XDG_STATE_HOME": str(daemon.root / "state"),
                },
            )
            daemon.process = restarted
            daemon._wait_for_socket()
            with daemon.connect() as client:
                client.call("system.version")
        finally:
            daemon.close()


if __name__ == "__main__":
    unittest.main()
