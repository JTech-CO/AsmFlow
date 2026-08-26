# AsmFlow 디자인 백서 (Design Whitepaper)

**버전**: 0.1.0-spec  
**작성일**: 2026년 8월 2일  
**작성자**: AsmFlow Contributors  
**참고 문서**: `docs/TECHNICAL_WHITEPAPER_KR.md`, `ARCHITECTURE.md`,
`docs/API_CONTRACT.md`, `HARNESS.md`

---

## 1. 프로젝트 개요 (Project Overview)

### 1.1. 프로젝트 명

**AsmFlow Terminal UI/UX Design**

### 1.2. 목적 (Purpose)

AsmFlow의 UI는 브라우저 대시보드가 아니라 터미널에서 장시간 운영되는 개발자용
Control Surface이다. 디자인 목표는 어셈블리어라는 소재를 과장한 복고풍 연출이 아니라,
여러 LLM 공급자와 MCP 서버의 상태·위험·라우팅 결정을 짧은 시간 안에 이해하고 정확히
조작할 수 있는 현대적인 TUI를 제공하는 것이다.

UI는 다음 문제를 해결해야 한다.

- 여러 공급자의 Health, Latency, Concurrency, Circuit 상태를 한 화면에서 비교한다.
- Model Alias가 실제 어느 Upstream으로 라우팅되는지 추적한다.
- 요청 실패와 Fallback이 언제·왜 발생했는지 본문 노출 없이 이해한다.
- MCP 서버가 Modern/Legacy 어느 세대로 동작하며 어떤 Capability를 제공하는지 확인한다.
- Server Restart, Disable, Tool Test처럼 영향 있는 작업은 실수로 실행되지 않게 한다.
- 80x24부터 넓은 개발자 터미널까지 정보 손실을 최소화한다.

### 1.3. 핵심 차별점 (Key Differentiators)

1. **운영 중심의 정보 밀도**: 장식보다 상태·원인·다음 행동을 우선한다. 한 화면의 모든
   색상과 기호는 운영 의미를 가져야 한다.
2. **Terminal-native 반응형**: 화면 크기에 따라 Column을 숨기고 Detail Panel을 전환하며,
   최소 80x24에서도 핵심 조작을 유지한다.
3. **비색상 의존 접근성**: `[OK]`, `[WARN]`, `[OPEN]`, `[OFF]` 등의 Text Label과
   Glyph를 색상과 함께 사용하고 `NO_COLOR`, Monochrome, ASCII Fallback을 제공한다.

### 1.4. 디자인 방향

- Minimal, technical, calm
- Flat surfaces, no heavy shadow
- 1-pixel terminal border or whitespace grouping
- Terminal 기본 색을 존중하고 과도한 Neon 사용 금지
- Matrix, CRT Scanline, Glitch, 과도한 ASCII Art 금지
- Animation은 Loading Spinner와 상태 변화 강조에 한정
- 작업 결과보다 브랜드 연출이 먼저 보이지 않게 구성

## 2. 상세 기능 요구사항 (Detailed Requirements)

### 2.1. 레이아웃 및 인터페이스 (Layout & Interface)

#### View Mode

TUI는 Full-screen Container-Based Layout을 사용한다.

```text
+--------------------------------------------------------------------------------+
| AsmFlow  connected  cfg:42  req:18  mcp:6                         23:41:08 UTC |
+----------------+--------------------------------------+------------------------+
| Overview       | Main table / timeline                | Detail inspector       |
| Providers      |                                      |                        |
| Routes         |                                      |                        |
| Requests       |                                      |                        |
| MCP            |                                      |                        |
| Logs           |                                      |                        |
| Settings       |                                      |                        |
+----------------+--------------------------------------+------------------------+
| / filter   Enter open   r refresh   : commands   ? help   q quit              |
+--------------------------------------------------------------------------------+
```

#### Wide Desktop: 120 columns 이상

