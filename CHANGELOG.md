# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog and the project intends to use Semantic Versioning
once executable releases begin.

## [Unreleased]

### Planned

- Benchmarks, packaging, CI, and release preparation (M12).

## [0.10.0] - 2026-08-31

### Added

- Bounded `diagnostics.export` with build/dependency identity, canonical config
  hash, last normalized error, and redacted config/provider/route/MCP state;
  payload and secret inclusion are hard-disabled.
- Assembly-owned SQLite online backup, read-only integrity verification, and
  restore-to-new-path primitives with checked size arithmetic, exclusive
  `NOFOLLOW` destinations, mode `0600`, and `fsync`.
- Payload-free `audit_events` rows for implemented provider and MCP mutations,
  plus the seven focused M11 targets and aggregate `make gate-m11` audit.
- Deterministic isolated fuzz smoke for HTTP, JSON, configuration, URL, SSE,
  MCP, control framing, and structured redaction.

### Changed

- The active milestone advances to M12 — Benchmark, Packaging, CI, and Release.
- Public `config_hash` fields are canonical unsigned decimal strings, preserving
  the full 64-bit revision domain across signed-64-bit JSON consumers.
- SIGTERM first closes the data-plane listener, then drains in-flight responses
  for up to five seconds on the existing reactor before MCP and SQLite teardown;
  a second signal expires the grace immediately.
- Startup now recovers a SIGKILL-left WAL and proven-stale control socket before
  revalidating migrations and persisted provider/route/MCP metadata.

### Security

- Config, state, database, and control paths enforce owner-only modes, regular
  file/type checks, `NOFOLLOW`, restrictive creation umask, and fail-closed
  same-EUID `SO_PEERCRED` validation.
- Header credentials reject empty/control-byte values, and HTTP input/auth/body
  buffers are securely wiped on consume, replacement, and release paths.
- A seeded secret corpus is absent from control output, diagnostics, CLI output,
  SQLite/WAL/SHM, normal logs, and abrupt SIGKILL process output.
- Non-loopback startup without auth is refused, and missing/wrong credentials
  are rejected before dispatch on every data-plane endpoint.

## [0.9.0] - 2026-08-30

### Added

- `asmflow-tui`, a keyboard-first ncursesw control client with seven screens,
  monochrome operation, deterministic `--dump-layout` output, and responsive
  compact, standard, wide, narrow, and too-small presentations.
- `asmflowctl`, a one-request control client with deterministic table output,
  complete one-line JSON response envelopes, bounded local parameter
  validation, and stable exit codes for success, runtime failure, and usage
  error.
- M10 layout, keyboard, monochrome, terminal-restore, and CLI contract suites,
  with `make gate-m10` as the aggregate milestone target.

### Changed

- The active milestone advances to M11 — Security, Observability, and
  Recovery.
- Interactive operator startup now checks control `protocol_version == 1`
  before loading a snapshot. Providers refresh keeps selection by stable ID
  across reordering and chooses a deterministic surviving row after removal.
  Composite refreshes stage bounded responses and restore prior frames plus
  stable selections if any response or detail lookup fails.
- Provider columns collapse by priority without horizontal scrolling.
  Requests and Logs show an explicit `unsupported_in_this_build` unavailable
  state.
- SIGHUP and every ncurses presentation error now use the same terminal
  restoration path as quit, SIGINT, and daemon disconnect.

### Security

- Both operator clients use only the mode-0600 control socket and never access
  SQLite or provider transports directly. Default TUI screens omit secrets,
  prompts, and model responses.
- Remote UTF-8 and control bytes are sanitized before terminal output;
  monochrome and table modes emit no ANSI colour sequences.
- The action-risk catalogue marks every Level 2 or 3 action as requiring
  confirmation and keeps Level 4 actions unavailable. The currently exposed
  `mcp.restart` palette flow proves both cancel-without-request and confirmed
  request paths. Daemon-side policy and method-specific confirmation checks
  remain authoritative.

## [0.8.0] - 2026-08-30

### Added

- MCP Streamable HTTP supervision driven by the existing epoll/libcurl-multi
  reactor. The modern `2026-07-28` adapter sends matching per-request `_meta`
  and `MCP-Protocol-Version` metadata and accepts bounded JSON or
  request-scoped SSE POST responses.
- A physically separate legacy `2025-11-25` HTTP adapter with initialization,
  session commit and echo, initialized notification, GET event stream,
  optional `Last-Event-ID`, and explicit timeout cancellation.
- Transport-neutral MCP control and readiness handling, including HTTP
  start/stop/restart/discover/tool-test lifecycle and current validated tools
  as the required readiness condition.
