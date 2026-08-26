# AsmFlow — Codex 작업 하네스 (Harness)

**버전**: 0.1.0-spec  
**작성일**: 2026년 8월 2일  
**관계 문서**: 루트 `AGENTS.md`(전역 규칙·불변식), `PROGRESS.md`(상태 인계),
`ARCHITECTURE.md`, `docs/TECHNICAL_WHITEPAPER_KR.md`,
`docs/DESIGN_WHITEPAPER_KR.md`, `docs/TEST_STRATEGY.md`

> 이 문서는 **무엇을 만드는가가 아니라 어떻게 진행·검증·복구하는가**를 정의한다.
> 각 Phase의 완료는 코드가 실행되는지가 아니라 측정 가능한 Definition of Done을 전부
> 통과했는지로 판정한다. AsmFlow처럼 Assembly, C ABI, Streaming, Child Process,
> SQLite, MCP Protocol이 만나는 시스템은 “에러 없이 실행되지만 상태가 이미 오염된”
> 경우가 많으므로, Gate를 우회하면 다음 Phase 전체가 신뢰할 수 없게 된다.

---

## 0. 사용법

### 0.1. 세션 루프

1. **시작**: `PROGRESS.md` → 현재 Phase → 다음 할 일 → 미결 질문을 읽는다.
2. `AGENTS.md`의 불변식과 본 문서의 해당 Phase를 확인한다.
3. 관련 Whitepaper, Contract, Fixture, ADR만 추가로 읽는다.
4. **작업**: 한 번에 한 Phase의 한 검증 가능한 단위만 변경한다.
5. 각 작업 단위 뒤에 가장 작은 검증 명령을 실행한다.
6. Phase 종료 전 전체 Gate를 실행한다.
7. **종료**: `PROGRESS.md`의 완료·다음 작업·미결 질문·결정 로그를 갱신한다.
8. Secret, Binary, DB, Log, Core Dump가 Staging되지 않았는지 확인하고 Commit한다.

### 0.2. Phase 완료 판정

- DoD 항목을 **모두** 충족해야 완료다.
- 한 항목이라도 미달이면 현재 Phase를 유지한다.
- “일단 다음 기능을 구현하면 같이 해결될 것”이라는 이유로 진행하지 않는다.
- Gate 수치가 비현실적이라고 판단되면 코드를 우회하지 말고 근거·측정·대안을 기록한
  ADR과 사용자 승인을 먼저 받는다.

### 0.3. 의존 순서

```text
M0 → M1 → M2 → M3 → M4 → M5 → M6 → M7 → M8 → M9 → M10 → M11 → M12
```

- M8과 M9의 세부 Fixture 작업은 병렬 가능하지만 M8의 공통 MCP Message Core가 먼저다.
- M10 TUI Wireframe·Snapshot Test는 앞서 준비할 수 있으나 Control Protocol이 안정되기
  전 Runtime 연결을 완료 처리하지 않는다.
- M11 Security는 모든 Phase에 적용되지만 전체 Threat Gate는 통합 후 수행한다.

### 0.4. `PROGRESS.md` 최소 구성

- 현재 Phase
- 직전에 완료한 것
- 다음 할 일
- 재현 가능한 미결 문제
- 결정 로그: 날짜 / 결정 / 이유 / 영향 파일
- 마지막으로 통과한 Gate와 Commit SHA

세션이 끊겨도 이 파일과 현재 Branch만으로 다음 Codex 세션이 이어져야 한다.

### 0.5. Phase 공통 증빙

각 Phase 완료 Commit에는 다음 중 해당 내용을 남긴다.

- 실행 명령과 Exit Code
- Test Count와 실패 0건
- Valgrind Summary
- Benchmark JSON/Markdown
- Fixture 또는 Golden Output Diff
- Protocol Trace의 Redacted Version
- Terminal Snapshot과 Text 설명
- 새 ADR 번호

---

## 1. Phase별 진입조건 · 할 일 · DoD · 검증

### M0 — 사양·계약·저장소 스캐폴딩

- **진입조건**: 빈 저장소 또는 문서 템플릿 확보
- **할 일**: Whitepaper → Architecture → Harness/Agents → Policies → Config Schema →
  Examples → Fixtures/Oracle → CI
