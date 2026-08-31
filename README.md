# AsmFlow

> An x86-64 Assembly LLM Gateway and MCP Supervisor for Linux.

AsmFlow is an open-source systems experiment: build a current AI control-plane
application with one of the earliest practical programming-language families.
The runtime is designed around NASM x86-64 assembly, a small and explicit C ABI
boundary, a local OpenAI-compatible gateway, and a supervisor for local and
remote Model Context Protocol (MCP) servers.

> **Project status:** `0.10.0` — M11 is complete; the current phase is
> `M12 — Benchmark, Packaging, CI, and Release`.
>
> `asmflowd` is a working gateway with strict bounded HTTP, deterministic
> routing, pre-commit fallback, buffered/SSE provider forwarding, MCP stdio and
> Streamable HTTP supervision, SQLite state, and a local control plane.
> Modern MCP `2026-07-28` and legacy `2025-11-25` keep physically separate
> state and only an unrecognized bodyless HTTP 400 selects legacy.
>
> `asmflow-tui` and `asmflowctl` are control-socket-only operator clients;
> neither opens SQLite or reaches provider transports. M11 adds owner-only
> file/peer enforcement, structured secret redaction, payload-free diagnostics
> and audit rows, verified backup/restore, bounded SIGTERM drain, SIGKILL/WAL
> recovery, and deterministic parser fuzz smoke. See [PROGRESS.md](PROGRESS.md)
> for authoritative milestone evidence and [HARNESS.md](HARNESS.md) for gates.

## 한국어 요약

AsmFlow는 Linux x86-64 환경에서 동작하는 어셈블리어 기반 LLM Gateway 및
MCP Supervisor이다. `/v1/responses`와 `/v1/chat/completions` 호환 데이터
플레인을 제공하고, 여러 모델 엔드포인트의 상태·라우팅·Fallback을 관리하며,
stdio 및 Streamable HTTP 기반 MCP 서버를 감독한다. 핵심 제어 흐름, 상태 머신,
라우팅, 메모리 소유권은 NASM 어셈블리어로 구현하고 TLS·SQLite·터미널 렌더링
등 검증된 범용 기능만 외부 C ABI 라이브러리에 위임한다.

## Product boundary

AsmFlow consists of one daemon and two cooperating operator clients:

- `asmflowd`: headless gateway, provider router, persistence owner, and MCP supervisor.
- `asmflow-tui`: keyboard-first ncurses control client connected through a local Unix-domain socket.
- `asmflowctl`: non-interactive control client with deterministic table and
  full-envelope JSON output.

The first public release targets:

- Linux x86-64 and the System V AMD64 ABI.
- OpenAI Responses API compatibility as the preferred interface.
- OpenAI Chat Completions compatibility for existing clients and local runtimes.
- Provider presets for OpenAI-compatible servers such as OpenAI, Ollama, LM Studio,
  llama.cpp server, and vLLM, without embedding provider SDKs.
- Deterministic priority, round-robin, and least-latency routing.
- Health checks, circuit breaking, concurrency limits, and pre-stream fallback.
- MCP `2026-07-28` modern per-request metadata with a version-isolated compatibility
  adapter for legacy `2025-11-25` initialization-based servers.
- MCP stdio process supervision and Streamable HTTP client supervision.
- Metadata-first observability with secret and payload redaction by default.

## Explicit non-goals for 1.0

- Implementing an LLM inference engine or GPU kernels.
- Automatically executing model tool calls against MCP servers.
- Building a visual node editor, RAG pipeline, vector database, or autonomous agent loop.
- Reimplementing TLS, SQLite, JSON Schema, or terminal emulation in assembly.
- Supporting Windows, macOS, or AArch64 in the first stable release.
- Transparent failover after any response byte has been forwarded to the client.

## Architecture at a glance

```text
OpenAI-compatible client
          |
          |  HTTP on loopback by default
          v
+---------------------------+
|         asmflowd          |
|---------------------------|
| Request parser            |
| Capability-aware router   |
| Health / circuit breaker  |
| libcurl multi event loop  |-----> Upstream LLM endpoints
| SQLite state owner        |
| MCP process/HTTP manager  |-----> MCP stdio / Streamable HTTP
+---------------------------+
          ^
          | Unix-domain control socket
          v
+---------------------------+
| Operator clients          |
| asmflow-tui / asmflowctl  |
+---------------------------+
```

See [ARCHITECTURE.md](ARCHITECTURE.md) and the
[technical whitepaper](docs/TECHNICAL_WHITEPAPER_KR.md) for the normative design.

## Operator clients

Both clients use the local NDJSON control protocol only. They do not read or
write SQLite, and their default views never show secrets, prompts, or model
responses. The default socket is
`${XDG_RUNTIME_DIR}/asmflow/control.sock` (or
`/run/user/<uid>/asmflow/control.sock` when the runtime directory is unset);
`--socket PATH` selects another socket.

