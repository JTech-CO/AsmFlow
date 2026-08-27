# AsmFlow

> An x86-64 Assembly LLM Gateway and MCP Supervisor for Linux.

AsmFlow is an open-source systems experiment: build a current AI control-plane
application with one of the earliest practical programming-language families.
The runtime is designed around NASM x86-64 assembly, a small and explicit C ABI
boundary, a local OpenAI-compatible gateway, and a supervisor for local and
remote Model Context Protocol (MCP) servers.

> **Project status:** `0.5.0` — current phase
> `M7 — Routing, health, circuit breaking, and fallback`. `asmflowd` is a
> working gateway: it validates its configuration, migrates SQLite, binds a
> mode-0600 control socket and a TCP listener, answers `/healthz`, `/readyz`,
> and `/v1/models`, and forwards `/v1/responses` and `/v1/chat/completions` to
> a configured provider — buffered or streamed as Server-Sent Events, with
> backpressure, cancellation, and normalised upstream errors. Target selection
> is priority-only for now; round-robin, least-latency, health checks, circuit
> breaking, and fallback are M7. The MCP supervisor and the console are not
> wired yet. See [PROGRESS.md](PROGRESS.md) for the authoritative per-milestone
> state and [HARNESS.md](HARNESS.md) for the gate each milestone must pass.

## 한국어 요약

AsmFlow는 Linux x86-64 환경에서 동작하는 어셈블리어 기반 LLM Gateway 및
MCP Supervisor이다. `/v1/responses`와 `/v1/chat/completions` 호환 데이터
플레인을 제공하고, 여러 모델 엔드포인트의 상태·라우팅·Fallback을 관리하며,
stdio 및 Streamable HTTP 기반 MCP 서버를 감독한다. 핵심 제어 흐름, 상태 머신,
라우팅, 메모리 소유권은 NASM 어셈블리어로 구현하고 TLS·SQLite·터미널 렌더링
등 검증된 범용 기능만 외부 C ABI 라이브러리에 위임한다.

## Product boundary

AsmFlow consists of two cooperating processes:

- `asmflowd`: headless gateway, provider router, persistence owner, and MCP supervisor.
- `asmflow-tui`: keyboard-first ncurses control client connected through a local Unix-domain socket.

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
|       asmflow-tui         |
| ncursesw dashboard        |
+---------------------------+
```

See [ARCHITECTURE.md](ARCHITECTURE.md) and the
[technical whitepaper](docs/TECHNICAL_WHITEPAPER_KR.md) for the normative design.

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
make gate-m6
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
Review [SECURITY.md](SECURITY.md) and [docs/SECURITY_MODEL.md](docs/SECURITY_MODEL.md)
before enabling non-loopback access or third-party MCP servers.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Changes that weaken an invariant, move
business logic into C, or bypass a phase gate require an architecture decision record
and maintainer approval.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
