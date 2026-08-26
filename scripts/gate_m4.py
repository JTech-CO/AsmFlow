#!/usr/bin/env python3
"""M4 gate: SQLite, migrations, and the control plane.

Checks the Definition of Done in HARNESS.md 1 / M4:

  1. an empty database migrates to the current schema in a transaction
  2. a failure injected into any migration statement rolls back the version
     and the data
  3. CRUD round trips match the domain model
  4. no test outside the daemon writes the database directly
  5. the control socket is mode 0600 inside a 0700 directory
  6. frames over the ceiling, invalid JSON, and unknown commands are refused
     safely
  7. a hundred client connect/disconnect cycles leak no descriptors
  8. a database write failure blocks neither read-only snapshot commands nor
     the daemon itself

Items 1-3 and 8 are proven by the assembly tests; 5-7 by the integration tests
against a running daemon. Item 4 is a structural property of the tree, checked
here.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class GateError(RuntimeError):
    pass


def run_assembly(binary: Path, prefix: str) -> None:
    result = subprocess.run(
        [str(binary), "--filter", prefix],
        capture_output=True,
        text=True,
        timeout=600,
    )
    if result.returncode != 0:
        raise GateError(f"assembly tests '{prefix}' failed:\n{result.stdout}{result.stderr}")


def run_python(module: str, build_dir: Path) -> None:
    env = dict(os.environ)
    env["BUILD_DIR"] = str(build_dir)
    result = subprocess.run(
        [sys.executable, "-m", "unittest", module],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=1800,
        env=env,
    )
    if result.returncode != 0:
        raise GateError(f"{module} failed:\n{result.stdout}{result.stderr}")


# --- DoD 4 -----------------------------------------------------------------

# `asmflowd` is the single writer (ARCHITECTURE.md 9). A test that opened the
# database itself would prove the daemon's behaviour against a file the daemon
# was not the only author of, and would also quietly establish a second writer
# as an acceptable pattern.
ALLOWED_SQLITE_USERS = {
    "src/storage/db.asm",
    "src/storage/migrations.asm",
    "src/storage/repo.asm",
    "src/ffi/sqlite_shim.c",
    "include/db.inc",
    "scripts/gate_m4.py",
    "Makefile",
}

SQLITE_PATTERN = re.compile(r"\bsqlite3?\b|import\s+sqlite3", re.IGNORECASE)


def check_single_writer() -> None:
    offenders: list[str] = []
    for pattern in ("tests/**/*.py", "tests/**/*.asm", "src/tui/*.asm",
                    "src/control/*.asm", "src/http/*.asm", "src/mcp/*.asm"):
        for path in ROOT.glob(pattern):
            relative = path.relative_to(ROOT).as_posix()
            if relative in ALLOWED_SQLITE_USERS:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            for number, line in enumerate(text.splitlines(), 1):
                if line.lstrip().startswith((";", "#")):
                    continue  # a comment naming SQLite is not a use of it
                if SQLITE_PATTERN.search(line):
                    offenders.append(f"{relative}:{number}: {line.strip()}")
    if offenders:
        raise GateError(
            "these files reach SQLite directly, but only the daemon's storage "
            "module may:\n  " + "\n  ".join(offenders)
        )


def check_tui_does_not_link_sqlite(build_dir: Path) -> None:
    """The console's link line is the enforcement, so check the binary."""
    tui = build_dir / "debug" / "asmflow-tui"
    if not tui.is_file():
        raise GateError(f"missing build artifact: {tui}")
    result = subprocess.run(
        ["readelf", "-Wd", str(tui)], capture_output=True, text=True, timeout=60
    )
    if "sqlite" in result.stdout.lower():
        raise GateError(
            "asmflow-tui links libsqlite3; the console must reach state only "
            "through the control socket (AGENTS.md invariant 14)"
        )
    if "libcurl" in result.stdout.lower():
        raise GateError("asmflow-tui links libcurl; it has no upstream to talk to")


def check_no_sql_string_building() -> None:
    """Every statement is a literal; values arrive through bind.

    SECURITY_MODEL.md 14. The mechanical form of the rule is that the storage
    module's SQL constants are all in .rodata and none is assembled at runtime,
    so a bind placeholder count that does not match the parameters would fail at
    prepare time rather than concatenating a value into the statement.
    """
    repo = (ROOT / "src/storage/repo.asm").read_text(encoding="utf-8")
    statements = re.findall(r'^\s*db\s+"(.*?)"', repo, re.MULTILINE)
    joined = " ".join(statements)
    # A quote or a format-like marker inside a statement would suggest a value
    # was meant to be spliced in.
    for suspicious in ("' ||", "||'", "%s", "{}"):
        if suspicious in joined:
            raise GateError(
                f"src/storage/repo.asm contains {suspicious!r}, which looks "
                f"like SQL assembled from a value rather than bound"
            )
    if "?1" not in joined:
        raise GateError("no bound parameters found; the repository should use them")


# --- DoD 1 and 2 -----------------------------------------------------------


def check_migration_statement_coverage() -> None:
    """The rollback test must cover every statement, not a sample.

    tests/asm/test_db.asm walks the injection point across
    af_migrations_statement_count() positions, so the coverage is whatever the
    migration actually contains. This asserts the count is what the schema
    implies, which is the part a reader would otherwise have to trust.
    """
    migrations = (ROOT / "src/storage/migrations.asm").read_text(encoding="utf-8")
    block = migrations.split("migration_1_statements:")[1].split("dq 0")[0]
    entries = [line for line in block.splitlines() if line.strip().startswith("dq ")]
    if len(entries) < 10:
        raise GateError(
            f"migration 1 declares only {len(entries)} statements; the schema in "
            f"ARCHITECTURE.md 9 lists ten tables"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", default="build")
    args = parser.parse_args()
    build_dir = (ROOT / args.build_dir).resolve()
    tests_binary = build_dir / "debug" / "asmflow-tests"
    if not tests_binary.is_file():
        print(f"[fail] missing build artifact: {tests_binary}", file=sys.stderr)
        return 1

    checks = [
        ("migrations and rollback", lambda: run_assembly(tests_binary, "db/")),
        ("migration covers every table", check_migration_statement_coverage),
        ("JSON serialisation", lambda: run_assembly(tests_binary, "jsonw/")),
        ("event loop", lambda: run_assembly(tests_binary, "loop/")),
        ("control framing", lambda: run_assembly(tests_binary, "ctlframe/")),
        ("single database writer", check_single_writer),
        ("console links no storage", lambda: check_tui_does_not_link_sqlite(build_dir)),
        ("no SQL built from values", check_no_sql_string_building),
        ("control protocol", lambda: run_python("tests.test_control_protocol", build_dir)),
    ]

    try:
        for label, check in checks:
            check()
            print(f"[ok] {label}")
    except GateError as exc:
        print(f"[fail] {exc}", file=sys.stderr)
        return 1
    print("M4 gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
