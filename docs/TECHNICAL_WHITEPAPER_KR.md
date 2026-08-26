# AsmFlow 기술 백서 (Technical Whitepaper)

**버전**: 0.1.0-spec  
**작성일**: 2026년 8월 2일  
**작성자**: AsmFlow Contributors  
**참고 문서**: `ARCHITECTURE.md`, `docs/DESIGN_WHITEPAPER_KR.md`,
`docs/API_CONTRACT.md`, `docs/MCP_COMPATIBILITY.md`, `HARNESS.md`

## 1. 프로젝트 개요 (Project Overview)

### 1.1. 프로젝트 명

**AsmFlow — Assembly LLM Gateway & MCP Supervisor**

### 1.2. 목적 (Purpose)

AsmFlow는 Linux x86-64 환경에서 동작하는 로컬 우선 LLM Gateway 및 MCP
Supervisor이다. 프로젝트의 기술적 목적은 단순히 어셈블리어로 실행 파일을
만드는 데 있지 않다. 최신 AI 인프라가 요구하는 네트워크 스트리밍, 상태 기반
라우팅, 프로세스 감독, 프로토콜 버전 호환, 영속화, 관측 가능성을 어셈블리어의
명시적인 메모리·ABI·상태 머신으로 구현하면서도 실제 사용자가 기존 AI 클라이언트
앞에 배치해 사용할 수 있는 제품 수준을 달성하는 데 있다.

AsmFlow가 해결하는 문제는 다음과 같다.

- 서로 다른 OpenAI 호환 LLM 엔드포인트를 하나의 로컬 주소와 모델 별칭으로
  통합한다.
- 엔드포인트 장애, 지연, 동시성 한도, 지원 기능 차이를 고려해 요청을 결정론적으로
  라우팅한다.
- OpenAI Responses API와 Chat Completions API를 모두 받아 최신 클라이언트와
  기존 로컬 런타임을 연결한다.
- 로컬 stdio 및 원격 Streamable HTTP MCP 서버를 등록·실행·감시하고, 프로토콜
  세대 차이를 격리한다.
- 운영자가 TUI에서 상태를 확인하고 설정을 바꿀 수 있도록 하되, 데이터 플레인과
  터미널 UI의 장애를 분리한다.

### 1.3. 핵심 차별점 (Key Differentiators)

1. **어셈블리어 중심의 실제 제품 구조**: 단순 벤치마크나 데모가 아니라 요청 수명
   주기, 라우팅 정책, MCP 감독, 오류 처리, 메모리 소유권을 NASM x86-64로
   구현한다. C는 검증된 시스템 라이브러리의 ABI를 연결하는 얇은 계층으로 제한한다.
2. **현대·레거시 프로토콜의 명시적 격리**: MCP `2026-07-28`의 per-request
   metadata·POST-only Streamable HTTP 구조와 `2025-11-25` 이전의 initialize
   기반 세션 구조를 별도 어댑터로 유지한다. 호환 코드를 조건문으로 뒤섞지 않는다.
3. **안전한 스트리밍 라우팅**: 요청이 클라이언트에 커밋되기 전까지만 제한적으로
   Fallback을 허용하고, 첫 바이트 이후에는 절대 재라우팅하지 않는다. 공급자 응답
   혼합, 중복 과금, 중복 작업을 구조적으로 차단한다.

### 1.4. 대상 사용자

- Ollama, LM Studio, llama.cpp server, vLLM 또는 원격 API를 함께 사용하는 개발자
- 여러 모델을 하나의 OpenAI 호환 URL로 묶으려는 로컬 AI 사용자
- MCP 서버를 직접 설치하고 상태·도구 목록·로그를 관리하는 AI 엔지니어
- 저수준 시스템 프로그래밍, ABI, 스트리밍 프록시 구조를 학습하려는 기여자
- 어셈블리어 기반 오픈소스 제품의 유지보수성과 실용성을 검증하려는 연구자

### 1.5. 1.0 기능 범위

#### LLM Gateway

- `GET /healthz`, `GET /readyz`, `GET /v1/models`
- `POST /v1/responses`
- `POST /v1/chat/completions`
- 스트리밍·비스트리밍 전달
- 모델 별칭 기반 경로 선택
- 공급자별 기능 플래그와 동시성 제한
- 우선순위, 라운드로빈, 최소 지연 라우팅
- Health Check, Circuit Breaker, Cooldown, Half-open Probe
- 첫 바이트 이전의 제한적 Fallback
- 클라이언트 연결 종료의 업스트림 취소 전파
- 메타데이터 로그·통계 및 선택적 본문 로깅

#### MCP Supervisor

- stdio 서버 직접 실행, 종료, 재시작, 로그 캡처
- Streamable HTTP 서버 등록과 상태 확인
- 최신 규격 `server/discover` 및 per-request `_meta`
- 레거시 initialize 기반 서버 호환
- 서버 정보, 도구, 리소스, 프롬프트 목록 조회
- 운영자 주도의 도구 테스트 호출
- Crash-loop 방지, 시작 제한시간, 종료 유예시간, 최대 재시작 횟수
- 프로토콜 세대·지원 버전·Capability Cache

#### 운영 인터페이스