- Validated `ttlMs` and `cacheScope`, bounded monotonic expiry, lazy
  transactional refresh, and server-local cache identity partitioned by a
  non-secret authorization-context fingerprint.
- Five focused M9 integration suites with 17 tests, nine protocol fixtures,
  `scripts/gate_m9.py`, and `make gate-m9`.

### Changed

- The active milestone advances to M10. MCP HTTP requests are serialized per
  configured server while stdio framing and process lifecycles remain
  independent.
- HTTP era fallback is limited to an unrecognized bodyless 400 response to the
  modern discovery probe. Recognized JSON-RPC errors, version/header mismatch,
  redirects, 5xx responses, timeouts, and transport failures never select the
  legacy adapter.

### Security

- MCP HTTP bearer and custom-header credentials are resolved from environment
  SecretRefs while constructing a request, securely released afterward, and
  never exposed through the control surface or request body.
- TLS peer and hostname verification are explicit, redirects are disabled,
  proxy environment variables are ignored, and automatic response
  decompression is not requested.
- Plaintext MCP HTTP is limited to loopback by default. The explicit insecure
  private-network flag admits only private/link-local IP literals, never a
  public address or hostname, and cannot disable TLS verification.
- Response headers, bodies, SSE events/counts, and legacy session state all
  have fixed hard limits.

## [0.7.0] - 2026-08-29

### Added

- MCP stdio process supervision with direct `execve`-style argv, an explicit
  working directory, and an allowlisted environment. Each emitted environment
  entry is capped at 128 KiB and the complete owned `envp` allocation,
  including its pointer array, is capped at 1 MiB.
- Process-lifetime modern `2026-07-28` discovery and isolated legacy
  `2025-11-25` initialization adapters. `mcp.list` and `mcp.get` expose the
  negotiated `protocol_version`, which is cleared whenever that process view
  ends.
- Timeout cancellation through `notifications/cancelled`; a timed-out modern
  probe is reaped before a fresh process receives legacy initialization, so
  protocol eras are never interleaved in one process.
- Strict NDJSON stdout handling for UTF-8, JSON-RPC correlation, member types,
  and accumulated frame limits. Any stdout noise is protocol contamination;
  stderr is drained separately and retains only its newest 64 KiB.
- Transactional, semantically validated tools, resources, and prompts
  inventories. Current tools are required for readiness; resources and prompts
  are optional caches and a failed refresh cannot replace a validated value.
- Nine live MCP control methods: `mcp.list`, `mcp.get`, `mcp.inventory`,
  `mcp.start`, `mcp.stop`, `mcp.restart`, `mcp.reset_crash_loop`,
  `mcp.discover`, and the explicitly confirmed asynchronous `mcp.tool_test`.
- Required-MCP dependency counts in `/readyz`, including current validated
  tools rather than process liveness alone.
- A true sliding restart budget, bounded exponential backoff, a crash-loop
  latch released only by explicit reset, and same-process-group helper cleanup
  even when the direct child exits first.
- `scripts/gate_m8.py`, `make gate-m8`, and the six focused stdio,
  malformed-input, lifecycle, crash-loop, and zombie/reaping targets from the
  M8 harness.

### Changed

- The active milestone advances to M9. Streamable HTTP transport,
  transport-version error handling, cache TTL/scope and credential-context
  partitioning remain M9 work and are not claimed by the 0.7.0 stdio adapter.

### Security

- MCP children do not receive the daemon's inherited environment; only
  explicitly allowlisted or mapped variables are emitted, and stdout is
  protocol-only.
- A tool test requires `confirmed=true` and a tool in the current validated
  inventory. AsmFlow still performs no automatic model-driven tool execution.

## [0.6.0] - 2026-08-27

### Added

- Routing. A request is matched to a target by the whitepaper's six filters in
  its order, and then by the route's policy: priority, round-robin, or
  EWMA least-latency. `tests/route_oracle.py` states the same rules in Python
  and `tests/test_routing_parity.py` runs both over a generated corpus of some
  fourteen hundred scenarios, failing on any disagreement.
- Provider health and a circuit breaker (ADR 0012). Consecutive failures
  degrade a provider and then open its circuit; the configured cooldown makes
  it half-open; one probe decides whether it closes or reopens with a longer
  wait. Every deadline is monotonic.
- Observed latency as an integer EWMA, so no routing decision depends on
  floating-point rounding.
- Pre-commit fallback. A retryable failure the route names moves the request to
  another target, bounded by `fallback.max_attempts` and by the set of targets
  this request has already tried.
