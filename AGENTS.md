# AGENTS.md — Codex operating rules for AsmFlow

## Mission

Implement AsmFlow as a Linux x86-64 NASM application that provides an
OpenAI-compatible LLM gateway and an MCP supervisor without moving the product's core
logic into a newer language. Codex is a collaborator, not an architecture authority.

## Required session start

Read, in order:

1. `PROGRESS.md`
2. `HARNESS.md`
3. `ARCHITECTURE.md`
4. the relevant file under `docs/`
5. the current phase's tests and fixtures

Work on one phase only. Do not start a later phase because an earlier module appears easy.

## Non-negotiable invariants

1. Runtime domain logic is authored in NASM assembly.
2. C shims are ABI adapters only; no routing, retry, provider, MCP lifecycle, security,
   or persistence policy in C.
3. System V AMD64 ABI is followed at every external boundary.
4. Stack alignment is 16 bytes immediately before a C call.
5. Callee-saved registers are preserved.
6. Every pointer has documented ownership: borrowed, owned, transferred, or static.
7. All size arithmetic is overflow-checked before allocation or copy.
8. All untrusted inputs have explicit byte, depth, count, and time limits.
9. Provider selection is deterministic for a fixed state snapshot.
10. Fallback is impossible after the first client-visible response byte.
11. Plaintext secrets are rejected by config validation.
12. MCP stdio commands use direct argument arrays; never invoke a shell.
13. Modern and legacy MCP adapters remain separate.
14. `asmflow-tui` never reads or writes SQLite directly.
15. Tests or thresholds are never weakened to manufacture a pass.

## Source boundaries

- `src/platform`: Linux x86-64 syscalls and OS adapters.
- `src/memory`: allocation, arenas, buffers, string views.
- `src/core`: results, errors, IDs, queues, timers.
- `src/json`: bounded JSON parsing, dependency wrappers, and normalized accessors.
- `src/config`: configuration model, schema-equivalent validation, secret references.
- `src/http`: listener, parsing envelope, response writer, SSE framing.
- `src/providers`: upstream request/response adapters.
- `src/routing`: candidate filtering and selection only.
- `src/mcp`: protocol and supervision.
- `src/storage`: migrations and SQL only.
- `src/control`: Unix-socket command protocol.
- `src/tui`: separate client binary.
- `src/ffi`: minimal C shims and ABI manifests.

Do not create cross-module imports that bypass this direction. Shared definitions belong
in `include/` only after a concrete second consumer exists.

## Implementation discipline

- Prefer small, auditable functions and explicit state tables.
- Add a failing test or fixture before a bug fix when reproducible.
- Use Python only as a test oracle or mock, never as runtime fallback.
- Do not add an SDK when the protocol can be handled by existing libcurl/JSON boundaries.
- Do not vendor large dependencies merely to simplify one call.
- Do not optimize before measurement; do not obscure ownership for micro-optimizations.
- Treat all external callbacks as re-entrancy and lifetime boundaries.

## Required verification

Run the current phase commands from `HARNESS.md`. For changes touching memory, ABI,
streaming, process supervision, or SQLite, also run the corresponding focused tests and
Valgrind/GDB checks. Record exact commands and outcomes in the pull request and
`PROGRESS.md`.

## Documentation synchronization

Update contracts in the same change:

- public behavior -> `README.md`, `CHANGELOG.md`, API/config docs;
- invariant/architecture -> `ARCHITECTURE.md`, this file, and an ADR;
- protocol fixture -> compatibility docs and test corpus;
- new option -> JSON Schema and examples;
- phase status -> `PROGRESS.md`.

## Session end

Before stopping:

1. run the phase gate;
2. update `PROGRESS.md` with completed work, next action, unresolved questions, and
   decisions;
3. ensure no secrets, build products, database files, or logs are staged;
4. leave the repository in a reproducible state.

When blocked, follow the STOP procedure in `HARNESS.md`; do not invent a bypass.