- `asmflowd` 데몬
- `asmflow-tui` 전체 화면 TUI
- `asmflowctl` 비대화형 CLI 또는 TUI 바이너리의 CLI 모드
- 로컬 Unix-domain control socket
- JSON 설정 파일 및 JSON Schema
- SQLite 상태 저장소
- systemd user service 예제

### 1.6. 명시적 비목표 (Non-goals)

- 모델 가중치 로딩, 토크나이저, GPU 추론 또는 CUDA 커널
- 자동 에이전트 루프와 모델이 생성한 MCP Tool Call의 무인 실행
- RAG 인덱싱, 벡터 데이터베이스, 문서 파이프라인
- 시각적 노드 에디터 또는 브라우저 관리 콘솔
- 자체 TLS, 자체 데이터베이스, 자체 범용 JSON 파서 구현
- 첫 안정판의 Windows, macOS, AArch64 지원
- 모든 공급자 고유 API의 완전한 상호 변환
- 스트림 시작 이후의 투명한 공급자 교체

### 1.7. 설계 원칙

- **Local-first**: 기본 리스너는 Loopback이며 원격 노출은 명시적 선택이다.
- **Single owner**: 변경 가능한 런타임 상태와 DB 쓰기는 `asmflowd` 하나가 소유한다.
- **Explicit ownership**: 모든 포인터와 버퍼의 소유권을 문서화한다.
- **Bounded input**: 네트워크·JSON·SSE·로그·프로세스 출력에 상한을 둔다.
- **Deterministic policy**: 동일한 상태 스냅샷과 입력은 동일한 라우팅 결과를 낸다.
- **Protocol isolation**: 규격 세대별 프레이밍·상태·헤더를 공유하지 않는다.
- **Observable, not invasive**: 기본 로그는 본문을 저장하지 않고 메타데이터만 기록한다.
- **No hidden runtime**: Python·Shell은 테스트와 빌드에만 사용한다.

## 2. 상세 기능 요구사항 (Detailed Requirements)

### 2.1. 시스템 환경 및 인터페이스 (System & Interface)

#### 운영 환경

| 항목 | 1.0 기준 |
|---|---|
| CPU | x86-64, 기본 ISA 우선 |
| OS | Linux, glibc 기반 배포판 우선 |
| ABI | System V AMD64 ABI |
| 어셈블러 | NASM, ELF64 출력 |
| 실행 모드 | 사용자 권한의 장기 실행 데몬 |
| UI | ncursesw TUI + 비대화형 CLI |
| 데이터 플레인 | socket/epoll + llhttp 기반 HTTP/1.1 Listener, libcurl 협상 범위 내 Upstream HTTP/2 가능 |
| 제어 플레인 | Unix-domain socket, NDJSON 프레임 |
| 영속화 | SQLite, 단일 작성자, WAL |
| 문자 인코딩 | UTF-8 |

#### 프로세스 분리

- `asmflowd`: 데이터 플레인, 업스트림, 라우팅, MCP, SQLite, 제어 소켓 소유
- `asmflow-tui`: 제어 소켓을 통해 읽기·변경 요청, 자체 상태는 화면과 입력에 한정
- Mock/Oracle: 테스트에서만 실행하며 배포 바이너리에 포함하지 않음

#### 데이터 플레인

기본 주소는 `http://127.0.0.1:8080`이다. 리스너는 다음 제한을 적용한다.

- 요청 헤더 총합 기본 64 KiB
- 요청 본문 기본 8 MiB
- 단일 JSON 문자열 기본 4 MiB
- 최대 JSON 중첩 기본 64
- 요청 처리 제한시간과 업스트림 연결·전체 제한시간 분리
- `Content-Length`와 Transfer-Encoding 모순 요청 거부
- 지원하지 않는 메서드 `405`
- 지원하지 않는 Content-Type `415`

#### 제어 플레인

기본 소켓은 `${XDG_RUNTIME_DIR}/asmflow/control.sock`이며 파일 모드는 `0600`이다.
각 명령은 한 줄 JSON이며 최대 크기는 기본 1 MiB이다. TUI는 SQLite를 직접 열지
않으며, 비밀값이 필요한 명령은 값이 아닌 Secret Reference 이름만 받는다.

#### MCP 인터페이스

- stdio: 데몬이 자식 프로세스를 직접 실행하고 stdin/stdout을 JSON-RPC 채널로 사용
- Streamable HTTP: 하나의 설정된 endpoint에 POST, JSON 또는 request-scoped SSE 수신
- 최신 세대: 모든 요청의 `_meta`에 protocol version, client info, capabilities 포함
- 레거시 세대: initialize/initialized 흐름과 세션 상태를 해당 어댑터 안에만 보관

### 2.2. 사용자 상호작용 로직 (Interaction Logic)

#### 데몬 시작

1. CLI 인자와 XDG 경로를 계산한다.
2. 설정 파일 권한과 JSON 구문을 검증한다.
3. Secret Reference에 필요한 환경 변수가 존재하는지 확인한다.
4. SQLite를 열고 Migration을 Transaction으로 적용한다.
5. 이전 실행의 비정상 상태를 복구하고 MCP 자식 PID를 맹신하지 않는다.
6. Control Socket을 생성하고 권한을 검증한다.
7. Data-plane Listener를 시작한다.
8. 공급자·MCP 서버를 등록하되 자동 연결 정책에 따라 순차 기동한다.
9. `ready=true`가 되기 전까지 `/readyz`는 `503`을 반환한다.