- Per-provider `max_concurrency`, enforced by a counter that is claimed once
  and released through one function on every path an attempt can end.
- `providers.list` now reports live state: `health`, `active_requests`,
  `observed_latency_us`, `consecutive_failures`, and `circuit_opened_count`.
- `af_monotonic_now`, a value-returning clock reading.
- `scripts/gate_m7.py` and `make gate-m7`, with the five suites HARNESS.md M7
  names.

### Fixed

- `af_monotonic_ns` takes an out-pointer and returns a status. Two call sites
  used it as if it returned the reading, so it wrote eight bytes of clock over
  whatever the register happened to hold. In M6 that register held the
  configuration snapshot, and every generation request wrote a nanosecond count
  over its reference count — the snapshot was never freed, and nothing crashed
  or failed a test. `af_monotonic_now` removes the trap and the M7 gate checks
  every remaining call site.
- A route's `endpoint_families` was no longer checked once selection moved into
  the router, so a route configured for chat completions would serve a
  Responses request. Caught by an M6 test that had asserted the old behaviour.

## [0.5.0] - 2026-08-27

### Added

- The upstream client. `asmflowd` forwards `/v1/responses` and
  `/v1/chat/completions` to a configured provider and returns the answer, both
  buffered and streamed.
- `src/ffi/curl_shim.c`: the whole libcurl boundary, driven by AsmFlow's own
  epoll loop through `curl_multi_socket_action` (ADR 0011). An upstream socket
  is a loop source like the listener and the control socket; there is no second
  reactor and no thread.
- `src/providers/`: the provider adapter, the SSE framer, the exchange state
  machine, and the normalisation of every libcurl failure into one of the
  `AF_E_UP_*` classes the configuration can name.
- Streaming with `Transfer-Encoding: chunked`. Events are forwarded byte for
  byte in order, and `limits.sse_event_max_bytes` applies to each event as a
  unit.
- Backpressure: a client that reads slower than its provider writes pauses the
  upstream transfer instead of growing a buffer.
- Cancellation: a client that disconnects cancels its upstream transfer
  immediately, rather than leaving a provider generating output nobody will
  read.
- `limits.max_active_requests` bounds concurrent upstream transfers, and a
  request beyond it is refused with `route_concurrency_exhausted` rather than
  queued for an unbounded time.
- `tests/mock_provider.py`: a provider whose wire bytes a test writes directly,
  and the four suites built on it.
- `scripts/gate_m6.py` and `make gate-m6`.

### Changed

- `/v1/responses` and `/v1/chat/completions` no longer answer
  `unsupported_in_this_build`. Every request-side refusal M5 made is unchanged.
- The response catalogue gained `upstream_connect_failed`, `upstream_tls_failed`,
  `upstream_timeout`, `invalid_upstream_response`, `no_eligible_target`, and
  `route_concurrency_exhausted`; `docs/API_CONTRACT.md` documents each.
- The connection outbox is compacted as it drains, so a stream bounds it by
  what is pending rather than by its own total length.

### Fixed

- `make check` errored instead of skipping on a machine with nothing built.
  The rule now lives on the one path that starts a daemon, and
  `make check-buildless` reproduces the condition locally.
- Both milestone gate scripts now fail when a suite they run skips anything;
  unittest exits 0 on a run that skipped everything, so a mis-set `BUILD_DIR`
  could have made a gate pass without testing.
- The test harness treated a connectable control socket as a started daemon.
  The socket binds several startup steps before the upstream engine and the
  listener open their descriptors, so a baseline taken then was counting a
  daemon mid-start; the M4 disconnect test failed on one CI machine and passed
  on another from the same commit. The harness now waits for the daemon's own
  `ready`.

## [0.4.0] - 2026-08-27

`asmflowd` serves HTTP. It binds a TCP listener, parses HTTP/1.1 with every
leniency mode off, applies the configured header, body, JSON, and idle limits,
authenticates when the listener policy asks it to, and answers `/healthz`,
`/readyz`, and `/v1/models`. `/v1/responses` and `/v1/chat/completions` apply
the whole request-side contract and then report that the upstream data plane is
not in this build. The router, the MCP supervisor, and the console are still
unwired.

### Added

- The data-plane TCP listener: a bounded connection table, drained writes,
  keep-alive, and pipelining answered in order.
- `src/ffi/llhttp_shim.c`, the whole llhttp boundary (ADR 0006). Every leniency
  switch the library offers is explicitly cleared, and `make gate-m5` reads
  `llhttp.h` to prove none was missed.
- Request-smuggling defences stated in assembly rather than inherited from the
  library's defaults: a repeated `Content-Length`, `Content-Length` together
  with `Transfer-Encoding`, a transfer coding other than `chunked`, and a
  repeated credential header are each refused, and the connection closes.