- **참조**: 저장소 전체 문서
- **DoD**:
  1. 사용자 요청 파일과 디렉터리가 모두 존재한다.
  2. 기술·디자인 백서에 미치환 Template Marker가 없다.
  3. 모든 JSON Example과 Fixture가 Parsing된다.
  4. Plaintext Secret Example이 없다.
  5. Route Oracle Unit Test가 통과한다.
  6. Apache-2.0 License 전문이 존재한다.
  7. `make check`가 Clean Checkout에서 Exit 0이다.
- **검증**:

```bash
make check
```

- **주의**: 이 Phase는 제품 Binary가 없음을 명확히 표시해야 한다. 문서 스캐폴딩을
  구현 완료로 오인하지 않는다.

### M1 — Toolchain 및 Build Foundation

- **진입조건**: M0 Gate 통과
- **할 일**: `Makefile` Build 확장 → Linker Flags → `src/platform/.../entry.asm` →
  `src/tui/entry.asm` → Debug/Release Targets → Symbol Map → GDB/Valgrind Targets
- **참조**: 기술 백서 §3, §4.5, `docs/BUILD_AND_RELEASE.md`
- **DoD**:
  1. `asmflowd --version`과 `asmflow-tui --version`이 `VERSION`과 일치한다.
  2. 두 Binary가 `--help` 후 Exit 0이며 Terminal Mode를 변경하지 않는다.
  3. Debug Build에 DWARF Symbol이 있고 Release Build는 의도된 Strip 정책을 따른다.
  4. Linker Warning 0, Executable Stack 0, Text Relocation 0이다.
  5. CI와 Local의 Build 명령이 동일하다.
  6. Build Artifact가 Git에 추적되지 않는다.
- **검증**:

```bash
make clean build-debug build-release
build/debug/asmflowd --version
build/debug/asmflow-tui --help
readelf -W -l build/release/asmflowd | grep -A1 GNU_STACK
readelf -W -d build/release/asmflowd
make check
```

- **주의**: 이 단계에서 Network, SQLite, TUI Screen 기능을 시작하지 않는다.

### M2 — ABI·Memory·Core Primitive ★

- **진입조건**: M1 Gate 통과
- **할 일**: ABI Macro → C Probe → Result/Error → Allocator Wrapper → Arena → Buffer →
  String View → Checked Arithmetic → ID/Clock → Unit Test Runner
- **참조**: 기술 백서 §4.5, `AGENTS.md`
- **DoD**:
  1. 모든 Exported Function이 System V AMD64 ABI Probe를 통과한다.
  2. C Call 직전 Stack Alignment Test 100% 통과한다.
  3. Callee-saved Register Corruption 0건이다.
  4. Buffer Append Corpus에서 Overflow·Max 초과가 명시적 오류로 반환된다.
  5. Allocation Failure 주입 시 Double Free, Leak, State Corruption이 없다.
  6. Arena Pointer가 Finalize 후 접근되는 Test가 Debug Assertion으로 잡힌다.
  7. Valgrind Invalid Read/Write 0, Definitely Lost 0이다.
  8. 단위 테스트가 고정 Seed에서 결정론적으로 재현된다.
- **검증**:

```bash
make test-abi test-unit
make test-alloc-failure
make valgrind-unit
make gdb-abi-smoke
```

- **주의**:
  - ABI 오류를 C Wrapper 추가로 가리지 않는다.
  - Memory Ownership Comment가 없는 Pointer API는 Merge하지 않는다.
  - “Valgrind가 Assembly를 완벽히 이해하지 못한다”는 이유로 실제 Invalid Access를 무시하지 않는다.

### M3 — JSON·Configuration·Secret Reference

- **진입조건**: M2 Gate 통과
- **할 일**: JSON ABI Wrapper → Bounded Parse → Config Model → Schema-equivalent Validation →
  SecretRef → Immutable Snapshot → Reload → Redacted Dump