#### LLM 요청 처리

- **Input**: HTTP Request, model alias, stream flag, endpoint family
- **Validate**: 크기, JSON, 필수 필드, 모델 별칭, 인증, 허용 endpoint
- **Resolve**: Route → Candidate Set → Capability Filter → Health/Concurrency Filter
- **Select**: 정책에 따라 단일 Candidate 선택
- **Dispatch**: 비밀값을 런타임에 주입하고 libcurl multi에 요청 등록
- **Commit**: 업스트림 상태·헤더를 확인한 후 클라이언트로 첫 바이트 전달
- **Stream**: Backpressure를 반영해 읽기·쓰기를 조절
- **Finalize**: 연결·메모리·핸들 해제, 메타데이터 기록, Health 갱신

#### Fallback 로직

Fallback은 다음 조건을 모두 만족할 때만 가능하다.

- 아직 클라이언트에 응답 바이트를 전달하지 않음
- Route에 Fallback이 활성화됨
- 시도 횟수가 상한 미만임
- 실패 종류가 설정된 `pre_commit_retryable` 집합에 포함됨
- 다음 Candidate가 Capability·Health·Concurrency 조건을 만족함
- 요청이 명시적 비재시도 모드가 아님

기본 재시도 가능 오류는 연결 실패, DNS 실패, 연결 제한시간, 명시된 502/503/504
등이다. 업스트림이 요청을 수신했을 가능성이 높은 경우에는 기본적으로 재시도하지
않는다. 공급자가 Idempotency Key를 지원하더라도 어댑터가 명시적으로 보장하지
않으면 자동 재시도 근거로 사용하지 않는다.

#### 스트리밍

- Chat Completions와 Responses 스트림은 SSE 프레임 경계를 보존한다.
- libcurl Callback 경계와 SSE Event 경계가 일치한다고 가정하지 않는다.
- CRLF/LF, 분할된 UTF-8, 여러 Event가 한 Callback에 들어오는 경우를 처리한다.
- 클라이언트가 느리면 업스트림 읽기를 Pause하고 출력 Buffer 상한을 지킨다.
- 클라이언트 연결 종료 시 Curl Handle을 취소하고 요청 상태를 `client_cancelled`로 기록한다.
- 첫 Event 전달 이후 업스트림 오류는 해당 스트림을 종료하며 다른 공급자의 데이터를
  이어 붙이지 않는다.

#### MCP 서버 관리

- 등록 시 Transport, Command/URL, Secret Reference, Env Allowlist, Working Directory,
  Protocol Preference, Restart Policy를 검증한다.
- stdio는 Shell String이 아니라 `argv[]`로 실행한다.
- stdout은 Protocol Frame 전용, stderr는 로그로 별도 캡처한다.
- 최신 stdio 서버는 `server/discover`로 규격 세대를 확인한다.
- 레거시 신호가 확인되면 해당 프로세스의 수명 동안 legacy adapter를 사용한다.
- Streamable HTTP는 modern request를 먼저 시도하고 규격에 정의된 오류 형식에 따라
  legacy fallback 여부를 판정한다.
- 도구 실행은 운영자 확인을 요구하며 기본적으로 읽기 전용이 아님을 명확히 표시한다.

#### 데이터 검증

- 설정 JSON은 `config/asmflow.schema.json`과 동일한 규칙을 런타임에서 검증한다.
- `additionalProperties` 정책은 객체별로 명시한다.
- Plaintext API Key, Bearer Token, Authorization 값은 설정에서 금지한다.
- Provider URL은 Scheme·Host·Port·Path를 파싱하고 사용자 요청으로 URL을 바꾸지 못하게 한다.
- HTTP remote endpoint는 HTTPS가 기본이며 HTTP는 Loopback 또는 명시된 Private Allowlist만 허용한다.
- MCP Command 경로, cwd, env 이름에 NUL과 제어문자를 허용하지 않는다.

### 2.3. 데이터 모델 (Data Model)

#### Provider

```text
Provider {
  id: stable string
  display_name: UTF-8 string
  adapter: enum(openai_responses, openai_chat, openai_dual)
  base_url: parsed URL
  auth: SecretRef | none
  enabled: bool
  max_concurrency: u32
  connect_timeout_ms: u32
  request_timeout_ms: u32
  health: HealthPolicy
  capabilities: CapabilitySet
}
```

#### ModelAlias / Route

```text
Route {
  id: stable string
  model_alias: string
  endpoint_families: set(responses, chat_completions)
  policy: enum(priority, round_robin, least_latency)
  fallback: FallbackPolicy
  targets: ordered RouteTarget[]
}

RouteTarget {
  provider_id: string
  upstream_model: string
  priority: i32
  weight: u32
  capability_overrides: CapabilitySet
}
```

#### HealthState

```text
HealthState {
  state: enum(healthy, degraded, open, half_open, disabled)
  consecutive_failures: u32
  consecutive_successes: u32
  ewma_latency_us: u64 | unknown
  open_until_monotonic_ns: u64
  active_requests: u32
  last_error_class: enum
}
```

