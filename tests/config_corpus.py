"""Configuration corpus and a schema-faithful reference validator.

HARNESS.md M3 DoD 8 requires zero accept/reject disagreements between the JSON
Schema contract and the assembly validator. Standard-library-only Python cannot
run a JSON Schema, and adding a schema library would make the corpus depend on a
third-party implementation's interpretation rather than on the schema itself.

So this module does two things:

  * generates the corpus, by starting from a known-good configuration and
    applying one mutation at a time, each with the outcome the schema demands;
  * implements the schema's rules directly, in the same order, as an independent
    second opinion.

Two independent implementations of the same contract disagreeing is exactly the
signal the parity test exists to raise. Neither is "the" answer: a mismatch means
the schema, this file, or the assembly is wrong, and the test says which case.
"""
from __future__ import annotations

import copy
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]

ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
ENV_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")
ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")
HEADER_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")

LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}

CREDENTIAL_KEYS = {
    "api_key", "apikey", "secret", "password", "token", "authorization",
    "private_key", "credential", "credentials", "passphrase", "bearer",
}

ALLOWED_XDG = {
    "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
    "XDG_RUNTIME_DIR",
}


@dataclass
class Case:
    """One corpus entry: a document plus the outcome the contract requires."""

    name: str
    document: Any
    accepted: bool
    reason: str = ""
    # Environment needed for secret resolution to succeed. Absent variables are
    # a deployment failure, not a document failure, so they are kept separate.
    env: dict[str, str] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Reference validator
# ---------------------------------------------------------------------------


class Reject(Exception):
    def __init__(self, pointer: str, rule: str) -> None:
        super().__init__(f"{pointer}: {rule}")
        self.pointer = pointer
        self.rule = rule


def _obj(value: Any, pointer: str) -> dict:
    if not isinstance(value, dict):
        raise Reject(pointer, "value must be a JSON object")
    return value


def _keys(node: dict, allowed: set[str], pointer: str) -> None:
    for key in node:
        if key not in allowed:
            raise Reject(f"{pointer}/{key}", "unknown key is not permitted here")


def _req(node: dict, key: str, pointer: str) -> Any:
    if key not in node:
        raise Reject(f"{pointer}/{key}", "required key is absent")
    return node[key]


def _int(node: dict, key: str, low: int, high: int, pointer: str) -> int:
    value = _req(node, key, pointer)
    # bool is a subclass of int in Python; the schema does not accept one here.
    if not isinstance(value, int) or isinstance(value, bool):
        raise Reject(f"{pointer}/{key}", "value has the wrong JSON type")
    if not (low <= value <= high):
        raise Reject(f"{pointer}/{key}", "value is outside the permitted range")
    return value


def _str(node: dict, key: str, pointer: str) -> str:
    value = _req(node, key, pointer)
    if not isinstance(value, str):
        raise Reject(f"{pointer}/{key}", "value has the wrong JSON type")
    return value


def _bool(node: dict, key: str, pointer: str) -> bool:
    value = _req(node, key, pointer)
    if not isinstance(value, bool):
        raise Reject(f"{pointer}/{key}", "value has the wrong JSON type")
    return value


def _enum(node: dict, key: str, choices: set[str], pointer: str) -> str:
    value = _str(node, key, pointer)
    if value not in choices:
        raise Reject(f"{pointer}/{key}", "value is not one of the permitted choices")
    return value


def _array(node: dict, key: str, low: int, high: int, pointer: str) -> list:
    value = _req(node, key, pointer)
    if not isinstance(value, list):
        raise Reject(f"{pointer}/{key}", "value has the wrong JSON type")
    if not (low <= len(value) <= high):
        raise Reject(f"{pointer}/{key}", "value is outside the permitted range")
    return value