- **참조**: `docs/CONFIGURATION.md`, `config/asmflow.schema.json`
- **DoD**:
  1. `examples/asmflow.minimal.json`과 `full.json`을 정상 Load한다.
  2. 모든 Invalid Fixture를 기대 오류 코드와 JSON Pointer 위치로 거부한다.
  3. Unknown Key 정책이 Schema와 Runtime에서 일치한다.
  4. Plaintext Secret Field는 100% 거부된다.
  5. Missing Environment Secret은 Ready 진입 전에 실패한다.
  6. Config Reload 실패 시 이전 Snapshot Hash와 Runtime State가 변하지 않는다.
  7. Reload 10,000회 Soak에서 Leak 0이다.
  8. Python Contract Validator와 Assembly Validator의 Accept/Reject 결과 불일치 0이다.
- **검증**:

```bash
make test-config test-config-parity
make test-config-reload-soak
make valgrind-config
```

- **주의**: Schema Library를 Runtime Dependency로 추가해 Assembly Validator를 생략하지 않는다.
  Schema는 계약이고 Runtime은 동일 규칙을 직접 적용한다.

### M4 — SQLite·Migration·Control Plane

- **진입조건**: M3 Gate 통과
- **할 일**: SQLite ABI → Migration Runner → Repository → WAL/Busy Policy → UDS Listener →
  NDJSON Control Protocol → Snapshot/Mutation Commands
- **참조**: `docs/API_CONTRACT.md`, `docs/SECURITY_MODEL.md`
- **DoD**:
  1. 빈 DB에서 최신 Schema까지 Transaction Migration 성공한다.
  2. 각 Migration 중간 실패 주입 후 Schema Version과 Data가 Rollback된다.
  3. CRUD 왕복 결과가 Domain Model과 일치한다.
  4. 데몬 외 Process가 DB를 직접 쓰는 Integration Test가 존재하지 않는다.
  5. Control Socket Mode가 `0600`, Parent Directory가 `0700`이다.
  6. 1 MiB 초과 Frame, Invalid JSON, Unknown Command를 안전하게 거부한다.
  7. Control Client 100개 연결/해제 후 FD Leak 0이다.
  8. DB Write Failure가 Read-only Snapshot Command와 데몬 생존을 방해하지 않는다.
- **검증**:

```bash
make test-migrations test-storage test-control
make test-control-fd-soak
make valgrind-storage
```

- **주의**: TUI 또는 Test Helper가 편의를 위해 SQLite를 직접 수정하지 않는다.

### M5 — Gateway HTTP Listener 및 Contract

- **진입조건**: M4 Gate 통과
- **할 일**: TCP Listener → llhttp ABI/Callback Adapter → HTTP Envelope → Limits → Auth → Health/Ready →
  Models → Responses/Chat Dispatch Stub → Client Writer
- **참조**: `docs/API_CONTRACT.md`, 기술 백서 §2.1~2.2
- **DoD**:
  1. `/healthz`는 Process Liveness, `/readyz`는 Dependency Readiness를 구분한다.
  2. `/v1/models`는 Enabled Route Alias만 노출하고 Provider Secret/URL을 노출하지 않는다.
  3. 지원 Method/Path/Content-Type의 Status Code가 계약과 일치한다.
  4. Header/Body/Depth/Timeout Limit Boundary Test가 통과한다.
  5. llhttp Leniency가 비활성이고 Smuggling Corpus의 CL/TE·중복 Framing·Invalid Header가 전부 거부된다.
  6. 1-byte Fragment와 Chunked Request Corpus가 동일한 정규화 결과를 낸다.
  7. Slowloris, Partial Request, Client Reset에서 데몬 Crash와 FD Leak이 없다.
  8. Non-loopback + Auth 없음 설정은 시작 단계에서 거부된다.
  9. 10,000개 순차 Health Request에서 RSS가 안정 구간을 유지한다.
- **검증**:

```bash
make test-http-contract test-http-limits test-http-smuggling
make test-http-fragments test-http-faults test-http-soak
```

- **주의**: 범용 완전 HTTP Server를 목표로 확장하지 않는다. 계약에 필요한 표면만 구현한다.

### M6 — Upstream Client·Responses/Chat·Streaming ★

- **진입조건**: M5 Gate 통과
- **할 일**: libcurl multi ABI → Provider Adapter → Header Builder → Body Transform →
  Non-streaming → SSE Framer → Backpressure → Cancellation → Finalizer