#### GatewayRequest

```text
GatewayRequest {
  request_id: 128-bit identifier
  endpoint_family: enum
  model_alias: string
  stream: bool
  received_at_monotonic_ns: u64
  client_deadline_ns: u64 | none
  auth_context: local token identity | anonymous loopback
  raw_body: bounded owned buffer
  parsed_envelope: borrowed views into normalized JSON tree
  state: enum(accepted, routed, dispatched, committed, completed, failed, cancelled)
}
```

#### RequestAttempt

```text
RequestAttempt {
  request_id: id
  attempt_no: u16
  provider_id: string
  upstream_model: string
  started_ns: u64
  first_byte_ns: u64 | none
  completed_ns: u64 | none
  http_status: u16 | none
  result_class: enum
  committed: bool
}
```

#### MCPServer

```text
MCPServer {
  id: stable string
  transport: enum(stdio, streamable_http)
  era: enum(unknown, modern_2026, legacy_2025)
  supported_versions: string[]
  desired_state: enum(running, stopped, disabled)
  observed_state: enum(stopped, starting, ready, degraded, crash_loop, failed)
  restart_policy: RestartPolicy
  capability_cache: MCPInventory
}
```

#### SecretRef

```text
SecretRef {
  source: enum(env)
  name: POSIX environment variable name
}
```

SecretRef 값 자체는 DB와 로그에 기록하지 않는다.

### 2.4. 출력 및 성능 기준 (Output & Performance)

#### 결과물 형식

- Data Plane: JSON 또는 SSE
- Control Plane: NDJSON Request/Response/Event
- Log: 구조화된 JSON Lines 또는 TUI용 정규화 Event
- Export: Redacted JSON 진단 번들
- Persistence: SQLite
- Release: 동적 링크 ELF64 바이너리, 기본 설정, Schema, Man Page, systemd user unit,
  SBOM, Checksums

#### 성능 목표

성능 수치는 업스트림 모델 지연을 제외한 AsmFlow 자체 Overhead를 측정한다.

| 항목 | 목표 |
|---|---:|
| Cold start to listener ready | p95 150 ms 이하 |
| 비스트리밍 Gateway overhead | p50 1 ms 이하, p95 5 ms 이하 |
| 스트리밍 first-event 추가 지연 | p95 10 ms 이하 |
| 기본 동시 스트림 | 100개 |
| Idle RSS | 40 MiB 이하 |
| 100 stream RSS | 160 MiB 이하 |
| Control command 응답 | p95 50 ms 이하 |
| TUI 입력→화면 반영 | p95 100 ms 이하 |
| Route selection | 1,000 target 기준 p95 250 µs 이하 |

초기 구현에서는 정확성과 누수 방지가 성능보다 우선한다. 목표 미달은 실패가 아니라
측정된 원인과 개선 계획이 있어야 하며, Invariant 위반은 수치가 좋아도 통과하지 않는다.

#### QA 기준

- `make check`와 각 Phase Gate 전부 통과
- Valgrind: Invalid Read/Write 0, Definitely Lost 0
- 1시간 Fault-injection Soak에서 데몬 Crash 0, Zombie 0
- 고정 Route Corpus의 Python Oracle 대비 불일치 0
- 스트림 시작 후 Fallback 시도 0
- Plaintext Secret이 Log/DB/Diagnostic Export에 나타나는 사례 0
- 설정 Migration 왕복 후 의미 변화 0
- 80x24 터미널에서 핵심 기능 접근 가능

### 2.5. 기능 요구사항 식별자

| ID | 요구사항 | 우선순위 |
|---|---|---|
| GW-001 | Responses endpoint 수용·전달 | Must |
| GW-002 | Chat Completions endpoint 수용·전달 | Must |
| GW-003 | Streaming backpressure와 cancellation | Must |
| GW-004 | Capability-aware routing | Must |
| GW-005 | Pre-commit fallback | Must |
| GW-006 | `/v1/models`에 노출 가능한 Alias만 반환 | Must |
| RT-001 | Priority route 결정론 | Must |
| RT-002 | Round-robin state persistence | Should |
| RT-003 | Least-latency EWMA | Should |
| RT-004 | Circuit breaker | Must |
| MCP-001 | Modern stdio discovery | Must |
| MCP-002 | Legacy stdio initialize | Must |
| MCP-003 | Modern Streamable HTTP | Must |
| MCP-004 | Legacy Streamable HTTP adapter | Should |
| MCP-005 | Tool/resource/prompt inventory | Must |
| MCP-006 | Operator-confirmed test tool call | Should |
| OPS-001 | TUI overview and status | Must |
| OPS-002 | Redacted logs and diagnostics | Must |
| SEC-001 | Env SecretRef only | Must |
| SEC-002 | Loopback default | Must |
| SEC-003 | Direct exec, no shell | Must |

### 2.6. 시스템 불변식