- Left Navigation: 16~20 columns
- Main Content: 가변, 최소 56 columns
- Right Inspector: 30~44 columns
- Bottom Command Bar: 1~2 rows
- Detail을 유지한 채 Table과 상태 추세를 동시에 표시

#### Standard: 100~119 columns

- Left Navigation 14~16 columns
- Main Content 중심
- Right Inspector는 28~32 columns 또는 `Tab` 전환
- 낮은 우선순위 Column 자동 숨김

#### Compact: 80~99 columns

- Navigation을 상단 Tab Row 또는 단축 Label로 변환
- Main Table 한 영역
- Detail은 `Enter`로 전체 화면 Overlay
- Command Bar는 핵심 Shortcut만 표시
- ID는 앞·뒤 일부를 남기고 중간 Ellipsis

#### Narrow: 79 columns 이하 또는 20 rows 이하

- 전체 화면 Table을 포기하고 List + Detail Drill-down 사용
- 치명적 상태와 복구 명령을 우선 표시
- 60x16 미만에서는 실행 중 상태를 보존한 채 “터미널 확대 필요” 안내와 CLI 명령을 제공
- TUI가 깨진 Layout을 억지로 표시하지 않는다.

#### Theme Policy

- 기본: Terminal Theme 존중
- Optional: `dark`, `light`, `high-contrast`, `mono`
- `NO_COLOR` 환경변수 지원
- 색상 Capability: True Color를 요구하지 않고 256/16/Mono로 단계적 축소
- 배경색을 강제로 칠하지 않는 `transparent` 모드 제공

### 2.2. 사용자 상호작용 (Interaction Logic)

#### Navigation

| Key | 동작 |
|---|---|
| `1`~`7` | 주요 Screen 직접 이동 |
| `Tab` / `Shift+Tab` | Pane Focus 이동 |
| `j/k` 또는 화살표 | Row 이동 |
| `Enter` | Detail/Open/확정 |
| `Esc` | Modal/Detail 닫기 또는 이전 단계 |
| `/` | 현재 Table Filter |
| `:` | Command Palette |
| `?` | Context Help |
| `r` | Snapshot Refresh 또는 선택 서버 재Probe(문맥별) |
| `Space` | Multi-select가 허용된 화면에서 선택 |
| `q` | TUI 종료, 데몬은 유지 |

Shortcut은 Screen마다 의미가 달라질 경우 Command Bar에 반드시 표시한다. 파괴적 작업은
단일 Key로 즉시 실행하지 않는다.

#### Hover Effects

TUI에는 Hover가 없다. Focused Row는 다음으로 표시한다.

- 배경 반전 또는 Accent Pair
- 좌측 `>` Cursor
- 상태 변화 없이 Focus만 바뀌었음을 명확히 함

Mouse 지원은 선택 사항이며 Keyboard Path와 동일한 기능만 제공한다.

#### Input

- Filter: Inline input, 150 ms Debounce 없이 즉시 로컬 필터
- Command Palette: Fuzzy 또는 Prefix Search, 실행 전 Command 설명 표시
- Config Edit: Inline raw JSON 편집이 아니라 Field Form 또는 외부 편집기 안내
- Secret: 값 입력 금지, Environment Variable 이름만 입력
- Tool Arguments: JSON Editor Modal, Schema 기반 Field 지원은 후속 범위

#### Confirmation Levels

- Level 0: View/Filter/Sort — 즉시 실행
- Level 1: Refresh/Probe/Export — 실행 후 결과 Toast
- Level 2: Enable/Disable/Restart — 명시적 Confirm
- Level 3: MCP Tool Call/Route Mutation/Non-loopback 설정 — 대상·영향·입력 표시 후 Confirm
- Level 4: 여러 Server Stop, DB Reset 등 — TUI에서 직접 제공하지 않거나 확인 문구 입력

### 2.3. 데이터 구조 및 모듈 (Component Structure)