- **참조**: 기술 백서 §4.2~4.4, OpenAI Fixture, `docs/API_CONTRACT.md`
- **DoD**:
  1. Responses와 Chat 비스트리밍 Request/Response Fixture가 왕복한다.
  2. Unknown 허용 필드와 SSE Event가 손실 없이 전달된다.
  3. SSE Fragment Corpus: 1-byte Fragment, CRLF, Multi-event Callback, UTF-8 Split 전부 통과한다.
  4. Client Slow-read에서 Output Buffer가 상한을 넘지 않고 Curl Pause/Resume이 동작한다.
  5. Client Disconnect가 Upstream Cancel로 전파된다.
  6. Curl Easy/Multi/Header List/Buffer Leak 0이다.
  7. Upstream TLS·Timeout·Malformed Response가 정규화된 Error Class로 변환된다.
  8. Mock Provider 1시간 Stream Soak에서 Event 순서·Byte Count 불일치 0이다.
- **검증**:

```bash
make test-provider-contract test-sse-fragments test-backpressure
make test-client-cancel test-stream-soak
make valgrind-provider
```

- **주의**:
  - libcurl Callback 1회가 JSON 또는 SSE Event 1개라고 가정하지 않는다.
  - 수신 Body 전체를 무조건 Buffering해 Streaming을 흉내 내지 않는다.
  - Provider-specific Feature를 Generic Adapter에 임시 조건문으로 누적하지 않는다.

### M7 — Routing·Health·Circuit·Fallback ★

- **진입조건**: M6 Gate 통과
- **할 일**: Capability Filter → Priority → Round-robin → EWMA Least-latency → Health →
  Circuit Breaker → Attempt State → Commit Barrier → Fallback → Request Metadata
- **참조**: 기술 백서 §4.3, `tests/route_oracle.py`
- **DoD**:
  1. 전체 Route Corpus에서 Python Oracle과 Candidate/Selection 불일치 0이다.
  2. 동일 Snapshot과 Input의 결과가 100회 반복에서 동일하다.
  3. Tie-break가 Config Order와 Stable ID 규칙을 따른다.
  4. Monotonic Clock 기반 Circuit State 전이가 Golden Timeline과 일치한다.
  5. Pre-commit Retryable Error에서만 Fallback이 발생한다.
  6. Client에 1 Byte 전달 후 Fallback Attempt 0이다.
  7. Fallback Attempt가 Max Attempts와 Already-tried Set을 초과하지 않는다.
  8. Fault-injection Soak에서 중복 Client-visible Response와 Mixed Provider Stream 0이다.
  9. Provider Concurrency Counter가 모든 종료 Path에서 원복된다.
- **검증**:

```bash
make test-routing-parity test-circuit-timeline
make test-fallback-invariant test-routing-concurrency
make test-routing-fault-soak
```

- **주의**: 이 Phase는 AsmFlow의 핵심 가치이자 위험 구간이다. Test를 통과하지 못한 상태로
  MCP나 TUI를 붙이면 잘못된 라우팅이 정상처럼 보이게 된다.

### M8 — MCP stdio Supervisor ★

- **진입조건**: M7 Gate 통과, 공통 JSON-RPC Core 준비
- **할 일**: argv/env/cwd Validation → fork/exec/pipe → Child Table → stdout Framer →
  stderr Capture → Modern Probe → Legacy Initialize Adapter → Inventory → Call Test →
  Restart Budget → Shutdown/Wait
- **참조**: `docs/MCP_COMPATIBILITY.md`, `docs/SECURITY_MODEL.md`
- **DoD**:
  1. Shell을 호출하지 않고 argv 그대로 Child를 실행한다.
  2. Env Allowlist 밖의 Variable이 Child에 전달되지 않는다.
  3. Modern Mock Server의 `server/discover`, `tools/list`가 통과한다.
  4. Legacy Mock Server의 initialize/initialized 흐름이 통과한다.
  5. Era Detection 결과가 Process Lifetime 동안 일관되고 Restart 후 재Probe된다.
  6. stdout Noise, Oversized Line, Invalid UTF-8/JSON을 안전하게 처리한다.
  7. stderr Flood가 Protocol Pipe를 막지 않고 상한·Rotation을 적용한다.
  8. Timeout/Cancel/Stop/Kill 모든 Path에서 Zombie 0이다.
  9. Crash Budget 초과 시 자동 Restart가 중지되고 Manual Reset 전 재시작하지 않는다.
  10. Tool Test는 운영자 Confirm Flag 없이는 거부된다.
