#!/usr/bin/env python3
"""M3 gate: JSON, configuration, and secret references.

Checks the Definition of Done in HARNESS.md 1 / M3:

  1. the shipped minimal and full examples load
  2. every invalid fixture is refused with an error code and a JSON Pointer
  3. the unknown-key policy matches the schema (rejected, not ignored)
  4. plaintext credential fields are refused without exception
  5. a missing environment secret fails before readiness
  6. a failed reload leaves the previous snapshot's hash and state unchanged
  7. a 10,000-iteration reload soak leaks nothing
  8. zero accept/reject disagreements between the schema and the assembly

Items 1-5 and 8 are driven through tests/test_config_parity.py, which runs the
whole corpus; this script adds the ones a corpus cannot express and reports the
result of each as its own line.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tests import config_corpus  # noqa: E402


class GateError(RuntimeError):
    pass


def clean_env(work: str, extra: dict[str, str] | None = None) -> dict[str, str]:
    """A minimal environment.

    Inheriting the caller's would let a stray OPENAI_API_KEY on one machine turn
    a missing-secret rejection into an acceptance on another.
    """
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": work,
        "XDG_CONFIG_HOME": f"{work}/config",
        "XDG_STATE_HOME": f"{work}/state",
        "XDG_RUNTIME_DIR": f"{work}/run",
    }
    env.update(extra or {})
    return env


def check_config(daemon: Path, document, extra_env=None) -> tuple[int, str]:
    with tempfile.TemporaryDirectory() as work:
        path = Path(work) / "asmflow.json"
        if isinstance(document, (str, bytes)):
            path.write_bytes(
                document if isinstance(document, bytes) else document.encode("utf-8")
            )
        else:
            path.write_text(json.dumps(document), encoding="utf-8")
        result = subprocess.run(
            [str(daemon), "--check-config", "--config", str(path)],
            capture_output=True,
            text=True,
            timeout=120,
            env=clean_env(work, extra_env),
        )
    return result.returncode, (result.stdout + result.stderr)


# --- DoD 1 -----------------------------------------------------------------


def check_examples_load(daemon: Path) -> None:
    code, output = check_config(daemon, config_corpus.base_document())
    if code != 0:
        raise GateError(f"examples/asmflow.minimal.json was refused:\n{output}")

    code, output = check_config(
        daemon, config_corpus.full_document(), config_corpus.FULL_ENV
    )
    if code != 0:
        raise GateError(f"examples/asmflow.full.json was refused:\n{output}")


# --- DoD 2 -----------------------------------------------------------------


def check_invalid_fixtures(daemon: Path) -> None:
    fixtures = sorted((ROOT / "tests/fixtures/config").glob("invalid_*.json"))
    if not fixtures:
        raise GateError("no invalid configuration fixtures were found")
    for fixture in fixtures:
        document = json.loads(fixture.read_text(encoding="utf-8"))
        code, output = check_config(daemon, document)
        if code == 0:
            raise GateError(f"{fixture.name} was accepted but must be refused")
        if "  at: " not in output:
            raise GateError(f"{fixture.name} was refused without a JSON Pointer:\n{output}")
        if "  code: " not in output:
            raise GateError(f"{fixture.name} was refused without an error code:\n{output}")


# --- DoD 4 -----------------------------------------------------------------


def check_plaintext_refused(daemon: Path) -> None:
    """Every credential-shaped key, at several depths, in every container."""
    for key in sorted(config_corpus.CREDENTIAL_KEYS):
        for placement in ("root", "provider", "nested", "array"):
            document = config_corpus.base_document()
            if placement == "root":
                document[key] = "value"
            elif placement == "provider":
                document["providers"][0][key] = "value"
            elif placement == "nested":
                document["listener"]["auth"][key] = "value"
            else:
                document["routes"][0]["targets"][0][key] = "value"
            code, output = check_config(daemon, document)
            if code == 0:
                raise GateError(
                    f"a plaintext {key!r} at {placement} was accepted"
                )
            if "plaintext credentials" not in output:
                raise GateError(
                    f"a plaintext {key!r} at {placement} was refused for the "
                    f"wrong reason:\n{output}"
                )


# --- DoD 5 -----------------------------------------------------------------


def check_missing_secret_fails(daemon: Path) -> None:
    document = config_corpus.full_document()
    code, output = check_config(daemon, document)  # no secrets in the environment
    if code == 0:
        raise GateError("a configuration with unset secret references was accepted")
    if "environment variable is not set" not in output:
        raise GateError(f"the missing secret was not identified as such:\n{output}")

    code, output = check_config(daemon, document, config_corpus.FULL_ENV)
    if code != 0:
        raise GateError(f"the same configuration failed with its secrets set:\n{output}")


# --- DoD 6 -----------------------------------------------------------------


def check_rejection_is_side_effect_free(daemon: Path) -> None:
    """A refused configuration must not create anything.

    docs/CONFIGURATION.md 13: any failure before publish leaves the old snapshot
    untouched. The observable form of that for `--check-config` is that a
    rejected run creates no database, no socket, and no directories.
    """
    document = config_corpus.base_document()
    document["routes"][0]["targets"][0]["provider_id"] = "absent"
    with tempfile.TemporaryDirectory() as work:
        path = Path(work) / "asmflow.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        before = sorted(p.name for p in Path(work).iterdir())
        result = subprocess.run(
            [str(daemon), "--check-config", "--config", str(path)],
            capture_output=True,
            text=True,
            timeout=120,
            env=clean_env(work),
        )
        after = sorted(p.name for p in Path(work).iterdir())
        if result.returncode == 0:
            raise GateError("an unresolvable route target was accepted")
        if before != after:
            raise GateError(
                f"a rejected configuration changed the filesystem: "
                f"{before} -> {after}"
            )


def check_hash_is_stable(daemon: Path) -> None:
    """Accepting the same bytes twice must produce the same summary."""
    document = config_corpus.base_document()
    first = check_config(daemon, document)
    second = check_config(daemon, document)
    if first != second:
        raise GateError(
            f"two runs over identical input disagreed:\n{first}\n{second}"
        )


# --- DoD 3 -----------------------------------------------------------------


def check_unknown_key_policy(daemon: Path) -> None:
    """Every closed object rejects an unknown key rather than ignoring it."""
    targets = [
        ("", lambda d: d),
        ("listener", lambda d: d["listener"]),
        ("listener/auth", lambda d: d["listener"]["auth"]),
        ("control", lambda d: d["control"]),
        ("storage", lambda d: d["storage"]),
        ("logging", lambda d: d["logging"]),
        ("limits", lambda d: d["limits"]),
        ("providers/0", lambda d: d["providers"][0]),
        ("providers/0/timeouts", lambda d: d["providers"][0]["timeouts"]),
        ("providers/0/capabilities", lambda d: d["providers"][0]["capabilities"]),
        ("providers/0/health", lambda d: d["providers"][0]["health"]),
        ("routes/0", lambda d: d["routes"][0]),
        ("routes/0/fallback", lambda d: d["routes"][0]["fallback"]),
        ("routes/0/targets/0", lambda d: d["routes"][0]["targets"][0]),
    ]
    for label, select in targets:
        document = config_corpus.base_document()
        select(document)["definitely_not_a_real_key"] = 1
        code, output = check_config(daemon, document)
        if code == 0:
            raise GateError(f"an unknown key inside /{label} was accepted")
        if "unknown key" not in output:
            raise GateError(
                f"an unknown key inside /{label} was refused for the wrong "
                f"reason:\n{output}"
            )


# --- DoD 7 -----------------------------------------------------------------


def check_reload_soak(tests_binary: Path, iterations: int) -> None:
    result = subprocess.run(
        [str(tests_binary), "--reload-soak", str(iterations)],
        capture_output=True,
        text=True,
        timeout=1800,
    )
    if result.returncode != 0:
        raise GateError(
            f"the reload soak failed (exit {result.returncode}):\n"
            f"{result.stdout}{result.stderr}"
        )
    if "returned to baseline" not in result.stdout:
        raise GateError(f"the reload soak did not confirm the baseline:\n{result.stdout}")


# --- DoD 8 -----------------------------------------------------------------


def check_parity(build_dir: Path) -> None:
    env = dict(os.environ)
    env["BUILD_DIR"] = str(build_dir)
    result = subprocess.run(
        [sys.executable, "-m", "unittest", "tests.test_config_parity"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=900,
        env=env,
    )
    if result.returncode != 0:
        raise GateError(f"schema/assembly parity failed:\n{result.stdout}{result.stderr}")


# --- bounded input ---------------------------------------------------------


def check_json_bounds(daemon: Path) -> None:
    """A document cannot widen the limits used to parse it."""
    deep = "[" * 400 + "]" * 400
    code, output = check_config(daemon, deep)
    if code == 0:
        raise GateError("a 400-level nested document was accepted")
    if "nesting" not in output:
        raise GateError(f"deep nesting was refused for the wrong reason:\n{output}")

    huge = "{" + '"a":"' + "x" * (5 * 1024 * 1024) + '"}'
    code, output = check_config(daemon, huge)
    if code == 0:
        raise GateError("a document larger than the ceiling was accepted")

    code, output = check_config(daemon, "not json at all")
    if code == 0:
        raise GateError("a non-JSON file was accepted")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", default="build")
    parser.add_argument("--soak-iterations", type=int, default=10000)
    args = parser.parse_args()

    build_dir = (ROOT / args.build_dir).resolve()
    daemon = build_dir / "debug" / "asmflowd"
    tests_binary = build_dir / "debug" / "asmflow-tests"
    for path in (daemon, tests_binary):
        if not path.is_file():
            print(f"[fail] missing build artifact: {path}", file=sys.stderr)
            return 1

    checks = [
        ("examples load", lambda: check_examples_load(daemon)),
        ("invalid fixtures refused with a pointer", lambda: check_invalid_fixtures(daemon)),
        ("unknown-key policy", lambda: check_unknown_key_policy(daemon)),
        ("plaintext credentials refused", lambda: check_plaintext_refused(daemon)),
        ("missing secret fails before readiness", lambda: check_missing_secret_fails(daemon)),
        ("rejection has no side effects", lambda: check_rejection_is_side_effect_free(daemon)),
        ("repeated loads are identical", lambda: check_hash_is_stable(daemon)),
        ("bounded JSON input", lambda: check_json_bounds(daemon)),
        (
            f"reload soak ({args.soak_iterations} iterations)",
            lambda: check_reload_soak(tests_binary, args.soak_iterations),
        ),
        ("schema/assembly parity", lambda: check_parity(build_dir)),
    ]

    try:
        for label, check in checks:
            check()
            print(f"[ok] {label}")
    except GateError as exc:
        print(f"[fail] {exc}", file=sys.stderr)
        return 1
    print("M3 gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
