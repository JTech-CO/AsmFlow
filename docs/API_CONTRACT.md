# AsmFlow API and Control Contract

**Contract version:** `0.1`

**Project version:** `0.10.0`

**Status:** normative contract; implemented through M11 security, observability, and recovery

## 1. Compatibility principles

AsmFlow is a transparent, capability-aware gateway rather than a universal schema
translator. It parses only the fields needed for validation, routing, limits, and safe
stream handling. Unknown valid request fields and unknown SSE event types should be
preserved whenever the selected upstream adapter can carry them.

- Preferred client surface: OpenAI Responses API.
- Compatibility surface: OpenAI Chat Completions API.
- Provider surface: configured OpenAI-compatible endpoints.
- AsmFlow-generated errors use the contract below.
- Upstream errors are passed through when safe, with redacted AsmFlow metadata headers.
- No API contract permits a client to provide or override an upstream URL.

## 2. Data-plane listener

Default:

```text
http://127.0.0.1:8080
```

The listener binds to loopback unless the operator explicitly configures another address.
A non-loopback listener requires an authentication policy.

### Common request headers

| Header | Behavior |
|---|---|
| `Authorization` | Optional on loopback; required when listener policy enables bearer auth |
| `Content-Type` | `application/json` for POST endpoints |
| `Accept` | `application/json` and/or `text/event-stream` |
| `X-Request-Id` | Optional caller ID; accepted only if length/charset validation passes |

### Common response headers

| Header | Behavior |
|---|---|
| `X-AsmFlow-Request-Id` | Stable request correlation ID |
| `X-AsmFlow-Route` | Selected route ID; omitted when disclosure is disabled |
| `X-AsmFlow-Attempt` | 1-based attempt number; omitted when disclosure is disabled |
| `Cache-Control` | `no-store` for generation responses |
| `X-Content-Type-Options` | `nosniff` |

Provider hostnames, API keys, secret references, and raw error bodies are never emitted as
custom headers.

## 3. Health endpoints

### `GET /healthz`

Reports process liveness only.

Successful response:

```json
{
  "status": "ok",
  "version": "0.10.0",
  "uptime_ms": 42000
}
```

- `200`: process event loop is alive.
- `500`: internal fatal state that has not yet terminated the process.

### `GET /readyz`

Reports whether the daemon can accept generation requests.

```json
{
  "status": "ready",
  "config_revision": 42,
  "database": "ready",
  "listener": "ready",
  "mcp": {
    "required": 1,
    "ready": 1
  },
  "routes": {
    "enabled": 4,
    "eligible": 3
  }
}
```

- `200`: ready.
- `503`: config invalid, migration pending/failed, no eligible required route, or shutdown in progress.

MCP server failures do not make the LLM gateway globally unready unless the operator marks a
specific MCP server as a required startup dependency. An enabled required stdio or Streamable
HTTP server counts as ready only after its protocol era is negotiated and its current,
semantically validated tools list has committed. Every enabled required server contributes to
`mcp.required`; every such READY server with current tools contributes to `mcp.ready`. Optional
MCP failures do not lower global readiness.

## 4. Models endpoint

### `GET /v1/models`

Returns enabled model aliases, not upstream model inventory.

```json
{
  "object": "list",
  "data": [
    {
      "id": "general",
      "object": "model",
      "created": 0,
      "owned_by": "asmflow"
    }
  ]
}
```

Rules:

- A disabled route is not listed.
- An alias with zero eligible providers may be listed only when `expose_unavailable_models=true`;
  the default is false.
- Upstream base URL and provider identity are not part of the model object.
- Exact provider-native model listing is outside the 1.0 contract.

## 5. Responses endpoint

### `POST /v1/responses`

AsmFlow accepts an OpenAI Responses-compatible JSON object.

Routing envelope:

- `model`: required string; interpreted as AsmFlow route alias.
- `stream`: optional boolean; default false.
- fields that imply capabilities, such as image input or tool definitions, are inspected only
  to filter providers that explicitly advertise support.

The selected provider adapter rewrites `model` to the configured upstream model. Other supported
fields are serialized without intentional semantic changes. Unknown fields are preserved if the
JSON library and adapter can round-trip them safely.

Streaming:

- `Content-Type: text/event-stream`
- `Transfer-Encoding: chunked`. A streamed response has no length to state when
  its head is written, and chunked framing is what keeps the connection
  reusable afterwards.
