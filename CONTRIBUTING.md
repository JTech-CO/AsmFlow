# Contributing to AsmFlow

AsmFlow welcomes protocol fixtures, tests, documentation, assembly modules, build
improvements, and security hardening. The project is deliberately strict about ABI,
memory ownership, routing correctness, and compatibility boundaries because small
mistakes in assembly can appear to work while corrupting state elsewhere.

## Before starting

1. Read `README.md`, `AGENTS.md`, `HARNESS.md`, `PROGRESS.md`, and `ARCHITECTURE.md`.
2. Check existing issues and the current milestone in `ROADMAP.md`.
3. For architecture changes, open a design issue before writing code.
4. Keep one pull request focused on one phase or one independently verifiable fix.

## Development environment

The target environment is Linux x86-64 with the System V AMD64 ABI. The planned
runtime dependencies are NASM, a C linker driver, libcurl, SQLite, ncursesw, and
Jansson. Python is used only for tests, mock servers, fixture generation, and parity
oracles.

At the specification stage, run:

```bash
make check
```

Implementation phases will add `make build`, `make test-unit`, `make test-contract`,
`make test-integration`, `make test-soak`, and `make bench` gates.

## Language boundary

Accepted first-party runtime code:

- NASM assembly for domain logic, state machines, routing, buffers, parsing control,
  process supervision, and application behavior.
- Minimal C shims only where a dependency exposes macro-heavy, variadic, or unstable
  calling surfaces that are unsafe to invoke directly from assembly.
- Shell and Python for build, release, test, mock, and analysis tooling only.

A C shim must:

- expose a narrow, documented, fixed-width ABI;
- contain no routing, retry, security-policy, provider-selection, or MCP lifecycle logic;
- have a corresponding contract test;
- be recorded in `docs/decisions/` if it introduces a new dependency or ownership rule.

Generated compiler assembly does not count as authored assembly.

## Assembly style

- NASM Intel syntax, ELF64 output.
- Follow the System V AMD64 ABI at every external boundary.
- Preserve `rbx`, `rbp`, and `r12`-`r15` across calls.
- Maintain 16-byte stack alignment before C calls.
- Use explicit ownership comments: `borrowed`, `owned`, `transferred`, or `static`.
- Pair every allocation path with a visible release path.
- Keep functions small enough to audit; prefer explicit state machines over clever jumps.
- Prefix exported symbols with `asmflow_` and internal symbols with their module name.
- Do not use self-modifying code, undocumented instructions, or CPU-specific extensions
  without a fallback and an ADR.

## Testing requirements

Every behavior change needs at least one of:

- unit test for pure assembly logic;
- parity case against the Python oracle;
- protocol-contract fixture;
- integration test using the mock provider or mock MCP server;
- regression test that fails before the fix.

Memory and FFI changes must pass Valgrind with zero definitely-lost bytes and no invalid
read/write. Streaming changes must test fragmented callbacks, client disconnects,
partial writes, and backpressure. Routing changes must prove that failover never occurs
after downstream bytes have been forwarded.

## Documentation requirements

Update relevant files in the same pull request:

- public behavior: `README.md`, `CHANGELOG.md`, API/config docs;
- architecture or invariant: `ARCHITECTURE.md`, `AGENTS.md`, and an ADR;
- milestone scope: `ROADMAP.md` and `PROGRESS.md`;
- new user-facing option: JSON Schema and an example configuration.

## Pull requests

A pull request should include:

- problem statement and chosen approach;
- changed invariants or an explicit statement that none changed;
- exact verification commands and their results;
- memory/ABI impact;
- security impact;
- documentation and fixture updates;
- screenshots only for TUI changes, accompanied by a text description.

Do not lower a threshold, delete a test, or relax secret handling solely to make CI pass.

## Commit messages

Use imperative, scoped messages where practical:

```text
routing: add deterministic least-latency tie break
mcp: isolate legacy initialization adapter
ffi: fix stack alignment before curl_easy_setopt shim
```

## Licensing

By contributing, you agree that your contribution is licensed under Apache License 2.0.
Do not submit code or fixtures that you do not have the right to redistribute.