1. 클라이언트에 한 바이트라도 전달된 요청은 다른 업스트림으로 전환되지 않는다.
2. 공급자 선택 순서는 Hash Map의 비결정적 순서에 의존하지 않는다.
3. TUI는 SQLite 파일을 직접 열지 않는다.
4. Config·DB·Log에 Plaintext Secret을 영속화하지 않는다.
5. MCP stdio stdout의 비프로토콜 데이터를 정상 Frame으로 처리하지 않는다.
6. Modern MCP 요청과 Legacy Session State는 같은 구조체에 저장하지 않는다.
7. C Shim은 Application Policy를 결정하지 않는다.
8. 실패한 DB 기록 때문에 이미 진행 중인 Client Stream을 중단하지 않는다.
9. Arena 소유 Pointer는 Request 수명을 넘어 보관하지 않는다.
10. 모든 Child Process는 종료 시 wait 처리되어 Zombie가 남지 않는다.

## 3. 기술 스택 및 라이브러리 (Tech Stack)

### 3.1. Core

- **Runtime Language**: NASM x86-64 Assembly
- **Object Format**: ELF64
- **Linker Driver**: GCC 또는 Clang
- **Operating System API**: Linux, glibc/POSIX + 필요한 직접 Syscall Wrapper
- **Concurrency**: Single-thread event loop, epoll, timerfd/signalfd 또는 동등한 Linux API
- **Data Plane**: 직접 socket/epoll Listener + llhttp inbound parser + libcurl multi upstream client
- **Persistence**: SQLite C API
- **TUI**: ncursesw
- **JSON**: Jansson C API
- **Build**: GNU Make
- **Test/Oracle**: Python 3.11+, unittest, mock HTTP/MCP servers
- **Debug**: GDB, Valgrind, strace, sanitizers for C shims

### 3.2. Libraries & Tools

| 도구 | 정책 | 용도 | 제약 |
|---|---|---|---|
| NASM | 필수 | x86-64 ELF 어셈블 | 기본 ISA 우선, 최신 전용 지시어 최소화 |
| llhttp | 필수 | Inbound HTTP/1.1 syntax·body framing parser | Leniency 비활성, 추가 framing/policy 검증은 Assembly |
| libcurl | 필수 | HTTPS, HTTP, SSE byte stream, multi event loop | Provider policy를 libcurl callback에 넣지 않음 |
| SQLite | 필수 | Config snapshot, health, metadata, migrations | 데몬 단일 작성자 |
| ncursesw | 필수 | Unicode 대응 TUI | TUI 별도 프로세스 |
| Jansson | 필수 | JSON parsing/serialization | Ownership wrapper와 중첩·크기 상한 필요 |
| OpenSSL | 간접 | libcurl TLS backend | 직접 호출하지 않음 |
| Python | 개발 전용 | Oracle, fixture, mock, validation | 런타임 의존 금지 |
| GDB | 개발 필수 | Register/stack/core 분석 | Debug symbol 제공 |
| Valgrind | CI/개발 | Memory/FD leak | Release gate 포함 |
| ShellCheck | 선택 | 예제·Release script 검사 | Runtime 무관 |

#### 버전 정책

- 소스는 NASM 2.16 계열과 최신 안정 버전의 공통 기능을 우선한다.
- CI는 배포판 기본 버전과 별도 최신 안정 버전 중 최소 하나를 검증한다.
- llhttp·libcurl·SQLite·ncursesw·Jansson은 시스템 동적 라이브러리를 기본으로 사용한다.
- 최소 지원 버전은 구현 초기 호환 테스트 후 고정하며, 문서에 근거 없이 임의로 올리지 않는다.
- Dependency API의 Macro·Variadic 함수는 필요 시 고정폭 C Shim으로 감싼다.

#### 언어 비율 정책

- First-party Runtime Logic의 85% 이상을 수작업 Assembly로 유지한다.
- 외부 라이브러리, 생성 파일, Fixture, Test, Script는 언어 비율 산정에서 분리한다.
- C Shim은 줄 수보다 역할로 판단하며 Policy Logic이 1개라도 들어가면 위반이다.

## 4. 아키텍처 및 로직 (Architecture & Logic)

### 4.1. 상태 관리 전략 (State Management)

#### Global state

`asmflowd`가 소유하는 장기 상태:

- Immutable Config Snapshot
- Provider Registry
- Route Registry와 Round-robin Cursor
- Health/Circuit State
- Active Request Map
- Curl Multi Handle
- Listener와 Control Connections
- MCP Server Registry와 Child Process Table
- SQLite Connection
- Timer Queue
- Structured Log Sink

Config Reload는 기존 구조를 제자리 수정하지 않는다. 새 Snapshot을 완전히 검증하고
관련 Secret Reference·Route 참조·Provider 참조가 유효할 때 Atomic Pointer Swap으로
교체한다. 진행 중인 요청은 시작 시 보유한 Snapshot을 참조하며 완료 후 Release한다.

#### Request-local state

요청마다 Arena, Parsed Envelope, Candidate Cursor, Attempt List, Input/Output Buffer,
Curl Easy Handle, Timer, Cancellation Flag를 가진다. 완료·실패·취소의 단일 Finalizer가
모든 Resource를 해제한다.

#### TUI local state

현재 Screen, Selection, Filter Text, Sort Key, Modal, Last Snapshot Version만 보유한다.
실제 운영 상태는 Control Plane Snapshot에서 가져온다.

### 4.2. 주요 동작 파이프라인 (Main Workflow)

#### Gateway Initialization