- Header, body, JSON depth, JSON string, and idle-timeout limits, each applied
  to what has accumulated rather than to what has completed. An oversized body
  is refused on its declaration rather than after being read.
- Bearer and named-header credentials, resolved once from the environment at
  startup and compared in constant time. The policy applies to every endpoint.
- `/healthz` (liveness only), `/readyz` (dependencies and route counts), and
  `/v1/models` (enabled aliases, never the provider behind them).
- One error catalogue: every failure the gateway can answer with is one row in
  one table, and `make gate-m5` checks each row against
  `docs/API_CONTRACT.md` 7.
- The idle sweep and the lingering close (ADR 0010), so a refusal reaches a
  client that is still transmitting instead of being destroyed by an RST.
- `make gate-m5` and six suites: contract, limits, a 21-case smuggling corpus,
  a one-byte-fragment corpus, a fault suite, and a ten-thousand-request soak.

### Changed

- A listen address must be an IP literal or `localhost`. A hostname is refused
  at startup, so no resolver decides what the daemon binds.
- A non-loopback listener with no authentication policy is now refused where the
  socket is created as well as where the file is read.
- `docs/API_CONTRACT.md` 7 gains the status rows the gateway actually emits:
  408, 411, 431, 500, 505, and the `route_disabled` and
  `unsupported_in_this_build` codes.

### Fixed

- `routes.get` and `routes.list` crashed the daemon for any route with more
  than one target. `include/config.inc` and `include/runtime.inc` both defined
  `RT_SIZE`, and `src/control/control_methods.asm` includes both, so the target
  array was walked with the runtime's 96-byte stride instead of the record's
  40. The route-target fields are now `RTG_*`, and `make check` fails on any
  macro name defined in two headers, since NASM replaces one silently.
- Scripts lost their executable bit in the index, because the repository is
  developed on a filesystem that reports every file as executable. `make check`
  now reads the mode git recorded rather than the mode the filesystem claims.

### Security

- No response discloses the server software, the upstream host, or a provider
  identity, and no refusal message contains anything from the request. The
  gate greps the catalogue for format specifiers to keep it that way.
- A credential is never echoed, and neither is the name of the environment
  variable it came from.
- The console links neither llhttp nor libsqlite3 nor libcurl, and carries no
  `af_http_*` symbol at all; the gate reads both binaries to confirm it.

- OpenAI-compatible Responses and Chat Completions data plane.
- Deterministic routing, health state, circuit breaking, and safe fallback.
- MCP stdio and Streamable HTTP supervision.
- ncursesw TUI and local control protocol.

## [0.3.0] - 2026-08-27

`asmflowd` is a working daemon. It loads its configuration, migrates its
database, binds a control socket, and serves the control protocol from a single
event loop until it is asked to stop. The HTTP data plane, the router, the MCP
supervisor, and the console are still unwired.

### Added

- JSON serialisation with the object/array grammar enforced by construction: a
  key inside an array, two keys in a row, or a mismatched close is a sticky
  error rather than malformed output. Strings are escaped per RFC 8259 and
  sanitised to valid UTF-8, so third-party text cannot carry a control sequence
  to an operator's terminal or make a frame undecodable.
- A single epoll event loop (ADR 0002). Sources are a bounded table, and epoll
  carries a slot index rather than a pointer so that a stale event cannot be
  delivered to whoever reused the slot.
- Signal handling through `signalfd` (ADR 0009), so shutdown runs as ordinary
  code with the whole runtime available. SIGPIPE is blocked, so a write to a
  departed peer returns `EPIPE` instead of killing the daemon.
- The SQLite boundary, a transactional migration runner, and the single-writer
  repository. The ten-table schema is migration 1; a failure injected at any of
  its statements rolls the version row and the data back together.
- The control socket: mode 0600 inside a 0700 directory, both verified rather
  than assumed, with a stale node removed only after a connection attempt proves
  nothing is listening.
- NDJSON framing with the 1 MiB ceiling applied to accumulated bytes rather than
  to a completed frame, CRLF tolerance, and UTF-8 validation.
- Ten control methods: `system.version`, `system.snapshot`, `providers.list`,
  `providers.get`, `routes.list`, `routes.get`, `mcp.list`, `config.current`,
  `provider.enable`, and `provider.disable`. Methods in the contract whose
  subsystem is not built yet answer `unsupported_in_this_build`.
- Operator enable/disable state persisted in the database, so a configuration
  reload cannot silently re-enable a provider somebody turned off.
