"""M11 SIGKILL next-start recovery against a real AsmFlow daemon.

The crash is deliberately process-level.  Opening the database between SIGKILL
and the second daemon would let Python/SQLite perform WAL recovery first and
would therefore test the wrong process, so the killed database is not touched
until AsmFlow has restarted successfully.
"""
from __future__ import annotations

import os
import signal
import socket
import sqlite3
import stat
import subprocess
import time
import unittest
from contextlib import closing
from pathlib import Path

from tests.control_client import ControlClient, ControlError
from tests.test_control_protocol import DaemonUnderTest, daemon_path


ROOT = Path(__file__).resolve().parents[1]


def _with_disabled_mcp(document: dict) -> None:
    """Add persisted MCP metadata without starting an external process."""
    document["mcp_servers"] = [
        {
            "id": "recovery-mcp",
            "display_name": "Recovery MCP",
            "transport": "stdio",
            "enabled": False,
            "required": False,
            "command": "/bin/false",
            "args": [],
            "cwd": str(ROOT),
            "env_allow": [],
            "env": {},
            "protocol": {
                "preferred": "2026-07-28",
                "legacy": ["2025-11-25"],
            },
            "restart": {
                "mode": "never",
                "max_restarts": 0,
                "window_ms": 1000,
                "backoff_ms": 0,
                "max_backoff_ms": 0,
            },
            "startup_timeout_ms": 1000,
            "shutdown_grace_ms": 1000,
        }
    ]


def _daemon_environment(daemon: DaemonUnderTest) -> dict[str, str]:
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(daemon.root),
        "XDG_RUNTIME_DIR": str(daemon.root / "run"),
        "XDG_STATE_HOME": str(daemon.root / "state"),
    }


def _stable_control_snapshot(client: ControlClient) -> dict:
    """Discard counters/timestamps while retaining domain meaning."""
    providers = []
    for value in client.call("providers.list"):
        providers.append(
            {
                key: value.get(key)
                for key in (
                    "id",
                    "display_name",
                    "adapter",
                    "base_url",
                    "enabled",
                    "required",
                    "max_concurrency",
                    "capabilities",
                    "auth",
                    "operator_disabled",
                )
            }
        )

    routes = []
    for value in client.call("routes.list"):
        routes.append(
            {
                key: value.get(key)
                for key in (
                    "id",
                    "model_alias",
                    "enabled",
                    "endpoint_families",
                    "policy",
                    "fallback",
                    "targets",
                )
            }
        )

    mcp = []
    for value in client.call("mcp.list"):
        mcp.append(
            {
                key: value.get(key)
                for key in (
                    "id",
                    "display_name",
                    "transport",
                    "enabled",
                    "required",
                    "state",
                )
            }
        )
    return {"providers": providers, "routes": routes, "mcp_servers": mcp}


def _database_semantics(path: Path) -> tuple[dict, str, str, list[tuple]]:
    """Read only stable columns; updated_at timestamps are not semantics."""
    with closing(
        sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5.0)
    ) as database:
        database.execute("PRAGMA query_only = ON")

        def rows(sql: str) -> list[tuple]:
            return database.execute(sql).fetchall()

        snapshot = {
            "schema_migrations": rows(
                "SELECT version FROM schema_migrations ORDER BY version"
            ),
            "providers": rows(
                "SELECT id, display_name, adapter, base_url, enabled, required, "
                "max_concurrency, capabilities FROM providers ORDER BY id"
            ),
            "provider_health": rows(
                "SELECT provider_id, operator_disabled FROM provider_health "
                "ORDER BY provider_id"
            ),
            "routes": rows(
                "SELECT id, model_alias, enabled, endpoint_families, policy, "
                "fallback_enabled, fallback_max_attempts, fallback_retryable "
                "FROM routes ORDER BY id"
            ),
            "route_targets": rows(
                "SELECT route_id, position, provider_id, upstream_model, priority, weight "
                "FROM route_targets ORDER BY route_id, position"
            ),
            "mcp_servers": rows(
                "SELECT id, display_name, transport, enabled, required, state, era, "
                "last_error, restart_count, crash_loop FROM mcp_servers ORDER BY id"
            ),
        }
        journal_mode = str(database.execute("PRAGMA journal_mode").fetchone()[0])
        integrity = str(database.execute("PRAGMA integrity_check").fetchone()[0])
        foreign_key_errors = rows("PRAGMA foreign_key_check")
    return snapshot, journal_mode, integrity, foreign_key_errors