- **검증**:

```bash
make test-mcp-stdio-modern test-mcp-stdio-legacy
make test-mcp-stdio-malformed test-mcp-process-lifecycle
make test-mcp-crash-loop test-mcp-zombie-soak
```

- **주의**:
  - stdout 로그를 관대하게 무시해 Protocol Corruption을 숨기지 않는다.
  - `system()` 또는 `/bin/sh -c` 사용 금지.
  - ServerInfo는 표시용이며 Security Decision 근거로 사용하지 않는다.

### M9 — MCP Streamable HTTP 및 Version Adapter ★

- **진입조건**: M8의 공통 MCP Message/Inventory Model Gate 통과
- **할 일**: Modern HTTP Headers → POST JSON/SSE → Version Error → Era Detection →
  Legacy Adapter → Auth SecretRef → TLS/Redirect Policy → Cache TTL → Cancellation
- **참조**: `docs/MCP_COMPATIBILITY.md`, 최신 MCP Fixture
- **DoD**:
  1. Modern 요청 Body `_meta`와 `MCP-Protocol-Version` Header가 일치한다.
  2. `Accept`가 JSON과 SSE를 모두 포함한다.
  3. Modern Adapter에서 GET Stream, Session ID, Last-Event-ID 사용 0이다.
  4. Request-scoped SSE의 Notification과 Final Response 순서를 보존한다.
  5. SSE 연결 종료가 해당 Request Cancellation로 처리된다.
  6. Recognized Modern Error와 Legacy Fallback 신호를 정확히 구분한다.
  7. Modern/Legacy Compatibility Matrix의 예상 결과와 일치한다.
  8. HTTP Plaintext Remote, Unsafe Redirect, Plaintext Auth Config를 거부한다.
  9. Cache TTL/Scope가 Server/Authorization 경계를 넘지 않는다.
- **검증**:

```bash
make test-mcp-http-modern test-mcp-http-legacy
make test-mcp-version-matrix test-mcp-http-stream
make test-mcp-http-security
```

- **주의**: `2025-11-25`의 Session/Get Stream 동작을 Modern 코드에 재사용하지 않는다.

### M10 — TUI 및 CLI

- **진입조건**: M4 Control Protocol 안정, M7~M9 Snapshot 필드 안정
- **할 일**: TUI Lifecycle → Theme/Mono → Layout → Keymap → Components → Screens →
  Command Palette → Confirm → Log Viewer → CLI JSON/Table → Crash Cleanup
- **참조**: `docs/DESIGN_WHITEPAPER_KR.md`
- **DoD**:
  1. 80x24, 100x30, 140x40 Golden Layout Test가 통과한다.
  2. 가로 Scroll 없이 Priority Column Collapse가 적용된다.
  3. Color 0개 환경에서 모든 상태가 Text Label로 구분된다.
  4. Keyboard Task Script 전체 통과한다.
  5. Level 2~4 Action의 Confirm Coverage 100%다.
  6. TUI 종료·SIGINT·Daemon Disconnect 후 Terminal Echo/Cursor가 정상 복구된다.
  7. Snapshot Refresh가 Stable ID Selection을 보존한다.
  8. TUI가 Secret·Prompt·Response를 기본 화면에 표시하지 않는다.
  9. `asmflowctl --json` 출력이 Control Contract와 일치한다.
- **검증**:

```bash
make test-tui-layout test-tui-keyboard test-tui-mono
make test-tui-terminal-restore test-cli-contract
```

- **주의**: Assembly 프로젝트라는 이유로 Retro Animation이나 장식 기능을 먼저 구현하지 않는다.

### M11 — Security·Observability·Recovery

- **진입조건**: M5~M10 기능 통합
- **할 일**: Threat Checklist → Redaction → Auth → Permissions → Limits → Diagnostic Export →
  Backup/Restore → Signal/Crash Recovery → Audit Events → Fuzz Harness