`asmflow-tui` provides seven keyboard-first screens: Overview, Providers,
Routes, Requests, MCP, Logs, and Settings. Requests and Logs explicitly report
`unsupported_in_this_build` instead of reading another data source. Examples:

```bash
asmflow-tui
asmflow-tui --socket /run/user/1000/asmflow/control.sock --screen providers
asmflow-tui --mono
asmflow-tui --screen overview --dump-layout 100x30
```

`--mono` and `NO_COLOR` preserve the same status text without colour.
`--dump-layout WIDTHxHEIGHT` writes a canonical, non-interactive snapshot.
Interactive startup checks control `protocol_version == 1` before loading
state. A Providers refresh preserves the focused provider by stable ID even
when rows reorder; if that ID disappears, selection moves to a deterministic
surviving row. Composite refreshes commit only after every staged response is
valid; a failure keeps the prior frames and stable selections visible as
`STALE`.

The implemented keyboard surface is `1`-`7` for screens, `j`/`k` or arrow
keys for rows, `r` to refresh or reconnect, `:` for available commands, `?`
for help, and `q` to quit. The UI does not advertise deferred filter/open
actions.

The layout reflows without horizontal scrolling:

| Terminal | Presentation |
| --- | --- |
| `80x24` | Compact tabs and priority-collapsed columns |
| `100x30` | Standard table layout |
| `140x40` | Navigation, main table, and detail panes |
| Below `80` columns | Narrow list/detail drill-down |
| Below `60x16` | Actionable size diagnostic with an `asmflowctl` fallback |

The currently exposed `mcp.restart` palette action requires explicit
confirmation before its control request is sent. The complete action catalogue
marks every Level 2 and 3 action as confirmation-required and keeps Level 4
actions unavailable; catalogue entries do not imply that every action already
has an interactive command. Confirmation does not replace the daemon's own
authorization, policy, or state checks.

`asmflowctl` accepts a control method and an optional bounded JSON object:

```bash
asmflowctl [--socket PATH] [--json|--table] METHOD [PARAMS_JSON]
asmflowctl providers.list '{}'
asmflowctl --table routes.list
asmflowctl --json system.snapshot '{}'
asmflowctl --json diagnostics.export '{}'
```

Table output is the human-readable default. `--json` preserves the complete
control response envelope, including additive fields, as exactly one JSON line
terminated by LF. Exit status is `0` for `ok: true`, `1` for daemon,
connection, protocol, or output failure, and `2` for local usage errors.
Scripts that require an explicit compatibility preflight can call
`asmflowctl --json system.version` and require `result.protocol_version == 1`.

## Repository map

- `HARNESS.md`: phase gates, verification commands, stop rules, and recovery runbook.
- `AGENTS.md`: Codex-facing invariants and repository operating rules.
- `PROGRESS.md`: session handoff and decision log.
- `docs/`: whitepapers, protocol contracts, security model, tests, and release process.
- `config/asmflow.schema.json`: versioned configuration contract.
- `examples/`: safe sample configurations, curl calls, and a user systemd unit.
- `tests/`: protocol fixtures, mock endpoints, and Python reference oracles.
- `.github/`: CI, issue forms, pull-request template, and dependency updates.
- `include/`: shared NASM includes — ABI frame macros, error codes, constants.
- `src/`: implementation module boundaries; each directory is populated only as
  its milestone begins.

## Build and verify

Repository contracts need only Python 3.11+ and GNU Make:

```bash
make check
```

That validates repository structure, JSON fixtures, sample configuration,
routing-oracle behavior, secret-reference policy, and documentation completeness.

Building the binaries additionally needs a Linux x86-64 toolchain:

```text
nasm gcc binutils make pkg-config
libllhttp-dev libcurl4-openssl-dev libsqlite3-dev libjansson-dev libncurses-dev
valgrind gdb   # for the memory and ABI gates
```

```bash
make build
```

`make build-debug` produces DWARF-annotated binaries under `build/debug/`;
`make build-release` produces stripped position-independent executables under
`build/release/` with separate `.debug` symbol files.

Each milestone has a gate target that asserts its Definition of Done from
`HARNESS.md`. Running the latest one runs every earlier one:

```bash
make gate-m11
```

- `gate-m0` — repository structure, JSON contracts, examples, secret policy,
  routing oracle.
- `gate-m1` — version agreement between `VERSION` and both binaries,
  side-effect-free `--help` verified on a pseudo-terminal, the debug/release
  symbol policy, and a link with no executable stack, no text relocations, and
  no toolchain warnings.
- `gate-m2` — assembly unit tests with per-test leak detection, a static
  callee-saved-register audit over every assembly function, scenarios that must
  terminate the process, and Valgrind memcheck with zero errors and zero
  definitely-lost bytes.
