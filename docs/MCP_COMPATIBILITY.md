# MCP Compatibility and Supervision Plan

**Primary target:** MCP `2026-07-28`  
**Legacy target:** MCP `2025-11-25`  
**Initial deprecated transport policy:** MCP `2024-11-05` HTTP+SSE is not implemented by default.

**0.8.0 implementation boundary:** the stdio supervisor and M9 Streamable HTTP
adapters are implemented and verified for the modern and legacy revisions
above. Deprecated 2024 HTTP+SSE and OAuth/browser authorization remain outside
this support boundary.

## 1. Why adapters are version-isolated

MCP `2026-07-28` changes more than a version string. It moves protocol version, client identity, and
capabilities into per-request `_meta`; introduces modern discovery; removes protocol-level sessions
from Streamable HTTP; removes the standalone GET stream; and scopes SSE responses to individual POST
requests. Earlier revisions use an `initialize` handshake and can maintain session-oriented transport state.

AsmFlow therefore treats them as two protocol eras:

- **Modern era**: `2026-07-28` and later, per-request metadata.
- **Legacy era**: `2025-11-25` and earlier, initialization-based.

The normalized inventory shown to users may be shared, but wire state, headers, session fields, framing,
and lifecycle logic remain separate.

## 2. Modern request metadata

Every modern request includes:

```json
{
  "_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientInfo": {
      "name": "AsmFlow",
      "version": "0.8.0"
    },
    "io.modelcontextprotocol/clientCapabilities": {}
  }
}
```

On Streamable HTTP, `MCP-Protocol-Version` must match the body metadata. Header/body mismatch is a
hard protocol error, not a signal to fall back to legacy behavior.

## 3. Modern discovery

AsmFlow uses `server/discover` because it provides identity, supported versions, and capabilities and
also acts as the recommended stdio era probe.

Request:

```json
{
  "jsonrpc": "2.0",
  "id": "discover-1",
  "method": "server/discover",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "AsmFlow",
        "version": "0.8.0"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
```

AsmFlow stores the validated negotiated version and bounded, semantically
validated inventory arrays, counts, monotonic fetch/expiry timestamps, and
cache scope. Streamable HTTP also keeps a non-secret authorization-context
fingerprint for server-local cache invalidation. Capability normalization,
server identity normalization, and instructions remain outside the current
normalized control view.

Server-reported identity is not used for authorization or executable trust decisions.

## 4. stdio modern transport

- AsmFlow launches the server as a child process.
- Client requests are newline-delimited UTF-8 JSON-RPC on child stdin.
- Server responses and notifications are newline-delimited on stdout.
- stderr is a separate log stream.
- AsmFlow writes no non-MCP data to child stdin.
- It rejects any non-MCP stdout line as protocol contamination and enters the
  bounded child-failure path.
- Server requests/notifications accept an optional string, integer, or null
  `id`; an optional `params` must be an object or array. Other member types are
  protocol contamination rather than permissive notifications.
- Timed-out non-initialize requests emit
  `notifications/cancelled` with `params.requestId` and the bounded reason
  `request timeout`; legacy `initialize` is explicitly exempt.
- EOF or process exit invalidates all in-flight requests and cached era state.

### Era detection

1. Spawn the server and send the fixed-version modern `server/discover` probe.
2. A valid success selects modern for that process lifetime.
3. A completed refusal or semantically invalid discovery success received as
   an otherwise valid, complete JSON-RPC response retires the probe before
   same-process legacy initialization, when legacy is configured; there is no
   longer a modern request in flight.
4. A probe timeout emits cancellation, stops and reaps the process, and starts
   a fresh child directly in legacy initialization.
5. Invalid UTF-8, JSON, JSON-RPC, or framing is protocol failure, not an era
   fallback signal.
6. An ordinary or manual later restart probes modern again.

On Streamable HTTP, a correlated unsupported-version response is recognized as
modern evidence and produces an actionable failure; it never selects legacy.
AsmFlow 0.8.0 does not retry a different mutually supported modern version.

A probe timeout is bounded, cancelled, and the probed process is stopped and
reaped before a fresh process receives legacy `initialize`. This internal era
switch bypasses automatic restart mode and budget once; later ordinary or
manual restarts probe modern again. AsmFlow never interleaves modern and legacy
requests before era selection is complete.

