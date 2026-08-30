# AsmFlow Progress

## Current phase

`M10 — TUI and CLI`

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

- 2026-08-27: M5 gateway HTTP listener and contract complete (`make gate-m5`).
  - `src/ffi/llhttp_shim.c` is the entire llhttp boundary (ADR 0006). Every
    leniency switch is cleared explicitly rather than left at a default, and
    the gate reads `llhttp.h` to prove none was missed.
  - `src/http/`: the TCP listener with a bounded connection table, the callback
    surface and the request policy applied to it, endpoint dispatch, the
    credential check, and the response writer.
  - The smuggling rules are AsmFlow's own statements rather than the library's
    defaults: a repeated `Content-Length`, `Content-Length` together with
    `Transfer-Encoding`, a coding other than `chunked`, an absolute-form
    target, and a repeated credential header are each refused and the
    connection closes. A 21-case corpus asserts that no second response ever
    follows.
  - Limits apply to what accumulates, not to what completes. The header ceiling
    caps what is fed to the parser while the section is still open, so the
    count is exact rather than an estimate a large body would spoil.
  - ADR 0010: one timerfd sweeps the table for idle connections, and a
    connection due to close is drained first. Closing a socket with unread
    bytes queued sends RST, and an RST destroys the very response explaining
    the refusal; the one-byte-fragment corpus found that on its first run.
  - `/healthz` reads no configuration and opens no handle; `/readyz` reports
    dependency state and route counts; `/v1/models` lists enabled aliases and
    nothing about the provider behind them.
  - Every failure the gateway can answer with is one row in one catalogue,
    checked against `docs/API_CONTRACT.md` 7 by the gate.
  - 137 assembly tests / 3574 checks, 77 HTTP integration tests across six
    suites, a 10,000-request soak with a flat resident set, Valgrind clean.

- 2026-08-27: M6 upstream client, Responses/Chat, and streaming complete
  (`make gate-m6`).
  - `src/ffi/curl_shim.c` is the whole libcurl boundary, driven through
    `curl_multi_socket_action` from AsmFlow's own epoll loop (ADR 0011). The
    two libcurl entry points that own the wait are absent from the shim, and
    the gate checks for their absence: using one would give the daemon a second
    reactor, and the symptom would be a control socket that stops answering
    while a provider is slow.
  - A generation request now suspends rather than being answered inside the
    dispatcher. The connection is marked, the idle sweep leaves it alone, the
    parser is not fed again until the exchange finishes, and a pipelined next
    request waits in the inbox — so responses on one connection stay ordered by
    construction.
  - Exactly one field of a request body is changed. Jansson re-emits the
    document because a JSON real has no decimal text recoverable from a double,
    and re-encoding one would change what was asked for to make the plumbing
    tidier.
  - The SSE framer finds event boundaries and never parses an event. Nothing
    decodes UTF-8, so a character split across two callbacks cannot be
    corrupted; the same stream at eleven packet sizes produces identical bytes.
    The one genuinely ambiguous case — a buffer ending in a bare CR — waits for
    the next byte rather than guessing, because guessing splits one event into
    two.
  - Backpressure is checked before bytes are consumed, because libcurl
    re-delivers what a paused callback did not take.
  - A client that disconnects cancels its transfer immediately. Refusing the
    next write callback is enough for a stream and not for anything else: a
    request whose provider has gone quiet produces no callbacks at all.
  - 30 assembly tests / 115 checks for `prov/`, 68 provider integration tests
    across four suites, Valgrind clean.

- 2026-08-27: M7 routing, health, circuit breaking, and fallback complete
  (`make gate-m7`).
  - `src/routing/`: candidate filtering in the whitepaper's documented order,
    the three policies the schema names, provider health with a circuit
    breaker, and observed latency as an integer EWMA.
  - The rules are stated twice and compared (ADR 0012). `tests/route_oracle.py`
    states them in Python and never links into the product;
    `tests/test_routing_parity.py` runs both over about fourteen hundred
    generated scenarios and fails on any disagreement in either the candidate
    set or the selection. Deliberately breaking four rules — inverting a
    tie-break, walking round-robin backwards, ranking unmeasured latency first,
    admitting a target at its concurrency ceiling — was caught by the corpus
    each time.
  - Runtime state is keyed by identifier and outlives every snapshot, so a
    reload that reorders providers cannot move an open circuit from one to
    another.
  - The selector is a pure function: no clock, no allocation, no mutation. The
    gate checks its call list rather than inferring purity from the
    hundred-repetition determinism test passing.
  - Fallback happens only before the commit point. That barrier turned out to
    be unreachable from the integration suite — every failure class that can
    occur after a head is written is a transport failure and none is retryable
    — so removing it changed nothing there. It is asserted directly in
    `tests/asm/test_provider.asm` instead, and removing it now fails two tests.
  - A concurrency slot is claimed in one place and released in one, on every
    path an attempt can end: success, failure, fallback, cancellation, timeout,
    and shutdown each have their own test.
  - `providers.list` reports live health, so an operator can see why traffic
    stopped reaching a provider.
  - 47 assembly tests / 183 checks across `route/` and `prov/`, 1400-scenario
    parity corpus, and five integration suites.