- `gate-m3` — the configuration contract: both shipped examples load, every
  invalid fixture is refused with a JSON Pointer, plaintext credentials are
  refused everywhere they can appear, a missing environment secret fails before
  readiness, ten thousand reload cycles leak nothing, and the JSON Schema and the
  assembly validator agree on every document in the corpus.
- `gate-m4` — storage and the control plane: an injected failure at every
  migration statement rolls back completely, configuration round-trips through
  the repository, the socket is mode 0600 inside a 0700 directory, oversized and
  malformed frames are refused safely, a hundred connect/disconnect cycles leak
  no descriptors, no credential reaches the database, and the console links
  neither libsqlite3 nor libcurl.
- `gate-m5` — the gateway: every leniency switch llhttp offers is explicitly
  off, a twenty-one case smuggling corpus is refused without a second response,
  the same request delivered one byte at a time gives the same answer, header
  and body and JSON and idle limits hold on both sides of their boundaries,
  slowloris and client-reset traffic leaks no descriptors, a non-loopback
  listener without an authentication policy refuses to start, ten thousand
  requests leave the resident set flat, and every error code the daemon can
  emit is documented in the API contract.
- `gate-m6` — the upstream client: a request round-trips to a provider with
  only `model` rewritten, unknown fields and Unicode survive unchanged, the
  same SSE stream delivered at eleven packet sizes produces identical bytes, a
  slow client pauses the upstream rather than growing a buffer, a client that
  disconnects cancels the transfer it started, every libcurl failure becomes a
  documented error class, no security-relevant transfer option is left to a
  libcurl default, and libcurl never owns the wait.
- `gate-m7` — routing: a fourteen-hundred-scenario corpus agrees with the
  Python routing oracle on every candidate set and every selection, the same
  scenario decides identically a hundred times running, the circuit breaker
  follows a golden timeline against a real provider, a fallback happens only
  on a pre-commit retryable failure and never after a byte has reached the
  client, no target is attempted twice for one request, the concurrency
  counter returns on every path an attempt can end, and a fault-injection soak
  produces no duplicate response and no stream carrying two providers' events.
- `gate-m8` — MCP stdio supervision: literal argv execution with an allowlisted
  environment and explicit cwd, isolated modern/legacy era selection, strict
  protocol framing and transactional inventory/readiness, a true sliding crash
  budget with a manual-reset latch, and bounded stop, timeout, crash,
  same-process-group helper, and daemon-shutdown reaping paths, including MCP
  Valgrind coverage.
- `gate-m9` — MCP Streamable HTTP: modern metadata/header parity and JSON or
  request-scoped SSE POSTs, physically separate modern/legacy adapters,
  bodyless-400-only era fallback, legacy session/GET behavior, cancellation,
  URL/auth/TLS/redirect/proxy policy, and monotonic TTL caches partitioned by
  configured server and authorization context.
- `gate-m10` — operator clients: deterministic responsive layouts at
  `80x24`, `100x30`, and `140x40`; keyboard-only navigation and
  confirmation; priority-based column collapse; monochrome and control-byte
  safety; provider stable-ID refresh; terminal restoration after quit, SIGINT,
  and daemon disconnect; and `asmflowctl` JSON/table and exit-code contracts.
- `gate-m11` — security and recovery: non-loopback authentication across every
  endpoint; same-EUID control peers; private config/state/socket/database
  permissions; structured secret redaction and payload-free diagnostics/audit
  rows; verified no-overwrite SQLite backup/restore; eight bounded fuzz targets;
  ordered SIGTERM drain; and SIGKILL WAL/migration/stale-socket recovery.

`make help` lists every target.

## Development sequence

1. Read `AGENTS.md`, `PROGRESS.md`, and `HARNESS.md`.
2. Implement only the current phase.
3. Keep runtime business logic in assembly; use C only for stable ABI shims.
4. Compare assembly outputs with the Python reference oracle where parity is required.
5. Update `PROGRESS.md` before every session-ending commit.

## Security posture

AsmFlow binds to loopback by default, never requires plaintext API keys in its
configuration, executes MCP stdio servers with `execve`-style argument arrays rather
than a shell, and does not store prompts or model outputs unless the operator opts in.
Remote MCP uses HTTPS by default and environment SecretRefs; TLS peer/name checks stay
enabled, redirects are disabled, and proxy environment variables are ignored.
Configuration and state paths fail closed on symlinks, wrong ownership, or unsafe
permissions. Diagnostic export never includes payloads or secret values.
Review [SECURITY.md](SECURITY.md) and [docs/SECURITY_MODEL.md](docs/SECURITY_MODEL.md)
before enabling non-loopback access or third-party MCP servers.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Changes that weaken an invariant, move
business logic into C, or bypass a phase gate require an architecture decision record
and maintainer approval.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