## 5. Streamable HTTP modern transport

Modern behavior:

- one HTTP POST per JSON-RPC request;
- one configured MCP endpoint;
- `Accept: application/json, text/event-stream`;
- response is a single JSON object or request-scoped SSE stream;
- no protocol-level session ID;
- no HTTP GET stream;
- no HTTP DELETE session termination;
- no `Last-Event-ID` resumability;
- closing a request SSE stream is cancellation for that request.

Every request body carries modern `_meta`, and its
`MCP-Protocol-Version: 2026-07-28` header matches that metadata. The adapter
also derives `Mcp-Method`, `Mcp-Name` for tool calls, and `Mcp-Param-*` only for
primitive arguments whose input-schema property declares `x-mcp-header`.
A response protocol-version header is optional, but a duplicate or mismatched
one is a hard protocol failure. A modern response carrying legacy session state
is also refused.

### HTTP era detection

1. Send a valid modern `server/discover` request first.
2. A validated success selects modern for the running transport view.
3. Correlated unsupported-version, header-mismatch, and method-not-found JSON-RPC
   responses, or a mismatched response protocol header, are modern evidence and
   never trigger legacy.
4. Redirects, transient/5xx responses, timeouts, and transport failures do not
   select an era.
5. Only an unrecognized bodyless HTTP 400 response to discovery selects a new,
   isolated legacy adapter.
6. Stop/restart clears the transport view and probes modern first again.

## 6. Legacy `2025-11-25`

Legacy support includes:

- initialize request/response;
- initialized notification;
- validated negotiated protocol version;
- stdio lifecycle corresponding to that revision;
- Streamable HTTP session state committed from the initialize response and
  echoed on later requests;
- an initialized POST followed by a session GET event stream;
- optional `Last-Event-ID` storage only in the legacy adapter;
- request timeout closes the affected transfer and POSTs an explicit
  `notifications/cancelled` with the same session.

The legacy HTTP adapter owns this state; the stdio adapter does not allocate its
session or GET-stream fields:

```text
LegacySession {
  negotiated_version
  initialized
  session_id | none
  server_capabilities
  client_capabilities
  transport_revision
}
```

No field from `LegacySession` appears in the modern request context.

## 7. Initial feature support

The table below is the implemented 0.8.0 stdio and Streamable HTTP subset.

| MCP feature | Modern 2026 | Legacy 2025 | 0.8.0 behavior |
|---|---:|---:|---|
| Discovery / initialization | Yes | Yes | Required, version-isolated |
| Tools list | Yes | Yes | Required current inventory |
| Tool call | Yes | Yes | Operator-confirmed test call |
| Resources list/read | List only | List only | Inventory list; read deferred |
| Prompts list/get | List only | List only | Inventory list; get deferred |
| Progress/log notifications | Count | Count | Bounded and counted, not displayed semantically |
| List-changed notifications | No event-driven refresh | No event-driven refresh | Positive TTL expiry or manual `mcp.discover` refresh |
| Subscriptions/listen | No initial | N/A/different | Deferred |
| Sampling | Request counted | Request counted | No reply or LLM dispatch; semantics deferred |
| Elicitation / roots | Request counted | Request counted | No reply or display semantics; deferred |
| MRTR input-required | No semantic handling | N/A | Raw result only; semantics deferred |
| Tasks extension | No | N/A | Deferred |
| MCP Apps/UI extension | No | N/A | Deferred |
| Authorization browser flow | No | No | Deferred; static bearer/custom-header environment SecretRefs only |

## 8. Inventory normalization

AsmFlow normalizes display data without changing wire semantics.

```text
MCPInventory {
  tools[] | null
  resources[] | null
  prompts[] | null
  tool_count
  resource_count
  prompt_count
  fetched_at_monotonic_ns
  expires_at_monotonic_ns
  cache_scope              // none | private | public
}
```

Stdio uses process-lifetime caches with zero timestamps and scope `none`.
Streamable HTTP validates `ttlMs` and `cacheScope` before transactional commit.
Modern missing or zero TTL records `expires_at_monotonic_ns` equal to the fetch
time and is refreshed only by explicit discovery; a positive TTL refreshes
lazily after expiry and is capped at 300 seconds. Legacy responses without a
TTL receive a local 60-second TTL. Scope defaults to `private` and only
`private` or `public` is accepted. Even `public` data remains server-local and
never crosses an authorization context; credential rotation invalidates only
that configured server's view. Deterministic server order is preserved, a
failed refresh never partially replaces a validated value, and stop, failure,
or restart invalidates the running view.

