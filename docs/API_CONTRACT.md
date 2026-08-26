# AsmFlow API and Control Contract

**Contract version:** `0.1`  
**Project version:** `0.1.0-spec`  
**Status:** normative target for the first implementation

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
  "version": "0.1.0",
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
  "routes": {
    "enabled": 4,
    "eligible": 3
  }
}
```

- `200`: ready.
- `503`: config invalid, migration pending/failed, no eligible required route, or shutdown in progress.

MCP server failures do not make the LLM gateway globally unready unless the operator marks a
specific MCP server as a required startup dependency.

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
- semantic SSE event names and data are forwarded.
- AsmFlow may add only transport comments or headers defined by this contract.
- AsmFlow does not merge streams from multiple providers.

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
| 400 | `asmflow_request_error` | `invalid_json`, `invalid_field`, `body_too_large` |
| 401 | `asmflow_auth_error` | `missing_token`, `invalid_token` |
| 404 | `asmflow_route_error` | `unknown_model_alias`, `unknown_path` |
| 405 | `asmflow_request_error` | `method_not_allowed` |
| 409 | `asmflow_state_error` | `reload_in_progress`, `server_crash_loop` |
| 413 | `asmflow_request_error` | `body_too_large` |
| 415 | `asmflow_request_error` | `unsupported_content_type` |
| 429 | `asmflow_capacity_error` | `route_concurrency_exhausted`, `queue_full` |
| 502 | `asmflow_upstream_error` | `invalid_upstream_response`, `upstream_connect_failed` |
| 503 | `asmflow_routing_error` | `no_eligible_target`, `not_ready` |
| 504 | `asmflow_upstream_error` | `upstream_timeout` |

Upstream API error bodies may be passed through when they are valid JSON and below the configured
limit. AsmFlow still adds its request ID header and records a normalized error class internally.

## 8. Retry and fallback contract

Fallback is not a generic retry loop.

Allowed only when:

- response is not committed to the client;
- failure class is configured as pre-commit retryable;
- the request has not exceeded route attempt limits;
- the next target is eligible;
- cancellation has not been requested.

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
- `system.version`
- `providers.list`
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
- `diagnostics.export`

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
- Control protocol uses `protocol_version` in the initial handshake once implemented.
- Additive response fields are allowed in `0.x`.
- Removing/renaming a field or changing meaning requires a contract version change and migration note.
- TUI and daemon versions must negotiate; incompatible versions fail with an actionable message.