- semantic SSE event names and data are forwarded.
- AsmFlow may add only transport comments or headers defined by this contract.
- AsmFlow does not merge streams from multiple providers.
- Events are forwarded byte for byte, in order, including their line
  terminators. AsmFlow finds event boundaries; it does not parse events, and it
  never re-encodes one. The same stream delivered in different packet sizes
  produces the same response.
- `limits.sse_event_max_bytes` applies to each event as a unit. An event at the
  limit is delivered; one byte more ends the stream, and no part of the refused
  event reaches the client.
- The framing of the response follows what the provider sent, not what the
  client asked for. A provider that answers `stream: true` with a plain JSON
  body is relayed as a plain JSON body, because wrapping it in event framing
  would be AsmFlow inventing a stream nobody sent.

## 6. Chat Completions endpoint

### `POST /v1/chat/completions`

Routing envelope:

- `model`: required route alias.
- `messages`: required array.
- `stream`: optional boolean.

AsmFlow preserves valid OpenAI-compatible fields supported by the selected adapter. It does not
silently translate Chat Completions into Responses unless a future adapter explicitly documents
that conversion and its parity tests.

## 7. AsmFlow-generated error format

```json
{
  "error": {
    "message": "No eligible upstream target for model alias 'vision'.",
    "type": "asmflow_routing_error",
    "param": "model",
    "code": "no_eligible_target"
  },
  "asmflow": {
    "request_id": "01J...",
    "retryable": false
  }
}
```

### Error classes

| HTTP | Type | Code examples |
|---:|---|---|
| 400 | `asmflow_request_error` | `invalid_json`, `invalid_field`, `malformed_request`, `conflicting_framing` |
| 401 | `asmflow_auth_error` | `missing_token`, `invalid_token` |
| 404 | `asmflow_route_error` | `unknown_model_alias`, `unknown_path` |
| 405 | `asmflow_request_error` | `method_not_allowed` |
| 408 | `asmflow_request_error` | `request_timeout` |
| 409 | `asmflow_state_error` | `reload_in_progress`, `server_crash_loop` |
| 411 | `asmflow_request_error` | `length_required` |
| 413 | `asmflow_request_error` | `body_too_large` |
| 415 | `asmflow_request_error` | `unsupported_content_type` |
| 429 | `asmflow_capacity_error` | `route_concurrency_exhausted`, `queue_full` |
| 431 | `asmflow_request_error` | `headers_too_large` |
| 500 | `asmflow_state_error` | `internal_error` |
| 502 | `asmflow_upstream_error` | `invalid_upstream_response`, `upstream_connect_failed`, `upstream_tls_failed` |
| 503 | `asmflow_routing_error` | `no_eligible_target`, `not_ready`, `route_disabled` |
| 503 | `asmflow_state_error` | `unsupported_in_this_build` |
| 504 | `asmflow_upstream_error` | `upstream_timeout` |
| 505 | `asmflow_request_error` | `unsupported_http_version` |

Notes on the framing and state codes:

- `malformed_request` is a message llhttp refused as syntax, with leniency
  disabled. `conflicting_framing` is narrower and is AsmFlow's own rule: a
  repeated `Content-Length`, a `Content-Length` together with a
  `Transfer-Encoding`, a transfer coding other than `chunked`, or a repeated
  credential header. Splitting the two means an operator can tell a broken
  client from a smuggling attempt.
- `headers_too_large` applies `listener.request_header_max_bytes` to the header
  section as it accumulates, so an unbounded header stream is refused while it
  is arriving rather than after it has been stored.
- `request_timeout` is what a connection is told when it has sat inactive longer
  than `listener.idle_timeout_ms` with a request part-delivered.
- `unsupported_in_this_build` reports that a subsystem the request needs is not
  present in the running binary. It is deliberately distinct from `not_ready`,
  which says a present subsystem is not yet usable, and from an empty success,
  which would be indistinguishable from a real answer.
- `upstream_connect_failed` covers both a refused connection and a name that
  does not resolve; `upstream_tls_failed` is separate because it is never
  retryable. A certificate that does not verify is an answer rather than a
  hiccup, and a fallback on it would silently prefer whichever target has the
  weakest TLS posture.
- `upstream_timeout` covers both `timeouts.request_ms` and
  `timeouts.idle_stream_ms`. The second is what a stream that stays open and
  stops producing runs into; a total timeout cannot express it.
- `route_concurrency_exhausted` is what a request receives once
  `limits.max_active_requests` transfers are already in flight. AsmFlow refuses
  rather than queueing, so a caller finds out immediately instead of waiting an
  unbounded time for a slot.