```text
args -> xdg paths -> config parse -> secret resolve check
     -> sqlite migrate -> control socket -> listener
     -> provider registry -> mcp registry -> ready
```

#### Non-streaming Request

```text
accept -> validate -> route -> dispatch -> collect bounded response
       -> validate upstream status -> write client response -> finalize
```

#### Streaming Request

```text
accept -> validate -> route -> dispatch
       -> buffer upstream headers
       -> commit route
       -> parse/pass SSE incrementally
       -> backpressure/cancel
       -> final event or transport close -> finalize
```

#### MCP stdio Modern

```text
spawn -> send server/discover with per-request _meta
      -> modern result or supported-version error
      -> cache era/version/capabilities
      -> list inventory / operator calls
```

#### MCP stdio Legacy

```text
spawn -> modern probe fails with non-modern signal
      -> initialize -> initialize result -> initialized notification
      -> legacy session state -> inventory / calls
```

#### MCP Streamable HTTP Modern

```text
POST one JSON-RPC request
  headers: MCP-Protocol-Version + method/name metadata + Accept JSON/SSE
  body: per-request _meta
-> single JSON or request-scoped SSE
-> close stream to cancel
```

### 4.3. 핵심 알고리즘 (Core Algorithms)

#### Candidate Filtering

입력 Route Targets를 순서대로 순회하며 다음을 제거한다.

1. Provider disabled
2. Endpoint family 미지원
3. 요청 필수 Capability 미지원
4. Circuit open이며 Cooldown 미경과
5. Active Requests가 Max Concurrency 이상
6. 현재 요청에서 이미 실패한 Target

결과는 원래 설정 순서를 보존한다.

#### Priority Selection

`priority`가 가장 작은 Candidate를 선택한다. 동률은 Route Targets의 원래 Index,
그 다음 Provider ID의 Bytewise Order로 해소한다.

#### Round-robin Selection

Route별 64-bit Cursor를 증가시키고 `cursor mod eligible_count`로 선택한다. Config Reload로
Target 집합이 바뀌면 Cursor는 유지하되 새 Count에 Modulo를 적용한다. Overflow는 자연스러운
Unsigned Wrap으로 정의하며 동일 구현 간 결과를 고정 Fixture로 검증한다.

#### Least-latency Selection

성공 요청의 Observed Latency에 EWMA를 적용한다.

```text
new_ewma = alpha * observed + (1 - alpha) * old_ewma
```

Floating Point를 피하기 위해 `alpha_num/alpha_den` 정수 비율과 128-bit Intermediate 또는
Overflow-checked 분해 계산을 사용한다. Unknown Latency는 Healthy Measured Candidate 뒤,
Half-open Candidate 앞에 둔다. 동률은 Config Order로 해소한다.

#### Circuit Breaker

- Closed: 요청 허용
- Open: 일반 요청 차단, `open_until`까지 대기
- Half-open: 제한된 Probe 1개 또는 설정값만 허용
- Success threshold 충족: Closed
- Probe failure: Open으로 복귀하고 Backoff 증가
- Manual disabled: Health 결과와 무관하게 요청 금지

Clock은 Wall Clock이 아니라 Monotonic Clock을 사용한다.

#### Fallback Commit Barrier

`committed` Flag는 클라이언트 Write가 성공적으로 1 Byte 이상 진행되기 직전에 단방향으로
변경한다. `false -> true`만 허용한다. Fallback 함수는 진입 시 반드시 `committed=false`를
검증하고, Debug Build에서는 위반 시 즉시 Fatal Assertion으로 종료해 테스트에서 발견한다.

#### Backpressure

Client Output Buffer가 High Watermark에 도달하면 Curl Receive를 Pause한다. Low Watermark
아래로 내려가면 Resume한다. Buffer 상한을 넘으면 요청을 종료하며 무제한 메모리 증가를
허용하지 않는다.

#### MCP Era Detection

- stdio: `server/discover` Probe
  - 정상 Discover 또는 Recognized Modern Error → Modern
  - Non-modern Error/Timeout/Invalid response → Legacy Initialize 시도
- HTTP: Modern Request
  - Recognized Modern JSON-RPC Error → Modern, Version Negotiation
  - 4xx이며 Recognized Modern Error가 아님 → Legacy Adapter 시도

Era 결과는 stdio Process Lifetime 또는 HTTP Origin 단위로 Cache한다. 실패 시 재Probe한다.

### 4.4. 이벤트 루프

초기 구현은 단일 Thread를 사용한다.

- Listener FD, Client FD, Control Socket, MCP Pipe, Signal FD, Timer FD를 epoll로 감시
- Client Byte Stream은 llhttp에 증분 공급하되 Leniency를 켜지 않고, Callback 결과를 Assembly Connection State로 정규화
- libcurl multi의 Socket/Timer 요구를 Event Loop에 통합하거나 `curl_multi_poll` 기반으로
  단일 Loop를 구성
- Callback에서는 무거운 Parsing·SQL을 수행하지 않고 Event Queue에 최소 작업만 등록
- 한 Connection이 Loop를 독점하지 않도록 처리 Byte/Frame Budget 적용
- Signal Handler에서 Allocation·Logging을 하지 않고 signalfd 또는 Self-pipe 사용

