#!/usr/bin/env python3
"""Repository-level validation for the AsmFlow specification scaffold.

This script intentionally uses only the Python standard library so a clean checkout
can validate the repository without installing project dependencies.
"""
from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]

REQUIRED_ROOT_FILES = {
    "README.md",
    ".gitattributes",
    "LICENSE",
    "NOTICE",
    "CONTRIBUTING.md",
    "CODE_OF_CONDUCT.md",
    "SECURITY.md",
    "CHANGELOG.md",
    "ROADMAP.md",
    "ARCHITECTURE.md",
    "HARNESS.md",
    "AGENTS.md",
    "PROGRESS.md",
    "Makefile",
    "VERSION",
}

REQUIRED_DIRECTORIES = {
    ".github",
    "config",
    "docs",
    "examples",
    "include",
    "packaging",
    "scripts",
    "src",
    "tests",
}

REQUIRED_DOCS = {
    "docs/README.md",
    "docs/TECHNICAL_WHITEPAPER_KR.md",
    "docs/DESIGN_WHITEPAPER_KR.md",
    "docs/API_CONTRACT.md",
    "docs/BUILD_AND_RELEASE.md",
    "docs/CONFIGURATION.md",
    "docs/FILE_TREE.md",
    "docs/GLOSSARY.md",
    "docs/MCP_COMPATIBILITY.md",
    "docs/SECURITY_MODEL.md",
    "docs/TEST_STRATEGY.md",
}

REQUIRED_GITHUB_FILES = {
    ".github/workflows/ci.yml",
    ".github/ISSUE_TEMPLATE/bug_report.yml",
    ".github/ISSUE_TEMPLATE/feature_request.yml",
    ".github/ISSUE_TEMPLATE/config.yml",
    ".github/pull_request_template.md",
    ".github/dependabot.yml",
}

REQUIRED_SOURCE_BOUNDARIES = {
    "src/platform/linux_x86_64",
    "src/memory",
    "src/core",
    "src/json",
    "src/http",
    "src/providers",
    "src/routing",
    "src/mcp",
    "src/storage",
    "src/control",
    "src/tui",
    "src/ffi",
}

TEMPLATE_MARKERS = (
    "{{",
    "}}",
    "[프로젝트 명]",
    "[YYYY",
    "[작성자/팀 명]",
    "[개발팀/작성자 명]",
    "*(가이드:",
)

SECRET_KEY_NAMES = {
    "api_key",
    "apikey",
    "secret",
    "password",
    "token",
    "authorization",
    "private_key",
}

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
ENV_NAME_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")


class ValidationError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ValidationError(message)


def require_paths(paths: Iterable[str], *, kind: str) -> None:
    for relative in sorted(paths):
        path = ROOT / relative
        if kind == "file" and not path.is_file():
            fail(f"required file is missing: {relative}")
        if kind == "directory" and not path.is_dir():
            fail(f"required directory is missing: {relative}")


def iter_text_files() -> Iterable[Path]:
    allowed = {".md", ".txt"}
    excluded_parts = {".git", "dist", "build", "__pycache__"}
    for path in ROOT.rglob("*"):
        if not path.is_file() or any(part in excluded_parts for part in path.parts):
            continue
        if path.suffix.lower() in allowed or path.name in {"Makefile", "VERSION", "LICENSE", "NOTICE"}:
            yield path


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"invalid JSON: {path.relative_to(ROOT)}: {exc}")


