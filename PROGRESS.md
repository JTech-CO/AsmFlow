# AsmFlow Progress

## Current phase

`M5 — Gateway HTTP listener and contract`

## Completed

- 2026-08-02: M0 specification and repository scaffold created.
  - Technical and design whitepapers completed.
  - Architecture, API, configuration, MCP, security, testing, and release contracts added.
  - Apache-2.0 project policies and GitHub collaboration files added.
  - Contract fixtures, mock endpoints, route oracle, and scaffold CI added.
  - `make check` established as the M0 gate.
- 2026-08-26: M1 toolchain and build foundation complete (`make gate-m1`).
  - NASM ELF64 debug and release builds, PIE with a non-executable stack, full
    RELRO, immediate binding, and `--fatal-warnings`.
  - `asmflowd` and `asmflow-tui` entry points: argument handling, `--version`,
    `--help`, usage errors, and nothing else.
  - Release binaries stripped with separate `.debug` files and a
    `.gnu_debuglink`; debug binaries keep DWARF.
  - `VERSION` is a build prerequisite, so `--version` cannot report a stale
    value.
  - `scripts/gate_m1.py` verifies version agreement, side-effect-free `--help`
    on a pseudo-terminal, the symbol policy, and the link security properties.
- 2026-08-26: M2 ABI, memory, and core primitives complete (`make gate-m2`).
  - `include/abi.inc`: one uniform frame shape (`AF_ENTER`/`AF_LEAVE`) that
    makes 16-byte call alignment and callee-saved preservation true by
    construction rather than by review.
  - `include/errors.inc`: the stable `af_status` code space.
  - Overflow-checked size arithmetic, an allocator with a block header,
    live-block accounting and deterministic failure injection, a bounded
    growable buffer, a request-scoped arena with an opt-in guard mode, string
    views, monotonic and realtime clocks with a test override, and ULID request
    identifiers.
  - Assembly unit-test runner with per-test leak detection: 55 tests, 492
    checks, zero failures.
  - `scripts/abi_audit.py` statically audits every assembly function (116
    framed, 111 conforming leaves, 1 documented exemption).
  - Valgrind memcheck: 0 errors, 0 leaks, all heap blocks freed.
  - Fatal-by-design scenarios (use-after-finalize, double free, foreign
    pointer free) verified from a parent process in `tests/test_asm_crash.py`.

- 2026-08-26: M3 JSON, configuration, and secret references complete
  (`make gate-m3`).
  - `src/ffi/json_shim.c` re-exports Jansson's macro accessors as functions
    (ADR 0007), so the `json_t` layout is no longer a build-time assumption. The
    type ordinals are asserted against the linked library rather than assumed.
  - `src/json/json.asm`: bounded parsing with byte, depth, string, and
    element-count ceilings. The depth check is a string-aware pre-scan over raw
    bytes, so a deeply nested document is refused before any node is built.
    Duplicate keys are rejected.
  - `src/config/` (ADR 0008): the configuration model, the schema-equivalent
    validator, environment secret references, and allowlisted `${XDG_*}` path
    expansion. Every rule in `config/asmflow.schema.json` is applied directly,
    including `additionalProperties: false` as an explicit unknown-key sweep.
  - A rejection reports an af_status code, an RFC 6901 JSON Pointer to the
    offending location, and the rule that was broken — and never a value from
    the file.
  - `asmflowd --check-config` loads a real configuration end to end.
  - `tests/config_corpus.py` states the rules a third time in Python;
    `tests/test_config_parity.py` runs the schema, the reference, and the
    assembly over 90 documents and fails on any disagreement. It found one:
    `redact_headers` was missing its `uniqueItems` check.
  - 10,000-iteration reload soak returns to the exact baseline live-block count.