- An upstream response body is relayed to the client when it is valid JSON
  within the configured limits, whatever its status. A body that is not — HTML
  from a proxy, a truncated document, an array where the shape is an object —
  becomes `invalid_upstream_response`, because relaying it under a JSON content
  type would be AsmFlow vouching for something it could not read.

Upstream API error bodies may be passed through when they are valid JSON and below the configured
limit. AsmFlow still adds its request ID header and records a normalized error class internally.

## 8. Routing, health, and fallback

### Choosing a target

A request names a route alias. The route names targets, each naming a provider.
A target is eligible when all six of these hold, checked in this order:

1. the provider is enabled;
2. the provider speaks the endpoint family being served — the capability bit
   says it supports the API, and the adapter says which shape it speaks, so a
   provider advertising `responses` behind an `openai_chat` adapter is not
   eligible for a Responses request;
3. the provider advertises every capability the request body implies;
4. the provider's circuit is not open, or its cooldown has elapsed;
5. the provider has fewer than `max_concurrency` attempts in flight;
6. this request has not already tried that target.

Eligible targets keep their configured order. The route's `policy` then picks
one:

- `priority`: the lowest `priority` value, ties broken by configured order and
  then by provider identifier, bytewise.
- `round_robin`: a per-route cursor advances and selects `cursor mod count`.
  The cursor survives a configuration reload and the new count is applied to
  it, so changing a route's targets does not restart the rotation.
- `least_latency`: the lowest observed latency, where a target with no
  measurement ranks after every measured one and a half-open target ranks last.
  A half-open target is a probe rather than a choice; ranking it on its recorded
  latency would defeat the circuit breaker that put it there.

Observed latency is an exponentially weighted moving average of successful
attempts, computed as an integer ratio. No routing decision depends on
floating-point rounding.

When nothing is eligible the request is answered `no_eligible_target`.

### Provider health

A provider is `healthy`, `degraded`, `open`, `half_open`, or `disabled`.

- consecutive failures below `health.failure_threshold` make it `degraded`, and
  a degraded provider still receives traffic;
- reaching the threshold opens the circuit for `health.open_cooldown_ms`;
- an open circuit receives nothing, and the cooldown elapsing makes it
  `half_open`;
- a half-open circuit admits exactly one probe;
- `health.success_threshold` consecutive successes close it;
- a failed probe reopens it with a longer cooldown, bounded, so a provider that
  is down for a long time is probed less and less often rather than at a fixed
  rate;
- `disabled` is the operator's decision and is never reached from a health
  result.

Every deadline is monotonic. A cancelled request — one whose client
disconnected — is not recorded as a provider failure.

State is keyed by provider identifier and survives a configuration reload, so
an operator reloading during an incident does not reset the circuits that
incident opened.

### Fallback

Fallback is not a generic retry loop.

Allowed only when:

- response is not committed to the client;
- failure class is configured as pre-commit retryable;
- the request has not exceeded route attempt limits;
- the next target is eligible;
- cancellation has not been requested.

A streamed response commits when its head is written, which is before the
first event: from that moment the status is decided and the only honest ending
is a correctly terminated stream. A non-streamed response commits at the end,
when the status and the length are both known, which is what keeps its fallback
window open for the whole transfer.

Never allowed when:

- any response byte has been written to the client;
- an SSE event has been forwarded;
- the client disconnected;
- policy marks the request non-retryable;
- failure indicates invalid client input;
- retry would violate a configured cost/safety policy.

## 9. Control-plane transport

Default socket:

```text
${XDG_RUNTIME_DIR}/asmflow/control.sock
```

- Unix stream socket.
- File mode `0600`.
- UTF-8 NDJSON, one object per line.
- Maximum frame 1 MiB.
- Request and response correlate by `id`.
- Server events use `event` and have no request `id`.

### Client compatibility preflight

`system.version` returns `version`, `target`, `build`, and the integer
control `protocol_version`. The implemented control protocol version is
`1`.

A long-lived interactive client sends `system.version` as its first request
and must receive an `ok: true` response with `result.protocol_version == 1`
before requesting a snapshot or enabling commands. `asmflow-tui` follows this
rule. A missing, malformed, or different value is an incompatible protocol:
the client shows an actionable error and sends no mutation.

`asmflowctl` is deliberately a one-request client. Scripts that need a
compatibility preflight call `asmflowctl --json system.version`, require
`result.protocol_version == 1`, and only then issue another command. This
control version is distinct from the nullable, process-scoped MCP
`protocol_version` exposed by `mcp.list` and `mcp.get`.

