# AsmFlow Test Strategy

## 1. Objective

Tests must prove behavior, invariants, and recovery—not merely that binaries start. The strategy combines
assembly unit tests, Python parity oracles, protocol fixtures, mock servers, fault injection, memory analysis,
fuzzing, terminal snapshot tests, benchmarks, and soak tests.

## 2. Test layers

### Layer A — Repository and contract validation

Current scaffold:

```bash
make check
```

Validates required files, JSON syntax, schema examples, secret policy, fixtures, and Python oracle tests.

### Layer B — Assembly unit tests

Targets pure functions:

- checked arithmetic;
- buffer growth and slicing;
- UTF-8/ASCII helpers;
- IDs and time conversion;
- route filtering and selection;
- circuit state transition;
- SSE framing;
- NDJSON framing;
- MCP era/error classification.

Every test has deterministic inputs and explicit expected registers/memory/output.

### Layer C — ABI tests

A small C probe calls assembly exports and assembly calls selected C functions.

Checks:

- stack alignment;
- callee-saved registers;
- argument order and width;
- struct layout offsets;
- return values;
- variadic shim behavior;
- callback context lifetime.

### Layer D — Parity oracles

Python reference implementations define expected behavior, not runtime fallback.

Initial oracle:

- candidate filtering;
- priority selection;
- round-robin selection;
- least-latency tie break;
- safe fallback eligibility.

Assembly and Python run the same JSON corpus. Any mismatch blocks the phase.

### Layer E — Contract fixtures

- OpenAI Chat request, response, and stream.
- OpenAI Responses request and semantic stream.
- MCP modern discovery and inventory.
- MCP legacy initialization.
- configuration valid/invalid cases.
- error normalization.

Fixtures are small, redistribution-safe, and contain no real credentials or copyrighted model output.

### Layer F — Mock integration

`tests/mock_provider.py` supplies:

- health endpoint;
- JSON Chat/Responses response;
- SSE stream;
- configurable delay, status, malformed data, and abrupt close.

`tests/mock_mcp_stdio.py` supplies:

- modern discovery;
- tools list;
- selected malformed/noise/crash modes;
- optional legacy mode during the implementation phase.

Future HTTP MCP mock uses the same standard-library-only policy.

### Layer G — Fault injection

Inject:

- malloc/realloc failure at every allocation index;
- partial read/write;
- `EINTR`, `EAGAIN`, connection reset;
- DNS/connect/TLS timeout;
- upstream 429/5xx;
- malformed/oversized JSON and SSE;
- client disconnect before and after commit;
- SQLite busy/I/O error;
- MCP child exit and stderr flood;
- terminal resize and daemon disconnect.

### Layer H — Memory, FD, and process analysis

- Valgrind Memcheck.
- `/proc/<pid>/fd` growth checks.
- Child process table vs `waitpid` results.
- RSS time series.
- C shim ASan/UBSan builds where compatible.
- Core/backtrace capture with test secrets only.

### Layer I — Fuzzing

Fuzz targets:

- config parser envelope;
- HTTP header/request envelope;
- JSON field extraction;
- SSE framer;
- NDJSON control framer;
- MCP modern/legacy era classifier;
- URL validation;
- redaction.

A fuzz input within configured maximum that crashes, hangs, or causes unbounded allocation is a defect.

### Layer J — TUI tests

- pseudo-terminal keyboard scripts;
- 80x24, 100x30, 140x40 golden text snapshots;
- mono/16/256 color modes;
- resize events;
- focus retention by stable ID;
- terminal restore after exit/signal;
- remote-string escape handling.

### Layer K — Benchmarks and soak

Metrics:

- local gateway overhead;
- first-event overhead;
- route selection latency;
- active stream memory;
- control response latency;
- TUI refresh latency;
- DB write throughput;
- restart and recovery time.

Soak profiles:

- 1 hour per risky phase;
- 8 hours for release candidate;
- mixed streaming/non-streaming;
- provider failures and recovery;
- MCP crash/restart;
- TUI connect/disconnect.

## 3. Invariant test table

| Invariant | Test |
|---|---|
| no fallback after first byte | provider sends one event then fails; attempt count remains 1 |
| deterministic routing | same corpus repeated 100 times and across fresh processes |
| no plaintext secret | seeded secret corpus searched in all outputs |
| TUI no direct DB | architecture/link/import check and file-open tracing |
| no shell MCP execution | metacharacter args received literally by mock child |
| modern/legacy isolation | modern state lacks session fields; legacy fixture never enters modern path |
| no zombie | repeated start/kill/timeout and process-tree assertion |
| bounded input | boundary-1, boundary, boundary+1 for every limit |
| control socket protection | mode/owner/unauthorized client tests |
| config reload atomicity | invalid reload leaves hash/revision/state unchanged |

## 4. Test data policy

- no real API keys;
- no user prompts or private logs;
- synthetic response text;
- stable IDs and timestamps where possible;
- large fixtures generated at test time rather than committed;
- random tests log seed;
- protocol fixtures record source specification revision.

## 5. CI stages

Planned:

1. repository validation;
2. debug build;
3. unit/ABI;
4. config/storage/control;
5. contract/integration;
6. route parity;
7. MCP matrix;
8. TUI PTY tests;
9. Valgrind selected suites;
10. package verification.

Long soak and fuzz campaigns run on scheduled or release workflows, not every pull request.

## 6. Failure triage

For each failure record:

- exact command;
- commit and tool versions;
- deterministic seed;
- expected/actual;
- smallest fixture;
- whether an invariant is affected;
- stack/register/FD/process evidence;
- whether prior phases must be reopened.

Do not rerun until green without understanding flaky behavior. A flaky test is a failing test.

## 7. Current scaffold tests

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 scripts/validate_repo.py
```

These tests validate contracts only and do not claim runtime functionality.
