"""M11 owner, type, and mode boundaries for local authority files."""
from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from tests import config_corpus
from tests.test_control_protocol import DaemonUnderTest, daemon_path


def _private_fixture(root: Path) -> tuple[dict, Path, Path]:
    """Create caller-owned secure paths and return (document, config, db)."""
    root.chmod(0o700)
    run = root / "run"
    state = root / "state"
    run.mkdir(mode=0o700)
    state.mkdir(mode=0o700)
    run.chmod(0o700)
    state.chmod(0o700)
    document = config_corpus.base_document()
    document["control"]["socket_path"] = str(run / "asmflow" / "control.sock")
    db = state / "asmflow.db"
    document["storage"]["database_path"] = str(db)
    config = root / "asmflow.json"
    return document, config, db


def _run_startup(config: Path, root: Path, timeout: float = 5.0) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(daemon_path()), "--config", str(config)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        env={
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(root),
            "XDG_RUNTIME_DIR": str(root / "run"),
            "XDG_STATE_HOME": str(root / "state"),
        },
    )


class PermissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not daemon_path().is_file():
            raise unittest.SkipTest("run `make build-debug` first")

    def test_runtime_state_and_sqlite_files_are_owner_only(self) -> None:
        with DaemonUnderTest() as daemon:
            paths = [
                daemon.config_path,
                daemon.root / "state",
                Path(daemon.socket_path).parent,
                Path(daemon.socket_path),
                daemon.root / "state" / "asmflow.db",
            ]
            for path in paths:
                info = os.stat(path)
                self.assertEqual(os.getuid(), info.st_uid, str(path))
                expected = 0o700 if stat.S_ISDIR(info.st_mode) else 0o600
                self.assertEqual(expected, stat.S_IMODE(info.st_mode), str(path))

            # WAL and SHM lifetimes are SQLite-controlled, but whenever present
            # they must inherit the daemon's 0077 creation policy.
            for suffix in ("-wal", "-shm"):
                path = daemon.root / "state" / f"asmflow.db{suffix}"
                if path.exists():
                    self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))

    def test_group_or_world_readable_config_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            document, config, _ = _private_fixture(root)
            config.write_text(json.dumps(document), encoding="utf-8")
            config.chmod(0o644)
            result = _run_startup(config, root)
            self.assertEqual(3, result.returncode, result.stderr.decode())
            self.assertIn(b"not owner-private", result.stderr)

    def test_non_private_config_directory_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            document, _, _ = _private_fixture(root)
            config_dir = root / "config"
            config_dir.mkdir(mode=0o755)
            config_dir.chmod(0o755)
            config = config_dir / "asmflow.json"
            config.write_text(json.dumps(document), encoding="utf-8")
            config.chmod(0o600)
            result = _run_startup(config, root)
            self.assertEqual(3, result.returncode, result.stderr.decode())

    def test_config_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            document, config, _ = _private_fixture(root)
            target = root / "real.json"
            target.write_text(json.dumps(document), encoding="utf-8")
            target.chmod(0o600)
            config.symlink_to(target)
            result = _run_startup(config, root)
            self.assertEqual(3, result.returncode, result.stderr.decode())

    def test_fifo_config_is_rejected_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, config, _ = _private_fixture(root)
            os.mkfifo(config, 0o600)
            # A blocking open would make subprocess.run raise TimeoutExpired.
            result = _run_startup(config, root, timeout=3.0)
            self.assertEqual(3, result.returncode, result.stderr.decode())

    def test_non_private_state_directory_is_rejected_not_repaired(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            document, config, _ = _private_fixture(root)
            state = root / "state"
            state.chmod(0o755)
            config.write_text(json.dumps(document), encoding="utf-8")
            config.chmod(0o600)
            result = _run_startup(config, root)
            self.assertEqual(4, result.returncode, result.stderr.decode())
            self.assertEqual(0o755, stat.S_IMODE(state.stat().st_mode))

    def test_unsafe_existing_database_and_symlink_are_rejected(self) -> None:
        for symlink in (False, True):
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                document, config, db = _private_fixture(root)
                config.write_text(json.dumps(document), encoding="utf-8")
                config.chmod(0o600)
                if symlink:
                    target = root / "other.db"
                    target.write_bytes(b"")
                    target.chmod(0o600)
                    db.symlink_to(target)
                else:
                    db.write_bytes(b"")
                    db.chmod(0o644)
                result = _run_startup(config, root)
                self.assertEqual(4, result.returncode, result.stderr.decode())


if __name__ == "__main__":
    unittest.main()