### Request envelope

```json
{
  "id": "ctl-1",
  "method": "providers.list",
  "params": {}
}
```

### Success response

```json
{
  "id": "ctl-1",
  "ok": true,
  "result": {
    "revision": 42,
    "providers": []
  }
}
```

### Error response

```json
{
  "id": "ctl-1",
  "ok": false,
  "error": {
    "code": "invalid_params",
    "message": "Provider id is required.",
    "field": "/provider_id"
  }
}
```

### Event envelope

```json
{
  "event": "provider.health_changed",
  "revision": 43,
  "data": {
    "provider_id": "local-ollama",
    "from": "healthy",
    "to": "open"
  }
}
```

## 10. Initial control methods

### Read methods

- `system.snapshot`
- `system.version` — product/build identity and control
  `protocol_version` (currently `1`).
- `providers.list` — configuration plus live state: `health`,
  `active_requests`, `observed_latency_us`, `consecutive_failures`, and
  `circuit_opened_count`. A provider nothing has yet tried reports `healthy`
  with zeroes rather than omitting the fields.
- `providers.get`
- `routes.list`
- `routes.get`
- `requests.list`
- `requests.get`
- `mcp.list`
- `mcp.get`
- `mcp.inventory`
- `logs.tail`
- `config.validate`
- `config.current`
- `diagnostics.export`

The config_hash fields in config.current, diagnostics.export, and its redacted
config view are the same canonical unsigned decimal string. The value is an
opaque revision identifier: clients compare the string exactly and do not
coerce it to a JSON number. A string preserves the complete 64-bit hash domain
across consumers whose JSON integer model is limited to signed 64-bit.

`diagnostics.export` accepts an empty object and returns one bounded, redacted
reproduction snapshot. It includes `format_version`, generation time, product version,
target/build/control protocol, the canonical `config_hash`, schema version, readiness
and shutdown state, the last normalized error/status time, dependency versions, the
redacted config view, and live provider/route/MCP metadata. The response always states
`redacted: true`, `payloads_included: false`, and `secrets_included: false`; no request
parameter enables payload or secret inclusion.

### Mutation methods

- `config.reload`
- `provider.enable`
- `provider.disable`
- `provider.probe`
- `mcp.start`
- `mcp.stop`
- `mcp.restart`
- `mcp.reset_crash_loop`
- `mcp.discover`
- `mcp.tool_test`

Every implemented provider or MCP mutation appends a best-effort `audit_events` row
containing only occurrence time, peer UID/PID, a static action name, static outcome, and
normalized status. Parameters, payloads, tool arguments/results, credentials, and
environment values are not audit columns.

### Operator command confirmation

The TUI classifies actions by operator risk before it emits a control frame:

- Levels 0 and 1 are read-only or low-impact actions and do not open a
  confirmation dialog.
- Levels 2 and 3 require an explicit confirmation. Cancelling with Escape sends
  no request.
- Level 4 actions are unavailable in this build.

The M10 command palette currently exposes `mcp.restart` as its mutation
workflow. Other catalogue entries establish risk and confirmation policy for
future interactive commands; their presence does not claim that each command
is already exposed by the TUI.

This client-side confirmation is not a security boundary. The daemon still
checks authorization, method-specific policy, parameters, and current state.
Methods whose wire contract includes `confirmed=true`, such as
`mcp.tool_test`, reject a missing or false value independently.

`mcp.tool_test` requires:

```json
{
  "confirmed": true,
  "server_id": "filesystem",
  "tool": "read_file",
  "arguments": {"path": "/tmp/example.txt"}
}
```

The daemon rejects `confirmed=false` or missing confirmation. TUI confirmation is not treated as a
security boundary; the daemon also validates policy and server state.

### Current MCP control surface

The nine implemented MCP methods are `mcp.list`, `mcp.get`,
`mcp.inventory`, `mcp.start`, `mcp.stop`, `mcp.restart`,
`mcp.reset_crash_loop`, `mcp.discover`, and `mcp.tool_test`. Every method
other than `mcp.list` requires `params.server_id`.

- `mcp.list` and `mcp.get` join configuration with bounded live state,
  `transport`, counters, the selected `era`, and nullable `protocol_version`.
  The negotiated version belongs to one running transport view and becomes
  null on stop, failure, or restart; it is not inferred from configuration.
  HTTP servers have no child process, so their `pid` is zero.