- 2026-08-29: M8 MCP stdio supervisor complete (component verification
  recorded below).
  - Child processes are launched with literal argv, an explicit cwd, and only
    allowlisted or mapped environment entries; no shell is involved. Embedded
    NUL is rejected, each `NAME=value` entry is capped at 128 KiB, and the
    complete owned `envp` allocation, including pointers, is capped at 1 MiB.
  - stdout is strict bounded NDJSON: invalid UTF-8, invalid JSON-RPC shapes,
    unmatched correlation, noise, blank lines, and oversized accumulated
    frames are protocol failures. stderr drains independently and retains the
    newest 64 KiB under its line and stream bounds.
  - Modern `server/discover` and legacy initialize are separate
    process-lifetime adapters. The negotiated `protocol_version` is owned by
    that process view; a timed-out discover is cancelled, stopped, and reaped
    before a fresh process receives legacy initialize.
  - Tools, resources, and prompts are fetched into bounded, semantically
    validated, transactional inventories. Current tools are required for
    readiness; optional resource/prompt refresh failures preserve the last
    validated cache.
  - All nine MCP control methods are live. Start, stop, restart, discover, and
    tool-test work is queued/asynchronous. `mcp.reset_crash_loop` synchronously
    clears only a latched crash-loop history and places that server on its
    restart path. `mcp.tool_test` also requires `confirmed=true`, validates the
    tool against current inventory, and is polled through `mcp.get`.
  - Restart accounting is a true sliding timestamp window with bounded
    exponential backoff and a crash-loop latch that only explicit reset clears.
    Stop, timeout, crash, EOF, shutdown, direct-child reap, and same-PGID helper
    cleanup paths leave zero zombies within their bounded budgets.
  - Focused M8 integration verification ran 38 tests with zero skips; native
    MCP verification ran 38 tests / 350 checks; the full native suite ran 222
    tests / 4155 checks; ABI verification ran 8 tests / 27 checks; MCP
    Valgrind reported 0 errors and 0 definitely lost bytes.

- 2026-08-30: M9 MCP Streamable HTTP and version adapters complete
  (`make gate-m9`).
  - One bounded MCP HTTP libcurl-multi engine is driven by the existing epoll
    and timerfd reactor; no blocking libcurl wait or runtime fallback language
    was introduced.
  - The modern `2026-07-28` adapter sends matching per-request `_meta` and
    `MCP-Protocol-Version`, accepts JSON or request-scoped SSE POST responses,
    and physically has no session, GET, DELETE, or `Last-Event-ID` state.
  - Era detection is exact: only an unrecognized bodyless HTTP 400 response to
    modern discovery selects legacy. Recognized JSON-RPC/version/header/method
    errors, redirects, 5xx responses, timeouts, and transport failures do not.
  - The isolated legacy `2025-11-25` allocation owns initialize/session state,
    initialized POST, session GET stream and optional resume ID. A legacy
    request timeout closes the transfer and posts explicit cancellation;
    modern cancellation closes only its request transfer.
  - HTTP credentials are resolved from environment SecretRefs at request
    construction. TLS verification is explicit, redirects and proxy discovery
    are disabled, and plaintext is limited to loopback or an explicit
    private/link-local IP-literal exception.
  - `ttlMs` and `cacheScope` commit transactionally with validated inventory.
    Positive monotonic TTLs refresh lazily, are capped at 300 seconds, legacy
    defaults to 60 seconds, and every cache stays server-local and partitioned
    by a non-secret authorization-context fingerprint.
  - The five focused M9 suites ran 17 tests with zero skips across nine
    fixtures; native MCP verification ran 38 tests / 350 checks; the full
    native suite ran 222 tests / 4167 checks; static M9 checks were 10/10; MCP
    Valgrind reported 0 errors and 0 definitely lost bytes.