def _sweep_credentials(node: Any, pointer: str = "") -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if key.lower() in CREDENTIAL_KEYS:
                raise Reject(
                    f"{pointer}/{key}",
                    "plaintext credentials are not accepted in configuration",
                )
            _sweep_credentials(value, f"{pointer}/{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            _sweep_credentials(value, f"{pointer}/{index}")


def _check_path(value: str, pointer: str) -> None:
    """The allowlisted `${NAME}` grammar, and nothing else."""
    out = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch in "`\n\r\0":
            raise Reject(pointer, "path uses a forbidden expansion")
        if ch != "$":
            out.append(ch)
            i += 1
            continue
        if i + 1 >= len(value) or value[i + 1] != "{":
            raise Reject(pointer, "path uses a forbidden expansion")
        close = value.find("}", i + 2)
        if close < 0:
            raise Reject(pointer, "path uses a forbidden expansion")
        name = value[i + 2 : close]
        if not name or name not in ALLOWED_XDG:
            raise Reject(pointer, "path uses a forbidden expansion")
        out.append("/expanded")
        i = close + 1
    expanded = "".join(out)
    if not expanded.startswith("/"):
        raise Reject(pointer, "path is not absolute")
    parts = expanded.split("/")
    if ".." in parts:
        raise Reject(pointer, "path climbs")


def _check_url(value: str, allow_insecure: bool, pointer: str) -> bool:
    """Returns whether the host is loopback. Raises on any policy violation."""
    for ch in value:
        if ord(ch) < 0x21 or ord(ch) > 0x7E or ch == "#":
            raise Reject(pointer, "URL violates the outbound policy")
    if value.startswith("https://"):
        secure, rest = True, value[8:]
    elif value.startswith("http://"):
        secure, rest = False, value[7:]
    else:
        raise Reject(pointer, "URL violates the outbound policy")

    authority = rest
    for sep in ("/", "?"):
        index = authority.find(sep)
        if index >= 0:
            authority = authority[:index]
    if not authority:
        raise Reject(pointer, "URL violates the outbound policy")
    if "@" in authority:
        raise Reject(pointer, "URL violates the outbound policy")

    host = authority
    bracket = host.rfind("]")
    colon = host.rfind(":")
    if colon > bracket:
        host = host[:colon]
    if not host:
        raise Reject(pointer, "URL violates the outbound policy")

    loopback = host in LOOPBACK_HOSTS
    if not secure and not loopback and not allow_insecure:
        raise Reject(pointer, "URL violates the outbound policy")
    return loopback


def _check_auth(node: Any, pointer: str) -> tuple[str, str | None]:
    auth = _obj(node, pointer)
    auth_type = _enum(auth, "type", {"none", "bearer_env", "header_env"}, pointer)
    if auth_type == "none":
        _keys(auth, {"type"}, pointer)
        return auth_type, None
    if auth_type == "bearer_env":
        _keys(auth, {"type", "env"}, pointer)
        env = _str(auth, "env", pointer)
        if not ENV_RE.fullmatch(env) or len(env) > 128:
            raise Reject(f"{pointer}/env", "environment variable name is not permitted")
        return auth_type, env
    _keys(auth, {"type", "header", "value"}, pointer)
    header = _str(auth, "header", pointer)
    if not HEADER_RE.fullmatch(header):
        raise Reject(f"{pointer}/header", "header name is not permitted")
    ref = _obj(_req(auth, "value", pointer), f"{pointer}/value")
    _keys(ref, {"source", "name"}, f"{pointer}/value")
    _enum(ref, "source", {"env"}, f"{pointer}/value")
    name = _str(ref, "name", f"{pointer}/value")
    if not ENV_RE.fullmatch(name) or len(name) > 128:
        raise Reject(f"{pointer}/value/name", "environment variable name is not permitted")
    return auth_type, name


def _check_timeouts(node: Any, pointer: str) -> None:
    obj = _obj(node, pointer)
    _keys(obj, {"connect_ms", "request_ms", "idle_stream_ms"}, pointer)
    _int(obj, "connect_ms", 100, 600_000, pointer)
    _int(obj, "request_ms", 1000, 86_400_000, pointer)
    _int(obj, "idle_stream_ms", 1000, 3_600_000, pointer)


def validate(document: Any) -> None:
    """Raises Reject on the first rule the document breaks."""
    root = _obj(document, "")
    _sweep_credentials(root, "")
    _keys(
        root,
        {
            "schema_version", "listener", "control", "storage", "logging",
            "limits", "providers", "routes", "mcp_servers",
        },
        "",
    )
    version = _req(root, "schema_version", "")
    if version != 1:
        raise Reject("/schema_version", "schema_version must be 1")

    # --- listener ---
    listener = _obj(_req(root, "listener", ""), "/listener")
    _keys(
        listener,
        {
            "host", "port", "auth", "request_header_max_bytes",
            "request_body_max_bytes", "idle_timeout_ms",
            "expose_unavailable_models",
        },
        "/listener",
    )
    host = _str(listener, "host", "/listener")
    if not (1 <= len(host) <= 255):
        raise Reject("/listener/host", "value is outside the permitted range")
    _int(listener, "port", 1, 65535, "/listener")
    _int(listener, "request_header_max_bytes", 4096, 1_048_576, "/listener")
    _int(listener, "request_body_max_bytes", 1024, 67_108_864, "/listener")
    _int(listener, "idle_timeout_ms", 1000, 3_600_000, "/listener")
    if "expose_unavailable_models" in listener:
        _bool(listener, "expose_unavailable_models", "/listener")
    auth_type, _ = _check_auth(_req(listener, "auth", "/listener"), "/listener/auth")
    if host not in LOOPBACK_HOSTS and auth_type == "none":
        raise Reject(
            "/listener/auth",
            "a non-loopback listener requires an authentication policy",
        )

    # --- control ---
    control = _obj(_req(root, "control", ""), "/control")
    _keys(control, {"socket_path", "mode", "frame_max_bytes"}, "/control")
    _check_path(_str(control, "socket_path", "/control"), "/control/socket_path")
    _enum(control, "mode", {"0600"}, "/control")
    _int(control, "frame_max_bytes", 4096, 4_194_304, "/control")

    # --- storage ---
    storage = _obj(_req(root, "storage", ""), "/storage")
    _keys(
        storage,
        {
            "database_path", "journal_mode", "busy_timeout_ms",
            "request_metadata_retention_days", "store_payloads",
        },
        "/storage",
    )
    _check_path(_str(storage, "database_path", "/storage"), "/storage/database_path")
    _enum(storage, "journal_mode", {"wal"}, "/storage")
    _int(storage, "busy_timeout_ms", 0, 60_000, "/storage")
    _int(storage, "request_metadata_retention_days", 0, 3650, "/storage")
    _bool(storage, "store_payloads", "/storage")

    # --- logging ---
    logging_node = _obj(_req(root, "logging", ""), "/logging")
    _keys(
        logging_node,
        {
            "level", "format", "destination", "file_path",
            "include_request_metadata", "include_payloads", "redact_headers",
        },
        "/logging",
    )
    _enum(
        logging_node, "level",
        {"trace", "debug", "info", "warn", "error", "fatal"}, "/logging",
    )
    _enum(logging_node, "format", {"jsonl", "text"}, "/logging")
    destination = _enum(logging_node, "destination", {"stderr", "file"}, "/logging")
    _bool(logging_node, "include_request_metadata", "/logging")
    _bool(logging_node, "include_payloads", "/logging")
    if destination == "file":
        if "file_path" not in logging_node:
            raise Reject("/logging/file_path", "a file log destination requires file_path")
        _check_path(_str(logging_node, "file_path", "/logging"), "/logging/file_path")
    redact = _array(logging_node, "redact_headers", 0, 128, "/logging")
    seen_headers: set[str] = set()
    for index, header in enumerate(redact):
        pointer = f"/logging/redact_headers/{index}"
        if not isinstance(header, str) or not HEADER_RE.fullmatch(header):
            raise Reject(pointer, "header name is not permitted")
        if header in seen_headers:
            raise Reject(pointer, "duplicate entry")
        seen_headers.add(header)

    # --- limits ---
    limits = _obj(_req(root, "limits", ""), "/limits")
    _keys(
        limits,
        {
            "max_active_requests", "max_queued_requests", "json_max_depth",
            "json_string_max_bytes", "sse_event_max_bytes",
            "mcp_frame_max_bytes", "stderr_line_max_bytes",
        },
        "/limits",
    )
    _int(limits, "max_active_requests", 1, 65535, "/limits")
    _int(limits, "max_queued_requests", 0, 65535, "/limits")
    _int(limits, "json_max_depth", 4, 256, "/limits")
    _int(limits, "json_string_max_bytes", 1024, 67_108_864, "/limits")
    _int(limits, "sse_event_max_bytes", 1024, 16_777_216, "/limits")
    _int(limits, "mcp_frame_max_bytes", 1024, 67_108_864, "/limits")
    _int(limits, "stderr_line_max_bytes", 256, 1_048_576, "/limits")

    # --- providers ---
    providers = _array(root, "providers", 0, 256, "")
    provider_ids: list[str] = []
    provider_caps: list[set[str]] = []
    for index, entry in enumerate(providers):
        pointer = f"/providers/{index}"
        provider = _obj(entry, pointer)
        _keys(
            provider,
            {
                "id", "display_name", "adapter", "base_url", "auth", "enabled",
                "required", "max_concurrency", "timeouts", "capabilities",
                "health", "allow_insecure_private_http",
            },
            pointer,
        )
        identifier = _str(provider, "id", pointer)
        if not ID_RE.fullmatch(identifier):
            raise Reject(f"{pointer}/id", "identifier does not match the permitted pattern")
        if identifier in provider_ids:
            raise Reject(f"{pointer}/id", "identifier is already used by another entry")
        provider_ids.append(identifier)

        display = _str(provider, "display_name", pointer)
        if not (1 <= len(display) <= 128):
            raise Reject(f"{pointer}/display_name", "value is outside the permitted range")
        _enum(
            provider, "adapter",
            {"openai_responses", "openai_chat", "openai_dual"}, pointer,
        )
        allow_insecure = provider.get("allow_insecure_private_http", False)
        if not isinstance(allow_insecure, bool):
            raise Reject(
                f"{pointer}/allow_insecure_private_http",
                "value has the wrong JSON type",
            )
        base_url = _str(provider, "base_url", pointer)
        if not (1 <= len(base_url) <= 2048):
            raise Reject(f"{pointer}/base_url", "value is outside the permitted range")
        _check_url(base_url, allow_insecure, f"{pointer}/base_url")
        _bool(provider, "enabled", pointer)
        _bool(provider, "required", pointer)
        _int(provider, "max_concurrency", 1, 4096, pointer)
        _check_auth(_req(provider, "auth", pointer), f"{pointer}/auth")
        _check_timeouts(_req(provider, "timeouts", pointer), f"{pointer}/timeouts")

        caps = _obj(_req(provider, "capabilities", pointer), f"{pointer}/capabilities")
        cap_names = {
            "responses", "chat_completions", "streaming", "tools", "vision",
            "json_schema",
        }
        _keys(caps, cap_names, f"{pointer}/capabilities")
        enabled_caps = set()
        for cap in sorted(cap_names):
            if _bool(caps, cap, f"{pointer}/capabilities"):
                enabled_caps.add(cap)
        provider_caps.append(enabled_caps)

        health = _obj(_req(provider, "health", pointer), f"{pointer}/health")
        _keys(
            health,
            {
                "path", "interval_ms", "failure_threshold", "success_threshold",
                "open_cooldown_ms",
            },
            f"{pointer}/health",
        )
        health_path = _str(health, "path", f"{pointer}/health")
        if not health_path.startswith("/") or len(health_path) > 512:
            raise Reject(f"{pointer}/health/path", "health path must start with /")
        _int(health, "interval_ms", 1000, 3_600_000, f"{pointer}/health")
        _int(health, "failure_threshold", 1, 100, f"{pointer}/health")
        _int(health, "success_threshold", 1, 100, f"{pointer}/health")
        _int(health, "open_cooldown_ms", 1000, 3_600_000, f"{pointer}/health")

    # --- routes ---
    routes = _array(root, "routes", 0, 256, "")
    route_ids: list[str] = []
    aliases: list[str] = []
    for index, entry in enumerate(routes):
        pointer = f"/routes/{index}"
        route = _obj(entry, pointer)
        _keys(
            route,
            {
                "id", "model_alias", "enabled", "endpoint_families", "policy",
                "fallback", "targets",
            },
            pointer,
        )
        identifier = _str(route, "id", pointer)
        if not ID_RE.fullmatch(identifier):
            raise Reject(f"{pointer}/id", "identifier does not match the permitted pattern")
        if identifier in route_ids:
            raise Reject(f"{pointer}/id", "identifier is already used by another entry")
        route_ids.append(identifier)

        alias = _str(route, "model_alias", pointer)
        if not ALIAS_RE.fullmatch(alias):
            raise Reject(f"{pointer}/model_alias", "model alias does not match the permitted pattern")
        if alias in aliases:
            raise Reject(f"{pointer}/model_alias", "model alias is already used by another route")
        aliases.append(alias)

        _bool(route, "enabled", pointer)
        families = _array(route, "endpoint_families", 1, 2, pointer)
        seen_families: set[str] = set()
        for family_index, family in enumerate(families):
            family_pointer = f"{pointer}/endpoint_families/{family_index}"
            if family not in {"responses", "chat_completions"}:
                raise Reject(family_pointer, "value is not one of the permitted choices")
            if family in seen_families:
                raise Reject(family_pointer, "duplicate entry")
            seen_families.add(family)
        _enum(route, "policy", {"priority", "round_robin", "least_latency"}, pointer)

        targets = _array(route, "targets", 1, 64, pointer)
        resolved: list[int] = []
        for target_index, target_entry in enumerate(targets):
            target_pointer = f"{pointer}/targets/{target_index}"
            target = _obj(target_entry, target_pointer)
            _keys(
                target,
                {"provider_id", "upstream_model", "priority", "weight"},
                target_pointer,
            )
            provider_id = _str(target, "provider_id", target_pointer)
            if not ID_RE.fullmatch(provider_id):
                raise Reject(
                    f"{target_pointer}/provider_id",
                    "identifier does not match the permitted pattern",
                )
            if provider_id not in provider_ids:
                raise Reject(
                    f"{target_pointer}/provider_id",
                    "route target names a provider that does not exist",
                )
            resolved.append(provider_ids.index(provider_id))
            upstream = _str(target, "upstream_model", target_pointer)
            if not (1 <= len(upstream) <= 256):
                raise Reject(
                    f"{target_pointer}/upstream_model",
                    "value is outside the permitted range",
                )
            _int(target, "priority", -2_147_483_648, 2_147_483_647, target_pointer)
            _int(target, "weight", 1, 1_000_000, target_pointer)

        fallback = _obj(_req(route, "fallback", pointer), f"{pointer}/fallback")
        _keys(fallback, {"enabled", "max_attempts", "retryable"}, f"{pointer}/fallback")
        _bool(fallback, "enabled", f"{pointer}/fallback")
        attempts = _int(fallback, "max_attempts", 1, 16, f"{pointer}/fallback")
        if attempts > len(targets):
            raise Reject(
                f"{pointer}/fallback/max_attempts",
                "max_attempts exceeds the number of targets",
            )
        retryable = _array(fallback, "retryable", 0, 32, f"{pointer}/fallback")
        classes = {
            "connect_failed", "dns_failed", "connect_timeout", "http_502",
            "http_503", "http_504",
        }
        seen_classes: set[str] = set()
        for class_index, failure_class in enumerate(retryable):
            class_pointer = f"{pointer}/fallback/retryable/{class_index}"
            if failure_class not in classes:
                raise Reject(class_pointer, "value is not one of the permitted choices")
            if failure_class in seen_classes:
                raise Reject(class_pointer, "duplicate entry")
            seen_classes.add(failure_class)

        if "responses" in seen_families:
            if not any("responses" in provider_caps[i] for i in resolved):
                raise Reject(
                    f"{pointer}/targets",
                    "a responses route needs a target that advertises responses",
                )

    # --- mcp_servers ---
    servers = _array(root, "mcp_servers", 0, 256, "")
    server_ids: list[str] = []
    for index, entry in enumerate(servers):
        pointer = f"/mcp_servers/{index}"
        server = _obj(entry, pointer)
        transport = _enum(server, "transport", {"stdio", "streamable_http"}, pointer)
        if transport == "stdio":
            allowed = {
                "id", "display_name", "transport", "enabled", "required",
                "command", "args", "cwd", "env_allow", "env", "protocol",
                "restart", "startup_timeout_ms", "shutdown_grace_ms",
            }
        else:
            allowed = {
                "id", "display_name", "transport", "enabled", "required",
                "url", "auth", "protocol", "timeouts",
                "allow_insecure_private_http",
            }
        _keys(server, allowed, pointer)

        identifier = _str(server, "id", pointer)
        if not ID_RE.fullmatch(identifier):
            raise Reject(f"{pointer}/id", "identifier does not match the permitted pattern")
        if identifier in server_ids:
            raise Reject(f"{pointer}/id", "identifier is already used by another entry")
        server_ids.append(identifier)

        display = _str(server, "display_name", pointer)
        if not (1 <= len(display) <= 128):
            raise Reject(f"{pointer}/display_name", "value is outside the permitted range")
        _bool(server, "enabled", pointer)
        _bool(server, "required", pointer)

        protocol = _obj(_req(server, "protocol", pointer), f"{pointer}/protocol")
        _keys(protocol, {"preferred", "legacy"}, f"{pointer}/protocol")
        _enum(protocol, "preferred", {"2026-07-28"}, f"{pointer}/protocol")
        legacy = _array(protocol, "legacy", 0, 8, f"{pointer}/protocol")
        seen_legacy: set[str] = set()
        for legacy_index, revision in enumerate(legacy):
            legacy_pointer = f"{pointer}/protocol/legacy/{legacy_index}"
            if revision != "2025-11-25":
                raise Reject(legacy_pointer, "value is not one of the permitted choices")
            if revision in seen_legacy:
                raise Reject(legacy_pointer, "duplicate entry")
            seen_legacy.add(revision)

        if transport == "stdio":
            command = _str(server, "command", pointer)
            if not command.startswith("/") or len(command) > 4096:
                raise Reject(f"{pointer}/command", "command must be an absolute path")
            args = _array(server, "args", 0, 128, pointer)
            for arg_index, arg in enumerate(args):
                if not isinstance(arg, str) or len(arg) > 4096:
                    raise Reject(f"{pointer}/args/{arg_index}", "value has the wrong JSON type")
            cwd = _str(server, "cwd", pointer)
            if not (1 <= len(cwd) <= 4096):
                raise Reject(f"{pointer}/cwd", "value is outside the permitted range")
            env_allow = _array(server, "env_allow", 0, 128, pointer)
            seen_allow: set[str] = set()
            for allow_index, name in enumerate(env_allow):
                allow_pointer = f"{pointer}/env_allow/{allow_index}"
                if not isinstance(name, str) or not ENV_RE.fullmatch(name) or len(name) > 128:
                    raise Reject(allow_pointer, "environment variable name is not permitted")
                if name in seen_allow:
                    raise Reject(allow_pointer, "duplicate entry")
                seen_allow.add(name)
            env = _obj(_req(server, "env", pointer), f"{pointer}/env")
            if len(env) > 128:
                raise Reject(f"{pointer}/env", "value is outside the permitted range")
            for name, ref in env.items():
                env_pointer = f"{pointer}/env/{name}"
                if not ENV_RE.fullmatch(name) or len(name) > 128:
                    raise Reject(env_pointer, "environment variable name is not permitted")
                ref_obj = _obj(ref, env_pointer)
                _keys(ref_obj, {"source", "name"}, env_pointer)
                _enum(ref_obj, "source", {"env"}, env_pointer)
                source_name = _str(ref_obj, "name", env_pointer)
                if not ENV_RE.fullmatch(source_name) or len(source_name) > 128:
                    raise Reject(
                        f"{env_pointer}/name",
                        "environment variable name is not permitted",
                    )

            restart = _obj(_req(server, "restart", pointer), f"{pointer}/restart")
            _keys(
                restart,
                {"mode", "max_restarts", "window_ms", "backoff_ms", "max_backoff_ms"},
                f"{pointer}/restart",
            )
            _enum(restart, "mode", {"never", "on_failure", "always"}, f"{pointer}/restart")
            _int(restart, "max_restarts", 0, 100, f"{pointer}/restart")
            _int(restart, "window_ms", 1000, 86_400_000, f"{pointer}/restart")
            backoff = _int(restart, "backoff_ms", 0, 3_600_000, f"{pointer}/restart")
            max_backoff = _int(restart, "max_backoff_ms", 0, 3_600_000, f"{pointer}/restart")
            if max_backoff < backoff:
                raise Reject(
                    f"{pointer}/restart/max_backoff_ms",
                    "max_backoff_ms must be at least backoff_ms",
                )
            _int(server, "startup_timeout_ms", 100, 600_000, pointer)
            _int(server, "shutdown_grace_ms", 0, 600_000, pointer)
        else:
            allow_insecure = server.get("allow_insecure_private_http", False)
            if not isinstance(allow_insecure, bool):
                raise Reject(
                    f"{pointer}/allow_insecure_private_http",
                    "value has the wrong JSON type",
                )
            url = _str(server, "url", pointer)
            if not (1 <= len(url) <= 2048):
                raise Reject(f"{pointer}/url", "value is outside the permitted range")
            _check_url(url, allow_insecure, f"{pointer}/url")
            _check_auth(_req(server, "auth", pointer), f"{pointer}/auth")
            _check_timeouts(_req(server, "timeouts", pointer), f"{pointer}/timeouts")


def accepts(document: Any) -> tuple[bool, str]:
    try:
        validate(document)
    except Reject as reject:
        return False, f"{reject.pointer}: {reject.rule}"
    return True, ""


# ---------------------------------------------------------------------------
# Corpus
# ---------------------------------------------------------------------------


def base_document() -> dict:
    return json.loads((ROOT / "examples/asmflow.minimal.json").read_text(encoding="utf-8"))


def full_document() -> dict:
    return json.loads((ROOT / "examples/asmflow.full.json").read_text(encoding="utf-8"))


FULL_ENV = {
    "ASMFLOW_GATEWAY_TOKEN": "test-gateway-token",
    "OPENAI_API_KEY": "test-openai-key",
    "REMOTE_MCP_TOKEN": "test-remote-token",
    "FILESYSTEM_TOKEN": "test-filesystem-token",
}


def _mutate(name: str, accepted: bool, reason: str,
            change: Callable[[dict], None], *, base: dict | None = None,
            env: dict[str, str] | None = None) -> Case:
    document = copy.deepcopy(base if base is not None else base_document())
    change(document)
    return Case(name, document, accepted, reason, env or {})


def corpus() -> list[Case]:
    """Every entry is one deviation from a known-good document.

    Single mutations keep a failure attributable: when the assembly and the
    reference disagree, the case name is the rule they disagree about.
    """
    cases: list[Case] = [
        Case("baseline/minimal", base_document(), True, "the shipped minimal example"),
        Case("baseline/full", full_document(), True, "the shipped full example", FULL_ENV),
    ]

    def add(name: str, accepted: bool, reason: str, change, **kwargs) -> None:
        cases.append(_mutate(name, accepted, reason, change, **kwargs))

    # --- document shape ---
    add("root/unknown_key", False, "additionalProperties is false at the root",
        lambda d: d.__setitem__("extra", 1))
    add("root/missing_listener", False, "listener is required",
        lambda d: d.pop("listener"))
    add("root/schema_version_two", False, "schema_version is const 1",
        lambda d: d.__setitem__("schema_version", 2))
    add("root/schema_version_string", False, "schema_version must be an integer",
        lambda d: d.__setitem__("schema_version", "1"))

    # --- credentials ---
    add("secrets/plaintext_api_key", False, "credential-shaped keys are refused",
        lambda d: d["providers"][0].__setitem__("api_key", "sk-example"))
    add("secrets/plaintext_nested", False, "the sweep reaches nested objects",
        lambda d: d["listener"]["auth"].__setitem__("token", "x"))
    add("secrets/plaintext_uppercase", False, "the sweep is case-insensitive",
        lambda d: d["providers"][0].__setitem__("API_KEY", "x"))

    # --- listener ---
    add("listener/unknown_key", False, "additionalProperties is false",
        lambda d: d["listener"].__setitem__("typo", 1))
    add("listener/port_zero", False, "port minimum is 1",
        lambda d: d["listener"].__setitem__("port", 0))
    add("listener/port_max", True, "65535 is the maximum",
        lambda d: d["listener"].__setitem__("port", 65535))
    add("listener/port_over", False, "65536 exceeds the maximum",
        lambda d: d["listener"].__setitem__("port", 65536))
    add("listener/header_max_below", False, "request_header_max_bytes minimum is 4096",
        lambda d: d["listener"].__setitem__("request_header_max_bytes", 4095))
    add("listener/header_max_at", True, "4096 is permitted",
        lambda d: d["listener"].__setitem__("request_header_max_bytes", 4096))
    add("listener/nonloopback_without_auth", False,
        "a non-loopback listener requires authentication",
        lambda d: d["listener"].__setitem__("host", "0.0.0.0"))
    add("listener/nonloopback_with_auth", True,
        "a non-loopback listener with bearer auth is permitted",
        lambda d: (d["listener"].__setitem__("host", "0.0.0.0"),
                   d["listener"].__setitem__(
                       "auth", {"type": "bearer_env", "env": "ASMFLOW_GATEWAY_TOKEN"})),
        env={"ASMFLOW_GATEWAY_TOKEN": "t"})
    add("listener/ipv6_loopback", True, "::1 is loopback",
        lambda d: d["listener"].__setitem__("host", "::1"))
    add("listener/auth_none_with_env", False,
        "the none variant permits no other key",
        lambda d: d["listener"].__setitem__("auth", {"type": "none", "env": "X"}))
    add("listener/auth_unknown_type", False, "auth.type is an enum",
        lambda d: d["listener"].__setitem__("auth", {"type": "basic"}))
    add("listener/auth_bad_env_name", False, "env names are uppercase",
        lambda d: d["listener"].__setitem__(
            "auth", {"type": "bearer_env", "env": "lowercase"}))
    add("listener/auth_header_env", True, "the header_env variant is permitted",
        lambda d: d["listener"].__setitem__("auth", {
            "type": "header_env", "header": "X-Api-Key",
            "value": {"source": "env", "name": "ASMFLOW_GATEWAY_TOKEN"}}),
        env={"ASMFLOW_GATEWAY_TOKEN": "t"})
    add("listener/auth_header_colon", False, "a colon in a header name is refused",
        lambda d: d["listener"].__setitem__("auth", {
            "type": "header_env", "header": "X:Key",
            "value": {"source": "env", "name": "T"}}))
    add("listener/auth_secret_ref_file_source", False, "source is const env",
        lambda d: d["listener"].__setitem__("auth", {
            "type": "header_env", "header": "X-Api-Key",
            "value": {"source": "file", "name": "T"}}))

    # --- control and storage paths ---
    add("control/relative_socket_path", False, "a socket path must be absolute",
        lambda d: d["control"].__setitem__("socket_path", "control.sock"))
    add("control/command_substitution", False, "command substitution is refused",
        lambda d: d["control"].__setitem__("socket_path", "$(id)/control.sock"))
    add("control/bare_variable", False, "$VAR is refused",
        lambda d: d["control"].__setitem__("socket_path", "$HOME/control.sock"))
    add("control/unknown_variable", False, "only XDG names expand",
        lambda d: d["control"].__setitem__("socket_path", "${PATH}/control.sock"))
    add("control/mode_0644", False, "mode is const 0600",
        lambda d: d["control"].__setitem__("mode", "0644"))
    add("storage/path_climb", False, "a climbing path is refused",
        lambda d: d["storage"].__setitem__(
            "database_path", "${XDG_STATE_HOME}/../../etc/passwd"))
    add("storage/journal_delete", False, "journal_mode is const wal",
        lambda d: d["storage"].__setitem__("journal_mode", "delete"))
    add("storage/retention_zero", True, "zero retention is permitted",
        lambda d: d["storage"].__setitem__("request_metadata_retention_days", 0))

    # --- logging ---
    add("logging/file_without_path", False, "a file destination needs file_path",
        lambda d: d["logging"].__setitem__("destination", "file"))
    add("logging/file_with_path", True, "a file destination with a path is permitted",
        lambda d: (d["logging"].__setitem__("destination", "file"),
                   d["logging"].__setitem__("file_path", "/tmp/asmflow.log")))
    add("logging/bad_redact_header", False, "redact_headers members are header names",
        lambda d: d["logging"]["redact_headers"].append("bad header"))
    add("logging/duplicate_redact_header", False, "redact_headers is uniqueItems",
        lambda d: d["logging"]["redact_headers"].append("authorization"))
    add("logging/unknown_level", False, "level is an enum",
        lambda d: d["logging"].__setitem__("level", "verbose"))

    # --- limits ---
    add("limits/depth_below", False, "json_max_depth minimum is 4",
        lambda d: d["limits"].__setitem__("json_max_depth", 3))
    add("limits/depth_at", True, "4 is permitted",
        lambda d: d["limits"].__setitem__("json_max_depth", 4))
    add("limits/depth_over", False, "json_max_depth maximum is 256",
        lambda d: d["limits"].__setitem__("json_max_depth", 257))
    add("limits/queued_zero", True, "a zero queue is permitted",
        lambda d: d["limits"].__setitem__("max_queued_requests", 0))
    add("limits/active_zero", False, "max_active_requests minimum is 1",
        lambda d: d["limits"].__setitem__("max_active_requests", 0))

    # --- providers ---
    add("provider/uppercase_id", False, "identifiers are lowercase",
        lambda d: d["providers"][0].__setitem__("id", "Local"))
    add("provider/duplicate_id", False, "provider ids are unique",
        lambda d: d["providers"].append(copy.deepcopy(d["providers"][0])))
    add("provider/remote_plain_http", False, "plain http to a remote host is refused",
        lambda d: d["providers"][0].__setitem__("base_url", "http://example.invalid/v1"))
    add("provider/remote_plain_http_allowed", True,
        "an explicit exception permits plain http",
        lambda d: (d["providers"][0].__setitem__("base_url", "http://example.invalid/v1"),
                   d["providers"][0].__setitem__("allow_insecure_private_http", True)))
    add("provider/url_with_credentials", False, "embedded credentials are refused",
        lambda d: d["providers"][0].__setitem__(
            "base_url", "https://user:pass@example.invalid/v1"))
    add("provider/url_with_fragment", False, "a fragment is refused",
        lambda d: d["providers"][0].__setitem__(
            "base_url", "https://example.invalid/v1#x"))
    add("provider/url_bad_scheme", False, "only http and https are accepted",
        lambda d: d["providers"][0].__setitem__("base_url", "ftp://example.invalid/v1"))
    add("provider/unknown_adapter", False, "adapter is an enum",
        lambda d: d["providers"][0].__setitem__("adapter", "anthropic"))
    add("provider/missing_capability", False, "every capability flag is required",
        lambda d: d["providers"][0]["capabilities"].pop("vision"))
    add("provider/extra_capability", False, "capabilities is closed",
        lambda d: d["providers"][0]["capabilities"].__setitem__("audio", True))
    add("provider/health_path_relative", False, "a health path starts with /",
        lambda d: d["providers"][0]["health"].__setitem__("path", "models"))
    add("provider/concurrency_zero", False, "max_concurrency minimum is 1",
        lambda d: d["providers"][0].__setitem__("max_concurrency", 0))
    add("provider/connect_timeout_below", False, "connect_ms minimum is 100",
        lambda d: d["providers"][0]["timeouts"].__setitem__("connect_ms", 99))
    add("provider/empty_display_name", False, "display_name has minLength 1",
        lambda d: d["providers"][0].__setitem__("display_name", ""))

    # --- routes ---
    add("route/unknown_provider", False, "a target must name a real provider",
        lambda d: d["routes"][0]["targets"][0].__setitem__("provider_id", "absent"))
    add("route/duplicate_alias", False, "model aliases are unique",
        lambda d: d["routes"].append({
            **copy.deepcopy(d["routes"][0]), "id": "second-route"}))
    add("route/duplicate_id", False, "route ids are unique",
        lambda d: d["routes"].append({
            **copy.deepcopy(d["routes"][0]), "model_alias": "other"}))
    add("route/no_targets", False, "at least one target is required",
        lambda d: d["routes"][0].__setitem__("targets", []))
    add("route/attempts_exceed_targets", False,
        "max_attempts cannot exceed the target count",
        lambda d: d["routes"][0]["fallback"].__setitem__("max_attempts", 2))
    add("route/no_endpoint_families", False, "endpoint_families has minItems 1",
        lambda d: d["routes"][0].__setitem__("endpoint_families", []))
    add("route/duplicate_family", False, "endpoint_families is uniqueItems",
        lambda d: d["routes"][0].__setitem__(
            "endpoint_families", ["chat_completions", "chat_completions"]))
    add("route/unknown_policy", False, "policy is an enum",
        lambda d: d["routes"][0].__setitem__("policy", "random"))
    add("route/unknown_retry_class", False, "retryable members are an enum",
        lambda d: d["routes"][0]["fallback"].__setitem__("retryable", ["http_418"]))
    add("route/duplicate_retry_class", False, "retryable is uniqueItems",
        lambda d: d["routes"][0]["fallback"].__setitem__(
            "retryable", ["http_502", "http_502"]))
    add("route/alias_with_space", False, "aliases have no spaces",
        lambda d: d["routes"][0].__setitem__("model_alias", "has space"))
    add("route/responses_without_capable_target", False,
        "a responses route needs a responses-capable target",
        lambda d: d["routes"][0].__setitem__(
            "endpoint_families", ["responses"]))
    add("route/responses_with_capable_target", True,
        "the same route is valid once the provider advertises responses",
        lambda d: (d["routes"][0].__setitem__("endpoint_families", ["responses"]),
                   d["providers"][0]["capabilities"].__setitem__("responses", True)))
    add("route/weight_zero", False, "weight minimum is 1",
        lambda d: d["routes"][0]["targets"][0].__setitem__("weight", 0))
    add("route/negative_priority", True, "priority may be negative",
        lambda d: d["routes"][0]["targets"][0].__setitem__("priority", -5))
    add("route/empty_upstream_model", False, "upstream_model has minLength 1",
        lambda d: d["routes"][0]["targets"][0].__setitem__("upstream_model", ""))

    # --- MCP servers ---
    stdio_server = {
        "id": "filesystem", "display_name": "Filesystem MCP", "transport": "stdio",
        "enabled": False, "required": False, "command": "/usr/bin/node",
        "args": ["/opt/mcp/server.js"], "cwd": "/opt/mcp",
        "env_allow": ["PATH", "HOME"], "env": {},
        "protocol": {"preferred": "2026-07-28", "legacy": ["2025-11-25"]},
        "restart": {"mode": "on_failure", "max_restarts": 3, "window_ms": 60000,
                    "backoff_ms": 1000, "max_backoff_ms": 30000},
        "startup_timeout_ms": 10000, "shutdown_grace_ms": 3000,
    }
    http_server = {
        "id": "remote-search", "display_name": "Remote Search MCP",
        "transport": "streamable_http", "enabled": False, "required": False,
        "url": "https://mcp.example.invalid/mcp",
        "auth": {"type": "bearer_env", "env": "REMOTE_MCP_TOKEN"},
        "protocol": {"preferred": "2026-07-28", "legacy": []},
        "timeouts": {"connect_ms": 3000, "request_ms": 30000,
                     "idle_stream_ms": 30000},
    }

    add("mcp/stdio_valid", True, "a well-formed stdio server is accepted",
        lambda d: d["mcp_servers"].append(copy.deepcopy(stdio_server)))
    add("mcp/http_valid", True, "a well-formed HTTP server is accepted",
        lambda d: d["mcp_servers"].append(copy.deepcopy(http_server)),
        env={"REMOTE_MCP_TOKEN": "t"})
    add("mcp/stdio_relative_command", False, "command must be absolute",
        lambda d: d["mcp_servers"].append(
            {**copy.deepcopy(stdio_server), "command": "node"}))
    add("mcp/stdio_with_url", False, "url is not a stdio field",
        lambda d: d["mcp_servers"].append(
            {**copy.deepcopy(stdio_server), "url": "https://x.invalid/mcp"}))
    add("mcp/http_with_command", False, "command is not an HTTP field",
        lambda d: d["mcp_servers"].append(
            {**copy.deepcopy(http_server), "command": "/usr/bin/node"}))
    add("mcp/http_plain_remote", False, "plain http to a remote MCP is refused",
        lambda d: d["mcp_servers"].append(
            {**copy.deepcopy(http_server), "url": "http://mcp.example.invalid/mcp"}),
        env={"REMOTE_MCP_TOKEN": "t"})
    add("mcp/backoff_ceiling_below_floor", False,
        "max_backoff_ms must be at least backoff_ms",
        lambda d: d["mcp_servers"].append({
            **copy.deepcopy(stdio_server),
            "restart": {**stdio_server["restart"], "backoff_ms": 5000,
                        "max_backoff_ms": 1000}}))
    add("mcp/unknown_preferred_version", False, "preferred is an enum",
        lambda d: d["mcp_servers"].append({
            **copy.deepcopy(stdio_server),
            "protocol": {"preferred": "2027-01-01", "legacy": []}}))
    add("mcp/unknown_legacy_version", False, "legacy members are an enum",
        lambda d: d["mcp_servers"].append({
            **copy.deepcopy(stdio_server),
            "protocol": {"preferred": "2026-07-28", "legacy": ["2024-11-05"]}}))
    add("mcp/bad_env_allow_name", False, "env_allow members are env names",
        lambda d: d["mcp_servers"].append({
            **copy.deepcopy(stdio_server), "env_allow": ["path"]}))
    add("mcp/duplicate_env_allow", False, "env_allow is uniqueItems",
        lambda d: d["mcp_servers"].append({
            **copy.deepcopy(stdio_server), "env_allow": ["PATH", "PATH"]}))
    add("mcp/env_secret_ref", True, "an env SecretRef is accepted",
        lambda d: d["mcp_servers"].append({
            **copy.deepcopy(stdio_server),
            "env": {"FS_TOKEN": {"source": "env", "name": "FILESYSTEM_TOKEN"}}}),
        env={"FILESYSTEM_TOKEN": "t"})
    add("mcp/env_bad_child_name", False, "the child variable name is validated",
        lambda d: d["mcp_servers"].append({
            **copy.deepcopy(stdio_server),
            "env": {"lower": {"source": "env", "name": "FILESYSTEM_TOKEN"}}}))
    add("mcp/duplicate_id", False, "MCP ids are unique",
        lambda d: d["mcp_servers"].extend([
            copy.deepcopy(stdio_server), copy.deepcopy(stdio_server)]))
    add("mcp/shell_metacharacters_in_args", True,
        "args are literal strings, so metacharacters are data",
        lambda d: d["mcp_servers"].append({
            **copy.deepcopy(stdio_server),
            "args": ["; rm -rf /", "$(whoami)", "`id`", "a|b", "x&&y"]}))

    return cases
