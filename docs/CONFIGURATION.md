# AsmFlow Configuration Contract

Configuration is JSON because the runtime already requires bounded JSON parsing for OpenAI and MCP
traffic. It avoids adding a second complex parser to the assembly codebase. The normative machine
schema is `config/asmflow.schema.json`.

## 1. Location and permissions

Default path:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/asmflow/asmflow.json
```

The immediate parent directory must be owned by the daemon user with mode exactly
`0700`. The file must be an owner-readable regular file owned by that user, with no
group/world permission bits (`0400` or `0600` are the normal choices). Symlinks, FIFOs,
device nodes, unsafe modes, and different owners are rejected before parsing; the daemon
does not broaden or silently repair an existing object.

For example:

```bash
install -d -m 0700 "${XDG_CONFIG_HOME:-$HOME/.config}/asmflow"
install -m 0600 examples/asmflow.minimal.json \
  "${XDG_CONFIG_HOME:-$HOME/.config}/asmflow/asmflow.json"
```

CLI override:

```bash
asmflowd --config /path/to/asmflow.json
```

The path itself is not accepted from data-plane requests.

## 2. Top-level shape

```json
{
  "schema_version": 1,
  "listener": {},
  "control": {},
  "storage": {},
  "logging": {},
  "limits": {},
  "providers": [],
  "routes": [],
  "mcp_servers": []
}
```

`schema_version` is mandatory. Unknown top-level keys are rejected.

## 3. Secrets

Plaintext credentials are forbidden.

Valid:

```json
"auth": {
  "type": "bearer_env",
  "env": "OPENAI_API_KEY"
}
```

Invalid:

```json
"api_key": "sk-example"
```

Rules:

- Environment variable names match `^[A-Z_][A-Z0-9_]*$` by default.
- The value is resolved at daemon startup and config reload.
- The value is never written to SQLite, logs, control snapshots, or diagnostics.
- Missing required secrets make affected providers ineligible; when marked required, readiness fails.
- Command-line secret values are not supported because process listings may expose them.

## 4. Listener

```json
{
  "listener": {
    "host": "127.0.0.1",
    "port": 8080,
    "auth": {"type": "none"},
    "request_header_max_bytes": 65536,
    "request_body_max_bytes": 8388608,
    "idle_timeout_ms": 30000
  }
}
```

Non-loopback host requires auth:

```json
"auth": {
  "type": "bearer_env",
  "env": "ASMFLOW_GATEWAY_TOKEN"
}
```

TLS termination is expected at a trusted local reverse proxy in 1.0. Direct TLS listener support is
not part of the first release.

## 5. Control socket

```json
{
  "control": {
    "socket_path": "${XDG_RUNTIME_DIR}/asmflow/control.sock",
    "mode": "0600",
    "frame_max_bytes": 1048576
  }
}
```

Only a small allowlisted variable expansion is permitted for XDG paths. Arbitrary shell expansion,
command substitution, and `~user` expansion are forbidden.

## 6. Storage

```json
{
  "storage": {
    "database_path": "${XDG_STATE_HOME}/asmflow/asmflow.db",
    "journal_mode": "wal",
    "busy_timeout_ms": 3000,
    "request_metadata_retention_days": 30,
    "store_payloads": false
  }
}
```

`store_payloads` defaults to false. Enabling it requires an explicit warning in TUI and documentation;
even then Authorization and secret headers remain excluded.

The database's immediate parent is created as `0700` when absent. An existing parent
must already be owned by the daemon user with mode exactly `0700`; it is never repaired.
An existing database must be an owner-readable/writable regular file with no group/world
permission bits and must not be a symlink. New database, WAL, and SHM files are created
under a process-wide `0077` umask (normally mode `0600`).

## 7. Logging

```json
{
  "logging": {
    "level": "info",
    "format": "jsonl",
    "destination": "stderr",
    "include_request_metadata": true,
    "include_payloads": false,
    "redact_headers": [
      "authorization",
      "proxy-authorization",
      "cookie",
      "set-cookie"
    ]
  }
}
```

Custom provider or MCP auth headers are automatically added to the redaction registry.

## 8. Global limits

```json
{
  "limits": {
    "max_active_requests": 256,
    "max_queued_requests": 512,
    "json_max_depth": 64,
    "json_string_max_bytes": 4194304,
    "sse_event_max_bytes": 1048576,
    "mcp_frame_max_bytes": 4194304,
    "stderr_line_max_bytes": 65536
  }
}
```

No limit may be zero to mean unlimited. An explicit documented maximum is always required.

## 9. Providers

```json
{
  "id": "local-ollama",
  "display_name": "Local Ollama",
  "adapter": "openai_chat",
  "base_url": "http://127.0.0.1:11434/v1",
  "auth": {"type": "none"},
  "enabled": true,
  "required": false,
  "max_concurrency": 4,
  "timeouts": {
    "connect_ms": 2000,
    "request_ms": 120000,
    "idle_stream_ms": 30000
  },
  "capabilities": {
    "responses": false,
    "chat_completions": true,
    "streaming": true,
    "tools": true,
    "vision": false,
    "json_schema": false
  },
  "health": {
    "path": "/models",
    "interval_ms": 10000,
    "failure_threshold": 3,
    "success_threshold": 2,
    "open_cooldown_ms": 30000
  }
}
```

### Provider URL rules

- `https` accepted for remote hosts.
- `http` accepted for loopback by default.
- Private-network HTTP requires explicit `allow_insecure_private_http=true` and exact host allowlist.
- Embedded credentials (`https://user:pass@host`) are rejected.
- Fragments are rejected.
- Redirects are disabled by default; if enabled, same-origin only.