def walk_json(value: Any, path: tuple[str, ...] = ()) -> Iterable[tuple[tuple[str, ...], Any]]:
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk_json(child, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk_json(child, path + (str(index),))


def check_layout() -> None:
    require_paths(REQUIRED_ROOT_FILES | REQUIRED_DOCS | REQUIRED_GITHUB_FILES, kind="file")
    require_paths(REQUIRED_DIRECTORIES | REQUIRED_SOURCE_BOUNDARIES, kind="directory")


def check_version() -> None:
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if not VERSION_RE.fullmatch(version):
        fail(f"VERSION is not SemVer-compatible: {version!r}")
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    if version not in readme:
        fail("README.md must state the current specification version")


def check_license() -> None:
    license_text = (ROOT / "LICENSE").read_text(encoding="utf-8", errors="strict")
    required_fragments = (
        "Apache License",
        "Version 2.0, January 2004",
        "http://www.apache.org/licenses/",
        "END OF TERMS AND CONDITIONS",
    )
    for fragment in required_fragments:
        if fragment not in license_text:
            fail(f"LICENSE is not a complete Apache-2.0 text; missing {fragment!r}")
    notice = (ROOT / "NOTICE").read_text(encoding="utf-8")
    if "AsmFlow" not in notice or "Apache License, Version 2.0" not in notice:
        fail("NOTICE must identify AsmFlow and Apache-2.0")


def check_template_markers() -> None:
    for path in iter_text_files():
        if path.name == "LICENSE":
            continue
        text = path.read_text(encoding="utf-8", errors="strict")
        for marker in TEMPLATE_MARKERS:
            if marker in text:
                fail(f"unresolved template marker {marker!r} in {path.relative_to(ROOT)}")


def check_json_files() -> None:
    for path in ROOT.rglob("*.json"):
        if any(part in {"dist", "build", ".git"} for part in path.parts):
            continue
        load_json(path)


def check_examples() -> None:
    example_paths = [
        ROOT / "examples/asmflow.minimal.json",
        ROOT / "examples/asmflow.full.json",
    ]
    for path in example_paths:
        config = load_json(path)
        if config.get("schema_version") != 1:
            fail(f"{path.relative_to(ROOT)} must use schema_version 1")

        provider_ids = [provider.get("id") for provider in config.get("providers", [])]
        if not provider_ids or len(provider_ids) != len(set(provider_ids)):
            fail(f"provider IDs must be non-empty and unique in {path.relative_to(ROOT)}")

        route_ids = [route.get("id") for route in config.get("routes", [])]
        if not route_ids or len(route_ids) != len(set(route_ids)):
            fail(f"route IDs must be non-empty and unique in {path.relative_to(ROOT)}")

        for route in config.get("routes", []):
            targets = route.get("targets", [])
            if not targets:
                fail(f"route {route.get('id')!r} has no targets in {path.relative_to(ROOT)}")
            max_attempts = route.get("fallback", {}).get("max_attempts")
            if not isinstance(max_attempts, int) or not (1 <= max_attempts <= len(targets)):
                fail(f"route {route.get('id')!r} has invalid max_attempts")
            for target in targets:
                if target.get("provider_id") not in provider_ids:
                    fail(
                        f"route {route.get('id')!r} references an unknown provider "
                        f"{target.get('provider_id')!r}"
                    )

        for json_path, node in walk_json(config):
            if not isinstance(node, dict):
                continue
            for key in node:
                if key.lower() in SECRET_KEY_NAMES:
                    rendered = ".".join(json_path + (key,))
                    fail(f"plaintext secret-shaped key in safe example: {rendered}")
            if node.get("source") == "env":
                name = node.get("name")
                if not isinstance(name, str) or not ENV_NAME_RE.fullmatch(name):
                    fail(f"invalid environment SecretRef at {'.'.join(json_path)}")

    minimal = load_json(example_paths[0])
    listener = minimal.get("listener", {})
    if listener.get("auth", {}).get("type") == "none" and listener.get("host") not in {
        "127.0.0.1",
        "::1",
        "localhost",
    }:
        fail("an unauthenticated example listener must be loopback-only")


def check_contract_fixtures() -> None:
    modern = load_json(ROOT / "tests/fixtures/mcp/discover_request_2026-07-28.json")
    meta = modern.get("params", {}).get("_meta", {})
    if meta.get("io.modelcontextprotocol/protocolVersion") != "2026-07-28":
        fail("modern MCP discovery fixture lacks 2026-07-28 per-request metadata")

    legacy = load_json(ROOT / "tests/fixtures/mcp/initialize_request_2025-11-25.json")
    if legacy.get("method") != "initialize":
        fail("legacy MCP compatibility fixture must use initialize")

    for path in sorted((ROOT / "tests/fixtures/openai").glob("*.sse")):
        for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not raw_line.startswith("data:"):
                continue
            payload = raw_line.removeprefix("data:").strip()
            if not payload or payload == "[DONE]":
                continue
            try:
                parsed = json.loads(payload)
            except json.JSONDecodeError as exc:
                fail(f"invalid SSE JSON in {path.relative_to(ROOT)}:{line_number}: {exc}")
            if not isinstance(parsed, dict):
                fail(f"SSE data must decode to an object in {path.relative_to(ROOT)}:{line_number}")


def git_recorded_modes() -> dict[str, int] | None:
    """The executable bit as git recorded it, or None outside a work tree.

    The filesystem mode cannot be trusted: a checkout on a Windows drive reports
    every file as 0777, so a script that lost its bit in the index still looks
    executable locally and only fails on a Linux CI checkout. What git stores is
    the same everywhere, so that is what this checks when it is available.
    """
    try:
        result = subprocess.run(
            ["git", "ls-files", "--stage", "--", "scripts", "examples", "tests"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    modes: dict[str, int] = {}
    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=3)
        if len(fields) == 4:
            modes[fields[3].strip()] = int(fields[0], 8)
    return modes


def git_untracked_paths() -> set[str] | None:
    """Return unignored working-tree paths, or None outside a work tree."""
    try:
        result = subprocess.run(
            [
                "git",
                "ls-files",
                "--others",
                "--exclude-standard",
                "--",
                "scripts",
                "examples",
                "tests",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def check_scripts() -> None:
    """Anything carrying a shebang must be executable.

    Deriving the list from the shebang rather than from a hard-coded list means
    a new gate script cannot be added without its bit. Tracked scripts use the
    index mode; an untracked, unignored script uses its working-tree mode so the
    repository gate can run before the milestone change is committed.
    """
    candidates = sorted(
        list(ROOT.glob("scripts/*.py"))
        + list(ROOT.glob("scripts/*.sh"))
        + list(ROOT.glob("examples/*.sh"))
        + list(ROOT.glob("tests/mock_*.py"))
    )
    if not candidates:
        fail("no scripts were found to check")
    recorded = git_recorded_modes()
    untracked = git_untracked_paths() if recorded is not None else None
    for path in candidates:
        if path.read_bytes()[:2] != b"#!":
            continue
        relative = path.relative_to(ROOT).as_posix()
        if recorded is not None and relative in recorded:
            if not recorded[relative] & 0o111:
                fail(
                    f"script is not executable in the git index: {relative} "
                    f"(fix with: git update-index --chmod=+x {relative})"
                )
            continue
        if recorded is not None and (untracked is None or relative not in untracked):
            fail(
                "script is neither tracked nor an unignored working-tree file: "
                f"{relative}"
            )
        if not path.stat().st_mode & stat.S_IXUSR:
            fail(f"script is not executable: {relative}")


DEFINE_RE = re.compile(r"\s*%i?define\s+([A-Za-z_][A-Za-z0-9_]*)(?![\w(])")


def macro_definitions(path: Path) -> list[tuple[str, int]]:
    found = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = DEFINE_RE.match(line)
        if match:
            found.append((match.group(1), number))
    return found


def check_macro_namespace() -> None:
    """No macro name may be defined twice.

    NASM lets a later %define silently replace an earlier one, so two headers
    that happen to pick the same name produce a translation unit where the
    meaning depends on include order and nothing warns. That is not theoretical:
    `runtime.inc` and `config.inc` both defined RT_SIZE, and the one file that
    included both walked an array of 40-byte records with a stride of 96 and
    crashed the daemon. The include directory is one flat namespace, so this
    check treats it as one.
    """
    owner: dict[str, str] = {}
    for path in sorted((ROOT / "include").glob("*.inc")):
        for name, number in macro_definitions(path):
            where = f"{path.relative_to(ROOT).as_posix()}:{number}"
            if name in owner:
                fail(
                    f"macro {name} is defined twice: {owner[name]} and {where}. "
                    f"Headers share one namespace; give one of them its own prefix."
                )
            owner[name] = where

    sources = sorted(
        list((ROOT / "src").rglob("*.asm")) + list((ROOT / "tests").rglob("*.asm"))
    )
    for path in sources:
        for name, number in macro_definitions(path):
            if name in owner:
                fail(
                    f"{path.relative_to(ROOT).as_posix()}:{number} redefines {name}, "
                    f"which {owner[name]} already defines"
                )


def check_size_and_binary_policy() -> None:
    allowed_binary_suffixes = {".png", ".jpg", ".jpeg", ".webp", ".gif"}
    for path in ROOT.rglob("*"):
        if not path.is_file() or any(part in {".git", "dist", "build", "__pycache__"} for part in path.parts):
            continue
        if path.stat().st_size > 2 * 1024 * 1024:
            fail(f"unexpected file larger than 2 MiB: {path.relative_to(ROOT)}")
        if path.suffix.lower() in allowed_binary_suffixes:
            continue
        sample = path.read_bytes()[:4096]
        if b"\x00" in sample:
            fail(f"unexpected binary file in source scaffold: {path.relative_to(ROOT)}")


def check_status_disclosure() -> None:
    """The README must disclose the real implementation state, not a target.

    Rather than pinning one sentence that goes stale the moment a milestone
    lands, this ties the README to `PROGRESS.md`: the phase named there is the
    single source of truth, and the README has to repeat it verbatim. A
    milestone that advances PROGRESS.md without touching the README fails here.
    """
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for fragment in ("**Project status:**", "Apache License 2.0"):
        if fragment not in readme:
            fail(f"README.md is missing required project-status disclosure: {fragment!r}")

    progress = (ROOT / "PROGRESS.md").read_text(encoding="utf-8")
    match = re.search(r"^## Current phase\s*\n+`([^`]+)`", progress, re.MULTILINE)
    if not match:
        fail("PROGRESS.md must name the current phase as `## Current phase` + a code span")
    phase = match.group(1).strip()
    if phase not in readme:
        fail(
            "README.md does not state the current phase from PROGRESS.md: "
            f"{phase!r}. Update both in the same change."
        )


def main() -> int:
    checks = [
        ("layout", check_layout),
        ("version", check_version),
        ("license", check_license),
        ("template markers", check_template_markers),
        ("JSON", check_json_files),
        ("examples", check_examples),
        ("contract fixtures", check_contract_fixtures),
        ("scripts", check_scripts),
        ("macro namespace", check_macro_namespace),
        ("size/binary policy", check_size_and_binary_policy),
        ("status disclosure", check_status_disclosure),
    ]
    try:
        for label, check in checks:
            check()
            print(f"[ok] {label}")
    except ValidationError as exc:
        print(f"[fail] {exc}", file=sys.stderr)
        return 1
    print(f"Validated AsmFlow scaffold at {ROOT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