#### 1. Top Bar

- `AsmFlow` Wordmark Text
- Daemon Connection: `CONNECTED`, `STALE`, `DISCONNECTED`
- Config Revision
- Active Request Count
- MCP Running/Total
- UTC Clock
- Critical Alert가 있으면 우측에 `[2 CRITICAL]`

Top Bar는 1행을 기본으로 하며 Compact에서 Clock과 Count 일부를 생략한다.

#### 2. Navigation

- Overview
- Providers
- Routes
- Requests
- MCP
- Logs
- Settings/Help

현재 Screen은 Accent와 `>`로 표시한다. Badge Count는 경고가 있을 때만 표시한다.

#### 3. Content Area

Screen별 Data Table 또는 Timeline을 표시한다. Table Header는 Sticky 개념으로 항상 유지한다.
Row 높이는 기본 1행, 긴 이름은 Detail에 표시한다.

#### 4. Detail Inspector

선택 객체의 다음 정보를 표시한다.

- ID/Name/State
- 핵심 수치
- 최근 오류와 Timestamp
- 현재 Policy/Capability
- 가능한 Actions
- Secret은 `env:OPENAI_API_KEY (set)`처럼 Reference와 존재 여부만 표시

#### 5. Command Bar

현재 Focus와 Screen에서 실행 가능한 5~7개 핵심 Key만 표시한다. 전체 Shortcut은 `?` Help로
분리해 하단을 과밀하게 만들지 않는다.

#### 6. Footer/Event Line

- 마지막 Command 결과
- Background Event 요약
- Error 시 해결 방향 또는 Log Drill-down Key

성공 Toast는 3초 후 사라지며 Error는 사용자가 확인할 때까지 유지할 수 있다.

### 2.4. 화면별 요구사항

#### Overview

- Gateway Ready 상태
- Active/Queued Requests
- 1m/5m Error Rate
- Provider Healthy/Degraded/Open Count
- MCP Ready/Crash-loop Count
- 최근 주요 Event 8~12개
- Route Summary

Overview는 복잡한 Dashboard Chart보다 즉시 조치가 필요한 상태를 먼저 표시한다.

#### Providers

Columns:

```text
STATUS NAME ADAPTER ACTIVE/MAX LATENCY_P95 CIRCUIT LAST_ERROR
```

Detail:

- Base URL은 Host 중심으로 표시, Query·Credential 금지
- Supported Endpoint/Capability
- Health Threshold
- Last 10 Attempts 요약
- `probe`, `disable`, `enable`, `view requests`

#### Routes

Columns:

```text
ALIAS POLICY TARGETS ELIGIBLE ACTIVE FALLBACK LAST_SELECTED
```

Detail:

- Ordered Targets
- Capability Filter
- Current Round-robin Cursor 또는 Latency Ranking
- Fallback Rules
- Route Simulation: 입력 Capability로 Candidate 결과만 계산, 실제 호출 없음

#### Requests

Columns:

```text
TIME ID ENDPOINT MODEL PROVIDER STATE STATUS TTFB TOTAL
```

기본적으로 Prompt와 Response Text를 표시하지 않는다. Payload Logging이 Opt-in인 경우에도
권한·모드·Redaction 여부를 명확히 표시한다.

Detail:

- Attempt Timeline
- Committed 시점
- Fallback 여부와 이유
- Error Class
- Byte Count
- Export Redacted Trace

#### MCP

Columns:

```text
STATUS NAME TRANSPORT ERA VERSION TOOLS RESOURCES RESTARTS
```

Detail:

- Command 또는 URL의 안전한 표시
- PID/Origin
- Era Detection 결과
- Capabilities와 Cache TTL
- stderr 최근 Line
- Restart Budget
- `discover`, `list`, `test call`, `restart`, `stop`

Tool Test는 Tool Description·Schema·위험 경고·Arguments를 보여 준 뒤 Confirm한다.

#### Logs

