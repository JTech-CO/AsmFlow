# AsmFlow Security Model

## 1. Security objective

AsmFlow handles API credentials, local network listeners, billable LLM calls, arbitrary third-party MCP
processes, remote MCP endpoints, and untrusted model/protocol payloads. The objective is not to prove that
all configured providers or MCP tools are safe. It is to ensure AsmFlow preserves operator intent, limits
blast radius, does not leak credentials, and fails without crossing trust boundaries or corrupting state.

## 2. Assets

- provider and MCP credentials;
- gateway bearer token;
- prompts, responses, tool arguments, and tool results;
- model routing policy and provider topology;
- local files and environment visible to MCP child processes;
- control socket and daemon authority;
- request metadata and operational logs;
- SQLite state and configuration;
- billable upstream request budget;
- terminal integrity and operator decisions.

## 3. Threat actors and failure sources

- untrusted local process connecting to the listener or control socket;
- remote client if the listener is intentionally exposed;
- malicious or compromised upstream provider;
- malicious or buggy MCP stdio executable;
- malicious remote MCP endpoint;
- malformed network input and protocol fuzzing;
- accidental operator misconfiguration;
- memory corruption caused by assembly or C ABI error;
- dependency or release-chain compromise;
- log/diagnostic leakage.

## 4. Trust boundaries

```text
[Client process]
      |
      | HTTP + optional bearer auth
      v
[asmflowd data plane] ---- HTTPS ---- [LLM provider]
      |
      | UDS mode 0600
      v
[asmflow-tui / asmflowctl]
      |
      +---- pipes/exec ---- [MCP stdio child]
      |
      +---- HTTPS POST ---- [Remote MCP server]
      |
      +---- local file ---- [SQLite/config/log]
```

The TUI is trusted as the same user but remains separated to reduce accidental state corruption. MCP
children are not trusted merely because the operator configured them.

## 5. Secure defaults

- bind data plane to `127.0.0.1`;
- require auth for non-loopback binding;
- UDS mode `0600`, runtime/state/config directories `0700`;
- environment-based secret references only;
- no payload persistence;
- no automatic MCP tool calls;
- no shell execution;
- remote HTTP rejected unless loopback or explicit private-network exception;
- redirect following disabled;
- bounded request/body/frame/log sizes;
- bounded concurrency, queue, restart, and retry counts;
- fallback prohibited after commit;
- modern/legacy MCP state separated;
- diagnostic export redacted by default.

## 6. Credential handling

### Allowed

- read from named environment variable at startup/reload;
- keep in a dedicated owned memory buffer with explicit lifetime;
- inject into an allowlisted header immediately before dispatch;
- zero buffer on replacement/shutdown where practical;
- report only `set/unset`, source type, and variable name.

### Forbidden

- plaintext JSON configuration;
- CLI arguments;
- SQLite;
- normal logs;
- core diagnostic export;
- provider error echo;
- TUI detail value;
- inherited MCP environment unless explicitly allowlisted.

Core dumps can contain secrets. Production service examples should disable or restrict coredumps; debug use
must occur with test credentials.

## 7. Listener and authentication

Loopback is not a complete security boundary against other local processes. Optional bearer auth should be
usable on loopback and mandatory on non-loopback. Token comparison must avoid early-exit timing where
practical and must not log submitted tokens.

AsmFlow 1.0 does not provide direct TLS termination. Non-loopback use should sit behind a trusted reverse
proxy on the same machine/network and still retain AsmFlow bearer auth. Proxy headers are not trusted unless
the proxy source is configured.

## 8. SSRF and outbound policy

Client requests cannot supply upstream URLs. All destinations come from validated configuration.

- resolve and connect only to configured origin;
- reject URL userinfo and fragments;
- disable redirect following;
- remote provider/MCP uses HTTPS by default;
- private and link-local ranges require explicit policy where not loopback;
- Unix socket or file URL schemes are not accepted as HTTP upstreams;
- DNS resolution changes are logged but DNS identity is not treated as authorization.

## 9. HTTP and streaming threats

Controls:

- strict header/body limits;
- request timeout, header timeout, idle stream timeout;
- reject conflicting framing headers;
- bounded provider SSE framing and bounded request-scoped MCP SSE event
  assembly; ignore comments and reject oversized or over-count events;
- output high/low watermarks;
- client disconnect cancellation;
- no cross-provider stream continuation;
- sanitize response headers and strip hop-by-hop headers;
- do not decompress beyond configured expansion limits.

## 10. Retry and billing safety

A retry may duplicate billable work. Therefore:

- no general automatic retry by default;
- only pre-commit failure classes explicitly configured;
- attempt count bounded;
- tried-target set prevents cycles;
- first-byte commit barrier permanently disables fallback;
- each attempt gets its own audit record;
- operator can disable fallback per route;
- future idempotency support requires provider-specific proof.

## 11. MCP stdio execution

- absolute executable path by default;
- `execve`-style argument vector, no shell;
- minimal allowlisted environment, never the daemon's full inherited
  environment;
- each emitted `NAME=value\0` entry is at most 128 KiB, and the complete owned
  `envp` allocation, including its pointer array and strings, is at most 1 MiB;
- explicit cwd;
- optional UID/GID drop only after design review;
- a saved process-group identity for termination even if the direct child is
  reaped before its helpers;
- resource limits for files, processes, CPU, address space, and output where feasible;
- stdout protocol-only, with strict UTF-8/JSON-RPC and a 4 MiB default / 64 MiB
  hard frame ceiling applied while a line accumulates;
- stderr lines have a 64 KiB default / 1 MiB hard ceiling and the captured tail
  retains only the newest 64 KiB;