## 10. Routes

```json
{
  "id": "general-route",
  "model_alias": "general",
  "enabled": true,
  "endpoint_families": ["responses", "chat_completions"],
  "policy": "priority",
  "fallback": {
    "enabled": true,
    "max_attempts": 2,
    "retryable": [
      "connect_failed",
      "connect_timeout",
      "http_502",
      "http_503",
      "http_504"
    ]
  },
  "targets": [
    {
      "provider_id": "openai-primary",
      "upstream_model": "gpt-example",
      "priority": 10,
      "weight": 1
    },
    {
      "provider_id": "local-ollama",
      "upstream_model": "qwen-example",
      "priority": 20,
      "weight": 1
    }
  ]
}
```

Rules:

- `model_alias` is unique.
- Target provider IDs must exist.
- At least one target is required.
- `max_attempts` cannot exceed target count or global maximum.
- A Responses request can use only a target that advertises Responses unless an explicit converter adapter exists.
- Route target order is semantically significant and preserved.

## 11. MCP stdio server

```json
{
  "id": "filesystem",
  "display_name": "Filesystem MCP",
  "transport": "stdio",
  "enabled": true,
  "required": false,
  "command": "/usr/bin/node",
  "args": ["/opt/mcp/filesystem/server.js", "/srv/allowed"],
  "cwd": "/opt/mcp/filesystem",
  "env_allow": ["PATH", "HOME"],
  "env": {
    "FILESYSTEM_TOKEN": {"source": "env", "name": "FILESYSTEM_TOKEN"}
  },
  "protocol": {
    "preferred": "2026-07-28",
    "legacy": ["2025-11-25"]
  },
  "restart": {
    "mode": "on_failure",
    "max_restarts": 3,
    "window_ms": 60000,
    "backoff_ms": 1000,
    "max_backoff_ms": 30000
  },
  "startup_timeout_ms": 10000,
  "shutdown_grace_ms": 3000
}
```

Rules:

- `command` is an absolute path by default.
- `args` are literal strings, not shell fragments.
- `command`, `cwd`, and every `args` member reject embedded U+0000; Linux process APIs use
  NUL-terminated strings, so accepting one would validate a suffix that `execve` or `chdir` never sees.
- Environment starts from an allowlist, not full inherited environment.
- Each emitted `NAME=value\0` entry has a runtime hard limit of 128 KiB. The
  complete owned `envp` allocation, including the pointer array and all
  strings, has a runtime hard limit of 1 MiB; exceeding either limit rejects
  process startup before allocation or `execve`.
- A child variable name cannot appear in both `env_allow` and `env`; this prevents duplicate
  `NAME=value` entries whose observed value would depend on the child runtime. JSON Schema
  Draft 2020-12 cannot compare dynamic array members with dynamic object keys, so this
  cross-field constraint is enforced identically by the reference and NASM validators and is
  recorded in the schema as a `$comment`.
- `cwd` must exist and satisfy configured path policy.
- Child stdout is protocol-only; stderr is captured separately.

## 12. MCP Streamable HTTP server

This is the active runtime contract for the M9 Streamable HTTP adapter.

```json
{
  "id": "remote-search",
  "display_name": "Remote Search MCP",
  "transport": "streamable_http",
  "enabled": true,
  "required": false,
  "url": "https://mcp.example.invalid/mcp",
  "auth": {
    "type": "bearer_env",
    "env": "REMOTE_MCP_TOKEN"
  },
  "protocol": {
    "preferred": "2026-07-28",
    "legacy": ["2025-11-25"]
  },
  "timeouts": {
    "connect_ms": 3000,
    "request_ms": 30000,
    "idle_stream_ms": 30000
  }
}
```

- `url` is an `http://` or `https://` URL of at most 2048 bytes. Userinfo,
  fragments, controls, and whitespace are rejected.
- Plain HTTP is accepted by default only for `127.0.0.1`, `localhost`, and
  `[::1]`. `allow_insecure_private_http: true` additionally admits RFC 1918,
  IPv4 link-local, IPv6 unique-local, and IPv6 link-local IP literals. It has
  no effect for public addresses or hostnames and never disables TLS peer or
  hostname verification.
- `auth.type` is `none`, `bearer_env`, or `header_env`. `bearer_env` names an
  environment variable in `auth.env`; `header_env` names an allowlisted header
  in `auth.header` and carries an environment SecretRef in `auth.value`, for
  example `{"source":"env","name":"REMOTE_MCP_TOKEN"}`. A plaintext secret
  is never a configuration value.
- Timeout ranges are `connect_ms` 100–600000, `request_ms` 1000–86400000, and
  `idle_stream_ms` 1000–3600000 milliseconds.
- Redirects are not followed and proxy environment variables are ignored.
  Only HTTP(S) schemes are enabled for the transfer.
- The modern adapter has no session ID, standalone GET, DELETE termination, or
  `Last-Event-ID` state. Legacy session/GET state exists only inside its
  version-specific adapter allocation and is not configurable here.

## 13. Reload behavior

1. Read candidate file.
2. Parse under size/depth limits.
3. Validate schema-equivalent rules.
4. Resolve references and secret presence.
5. Build immutable candidate snapshot.
6. Diff listeners, providers, routes, MCP servers, and retention policy.
7. Reject changes that require restart unless `--allow-restart-required` policy permits a planned restart.
8. Atomically publish the snapshot.
9. Apply lifecycle changes.
10. Persist config hash and revision, not secret values.

Any failure before publish leaves the old snapshot untouched.

## 14. Schema migration

- `schema_version` is an integer.
- Unknown future versions are rejected with an upgrade message.
- Upgrade tooling must use the bounded verified backup/restore primitives before a
  destructive migration; M11 provides those Assembly storage primitives, while the M12
  packaging/upgrade workflow is responsible for invoking them.
- Automatic destructive migration is forbidden.
- Examples always target the newest schema.