- `mcp.inventory` returns validated `tools`, `resources`, and `prompts`, their
  counts, `fetched_at_monotonic_ns`, `expires_at_monotonic_ns`, and
  `cache_scope` (`none`, `private`, or `public`). Tools are the required current
  inventory. Optional arrays may be null, and a failed optional refresh
  preserves its prior validated cache. Stdio reports process-lifetime cache
  metadata with scope `none`; HTTP applies bounded monotonic TTLs and keeps
  every cache server-local and authorization-context partitioned.
- `mcp.start`, `mcp.stop`, `mcp.restart`, and `mcp.discover` require
  `server_id` and initiate bounded asynchronous work. Discovery refuses a
  second refresh while any list call is still pending. These mutations apply
  to both transports: stopping or restarting HTTP cancels active POST/GET
  transfers, and a restart probes modern first again.
- `mcp.reset_crash_loop` is valid only for a latched `crash_loop` server. It
  synchronously clears the latch and restart history and places the server on
  its restart path; it is not a general start alias.
- `mcp.tool_test` additionally requires `confirmed=true`, a READY server, and a
  tool name present in the current validated inventory. It queues one bounded
  asynchronous call; the caller polls `mcp.get.tool_test` for its pending or
  done status and result.

### `asmflowctl` output and exit contract

```text
asmflowctl [--socket PATH] [--json|--table] METHOD [PARAMS_JSON]
```

`PARAMS_JSON`, when present, must be a bounded JSON object and is validated
before a socket connection is attempted. Table mode is the default:
`system.version`, `system.snapshot`, `providers.list`, `routes.list`, and
`mcp.list` have deterministic human-readable schemas. Daemon errors use a
stable status/code/message/field table. Methods without a specialized table
fall back to the complete JSON envelope. Output contains no ANSI colour or raw
terminal control byte.

In `--json` mode, stdout is the daemon's complete correlated response
envelope, including additive top-level and result fields, serialized as exactly
one JSON line followed by LF. A daemon error remains a full `ok: false`
envelope on stdout. Connection, framing, correlation, parsing, and write
failures produce no partial JSON envelope and report an actionable diagnostic
on stderr.

Exit codes are stable:

- `0`: a valid correlated response with `ok: true`;
- `1`: `ok: false`, connection failure, invalid control response, or output
  failure;
- `2`: local command-line, socket-path, method, or `PARAMS_JSON` usage error.

### `asmflow-tui` state contract

The TUI has Overview, Providers, Routes, Requests, MCP, Logs, and Settings
screens. It obtains state only through the control socket and never opens
SQLite. Requests and Logs are explicit unavailable states in this build:
their screens show `UNAVAILABLE` and `unsupported_in_this_build` rather than
inventing rows or exposing payloads.

The default screens do not display secrets, prompts, or model responses.
Remote text is UTF-8 validated and terminal control bytes are rendered as
visible text. Providers refresh resolves the focused provider by stable ID
across reordering; if the ID was removed, selection falls back
deterministically.

If the initial connection or compatibility preflight fails, the client exits
with status 1 and an actionable stderr diagnostic before entering curses.
Once a session has loaded valid frames, composite Overview and Providers
refreshes stage their bounded responses before commit. A failed response,
validation, or provider-detail lookup restores the previous frames and
Provider/Route stable-ID selections as `STALE`; a closed control connection is
shown as `DISCONNECTED`. Neither state may send a mutation, and `r` retries the
same socket path. Quit, SIGINT, SIGHUP, and ncurses presentation errors use the
same cleanup path, and exiting after a daemon disconnect restores terminal
echo, cursor, and screen state.

## 11. Pagination and filtering

List methods use cursor pagination:

```json
{
  "limit": 100,
  "cursor": "opaque-token",
  "filter": "open",
  "sort": "latency_desc"
}
```

- Default limit: 100.
- Maximum limit: 1000.
- Cursor is opaque and tied to a snapshot revision.
- Invalidated cursor returns `cursor_stale`, not silently restarted pagination.

## 12. Contract evolution

- Data-plane compatibility follows endpoint-family expectations and is tested by fixtures.
- Long-lived control clients require `protocol_version == 1` during the
  `system.version` preflight. This control-plane version is distinct from each
  MCP server's nullable, process-scoped negotiated `protocol_version`.
- Additive response fields are allowed in `0.x`.
- Removing/renaming a field or changing meaning requires a contract version change and migration note.
- Incompatible control versions fail with an actionable message before a
  snapshot or mutation is requested.