- **참조**: `SECURITY.md`, `docs/SECURITY_MODEL.md`, `docs/TEST_STRATEGY.md`
- **DoD**:
  1. Secret Corpus가 Log/DB/Export/Crash Message에 나타나는 사례 0이다.
  2. Non-loopback Auth Bypass 0이다.
  3. UDS/File/Directory Permission Test 전부 통과한다.
  4. HTTP/JSON/SSE/MCP Config Fuzz에서 Crash·Hang·Unbounded Allocation 0이다.
  5. DB Backup→Restore 후 Config/Route/MCP Metadata 의미가 일치한다.
  6. SIGTERM Graceful Shutdown이 새 요청 수락 중단→진행 요청 유예→MCP 종료→DB Close 순서다.
  7. SIGKILL 후 다음 시작에서 Migration·WAL·Stale Socket 복구가 통과한다.
  8. Diagnostic Export가 재현에 필요한 Version/Config Hash/Error를 포함하고 Payload는 Redact한다.
- **검증**:

```bash
make test-security test-redaction test-permissions
make fuzz-smoke test-backup-restore
make test-crash-recovery test-graceful-shutdown
```

- **주의**: Fuzzer Crash를 “현실적 입력이 아님”으로 닫지 않는다. 입력 상한 내 Crash는 결함이다.

### M12 — Benchmark·Packaging·CI·Release

- **진입조건**: M11 Gate 통과
- **할 일**: Benchmark Runner → Soak Matrix → Reproducibility → systemd/man → SBOM → Checksum →
  GitHub Release Workflow → Upgrade Guide → RC
- **참조**: `docs/BUILD_AND_RELEASE.md`, 기술 백서 §2.4
- **DoD**:
  1. Clean Runner의 CI가 Build/Test/Valgrind/Contract/Security를 통과한다.
  2. Gateway Overhead, TTFB Overhead, RSS, Route Latency가 Report로 생성된다.
  3. 기준 미달 항목은 원인과 승인된 예외가 없으면 Release Block이다.
  4. 8시간 Mixed Soak에서 Crash, Zombie, Definitely Lost, Mixed Stream 0이다.
  5. Tarball 설치·실행·제거가 User Scope에서 재현된다.
  6. Release에 Binary, Default Config, Schema, License, Notice, Man Page, systemd Unit,
     SBOM, SHA256SUMS가 포함된다.
  7. Tag, `VERSION`, `--version`, Changelog가 일치한다.
  8. Release Artifact에 Secret, Test DB, Log, Core, Debug Path가 없다.
  9. RC Upgrade/Backup/Restore Drill을 통과한다.
- **검증**:

```bash
make ci-local
make bench test-soak-8h
make package verify-package
make reproducible-check
```

- **주의**: Release 직전 Threshold를 낮추거나 Debug Build 결과를 Release 수치로 대체하지 않는다.

---

## 2. 런북 (증상 → 원인 → 조치)