## Next actions

1. Implement the ncursesw lifecycle and one cleanup path that restores echo,
   cursor, and terminal mode after normal exit, SIGINT, or daemon disconnect.
2. Add theme/monochrome behavior and responsive 80x24, 100x30, and 140x40
   layouts with priority-column collapse and no horizontal scrolling.
3. Build components and screens from control-protocol snapshots while
   preserving selection by stable ID across refreshes.
4. Add the keymap, keyboard task scripts, command palette, complete Level 2–4
   confirmation coverage, and a bounded/escaped log viewer.
5. Implement `asmflowctl` table output and `--json` output matching the control
   contract without direct SQLite access.
6. Add and pass `test-tui-layout`, `test-tui-keyboard`, `test-tui-mono`,
   `test-tui-terminal-restore`, and `test-cli-contract`.

## Open questions

- Whether 1.0 release artifacts should use glibc-only dynamic linking or also provide a
  musl build after the glibc path is stable.
- Whether HTTP/2 is required for 1.0 or merely supported when libcurl negotiates it.
- Whether the arena guard mode should be extended to the HTTP connection
  buffers or stay limited to request arenas.
- Whether the control protocol should gain a handshake carrying
  `protocol_version` before the first request, as `docs/API_CONTRACT.md` 12
  anticipates, or keep reporting it from `system.version` as it does now. The
  console in M10 is the first thing that would negotiate on it.
- Whether the exchange table should grow beyond 64 slots. It is a hard ceiling
  independent of `limits.max_active_requests`, which can lower it and cannot
  raise it. Sixty-four upstream sockets plus 128 clients fits the loop's
  256-source table with room; raising either would need both revisited.
- Whether a provider credential should be readable from a file as well as an
  environment variable. It is read at request time rather than cached on the
  snapshot, so the read is already pluggable; nothing has asked for it yet.
- Whether M11 should use cgroups or namespaces to contain MCP descendants that
  deliberately escape the supervised process group with `setsid` or
  `setpgid`. M8 cleans only the same process group and does not claim a sandbox.

## Resolved questions

- 2026-08-26: the Jansson boundary uses a minimal C shim rather than hard-coding
  the `json_t` layout in assembly. See ADR 0007.
- 2026-08-27: the listener address question is settled independently of the
  provider-URL one. `listener.host` must be an IPv4 literal, an IPv6 literal,
  or `localhost`, and `::1` both binds and counts as loopback. A hostname is
  refused, because a daemon whose exposure depends on a DNS answer is a daemon
  that a DNS answer can expose.