Thread 도입은 1.0 성능 측정에서 단일 Loop가 목표를 충족하지 못하고, 병목이 명확하며,
Memory Ownership·SQLite·libcurl Thread Safety 계획을 ADR로 승인받은 경우에만 허용한다.

### 4.5. 메모리 소유권과 ABI

#### Ownership 표기

- `borrowed`: 호출 동안만 유효, 해제 금지
- `owned`: 현재 객체가 해제 책임
- `transferred`: 호출 성공 후 수신자 책임
- `static`: 프로세스 전체 수명, 해제하지 않음

#### 호출 규약

- Integer/Pointer Args: `rdi, rsi, rdx, rcx, r8, r9`
- Return: `rax`, 필요 시 `rdx:rax`
- Callee-saved: `rbx, rbp, r12-r15`
- Stack: C Call 직전 16-byte Alignment
- Variadic: 직접 호출을 최소화하고 C Shim 사용
- `errno`: 필요한 즉시 캡처하며 후속 libc 호출 전에 보관

#### Buffer

```text
Buffer {
  ptr: u8*
  len: usize
  cap: usize
  max: usize
  allocator: allocator_id
}
```

Append는 `len + incoming` Overflow를 먼저 검사하고 `max`를 초과하면 명시적 오류를 반환한다.
성장 전략은 1.5~2배 범위의 검증된 정수 규칙을 사용하고, 재할당 실패 시 원래 Buffer를 보존한다.

### 4.6. 데이터베이스 스키마

```sql
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);

CREATE TABLE providers (
  id TEXT PRIMARY KEY,
  config_hash TEXT NOT NULL,
  enabled INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE routes (
  id TEXT PRIMARY KEY,
  model_alias TEXT NOT NULL UNIQUE,
  policy TEXT NOT NULL,
  config_hash TEXT NOT NULL
);

CREATE TABLE request_attempts (
  request_id TEXT NOT NULL,
  attempt_no INTEGER NOT NULL,
  provider_id TEXT NOT NULL,
  result_class TEXT NOT NULL,
  committed INTEGER NOT NULL,
  started_ns INTEGER NOT NULL,
  first_byte_ns INTEGER,
  completed_ns INTEGER,
  http_status INTEGER,
  PRIMARY KEY(request_id, attempt_no)
);
```

실제 Migration은 별도 파일로 관리하며 Whitepaper SQL은 개념 스키마다. Prompt, Response,
Authorization Header, API Key는 기본 테이블에 포함하지 않는다.

### 4.7. 관측 가능성

#### Log Level

`trace`, `debug`, `info`, `warn`, `error`, `fatal`

#### 필수 필드

- timestamp UTC
- monotonic offset
- level
- component
- event
- request_id 또는 mcp_server_id
- provider_id, route_id 등 비민감 식별자
- duration_us
- result_class
- redaction flags

#### Metrics

- Request Count/Status/Latency
- Active/Queued Requests
- Provider Health/Circuit State
- Fallback Attempt Count
- Stream Cancellation Count
- MCP Restart/Crash Count
- DB Write Error Count
- Buffer High-water Events

1.0은 Prometheus Listener를 추가하지 않고 Control Plane Snapshot과 Log Export를 제공한다.
새 네트워크 Metrics Listener는 ADR 대상이다.

## 5. UI 구현 가이드 (Implementation Guide)

### 5.1. 디자인 토큰 (Design Tokens)

TUI는 Terminal Color를 Semantic Pair로 추상화한다.

- `surface.base`: terminal default background
- `surface.raised`: selected row 또는 modal background
- `text.primary`: terminal default foreground
- `text.muted`: metadata
- `accent.primary`: active focus, selected route
- `status.ok`: healthy/success
- `status.warn`: degraded/half-open
- `status.error`: open/failed
- `status.info`: starting/paused

색상 외에도 `[OK]`, `[WARN]`, `[FAIL]`, `[OFF]` Text Label을 항상 함께 표시한다.
`NO_COLOR`와 monochrome mode를 지원한다.

- Typography: Terminal Font를 존중, Custom Font 없음
- Minimum Layout: 80x24
- Standard: 100x30
- Wide: 140x40 이상
- Refresh: Event-driven, 최대 10 FPS; 지속적인 장식 Animation 금지

### 5.2. 공통 컴포넌트 (Shared Components)

- **TopBar**: 앱 이름, 연결 상태, 현재 Config Revision
- **SideNav**: Overview, Providers, Routes, Requests, MCP, Logs, Settings
- **DataTable**: 정렬, Filter, 키보드 선택, Column Collapse
- **StatusBadge**: 색상+Text+Glyph
- **DetailPanel**: 선택 객체의 Redacted Key/Value
- **CommandPalette**: `:` 또는 `/` 기반 명령 검색
- **ConfirmDialog**: MCP Tool Test, Server Stop 등 영향 있는 작업 확인
- **Toast/EventLine**: 성공·실패를 화면 하단에 제한 시간 표시
- **LogViewer**: Search, Level Filter, Follow/Pause
- **Sparkline**: 선택적 ASCII 지연 추세, Data Table을 대체하지 않음

## 6. 파일 구조 (File Structure)