- each validated tools, resources, or prompts inventory is bounded to 1 MiB;
- restart budget and backoff;
- operator confirmation for tool calls;
- tool descriptions and server identity are untrusted display strings;
- ANSI control sequences in stderr/tool results are escaped before TUI rendering.

A future seccomp or namespace sandbox is desirable but not claimed for 1.0 unless actually implemented and
tested. M8 cleanup covers helpers that remain in the saved PGID; a descendant that deliberately escapes
with `setsid` or `setpgid` is not contained. Documentation must not imply stronger isolation than exists.

## 12. MCP HTTP security

The M9 Streamable HTTP adapter enforces these controls:

- HTTPS is the remote default. Plain HTTP accepts loopback only unless an
  explicit exception admits a private/link-local IP literal; the exception
  never admits a public address or hostname.
- TLS peer and hostname verification remain enabled and cannot be disabled by
  the plaintext-private-network flag. libcurl is restricted to HTTP(S), does
  not follow redirects, ignores proxy environment variables, and is not asked
  to decompress responses automatically.
- Bearer and custom-header credentials come only from environment SecretRefs.
  They are resolved while constructing the request, the staging buffer is
  securely released, and neither the control surface, request body, nor cache
  retains the secret. The cache keeps only a non-secret change fingerprint.
- Every modern body carries request metadata matching its outbound
  `MCP-Protocol-Version`. Duplicate or mismatched response protocol headers and
  a modern response carrying a session header are protocol failures.
- The modern adapter physically has no session, GET, DELETE, or
  `Last-Event-ID` state. A modern timeout closes only that request transfer;
  legacy timeout cancellation is an explicit session-scoped notification from
  the separate legacy adapter.
- Only an unrecognized bodyless HTTP 400 response to modern discovery is
  legacy evidence. Recognized JSON-RPC errors, redirects, 5xx responses,
  timeouts, and transport failures never downgrade the adapter.
- Inventory caches are server-local and authorization-context partitioned,
  use monotonic bounded TTLs, and replace validated data transactionally.
- Response headers are capped at 1 MiB, bodies at 64 MiB, individual SSE
  events at 16 MiB with at most 1024 events, and legacy session/resume values
  at 4 KiB each; lower defaults apply where documented in the compatibility
  contract.
- OAuth/browser authorization is deferred unless separately designed.

## 13. Configuration and file security

At startup:

- reject world-writable config parent unless explicitly overridden for development;
- reject symlink-sensitive paths where `NOFOLLOW` policy applies;
- create runtime/state directories with restrictive umask;
- bind UDS atomically and remove only a stale socket proven not to be active;
- use temporary file + fsync + rename for generated config/migration backup;
- never chmod broader to repair permissions automatically without explicit command.

## 14. SQLite security and integrity

- single daemon writer;
- prepared statements;
- no SQL built from provider IDs or user strings;
- transactional migrations;
- schema version table;
- backup before destructive migration;
- WAL and SHM files protected by directory permissions;
- integrity check available as maintenance command;
- raw payloads disabled by default;
- database failure does not cause unsafe fallback or secret logging.

## 15. Memory-safety controls

Assembly is memory-unsafe; process-level security depends on discipline and tests.

- checked size arithmetic;
- bounded buffer API only;
- ownership annotations;
- single finalizer per complex object;
- stack-alignment and callee-saved ABI probes;
- allocation-failure injection;
- Valgrind and guard pages for selected buffers;
- fuzz parsers and state machines;
- debug canaries where useful;
- no executable stack;
- PIE/RELRO/NOW and stack protector for C shims where applicable;
- avoid custom cryptography.

## 16. Logging and diagnostics

Redact case-insensitively:

- authorization;
- proxy-authorization;
- cookies;
- configured custom secret headers;
- secret environment values;
- bearer-like tokens in known fields.

Do not apply broad regex replacement that corrupts unrelated data without tests. Use structured-field
redaction first. Payload logging is explicit opt-in and carries a persistent warning.

Diagnostic export includes:

- version/build ID;
- config hash and redacted config;
- route/provider/MCP state;
- error classes and timestamps;
- dependency versions;
- no secret values;
- no payloads unless separately and explicitly requested.

## 17. TUI safety

- escape control characters from remote strings;
- no terminal escape passthrough;
- confirmation for mutating actions;
- display exact target and consequences;
- terminal mode restored on normal and handled abnormal exits;
- stale snapshot visibly marked;
- TUI disconnect never mutates daemon state.

## 18. Security test gates

- secret corpus redaction across logs, DB, exports, errors;
- non-loopback listener auth enforcement;
- UDS permission and peer-user checks where supported;
- malformed HTTP/JSON/SSE/MCP fuzz smoke;
- shell metacharacter argv test proves no shell interpretation;
- env inheritance test;
- child zombie/crash-loop test;
- redirect/URL policy test;
- MCP HTTP plaintext, proxy, SecretRef non-disclosure, authorization-cache
  partition, and TTL-refresh tests;
- first-byte fallback invariant test;
- allocation failure and integer boundary tests;
- package scan for secrets, DBs, logs, core files, debug paths.

## 19. Residual risks

- same-user local processes may read environment or attach debuggers depending on OS policy;
- third-party MCP tools can perform dangerous actions with the operator's permissions;
- assembly memory-safety defects may remain despite testing;
- reverse proxy misconfiguration can expose the gateway;
- provider compatibility claims rely on tested protocol subsets;
- 1.0 does not claim sandbox-grade MCP isolation;
- MCP descendants that escape the supervised PGID require future cgroup,
  namespace, or equivalent containment;
- daemon shutdown is time-bounded and does not wait forever for an
  uninterruptible `D`-state child; shutdown may return while the kernel still
  owns such a task until its blocking operation completes;
- opt-in payload logging creates privacy risk.

These risks must be stated plainly in release documentation.
