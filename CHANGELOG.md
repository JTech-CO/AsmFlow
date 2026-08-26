# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog and the project intends to use Semantic Versioning
once executable releases begin.

## [Unreleased]

### Planned

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