- 2026-08-30: bracketed IPv6 URL literals are unwrapped before address
  classification, so `[::1]` is loopback and private/link-local IPv6 literals
  remain gated by the explicit insecure-private-HTTP option.

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
| 2026-08-27 | llhttp's leniency switches are all cleared explicitly, and the gate reads the header to check | Leaving a switch at its default makes "leniency is disabled" a statement about a library version rather than about AsmFlow, and a switch added in a future release would arrive enabled-by-default with nobody noticing. |
| 2026-08-27 | The smuggling rules are restated in assembly even where llhttp already refuses them | A request-smuggling defence that depends on a library's default is a defence a version bump can remove. The corpus then proves something about this code rather than about llhttp. |
| 2026-08-27 | An absolute-form request target is refused, not answered as an unknown path | It is the classic desync: a front end routing by `Host` and a back end routing by URI serve two different requests from the same bytes. The form is the problem, so the form is what is refused. |
| 2026-08-27 | A listen address is an IP literal or `localhost`, never a hostname | Resolving a name to decide what to bind makes the daemon's exposure a function of a DNS answer. |
| 2026-08-27 | The header ceiling caps what is fed to the parser while the header section is open | Counting consumed bytes is exact only if none of them can be body. Capping the feed makes the count exact instead of an estimate that a large body would turn into a false refusal. |
| 2026-08-27 | One timerfd sweeps the table rather than a timer per connection (ADR 0010) | A timer per connection doubles the descriptor cost of a connection in order to enforce a property of the table, not of any member of it. |
| 2026-08-27 | A connection due to close is drained before it is closed (ADR 0010) | `close(2)` with unread bytes queued sends RST, and an RST discards data the peer has not read yet — which is exactly the response explaining the refusal. |
| 2026-08-27 | Requests are answered from inside the parse, in `on_message_complete` | A pipelined batch is then answered in order by construction, and the outbox ceiling bounds a pipelining client instead of a per-message pause. |
| 2026-08-27 | Every gateway failure is one row in one catalogue | The contract is a table; making the implementation a table too is what lets the gate check them against each other instead of a reviewer reading both. |
| 2026-08-27 | libcurl is driven by AsmFlow's loop rather than owning the wait (ADR 0011) | The two multi-interface entry points that block would make libcurl the reactor, and a daemon with two loops has no single answer to what it is waiting for. `curl_multi_socket_action` hands the wait back, and an upstream socket becomes an ordinary loop source. |
| 2026-08-27 | A timer request of zero milliseconds arms the timerfd for one nanosecond | libcurl forbids re-entering `curl_multi_socket_action` from inside a callback it is making, and "call me back immediately" is the request that invites exactly that. Going through the loop says the same thing without the re-entry. |
| 2026-08-27 | An upstream descriptor is deregistered, never closed | libcurl owns those sockets and reuses connections across transfers. Closing one would take a connection out from under a live transfer, and the fault would surface on whichever later request reused the descriptor number. |
| 2026-08-27 | The request body is re-emitted by Jansson, not by AsmFlow's writer | Our writer is exact for everything it can name, but a JSON real has no decimal text recoverable from a double. Re-encoding one would change a request's meaning in order to make the plumbing tidier. |
| 2026-08-27 | The SSE framer finds boundaries and never parses an event | Nothing decodes UTF-8, so a character split across two callbacks cannot be corrupted — there is no decode to get wrong. It also keeps AsmFlow a gateway: a component that understood the payload could change it. |
| 2026-08-27 | A buffer ending in a bare CR is undecidable, and the scanner says so | That CR is either a line ending or the first half of a CRLF still in flight. Guessing splits one event into two, and the split is invisible until a client renders it. |
| 2026-08-27 | The per-event ceiling is enforced by accumulating an event before forwarding it | A limit on a unit only means something if the unit exists. Forwarding as bytes arrive would put half an oversized event on the wire before the limit was reached, which is a limit that reports rather than defends. |
| 2026-08-27 | Backpressure is decided before any byte is consumed | libcurl re-delivers whatever a paused write callback did not take, so a callback that buffered and then paused would deliver the same bytes twice. |
| 2026-08-27 | A cancelled exchange is torn down at once, not flagged for later | Refusing the next write callback is enough for a stream, which produces callbacks. A request whose provider has accepted it and gone quiet produces none, so a flag would sit there until the provider's own timeout — with the client gone and the tokens still being generated. |
| 2026-08-27 | The outbox is compacted as it drains | A buffer with a write cursor keeps sent bytes until it empties completely, which for a stream is never until the stream ends. Without compaction a bounded outbox would have to hold the whole stream, which is the opposite of what bounding it is for. |
| 2026-08-27 | An upstream status classifies the response; it does not decide whether to send one | The transport succeeding means there IS a response. Turning every non-2xx into AsmFlow's own 502 would throw away the provider's explanation, which is usually the more useful of the two. |
| 2026-08-27 | Streaming is framed with chunked transfer coding | A streamed response has no length to state when its head is written. `Connection: close` plus a raw stream would work and would end the connection; chunked keeps it reusable. |
| 2026-08-27 | Routing state is keyed by identifier, not by array position (ADR 0012) | A reload can add, remove, or reorder providers. Keying on index would move an open circuit to whichever provider now occupies that slot, and the symptom would be a healthy provider starved of traffic while a broken one received all of it. |
| 2026-08-27 | The routing rules are stated twice and compared | A routing defect answers the request, and the answer parses, and nothing is logged. "Does it work" is not a question a test can ask; "does it agree with an independent statement of the rules" is. Four deliberate mutations confirmed the corpus discriminates. |
| 2026-08-27 | The selector reads no clock, allocates nothing, and mutates nothing | Determinism asserted by repetition is a property of those repetitions. Purity checked against the call list is a property of the code. |
| 2026-08-27 | Every tie-break is applied even where the preceding key already decided | The oracle applies them all. A shortcut that is correct today would make the parity test compare two different algorithms that happen to agree. |
| 2026-08-27 | Every routing policy is named explicitly, with no default branch | A fourth policy added to the schema later would otherwise be served silently as whichever one it fell through to. |
| 2026-08-27 | The concurrency counter is claimed in one place and released in one | A counter that is not returned on some path does not fail visibly: the provider looks progressively busier until it is permanently ineligible, and nothing in a log says why. |
| 2026-08-27 | A cancelled attempt is not recorded as a provider failure | Otherwise a client pressing stop repeatedly could open a circuit against a provider that never misbehaved. |
| 2026-08-27 | `af_monotonic_now` exists so a caller can ask for a reading | The out-parameter form is a trap in an assembly call site: a stale `rdi` writes eight bytes of clock over whatever it pointed at and returns a status that reads like a plausible timestamp. M6 shipped exactly that over the configuration snapshot's reference count, and nothing crashed. |
| 2026-08-27 | A test daemon is ready when it says it is, not when its socket answers | The control socket binds several startup steps before the upstream engine and the data-plane listener open their own descriptors, and that ordering is deliberate: an operator connecting mid-start should see `ready: false` rather than a refused connection. A descriptor baseline taken the moment the socket answered was counting a daemon that had not finished starting, and would then see three descriptors appear from nowhere — which is how the M4 disconnect test failed on one CI machine and passed on another from the same commit. |
| 2026-08-27 | A suite that needs a binary skips from the constructor, not from each test class | `make check` is the buildless M0 gate, so a suite needing a daemon must skip there rather than error. Stated per class it was forgotten by all seventeen M5 classes; stated once on the only path that spawns a daemon it cannot be. `make check-buildless` reproduces the condition on a machine that has built. |
| 2026-08-27 | A generation endpoint answers `unsupported_in_this_build`, not `not_ready` and not an empty completion | "A subsystem is absent from this binary" is a different fact from "a present subsystem is not usable yet", and an empty completion is indistinguishable from a real one. |
| 2026-08-29 | An MCP era belongs to one process lifetime; timed-out modern discovery falls back only through a fresh process | Cancellation is advisory. Reusing the probed process for legacy initialize could interleave eras if the server completed the cancelled request late. |
| 2026-08-29 | MCP inventory commits transactionally; validated tools are required for readiness while resources and prompts are optional caches | A malformed required tool list must not make a server ready, while an optional refresh failure must not destroy the last known-valid display state. |
| 2026-08-29 | Restart budgeting uses a true sliding timestamp window and crash-loop recovery requires an explicit reset | A tumbling window permits boundary bursts, and stop/start aliases must not bypass an operator-visible exhausted-budget latch. |
| 2026-08-30 | Modern and legacy MCP HTTP state use physically different adapter allocations | The modern type cannot accidentally acquire legacy session, GET-stream, or resume state through a shared optional field. |
| 2026-08-30 | Only an unrecognized bodyless HTTP 400 response to modern discovery is legacy evidence | Recognized JSON-RPC errors and transient transport failures prove either modern semantics or no era at all; treating either as downgrade evidence would hide faults. |
| 2026-08-30 | Modern HTTP timeout closes only the request transfer; legacy timeout also sends its session-scoped cancellation notification | The two revisions define different cancellation lifecycles, so sharing one policy would leak legacy behavior into modern requests. |
| 2026-08-30 | HTTP inventory caches remain server-local and use only a non-secret credential-change fingerprint | Even public cache scope cannot authorize cross-server or cross-credential reuse, and retaining the credential itself would create a new secret store. |
| 2026-08-30 | MCP HTTP redirects and proxy discovery are disabled and TLS verification is never controlled by the plaintext-private-network exception | A configured endpoint and credential must not be silently redirected or routed through ambient process settings, and allowing HTTP to a private literal is not permission to weaken HTTPS. |

## Last passed gate

**`BUILD_DIR=build make gate-m9` from the WSL repository root at
AsmFlow 0.8.0 — PASS (2026-08-30)**

M0 through M9 are all green.

- The five focused M9 integration targets ran 17/17 tests with zero skips:
  modern 3, legacy 2, version matrix 3, stream/cancellation 3, and security 6.
- The six focused M8 regression targets ran 38/38 tests with zero skips.
- `build/debug/asmflow-tests --filter mcp/ --verbose`: 38 tests / 350 checks.
- Full native `build/debug/asmflow-tests`: 222 tests / 4167 checks.
- Static ABI audit: 726 framed functions, 223 conforming leaf functions, and
  1 documented exemption.
- Static M9 gate checks: 10/10 PASS.
- MCP Valgrind: 0 errors / 0 definitely lost bytes.