- `make gate-m4`, and `tests/test_control_protocol.py`: 27 integration tests
  against a live daemon covering permissions, framing, descriptor accounting,
  redaction, restart persistence, and clean shutdown.

### Security

- No credential reaches SQLite. The `providers` and `mcp_servers` tables have no
  `auth` column at all, and a test greps the database file to prove it.
- `config.current` reports an authentication policy's type and whether its
  environment variable is set, but never the value and never the variable's
  name.
- The console links neither libsqlite3 nor libcurl; the gate reads its dynamic
  section to confirm it.

## [0.3.0-alpha.1] - 2026-08-26

`asmflowd --check-config` now does real work: it loads a configuration file,
validates it against the full contract, and resolves environment secret
references. The gateway, router, storage, control plane, MCP supervisor, and
console are still unwired.

### Added

- Bounded JSON parsing with byte, depth, string-length, and element-count
  ceilings. The depth check is a string-aware pre-scan over the raw bytes, so a
  deeply nested document is refused before any node is allocated. Duplicate
  object keys are rejected rather than silently resolved to the last value.
- `src/ffi/json_shim.c`, a policy-free adapter that re-exports Jansson's macro
  accessors as functions (ADR 0007). The library's type ordinals are asserted
  against the assembly's constants rather than assumed.
- `src/config/`, the configuration model and the schema-equivalent runtime
  validator (ADR 0008). Every rule in `config/asmflow.schema.json` is applied
  directly, including `additionalProperties: false` as an explicit unknown-key
  sweep over each closed object.
- Environment secret references with presence checked before readiness, and a
  document-wide sweep that refuses any credential-shaped key.
- Allowlisted `${XDG_*}` path expansion. `$VAR`, `$(cmd)`, backticks, `~`,
  relative paths, and paths containing `..` are all refused rather than passed
  through.
- Immutable, reference-counted configuration snapshots. A rejected document
  produces no snapshot at all.
- Rejection reporting: an af_status code, an RFC 6901 JSON Pointer to the exact
  location, and the rule that was broken — never a value from the file.
- `tests/config_corpus.py` and `tests/test_config_parity.py`: a 90-document
  corpus run through the schema, an independent Python reference, and the
  assembly, failing on any disagreement.
- `make gate-m3`, including a 10,000-iteration reload soak.

### Fixed

- `redact_headers` did not enforce the schema's `uniqueItems`. Found by the
  parity harness on its first run.

## [0.2.0] - 2026-08-26

First release with executable output. The binaries parse their command line and
exit; no gateway, router, storage, control plane, or MCP behaviour exists yet.

### Added

- NASM ELF64 build for Linux x86-64 with separate debug and release modes.
  Release binaries are position-independent, stripped, and shipped with separate
  `.debug` symbol files linked by `.gnu_debuglink`.
- `asmflowd` and `asmflow-tui` entry points with `--version`, `--help`, and
  usage-error handling that leaves terminal modes untouched.
- `include/abi.inc`: a single uniform stack frame that makes 16-byte call
  alignment and callee-saved register preservation hold by construction.
- `include/errors.inc`: the stable `af_status` code space used by logs, control
  errors, and tests.
- Overflow-checked size arithmetic for every allocation and copy path.
- Heap allocator wrapper with a block header, live-block accounting, and
  deterministic allocation-failure injection.
- Bounded growable buffers, a request-scoped arena with an opt-in guard mode
  that makes use-after-finalize fault at the offending address, borrowed string
  views, monotonic and realtime clocks with a test override, and ULID request
  identifiers.
- Assembly unit-test runner with per-test heap-leak detection and a
  deliberately fatal scenario mode driven from a parent process.
- `scripts/gate_m1.py`, `scripts/abi_audit.py`, and `make gate-m1` /
  `make gate-m2` milestone gates, all run by CI.

### Changed

- `make check` no longer implies that the repository has no runtime; the README
  status block is now tied mechanically to the phase named in `PROGRESS.md`.

## [0.1.0-spec] - 2026-08-02

### Added

- Technical and design whitepapers.
- Codex-oriented single-page implementation harness.
- Architecture, security, configuration, API, MCP compatibility, test, and release docs.
- llhttp inbound-parser ADR and bounded HTTP framing test requirements.
- Apache License 2.0, contribution policy, code of conduct, and security policy.
- Versioned JSON configuration schema and safe examples.
- OpenAI and MCP protocol fixtures.
- Python routing oracle, mock provider, mock MCP stdio server, and contract checks.
- GitHub Actions CI, issue forms, pull-request template, and Dependabot configuration.
- Empty source-module boundaries for the implementation phase.