Before committing a bounded list, every tool entry must be an object with a
nonempty string `name` and object `inputSchema`; every resource needs nonempty
string `uri` and `name`; and every prompt needs a nonempty string `name`.
Invalid required tools clear current readiness and degrade the server. Invalid
optional lists do not replace their last validated cache.

## 9. Tool-test safety

AsmFlow is a supervisor, not an autonomous agent runtime.

A manual tool test requires:

- server ready;
- tool present in current inventory;
- arguments valid JSON and within size/depth limits;
- daemon `confirmed=true` field;
- timeout and output bounds.

TUI confirmation and warnings are M10 work; configurable per-tool policy and a
persistent redacted audit event are M11 work. They are not 0.8.0 claims. AsmFlow
does not infer that a tool is safe from its name or description.

## 10. Process supervision

States:

```text
stopped -> starting -> probing -> ready
                    \-> degraded
                    \-> failed -> restarting -> starting
                               \-> crash_loop
```

Restart policy keeps a bounded timestamp history, compacts entries outside the
configured sliding window, applies bounded exponential backoff, and latches
`crash_loop` before scheduling a restart beyond the budget. Only explicit
`mcp.reset_crash_loop` clears that history and latch. Shutdown sequence:

1. stop new calls;
2. cancel or wait for in-flight calls according to policy;
3. close stdin for stdio;
4. wait grace period;
5. send termination signal;
6. wait;
7. force kill if required;
8. reap child;
9. send SIGKILL to the saved process group so helpers cannot survive a leader
   that exited first, then retire the PGID after success or ESRCH;
10. clear process-scoped era and inventory cache.

The process-group guarantee covers descendants that remain in the child's
saved PGID. A descendant that deliberately escapes with `setsid` or `setpgid`
is outside the M8 guarantee; cgroup or namespace containment is future
hardening, not a 0.8.0 sandbox claim.

## 11. Framing and limits

- UTF-8 required.
- stdio frame: one JSON object per line, default 4 MiB and configuration hard
  maximum 64 MiB; the ceiling applies while a line accumulates.
- stderr line: default maximum 64 KiB and configuration hard maximum 1 MiB;
  the captured tail retains exactly the newest 64 KiB and counts truncation.
- each committed tools, resources, or prompts list is bounded to 1 MiB.
- HTTP response headers: 64 KiB default / 1 MiB hard maximum.
- HTTP response bodies: 4 MiB default / 64 MiB hard maximum.
- request-scoped SSE event: 1 MiB default / 16 MiB hard maximum, with at most
  1024 events per response.
- legacy session and `Last-Event-ID` storage: 4 KiB each.
- JSON maximum depth: default 64.
- Each inventory array is limited to 100,000 JSON elements and each committed
  list is also subject to the 1 MiB byte ceiling above.
- Unknown fields are retained only when safely bounded; display snapshots may omit them.

## 12. Compatibility test matrix

| Client adapter | Server | Expected |
|---|---|---|
| modern only | modern | Works |
| modern only | legacy | Actionable incompatibility |
| dual-era | modern | Exact supported-version validation, no initialize |
| dual-era | legacy | Probe fallback, initialize, legacy state only |
| legacy only | modern | Not supported by AsmFlow's modern path; diagnostic only |
| dual-era HTTP | modern 2026 | Works: POST JSON/SSE, no session/GET |
| dual-era HTTP | legacy 2025 | Works: isolated session/GET adapter only |
| modern HTTP | deprecated 2024 HTTP+SSE | Unsupported in initial release |

Each row needs a fixture or mock integration test before the corresponding support claim is marked complete.

## 13. Reference documents

- https://modelcontextprotocol.io/specification/2026-07-28
- https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
- https://modelcontextprotocol.io/specification/2026-07-28/server/discover
- https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio
- https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
- https://modelcontextprotocol.io/specification/2026-07-28/server/tools
- https://modelcontextprotocol.io/specification/2025-11-25