- 2026-08-27: M4 SQLite, migrations, and the control plane complete
  (`make gate-m4`).
  - `src/json/json_write.asm`: JSON serialisation with the grammar enforced by
    construction, RFC 8259 escaping, and UTF-8 sanitisation — invalid sequences
    become U+FFFD rather than reaching an operator's terminal or making a frame
    undecodable.
  - `src/platform/linux_x86_64/loop.asm`: the single epoll reactor
    (ADR 0002). epoll carries a slot index rather than a pointer, and the
    dispatcher re-checks the descriptor, so a stale event cannot reach a
    reused slot's new owner.
  - `src/platform/linux_x86_64/signals.asm`: signals as loop events via
    signalfd (ADR 0009), so shutdown runs on the normal path.
  - `src/storage/`: the SQLite ABI, a transactional migration runner, and the
    single-writer repository. The whole ten-table schema is migration 1, and a
    failure injected at ANY of its statements rolls the version and the data
    back together.
  - `src/control/`: socket binding with the 0600/0700 permission policy and
    proven-stale detection, NDJSON framing with the ceiling applied to what
    accumulates rather than to a completed frame, request dispatch, and ten
    working methods.
  - `asmflowd` runs for real: loads configuration, migrates storage, projects
    the configuration into the database, binds the control socket, serves from
    the loop, and shuts down cleanly on SIGTERM or SIGINT.
  - 118 assembly tests / 3304 checks; 27 integration tests against a live
    daemon; Valgrind clean on the storage and loop suites.

## Next actions

1. Add the TCP listener with bounded accept, per-connection state, and the
   idle timeout.
2. Wire llhttp through `src/ffi/` for incremental HTTP/1.1 syntax, with
   leniency disabled.
3. Apply the header, body, depth, and timeout limits from the configuration,
   and reject conflicting or duplicated framing headers.
4. Implement `/healthz`, `/readyz`, `/v1/models`, and the dispatch stubs for
   `/v1/responses` and `/v1/chat/completions`.
5. Refuse a non-loopback listener without an authentication policy at bind
   time as well as at load time.
6. Add `scripts/gate_m5.py`: a smuggling corpus, a 1-byte-fragment corpus, a
   slowloris and client-reset fault suite, and a 10,000-request RSS soak.

## Open questions

- Whether 1.0 release artifacts should use glibc-only dynamic linking or also provide a
  musl build after the glibc path is stable.
- Whether HTTP/2 is required for 1.0 or merely supported when libcurl negotiates it.
- Whether the arena guard mode should be extended to the HTTP connection buffers
  once M5 exists, or stay limited to request arenas.
- Whether the control protocol should gain a handshake carrying
  `protocol_version` before the first request, as `docs/API_CONTRACT.md` 12
  anticipates, or keep reporting it from `system.version` as it does now. The
  console in M10 is the first thing that would negotiate on it.
- Whether a bracketed IPv6 literal such as `https://[::1]/v1` should be
  recognised as loopback. It currently is not, so such a URL needs HTTPS or the
  explicit insecure-HTTP exception. That is the safe direction, but it is a
  divergence from what an operator would expect and should be settled before
  M5 binds a listener.

## Resolved questions

- 2026-08-26: the Jansson boundary uses a minimal C shim rather than hard-coding
  the `json_t` layout in assembly. See ADR 0007.

## Decision log