- Level, Component, Event, ID, Time
- Follow/Pause
- Regex가 아닌 안전한 Substring Search를 1.0 기본으로 사용
- Secret Redaction 상태 표시
- Raw ANSI Escape를 해석하지 않고 Escape하거나 제거

#### Settings/Help

- 현재 Config Path와 Revision
- Listener, Storage, Logging, Limits 요약
- Secret Reference 상태
- Keymap
- Build/License/Dependency 정보
- Config Reload와 Validation 결과

### 2.5. 출력 및 결과물 (Output)

- ncursesw 기반 ELF64 TUI Binary
- Monochrome/16/256-color 화면
- UTF-8 Box Drawing + ASCII Fallback
- Text 기반 Snapshot Export
- Redacted JSON Diagnostic Export

#### QA Standards

- Keyboard-only 전체 Workflow
- Color 없이 모든 상태 구분
- 80x24에서 가로 스크롤 없음
- 100x30, 140x40에서 Critical Action Clipping 없음
- Resize 중 Crash/Memory Error 없음
- 비정상 종료 후 Terminal Mode 복구
- Screen Reader 친화성 한계는 문서화하되 CLI로 동일 정보 접근 가능
- `NO_COLOR` 준수

## 3. 기술 스택 및 라이브러리 (Tech Stack)

### 3.1. Core

- **Frontend Framework**: 없음. 별도 `asmflow-tui` NASM Binary
- **Rendering Engine**: ncursesw
- **Control Transport**: Unix-domain socket + NDJSON
- **State**: Daemon Snapshot + TUI Local Selection/Filter
- **Text Width**: `wcwidth` 또는 검증된 Wide Character 폭 계산

### 3.2. Libraries & Tools

1. **ncursesw**
   - 용도: Pane, Input, Color Pair, Resize, Keyboard
   - 설정: Default Terminal Color 사용, `use_default_colors` 가능 시 적용
2. **locale / wide-character C API**
   - 용도: UTF-8과 Display Width
   - 제약: 실패 시 ASCII Mode로 안전하게 축소
3. **Python Snapshot Tests**
   - 용도: Layout Model과 Column Collapse의 Reference Test
   - 제약: Product Runtime에 포함하지 않음

## 4. 아키텍처 및 로직 (Architecture & Logic)

### 4.1. 시각적 계층 구조 (Visual Hierarchy)

Terminal은 Pixel Font Size를 제어하지 못하므로 Weight, Case, Spacing, Border, Color Pair로
계층을 만든다.

- **Level 1 — Screen Title**: Bold, Primary Text, 왼쪽 정렬, 1행
- **Level 2 — Section/Pane Title**: Bold 또는 Accent, Border Label
- **Level 3 — Table/Body**: Normal, 1행 Row
- **Level 4 — Meta/Caption**: Dim/Muted, Timestamp·ID·Unit
- **Critical**: Bold + Error Pair + `[CRIT]`, Blink 금지

```text
ROUTES  12 total / 10 healthy

[OK]   general        priority      3/3 eligible
[WARN] code-fast      least_latency 1/2 eligible
[OPEN] vision         priority      0/2 eligible
```

### 4.2. 반응형 로직 (Responsive Logic)

#### Column Priority

각 Column은 Priority 0~3을 가진다.

- 0: 상태, 이름, 핵심 값 — 절대 숨기지 않음
- 1: 주요 운영 판단 — Standard 이상 표시
- 2: 분석 값 — Wide에서 표시
- 3: Metadata — Detail에만 표시 가능

Layout Engine은 가용 폭을 계산해 Priority가 낮은 Column부터 숨긴다. 마지막에 Column 안의
Text를 Ellipsis 처리하며, 상태·단위·부호를 잘라 의미를 바꾸지 않는다.

#### Height Priority

- Top Bar 1
- Command Bar 1
- Error/Event Line 1
- 나머지 Content