```text
AsmFlow/
├── README.md
├── LICENSE
├── NOTICE
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── SECURITY.md
├── CHANGELOG.md
├── ROADMAP.md
├── ARCHITECTURE.md
├── HARNESS.md
├── AGENTS.md
├── PROGRESS.md
├── VERSION
├── Makefile
├── config/
│   └── asmflow.schema.json
├── docs/
│   ├── TECHNICAL_WHITEPAPER_KR.md
│   ├── DESIGN_WHITEPAPER_KR.md
│   ├── API_CONTRACT.md
│   ├── CONFIGURATION.md
│   ├── MCP_COMPATIBILITY.md
│   ├── SECURITY_MODEL.md
│   ├── TEST_STRATEGY.md
│   ├── BUILD_AND_RELEASE.md
│   ├── FILE_TREE.md
│   ├── GLOSSARY.md
│   └── decisions/
├── examples/
├── tests/
├── scripts/
├── include/
├── packaging/
├── src/
│   ├── platform/linux_x86_64/
│   ├── memory/
│   ├── core/
│   ├── json/
│   ├── http/
│   ├── providers/
│   ├── routing/
│   ├── mcp/
│   ├── storage/
│   ├── control/
│   ├── tui/
│   └── ffi/
└── .github/
```

## 7. 개발 시 주의사항 (Implementation Notes)

### 7.1. 보안 (Security)

1. Data Plane을 비Loopback에 열 때 Token 인증 없이는 시작을 거부한다.
2. Secret은 환경 변수 이름으로만 설정하고 Process List·Log·DB에 값을 남기지 않는다.
3. MCP stdio는 Shell을 사용하지 않고 Env Allowlist와 Working Directory를 적용한다.
4. Config File·Control Socket·State Directory 권한을 시작 시 검증한다.
5. `Authorization`, `Proxy-Authorization`, `Cookie`, 사용자 정의 Secret Header를 Redact한다.
6. Remote MCP/Provider URL의 Redirect는 기본 비활성 또는 동일 Origin으로 제한한다.
7. Request Body·SSE Line·MCP Frame·stderr Line에 Size Limit를 둔다.
8. Diagnostics Export는 생성 전후 Redaction Test를 거친다.

### 7.2. 성능 최적화 (Optimization)

- 먼저 Byte Copy, JSON Parse, SQL, TUI Redraw를 Profile한다.
- Zero-copy는 Lifetime을 명확히 증명할 수 있을 때만 사용한다.
- Request Arena로 다수의 작은 Free를 줄이되 Global Pointer 보관을 금지한다.
- Upstream Connection Reuse는 libcurl에 맡기고 자체 Pool을 중복 구현하지 않는다.
- SQLite Write는 짧은 Transaction으로 Batch하되 요청 완료 자체를 DB에 종속시키지 않는다.
- TUI는 변경된 영역만 갱신하고 매 Tick 전체 화면을 다시 그리지 않는다.

### 7.3. 알려진 위험과 대응

| 위험 | 대응 |
|---|---|
| C ABI Stack Alignment 오류 | ABI Macro + C Probe Test + GDB Gate |
| SSE Event가 Callback 경계에서 분할 | Incremental Framer + Fragment Corpus |
| Upstream 첫 바이트 전에 상태만 보고 Commit | 실제 Client Write 성공 직전에 Commit Flag 설정 |
| Client Disconnect 후 Curl Handle 잔존 | FD Event와 Curl Remove를 단일 Finalizer로 통합 |
| MCP stdout에 로그 혼입 | Invalid Frame 처리, stderr 안내, 서버 Degraded 표시 |
| Child Crash Loop | Sliding window restart budget와 manual reset |
| SQLite Busy/Corruption | Single writer, busy timeout, backup, transactional migration |
| Config Reload 중 Use-after-free | Refcounted immutable snapshot |
| Terminal 크기·Wide Character 오류 | `wcwidth`, Compact layout, ASCII fallback |
| 최신 MCP 규격 변화 | Versioned adapter와 fixture corpus |

### 7.4. 단계적 구현

기술 백서 전체를 한 번에 구현하지 않는다. `HARNESS.md`의 M1~M12 순서를 지키며,
각 Phase는 실행 여부가 아니라 측정 가능한 Gate로 완료 판정한다. 특히 ABI/Memory,
Streaming, Routing Parity, MCP Era Detection을 핵심 위험 Phase로 취급한다.

### 7.5. 참고 규격

- NASM documentation: https://www.nasm.us/docs.html
- llhttp repository/API: https://github.com/nodejs/llhttp
- libcurl multi interface: https://curl.se/libcurl/c/libcurl-multi.html
- SQLite C interface: https://www.sqlite.org/c3ref/intro.html
- OpenAI Responses API: https://developers.openai.com/api/reference/responses/overview/
- OpenAI streaming guide: https://developers.openai.com/api/docs/guides/streaming-responses
- OpenAI Chat Completions: https://developers.openai.com/api/reference/chat-completions/overview/
- MCP 2026-07-28 specification: https://modelcontextprotocol.io/specification/2026-07-28
- MCP Streamable HTTP: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
- System V AMD64 ABI: 배포판 Toolchain의 ABI 문서와 CPU Vendor Manual을 함께 참조