| Date | Decision | Reason |
|---|---|---|
| 2026-08-02 | Linux x86-64 and NASM first | Preserves project thesis while keeping ABI and deployment scope finite. |
| 2026-08-02 | Separate daemon and TUI | Isolates terminal failures and makes daemon state single-owner. |
| 2026-08-02 | Responses primary, Chat Completions compatibility | Supports modern API semantics without abandoning broad local-runtime compatibility. |
| 2026-08-02 | Modern MCP 2026-07-28 plus isolated legacy 2025-11-25 adapter | Current MCP changed versioning and transport semantics; adapter separation prevents state leakage. |
| 2026-08-02 | No automatic MCP tool execution in 1.0 | Keeps the project a gateway/supervisor rather than an autonomous agent runtime. |
| 2026-08-02 | JSON config with environment secret references | Reuses required JSON capability and avoids a second complex parser. |
| 2026-08-02 | llhttp only for inbound HTTP syntax parsing | Avoids hand-written grammar risk while keeping sockets, limits, auth, and response policy in Assembly. |
| 2026-08-26 | One uniform stack frame for every non-leaf function | Saving all five callee-saved registers unconditionally costs ten instructions and removes an entire class of ABI defect; `scripts/abi_audit.py` can then check the shape mechanically. |
| 2026-08-26 | Allocation block header with a magic value, checked in release too | A corrupted or double-freed header means memory is already being written out of bounds; continuing would turn a contained defect into arbitrary heap corruption. |
| 2026-08-26 | Arena guard mode is opt-in, not the debug default | Retained `PROT_NONE` mappings are the right diagnostic for a use-after-finalize test, but would exhaust address space during the 10,000-iteration reload soak in M3. |
| 2026-08-26 | Test registry uses self-relative 32-bit offsets | Absolute pointers in a PIE need a dynamic relocation, which would force the table to be writable or produce a text relocation; offsets resolve at link time. |
| 2026-08-26 | ABI conformance is audited statically for all functions and dynamically for representatives | Calling every export with synthetic arguments is not feasible for pointer-taking functions; the structural property that AF_ENTER guarantees is checkable for all of them. |
| 2026-08-26 | Jansson's macro accessors are re-exported through a C shim (ADR 0007) | Hard-coding the `json_t` layout would fail silently on a library upgrade: every document would be interpreted as the wrong type, with no compile or link error. |
| 2026-08-26 | Configuration is `src/config`, not part of `src/json` (ADR 0008) | `src/json` is documented as holding no policy, and validation is roughly two thousand lines of policy. |
| 2026-08-26 | The JSON depth check runs on raw bytes before the parse | Jansson's depth ceiling is a compile-time constant. Checking after the parse would mean building the nodes first, which makes the limit a report rather than a defence. |
| 2026-08-26 | Configuration rules are stated three times: schema, assembly, Python reference | Two implementations disagreeing tells you something is wrong; three tell you which one. The parity test found a real omission on its first run. |
| 2026-08-26 | A rejection message names the rule, never the value | A configuration rejection is logged before the file's own redaction policy is available, so it cannot echo the file's contents. |
| 2026-08-27 | Signals arrive through signalfd, not handlers (ADR 0009) | Almost nothing shutdown needs to do is async-signal-safe; as a loop event it runs on the normal path with the whole runtime available. |
| 2026-08-27 | epoll carries a slot index, not a pointer | An index can be validated against the table and re-checked against the descriptor; a stale pointer cannot, and would dispatch a dead connection's event to whoever reused its slot. |
| 2026-08-27 | The whole schema is migration 1, statement by statement | One transaction per migration with its version row inside it means a crash can never leave a database claiming a version whose statements did not all run; per-statement granularity is what lets the rollback test inject at every position. |
| 2026-08-27 | A stale control socket is unlinked only after a connect proves it dead | Removing whatever is at the path would let a second daemon silently steal a live socket from the first. |
| 2026-08-27 | The frame ceiling applies to accumulated bytes, not to a completed frame | Waiting for the terminator before checking would let a peer that never sends one grow the buffer without bound, which is what the ceiling exists to prevent. |
| 2026-08-27 | A method whose subsystem is unbuilt returns `unsupported_in_this_build` | An empty result would claim there is nothing to report, which is a different fact from being unable to report. |
| 2026-08-27 | The daemon's long-lived state is one heap block | The loop's source table and the control server's connection table are kilobytes each; a stack frame would silently overrun, and one zeroed block makes teardown safe from the first failure onward. |
| 2026-08-27 | The include directory is one macro namespace, checked by `make check` | NASM lets a later `%define` replace an earlier one with no warning, so a name chosen twice makes meaning depend on include order. `RT_SIZE` was defined by both `config.inc` and `runtime.inc`, and the one file including both crashed on any route with two targets. |

## Last passed gate

`make gate-m4` at AsmFlow 0.3.0 — M0 through M4 all green:
118 assembly tests / 3304 checks, 5 crash-scenario tests, 6 configuration
parity tests over a 90-document corpus, 27 control-protocol integration tests
against a live daemon, a 10,000-iteration reload soak returning to baseline,
Valgrind 0 errors and 0 leaks, ABI audit clean over 579 assembly functions
(401 framed, 177 conforming leaves, 1 documented test-fixture exemption).