Height가 부족하면 Inspector → Secondary Summary → Event History 순으로 축소한다. Critical
Error와 Current Selection은 유지한다.

#### Resize

`SIGWINCH`를 안전한 Event로 변환하고 다음 Loop에서 Layout을 재계산한다. Signal Handler에서
ncurses 함수를 호출하지 않는다.

### 4.3. 핵심 컴포넌트 로직 (Core Components)

#### DataTable

- Stable sort
- Selection은 Row Index가 아니라 Stable ID로 유지
- Refresh 후 객체가 사라지면 가장 가까운 Row 선택
- Filter 결과가 0이면 Empty State와 Clear Key 표시
- Header와 Body 폭 계산을 분리
- 숫자는 오른쪽, Text는 왼쪽 정렬
- Time/Bytes/Latency Unit 일관성 유지

#### StatusBadge

```text
[OK]    healthy/completed/ready
[WARN]  degraded/half-open/stale
[OPEN]  circuit open
[FAIL]  failed/crash-loop
[OFF]   disabled/stopped
[RUN]   starting/in-flight
```

Glyph는 선택사항이며 Text Label은 필수다.

#### DetailPanel

- Key/Value 정렬
- 긴 값 Wrapping
- Secret/Token/Body는 `[REDACTED]`
- List는 최대 항목과 “+N more” 표시
- Error에는 분류, 원인, 마지막 시각, 다음 행동 제공

#### CommandPalette

- Command ID, Label, Description, Risk Level
- 현재 Context에서 사용할 수 없는 Command는 숨기거나 Disabled 이유 표시
- Level 2 이상은 Confirm 단계로 이동
- 검색 결과 순서가 매 실행마다 바뀌지 않음

#### ConfirmDialog

다음 문장을 포함한다.

- 무엇을 변경하는가
- 영향을 받는 대상
- 자동 복구 여부
- 실행 후 취소 가능 여부
- 실제 실행 Key

MCP Tool Call은 Tool Name, Server, Arguments, 잠재적 외부 효과를 표시한다.

## 5. UI/UX 디자인 가이드 (Design System)

### 5.1. 색상 팔레트 (Color Palette)

고정 Hex는 Terminal에서 강제하지 않고 디자인 Reference로만 사용한다.

| Semantic Token | Reference | 용도 |
|---|---|---|
| `accent.primary` | `#5EA1FF` | Focus, Link, Current Selection |
| `status.ok` | `#43B581` | Healthy, Success |
| `status.warn` | `#E0A82E` | Degraded, Half-open |
| `status.error` | `#E25555` | Failure, Open Circuit |
| `status.info` | `#7B8CFF` | Starting, Running |
| `text.primary` | Terminal default | Main text |
| `text.muted` | Terminal dim | Metadata |
| `surface.base` | Terminal default | Background |
| `surface.raised` | Terminal selection | Modal/Focused row |

Color Pair가 부족하면 `ok/warn/error/info`를 Bold, Underline, Reverse와 Text Label로 구분한다.

### 5.2. 타이포그래피 (Typography)

- Font Family: 사용자 Terminal Font
- Weight: Normal, Bold, Dim
- Monospace 전제
- All Caps는 Screen Title과 짧은 Status Label에만 사용
- 긴 설명은 Sentence Case
- 숫자와 Unit 사이 한 칸: `12 ms`, `4.2 MiB`
- Timestamp 기본 UTC, Detail에서 Local Time 옵션

### 5.3. 간격과 경계

- Pane 내부 좌우 Padding 1 column
- Section 사이 최소 1 blank row 또는 Border
- Double Border 남용 금지
- Modal은 화면 80% 이하, 최소 Margin 2 columns/1 row
- Table Row 사이 Blank Line 없음
- 장식용 ASCII Art 없음

### 5.4. 상태와 오류 문구

나쁜 예:

```text
Error 23
Operation failed
```

좋은 예:

```text
[FAIL] MCP server “filesystem” exited 3 times in 60 s.
Restart is paused to prevent a crash loop. Press Enter for stderr or :mcp-reset.
```

오류 문구는 대상, 상태, 측정값, 다음 행동을 포함한다.

## 6. 파일 구조 (File Structure)

```text
src/tui/
├── app.asm              # TUI lifecycle and main event loop
├── client.asm           # control-socket client
├── state.asm            # local selection/filter/modal state
├── layout.asm           # width/height and responsive rules
├── theme.asm            # semantic color pairs and mono fallback
├── keymap.asm            # context-sensitive commands
├── screens/
│   ├── overview.asm
│   ├── providers.asm
│   ├── routes.asm
│   ├── requests.asm
│   ├── mcp.asm
│   ├── logs.asm
│   └── settings.asm
├── components/
│   ├── topbar.asm
│   ├── sidenav.asm
│   ├── table.asm
│   ├── status_badge.asm
│   ├── detail_panel.asm
│   ├── command_palette.asm
│   ├── confirm_dialog.asm
│   └── event_line.asm
└── text/
    ├── truncate.asm
    ├── wrap.asm
    └── width.asm
```

## 7. 개발 시 주의사항 (Implementation Notes)

### 7.1. 스타일링 전략

- Widget별 직접 색상 번호 사용 금지, Semantic Token만 사용
- Screen이 Layout 계산을 중복 구현하지 않음
- Table Column은 ID, Label, Priority, Min Width, Max Width, Align을 Descriptor로 정의
- 데이터와 렌더링을 분리해 동일 Snapshot을 CLI Text로도 출력 가능하게 함
- Terminal-specific Escape Sequence 직접 출력보다 ncursesw API 우선

### 7.2. 접근성 가이드

- 색상만으로 상태를 표현하지 않음
- Keyboard-only Path 필수
- Focus 위치를 `>` 또는 Reverse로 명확히 표시
- Blink 사용 금지
- 실시간 로그 자동 스크롤을 Pause 가능하게 함
- 정보 갱신이 Selection을 임의로 이동시키지 않음
- `NO_COLOR`, Mono, ASCII Fallback 제공
- TUI 사용이 어려운 사용자를 위해 `asmflowctl ... --json`과 `--table` 출력 제공

### 7.3. 예외 처리

- Daemon 연결 실패: 마지막 Snapshot을 “STALE”로 표시하고 Retry/Exit 제공
- Config Reload 실패: 이전 Config를 유지하고 오류 위치 표시
- Terminal Resize: Layout 재계산 전 화면 입력을 안전하게 중단
- Unicode 폭 계산 실패: 해당 Cell을 Replacement Glyph 또는 ASCII로 표시
- 데이터 없음: 빈 Table 대신 원인과 생성 방법 표시
- 권한 부족: 명령을 실행하지 않고 필요한 File Mode/Token 설정 안내
- Crash Signal: 가능한 범위에서 `endwin()` 복구 후 비대화형 오류 출력

### 7.4. 금지되는 시각적 기믹

- 네온 그라디언트 흉내
- CRT Scanline, Flicker, 지속 Glitch
- 의미 없는 Hex Dump 배경
- 로딩 중 무한 고주파 Redraw
- 모든 Pane에 Heavy Border
- 상태가 정상인데도 빨간색·경고색을 장식으로 사용
- Assembly라는 이유만으로 1980년대 DOS UI를 그대로 복제

### 7.5. 디자인 완료 기준

- 주요 7개 Screen의 Text Wireframe 존재
- 80x24/100x30/140x40 Golden Layout Test 통과
- Color/Mono 상태 의미 일치
- 파괴적 Action Confirm Coverage 100%
- 모든 Error State에 다음 행동 존재
- Keyboard Task Script: Provider 상태 확인 → Route Detail → MCP Restart → Log 확인 → 종료
- TUI 종료 후 Shell Echo와 Cursor 상태 정상