| # | 증상 | 흔한 원인 | 조치 |
|---:|---|---|---|
| 1 | C 함수 호출 직후 Segfault | Stack 16-byte 미정렬, Variadic ABI 오용 | Call 직전 `rsp` 기록, ABI Probe 재실행, Shim 필요성 검토 |
| 2 | 다른 함수에서 나중에 상태가 깨짐 | Callee-saved Register 미복원 | `rbx/rbp/r12-r15` 전후 비교, Prologue/Epilogue 수정 |
| 3 | Debug만 정상, Release 실패 | 미초기화 Register/메모리, 최적화된 Link 차이 | Zero-init 전제 제거, Map/Disassembly 비교, 최소 재현 Test |
| 4 | Valgrind Leak | Error Path Finalizer 누락 | Resource Acquisition 순서와 단일 Cleanup Label 점검 |
| 5 | Buffer 길이가 음수처럼 보임 | Size Overflow 또는 Signed/Unsigned 혼용 | Checked Arithmetic API만 사용, Boundary Fixture 추가 |
| 6 | Config는 Valid인데 Runtime 거부 | Schema/Assembly Validator Parity 불일치 | JSON Pointer별 결과 비교, 단일 Contract 규칙으로 정렬 |
| 7 | Reload 후 간헐적 UAF | 이전 Snapshot Refcount 조기 해제 | Request가 Snapshot Ref를 잡는 시점·Release Path 검사 |
| 8 | DB `BUSY` 반복 | 긴 Transaction, 다중 Writer, Checkpoint 경합 | 데몬 단일 Writer 확인, Transaction 축소, Busy Timeout/Checkpoint 검토 |
| 9 | Health는 200인데 Ready 실패 | Migration/Secret/Listener/MCP 필수 의존 미완료 | `/readyz` Detail과 Startup Event 확인 |
| 10 | SSE JSON이 가끔 깨짐 | Callback 경계=Event 경계로 오판 | Incremental Framer, 1-byte Fragment Fixture 재실행 |
| 11 | Stream 중 응답이 두 Provider에서 섞임 | Commit Flag 설정 시점 오류, Fallback Guard 누락 | 즉시 STOP, Regression Fixture 작성, Commit Barrier 감사 |
| 12 | Client 종료 후 Upstream 지속 | Disconnect Event와 Curl Remove 분리 | 단일 Finalizer와 Cancellation Propagation Trace 확인 |
| 13 | 메모리가 느린 Client에서 증가 | Backpressure Pause 미적용, High Watermark 오류 | Buffer Metrics 확인, Pause/Resume Boundary Test |
| 14 | Round-robin 결과가 재실행마다 다름 | Unordered Container 순회, Cursor 초기화 차이 | Config Order 보존, Stable ID Tie-break, Oracle 비교 |
| 15 | Circuit가 너무 오래/짧게 열림 | Wall Clock 사용, 단위 혼동 | Monotonic ns 단위 통일, Golden Timeline Test |
| 16 | MCP Server가 Ready가 되지 않음 | Modern/Legacy Era 오판, stdout Noise | Probe Trace 확인, Recognized Error 판별, stderr/stdout 분리 |
| 17 | MCP stdout Parse Error | Server가 Log를 stdout에 출력 | 서버 설정 수정 안내, AsmFlow는 Degraded/Invalid Frame 처리 |
| 18 | Child가 Zombie로 남음 | SIGCHLD/wait 누락, Kill 후 Reap 없음 | Child Table과 waitpid Loop 검증, Lifecycle Test |
| 19 | MCP가 무한 Restart | Sliding Window Budget 누락 | Crash-loop State로 전환, Manual Reset 전 자동 기동 금지 |
| 20 | 최신 MCP HTTP가 Session ID를 요구 | Legacy Adapter가 Modern Path에 섞임 | Era별 구조 분리 확인, Modern GET/Session 사용 금지 Test |
| 21 | HTTP MCP가 400 | Header/body Version 불일치, Method/Name Header 누락 | Redacted Request Metadata 비교, 계약 Fixture 확인 |
| 22 | TUI가 깨지거나 잔상이 남음 | Resize 처리 중 직접 Draw, 전체 갱신 순서 오류 | SIGWINCH Event화, Layout→Erase→Draw→Refresh 순서 확인 |
| 23 | TUI 종료 후 입력이 보이지 않음 | `endwin`/Terminal Restore 누락 | Signal/Exit 공통 Cleanup, PTY Test 추가 |
| 24 | Wide Character Column 어긋남 | Byte Length를 Display Width로 사용 | `wcwidth` 기반 계산, ASCII Fallback |
| 25 | Log에 Token 일부가 노출 | Header 변형/대소문자/Custom Secret 누락 | Canonical Header Name과 Config Secret Registry로 Redact |
| 26 | CI와 Local 결과 다름 | Dependency/Locale/Clock/Seed 차이 | Version 출력, `LC_ALL`, Seed, Time Source 고정 |
| 27 | “돈다”지만 Route가 선택되지 않음 | Capability Filter 과도, Health/Concurrency 상태 누락 | Candidate Rejection Reason을 단계별 출력, Oracle Input 비교 |
| 28 | Provider Error가 500으로만 보임 | Error Class Normalization 누락 | Curl/HTTP/Parse/Policy Error를 분리하고 원본 Status 보존 |
| 29 | Control Socket 접근 거부 | XDG Runtime Path/Mode/User 불일치 | Path, Owner, `0600`, Parent `0700` 확인 |
| 30 | Package는 실행되지만 License 누락 | Release Manifest 불완전 | `verify-package`에서 필수 파일 목록 검사 |