class CrashRecoveryTests(unittest.TestCase):
    def test_sigkill_recovers_wal_migrations_socket_and_domain_state(self) -> None:
        daemon = DaemonUnderTest(mutate=_with_disabled_mcp)
        database_path = daemon.root / "state" / "asmflow.db"
        wal_path = Path(f"{database_path}-wal")
        killed_process: subprocess.Popen[bytes] | None = None
        try:
            with daemon.connect() as client:
                client.call("provider.disable", {"provider_id": "local-ollama"})
                before_control = _stable_control_snapshot(client)

            before_database, mode, integrity, foreign_errors = _database_semantics(
                database_path
            )
            self.assertEqual("wal", mode.lower())
            self.assertEqual("ok", integrity.lower())
            self.assertEqual([], foreign_errors)
            migration_versions = [
                row[0] for row in before_database["schema_migrations"]
            ]
            self.assertTrue(migration_versions, "the database has no migration record")
            self.assertEqual(
                list(range(1, migration_versions[-1] + 1)),
                migration_versions,
                "migration versions must be contiguous through the current schema",
            )
            self.assertEqual(
                [("local-ollama", 1)],
                before_database["provider_health"],
                "the committed operator decision is the recovery sentinel",
            )
            self.assertTrue(wal_path.is_file(), "WAL mode must create the WAL companion")
            self.assertGreater(
                wal_path.stat().st_size,
                32,
                "the crash must occur with committed frames in the WAL",
            )

            killed_process = daemon.process
            killed_process.send_signal(signal.SIGKILL)
            killed_process.wait(timeout=5.0)
            self.assertEqual(-signal.SIGKILL, killed_process.returncode)
            self.assertTrue(
                Path(daemon.socket_path).exists(),
                "SIGKILL must leave the stale UDS node used by this drill",
            )
            self.assertTrue(
                stat.S_ISSOCK(os.lstat(daemon.socket_path).st_mode),
                "the stale path must still be the killed daemon's socket",
            )

            # Do not open SQLite here.  The next database opener must be AsmFlow.
            restarted = subprocess.Popen(
                [str(daemon_path()), "--config", str(daemon.config_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=_daemon_environment(daemon),
            )
            daemon.process = restarted
            wait_for_recovered_daemon(daemon)

            with daemon.connect() as client:
                after_control = _stable_control_snapshot(client)
            self.assertEqual(before_control, after_control)
            self.assertTrue(socket_path_is_live(daemon.socket_path))

            self.assertEqual(0, daemon.terminate(signal.SIGTERM))
            after_database, mode, integrity, foreign_errors = _database_semantics(
                database_path
            )
            self.assertEqual(before_database, after_database)
            self.assertEqual("wal", mode.lower())
            self.assertEqual("ok", integrity.lower())
            self.assertEqual([], foreign_errors)
            self.assertEqual(
                migration_versions,
                [row[0] for row in after_database["schema_migrations"]],
            )
        finally:
            # daemon.close owns only the currently assigned process.  Close the
            # killed process's captured pipes as well so the test itself has no
            # descriptor leak across repeated recovery runs.
            if killed_process is not None:
                if killed_process.stdout is not None:
                    killed_process.stdout.close()
                if killed_process.stderr is not None:
                    killed_process.stderr.close()
            daemon.close()


def socket_path_is_live(path: str) -> bool:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            probe.settimeout(1.0)
            probe.connect(path)
        return True
    except OSError:
        return False


def wait_for_recovered_daemon(
    daemon: DaemonUnderTest, timeout: float = 15.0
) -> None:
    """Wait past the stale-node interval without leaking failed probes."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if daemon.process.poll() is not None:
            stdout, stderr = daemon.process.communicate()
            raise RuntimeError(
                "the recovery daemon exited during startup with "
                f"{daemon.process.returncode}:\n"
                f"{stdout.decode('utf-8', 'replace')}"
                f"{stderr.decode('utf-8', 'replace')}"
            )
        if not socket_path_is_live(daemon.socket_path):
            time.sleep(0.02)
            continue
        try:
            with daemon.connect() as client:
                if client.call("system.snapshot").get("ready"):
                    return
        except (OSError, ControlError, ValueError):
            pass
        time.sleep(0.02)
    raise RuntimeError("the recovery daemon never became ready")


if __name__ == "__main__":
    unittest.main()
