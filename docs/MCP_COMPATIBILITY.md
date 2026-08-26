# MCP Compatibility and Supervision Plan

**Primary target:** MCP `2026-07-28`  
**Legacy target:** MCP `2025-11-25`  
**Initial deprecated transport policy:** MCP `2024-11-05` HTTP+SSE is not implemented by default.

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
      "version": "0.1.0"
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
        "version": "0.1.0"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
```

AsmFlow stores only normalized, non-secret fields:

- supported versions;
- capability names;
- server name/version for display only;
- cache TTL and scope;
- instructions with bounded length.

Server-reported identity is not used for authorization or executable trust decisions.

## 4. stdio modern transport

- AsmFlow launches the server as a child process.
- Client requests are newline-delimited UTF-8 JSON-RPC on child stdin.
- Server responses and notifications are newline-delimited on stdout.
- stderr is a separate log stream.
- AsmFlow writes no non-MCP data to child stdin.
- It rejects or records any non-MCP stdout line as protocol contamination.
- Cancellation uses the version-defined stdio cancellation message.
- EOF or process exit invalidates all in-flight requests and cached era state.

### Era detection

1. Spawn server.
2. Send modern `server/discover` probe.
3. If Discover succeeds, remain modern.
4. If a recognized modern version error is returned, choose a mutually supported modern version and retry.
5. If the response is a non-modern error, invalid response, or protocol-defined fallback signal, restart or
   reset framing as required and attempt legacy initialization.
6. Cache the era for that process lifetime only.

A probe timeout is bounded and recorded. AsmFlow never interleaves modern and legacy requests before era
selection is complete.

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

Required/derived headers include the protocol-version header and current standard request metadata headers
such as method/name where defined by the specification. Header construction lives in the modern adapter and
is verified against fixtures.

### HTTP era detection

1. Send a valid modern request.
2. Success or recognized modern JSON-RPC error means the origin is modern.
3. Unsupported version error triggers version negotiation, not legacy fallback.
4. A relevant 4xx without a recognized modern error body may trigger the isolated legacy adapter.
5. Cache the era by configured origin and authentication context; invalidate on repeated contradiction.

## 6. Legacy `2025-11-25`

Legacy support includes:

- initialize request/response;
- initialized notification;
- negotiated protocol version and capabilities;
- stdio lifecycle corresponding to that revision;
- Streamable HTTP session behavior only inside the legacy adapter when implemented;
- session ID, GET stream, and server-initiated request behavior only where that revision requires it.

Legacy state structure:

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

| MCP feature | Modern 2026 | Legacy 2025 | 1.0 behavior |
|---|---:|---:|---|
| Discovery / initialization | Yes | Yes | Required |
| Tools list | Yes | Yes | Required |
| Tool call | Yes | Yes | Operator-confirmed test call |
| Resources list/read | Yes | Yes | Inventory and manual read |
| Prompts list/get | Yes | Yes | Inventory and manual get |
| Progress/log notifications | Parse | Parse | Display bounded metadata |
| List-changed notifications | Limited | Limited | Refresh cache when safely supported |
| Subscriptions/listen | No initial | N/A/different | Deferred |
| Sampling | No | No | Deferred; no automatic LLM calls |
| Elicitation / roots | No automatic | No automatic | Display unsupported/input-required state |
| MRTR input-required | Recognize | N/A | Surface to operator; no automatic continuation |
| Tasks extension | No | N/A | Deferred |
| MCP Apps/UI extension | No | N/A | Deferred |
| Authorization browser flow | Limited | Limited | Static secret-ref headers first |

## 8. Inventory normalization

AsmFlow normalizes display data without changing wire semantics.

```text
MCPInventory {
  tools[]
  resources[]
  prompts[]
  fetched_at_monotonic_ns
  expires_at_monotonic_ns
  cache_scope
  source_protocol_version
}
```

Modern cacheable list results may include `ttlMs` and `cacheScope`; AsmFlow respects them. Private cache
entries are never shared across different configured credentials. Deterministic tool order from the server
is preserved. Legacy data receives a local conservative TTL when the protocol lacks equivalent hints.

## 9. Tool-test safety

AsmFlow is a supervisor, not an autonomous agent runtime.

A manual tool test requires:

- server ready;
- tool present in current inventory;
- arguments valid JSON and within size/depth limits;
- TUI/CLI explicit confirmation;
- daemon `confirmed=true` field;
- configured tool/server policy permitting calls;
- timeout and output bounds;
- redacted audit event.

The UI warns that MCP tools may read, write, execute, spend money, or access remote systems. AsmFlow does
not infer that a tool is safe from its name or description.

## 10. Process supervision

States:

```text
stopped -> starting -> probing -> ready
                    \-> degraded
                    \-> failed -> restarting -> starting
                               \-> crash_loop
```

Restart policy uses a sliding time window, bounded exponential backoff, and manual reset after budget
exhaustion. Shutdown sequence:

1. stop new calls;
2. cancel or wait for in-flight calls according to policy;
3. close stdin for stdio;
4. wait grace period;
5. send termination signal;
6. wait;
7. force kill if required;
8. reap child;
9. clear process-scoped era and inventory cache.

## 11. Framing and limits

- UTF-8 required.
- stdio frame: one JSON object per line, configurable maximum 4 MiB.
- stderr line: default maximum 64 KiB, longer lines truncated with a counter.
- HTTP response: bounded JSON; SSE event default maximum 1 MiB.
- JSON maximum depth: default 64.
- Inventory maximum counts are configurable.
- Unknown fields are retained only when safely bounded; display snapshots may omit them.

## 12. Compatibility test matrix

| Client adapter | Server | Expected |
|---|---|---|
| modern only | modern | Works |
| modern only | legacy | Actionable incompatibility |
| dual-era | modern | Modern probe/version negotiation, no initialize |
| dual-era | legacy | Probe fallback, initialize, legacy state only |
| legacy only | modern | Not supported by AsmFlow's modern path; diagnostic only |
| dual-era HTTP | modern 2026 | POST JSON/SSE, no session/GET |
| dual-era HTTP | legacy 2025 | Legacy adapter only |
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
