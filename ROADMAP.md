# AsmFlow Roadmap

The roadmap is milestone-based rather than date-based. A milestone advances only after
its Definition of Done in `HARNESS.md` passes. Feature requests do not enter the current
milestone unless they repair an invariant or unblock a gate.

## 0.1 — Specification and contracts

Status: complete in this scaffold.

- Technical and design whitepapers.
- Architecture decisions and module boundaries.
- Configuration schema, API contract, MCP compatibility matrix, and security model.
- Test fixtures, Python parity oracle, mock endpoints, and repository CI.

Exit gate: `make check` passes from a clean checkout.

## 0.2 — Toolchain and assembly foundation

- NASM ELF64 build, linker configuration, debug/release modes.
- System V AMD64 ABI macros and C-call wrappers.
- Allocator, arena, dynamic buffer, string view, error type, and structured logger.
- Unit-test runner callable from shell and GDB/Valgrind developer workflow.

Exit gate: primitive tests pass and Valgrind reports zero invalid accesses and zero
`definitely lost` bytes.

## 0.3 — Configuration, persistence, and control plane

- JSON configuration loading and schema-equivalent runtime validation.
- Environment-based secret references.
- SQLite migrations and single-writer repository layer.
- Unix-domain control socket and request correlation IDs.

Exit gate: configuration and database round trips match fixtures; control socket rejects
unauthorized file permissions and malformed frames.

## 0.4 — Gateway baseline

- Loopback HTTP listener with llhttp-backed bounded HTTP/1.1 parsing.
- `/healthz`, `/readyz`, `/v1/models`, `/v1/responses`, and
  `/v1/chat/completions`.
- Generic OpenAI-compatible upstream adapter using libcurl multi.
- Streaming and non-streaming pass-through with backpressure and cancellation.

Exit gate: mock-provider contract tests pass for fragmented headers, JSON, SSE, disconnect,
timeout, and upstream error cases.

## 0.5 — Routing and resilience

- Priority, round-robin, and least-latency policies.
- Capability filtering, concurrency limits, health probes, circuit breaker, and cooldown.
- Safe pre-stream fallback and explicit no-failover-after-first-byte invariant.
- Request and upstream metadata persistence with payloads disabled by default.

Exit gate: assembly decisions match the Python oracle for the full route corpus and the
one-hour fault-injection soak has zero duplicate attempts after stream start.

## 0.6 — MCP stdio supervisor

- Direct process launch without shell.
- Modern `2026-07-28` `server/discover` probe and per-request metadata.
- Legacy `2025-11-25` initialization adapter.
- Capability cache, stderr capture, crash-loop protection, ping, list, and test-call tools.

Exit gate: mock and reference MCP servers pass lifecycle, malformed-output, timeout,
cancellation, and restart tests without zombie processes.

## 0.7 — MCP Streamable HTTP supervisor

- Modern POST-only request-scoped JSON/SSE transport.
- Version and header validation.
- Legacy Streamable HTTP compatibility adapter isolated from modern transport code.
- Remote auth header references and TLS policy.

Exit gate: compatibility matrix passes against modern and legacy fixtures; no session or
GET-stream behavior leaks into the modern adapter.

## 0.8 — TUI and operator workflow

- Overview, Providers, Routes, Requests, MCP, Logs, and Settings/Help screens.
- Compact 80x24 fallback, monochrome mode, `NO_COLOR`, command palette, and accessible
  non-color status labels.
- Export diagnostics with automatic redaction.

Exit gate: keyboard-only task script passes at 80x24, 100x30, and 140x40 with no clipped
critical action and no terminal left in raw mode after crashes.

## 0.9 — Hardening and release candidates

- Input fuzzing, ABI review, memory soak, concurrency benchmark, failure injection,
  package integrity, SBOM, release signing, and reproducible-build notes.
- User systemd unit, man pages, migration backup/restore, and upgrade guide.

Exit gate: all CI, security, soak, and benchmark thresholds pass on a tagged release
candidate.

## 1.0 — Stable Linux x86-64 release

1.0 means the documented contracts are stable, not that every provider-specific feature
exists. Compatibility shims may expand, but core invariants and configuration migration
rules cannot be broken without a major version.

## Post-1.0 candidates

- AArch64/Raspberry Pi 5 port.
- Optional provider-native adapters where OpenAI compatibility is insufficient.
- Read-only web observability endpoint.
- MCP subscriptions and selected extensions after explicit threat review.
- Debian/RPM packages.

## Deferred indefinitely unless scope is revised

- Built-in model inference.
- Autonomous agent loops.
- Automatic execution of model-generated MCP tool calls.
- Visual flow editor.
- Windows/macOS ports before the Linux contract is stable.
