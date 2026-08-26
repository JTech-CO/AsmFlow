; AsmFlow — shared runtime constants.
;
; Only values that genuinely have more than one consumer belong here; per
; AGENTS.md, module-private constants stay in their module.

%ifndef ASMFLOW_INC
%define ASMFLOW_INC

%include "abi.inc"
%include "errors.inc"
%include "assert.inc"

; AF_VERSION_STRING is injected by the build so that VERSION, --version, the
; release tag, and the changelog cannot drift (M1 DoD 1, M12 DoD 7).
%ifndef AF_VERSION_STRING
    %define AF_VERSION_STRING "0.0.0-unconfigured"
%endif

%define AF_PRODUCT_NAME  "AsmFlow"
%define AF_DAEMON_NAME   "asmflowd"
%define AF_TUI_NAME      "asmflow-tui"
%define AF_CTL_NAME      "asmflowctl"

; MCP protocol eras. Kept as separate constants because modern and legacy
; adapters may not share state (AGENTS.md invariant 13).
%define AF_MCP_MODERN_VERSION "2026-07-28"
%define AF_MCP_LEGACY_VERSION "2025-11-25"

; Era discriminator stored per stdio process / HTTP origin.
%define AF_ERA_UNKNOWN   0
%define AF_ERA_MODERN    1
%define AF_ERA_LEGACY    2

; Endpoint families (bit flags; a route may advertise both).
%define AF_EPF_RESPONSES        1
%define AF_EPF_CHAT_COMPLETIONS 2

; Capability bits, ordered to match config/asmflow.schema.json `capabilities`.
%define AF_CAP_RESPONSES        1
%define AF_CAP_CHAT_COMPLETIONS 2
%define AF_CAP_STREAMING        4
%define AF_CAP_TOOLS            8
%define AF_CAP_VISION           16
%define AF_CAP_JSON_SCHEMA      32

; Provider health states. Ordering matters: eligibility is a set membership
; test, not a comparison, so the values are plain tags.
%define AF_HEALTH_HEALTHY       0
%define AF_HEALTH_DEGRADED      1
%define AF_HEALTH_OPEN          2
%define AF_HEALTH_HALF_OPEN     3
%define AF_HEALTH_DISABLED      4

; Routing policies, matching the schema enum order.
%define AF_POLICY_PRIORITY      0
%define AF_POLICY_ROUND_ROBIN   1
%define AF_POLICY_LEAST_LATENCY 2

; Log levels, matching the schema enum order.
%define AF_LOG_TRACE 0
%define AF_LOG_DEBUG 1
%define AF_LOG_INFO  2
%define AF_LOG_WARN  3
%define AF_LOG_ERROR 4
%define AF_LOG_FATAL 5

; Process exit codes. 0 and 1 follow convention; the rest let the harness and
; systemd distinguish configuration faults from runtime faults.
%define AF_EXIT_OK          0
%define AF_EXIT_FAILURE     1
%define AF_EXIT_USAGE       2
%define AF_EXIT_CONFIG      3
%define AF_EXIT_STORAGE     4
%define AF_EXIT_LISTENER    5
%define AF_EXIT_INTERNAL    70

; Hard ceilings that no configuration may raise. Config-supplied limits are
; validated against these before a snapshot is published.
%define AF_MAX_CONFIG_BYTES     (4 * 1024 * 1024)
%define AF_MAX_JSON_DEPTH       256
%define AF_MAX_CONTROL_FRAME    (4 * 1024 * 1024)
%define AF_MAX_ROUTE_TARGETS    64
%define AF_MAX_PROVIDERS        256
%define AF_MAX_ROUTES           256
%define AF_MAX_MCP_SERVERS      256
%define AF_MAX_ATTEMPTS         16

; Clock identifiers and the two conversions every duration in the daemon uses.
; Shared because the clock module and the listener's idle timer both need them,
; and one name defined in two places is one name whose meaning depends on
; include order.
%define CLOCK_REALTIME  0
%define CLOCK_MONOTONIC 1
%define NS_PER_SEC      1000000000
%define NS_PER_MS       1000000

%endif ; ASMFLOW_INC