반복되는 새 문제는 먼저 `PROGRESS.md`에 기록하고 두 번째 발생 시 본 표에 추가한다.

---

## 3. 멈춤 규칙 (STOP)

### 3.1. 즉시 멈춰야 하는 상황

- 같은 실패를 서로 다른 방법으로 3회 시도했으나 원인이 좁혀지지 않음
- Stack/Heap Corruption, Double Free, Use-after-free, Mixed Provider Stream 발견
- 첫 바이트 이후 Fallback이 한 번이라도 발생
- Plaintext Secret이 Log, DB, Export, Fixture에 나타남
- Modern/Legacy MCP State가 섞여 Protocol 결과가 비결정적임
- Gate를 넘기 위해 Test 삭제, Threshold 하향, Error 무시가 필요해 보임
- C에 Policy Logic을 넣어야만 일정이 맞을 것 같음
- Thread 도입, New Listener, New DB, Architecture Boundary 변경 필요
- 외부 Service/API 접근 권한이 없거나 약관 위반 가능성 존재
- 재현 중 실제 유료 API 중복 호출 또는 비용 폭주 위험 존재

### 3.2. 멈출 때 절차

1. 새 변경을 중단하고 재현 Branch/Commit을 보존한다.
2. `PROGRESS.md`에 다음을 기록한다.
   - 증상
   - 최소 재현 명령
   - 기대 결과 / 실제 결과
   - 시도 1~3과 각 결과
   - Register/Stack/FD/State/Trace 등 확인된 사실
   - 아직 검증되지 않은 가설
   - 영향을 받는 Invariant와 Phase Gate
3. Secret을 제거한 Log, Core Backtrace, Fixture를 첨부한다.
4. 선택지가 있다면 장단점과 Contract 영향을 정리해 사용자 결정을 요청한다.
5. 결정 전까지 임시 우회, Test 약화, Architecture Drift를 Commit하지 않는다.

### 3.3. 절대 금지

- 실패 Test를 `skip`, `xfail`, 조건부 통과로 숨김
- Valgrind Invalid Access를 Suppression으로 먼저 가림
- Assembly 구현을 C/Python Helper 호출로 대체
- Secret을 Debug 편의를 위해 Config/Command Line에 직접 기록
- Provider Response 일부를 전달한 뒤 다른 Provider로 이어 붙임
- MCP stdio Command를 Shell String으로 실행
- TUI가 SQLite를 직접 수정
- Modern MCP Adapter에서 Legacy Session/Get-stream 동작 사용
- `0.0.0.0` Listener를 무인증 기본값으로 변경
- 사용자 승인 없이 Phase 순서, Package Boundary, 목표 수치 변경

---

## 4. 검증 우선순위

```text
보안·불변식 정확성
  > ABI·메모리 안전성
  > Protocol/Route 정합성
  > Streaming 실효성
  > Process/DB 복구성
  > UX
  > 성능
  > 배포 편의
```

앞 단계가 깨지면 뒤 단계의 통과는 무효다. 예를 들어 TUI가 완성되어도 Route Parity가
깨졌다면 프로젝트는 M7 미완료 상태다. Benchmark가 좋아도 Invalid Read가 있으면 Release할
수 없다.

---

## 5. 현재 스캐폴딩 Gate

이 ZIP은 M0 결과물이다. 현재 즉시 실행 가능한 검증은 다음과 같다.

```bash
make check
```

통과 항목:

- 필수 파일·디렉터리
- Apache-2.0 License
- 문서 Template Marker
- JSON Schema/Example/Fixture Parsing
- Plaintext Secret 금지 규칙
- Route Oracle
- OpenAI/MCP Fixture 기본 Contract

M1 시작 전 `PROGRESS.md`를 갱신하고, Build Foundation PR에서 이 하네스의 M1 명령을 실제
Make Target으로 연결한다.
