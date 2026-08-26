; AsmFlow — configuration snapshot layout.
;
; A snapshot is immutable once published. Requests take a reference for their
; whole lifetime, so a reload can build a new snapshot and swap the pointer
; without any in-flight request observing a half-applied change
; (docs/CONFIGURATION.md 13).
;
; Ownership: the `af_config` block itself comes from af_alloc. Everything it
; points at — every string, array, and nested record — is allocated from the
; arena embedded at the end of the block, so releasing a snapshot is one arena
; finalize plus one free, with no per-field teardown to get wrong.
;
; Strings are stored as NUL-terminated C strings even where a length is also
; kept, because they are handed to libcurl, SQLite, and execve unchanged.

%ifndef ASMFLOW_CONFIG_INC
%define ASMFLOW_CONFIG_INC

; --- enumerations ----------------------------------------------------------
; The ordinals match the enum order in config/asmflow.schema.json. Anything
; that is not one of these is a validation failure, never a default.

%define AF_AUTH_NONE        0
%define AF_AUTH_BEARER_ENV  1
%define AF_AUTH_HEADER_ENV  2

%define AF_ADAPTER_OPENAI_RESPONSES 0
%define AF_ADAPTER_OPENAI_CHAT      1
%define AF_ADAPTER_OPENAI_DUAL      2

%define AF_JOURNAL_WAL 0

%define AF_LOG_FORMAT_JSONL 0
%define AF_LOG_FORMAT_TEXT  1

%define AF_LOG_DEST_STDERR 0
%define AF_LOG_DEST_FILE   1

%define AF_TRANSPORT_STDIO           0
%define AF_TRANSPORT_STREAMABLE_HTTP 1

%define AF_RESTART_NEVER      0
%define AF_RESTART_ON_FAILURE 1
%define AF_RESTART_ALWAYS     2

; Retryable failure classes, as a bitmask. The names match the schema enum in
; `fallback.retryable`, and each one maps onto exactly one AF_E_UP_* code so
; that "is this class retryable" is a single test.
%define AF_RETRY_CONNECT_FAILED  1
%define AF_RETRY_DNS_FAILED      2
%define AF_RETRY_CONNECT_TIMEOUT 4
%define AF_RETRY_HTTP_502        8
%define AF_RETRY_HTTP_503        16
%define AF_RETRY_HTTP_504        32

; Legacy MCP protocol revisions the operator allows, as a bitmask.
%define AF_MCP_LEGACY_2025_11_25 1

; --- af_cfg_auth (24 bytes) ------------------------------------------------
%define AUTH_TYPE   0
%define AUTH_HEADER 8       ; char* canonical header name, or NULL
%define AUTH_ENV    16      ; char* environment variable name, or NULL
%define AUTH_SIZE   24

; --- af_cfg_timeouts (24 bytes) --------------------------------------------
%define TMO_CONNECT_MS 0
%define TMO_REQUEST_MS 8
%define TMO_IDLE_MS    16
%define TMO_SIZE       24

; --- af_cfg_health (40 bytes) ----------------------------------------------
%define HLT_PATH        0   ; char*
%define HLT_INTERVAL_MS 8
%define HLT_FAIL_THR    16
%define HLT_SUCC_THR    24
%define HLT_COOLDOWN_MS 32
%define HLT_SIZE        40

; --- af_cfg_provider (176 bytes) -------------------------------------------
%define PRV_ID              0
%define PRV_ID_LEN          8
%define PRV_DISPLAY_NAME    16
%define PRV_ADAPTER         24
%define PRV_BASE_URL        32
%define PRV_BASE_URL_LEN    40
%define PRV_AUTH            48      ; AUTH_SIZE
%define PRV_ENABLED         72
%define PRV_REQUIRED        80
%define PRV_MAX_CONCURRENCY 88
%define PRV_TIMEOUTS        96      ; TMO_SIZE
%define PRV_CAPABILITIES    120     ; AF_CAP_* bitmask
%define PRV_HEALTH          128     ; HLT_SIZE
%define PRV_ALLOW_INSECURE  168
%define PRV_SIZE            176

; --- af_cfg_route_target (40 bytes) ----------------------------------------
%define RTG_PROVIDER_ID    0
%define RTG_PROVIDER_INDEX 8         ; resolved during validation; -1 is invalid
%define RTG_UPSTREAM_MODEL 16
%define RTG_PRIORITY       24        ; signed
%define RTG_WEIGHT         32
%define RTG_SIZE           40

; --- af_cfg_route (88 bytes) -----------------------------------------------
%define RTE_ID                0
%define RTE_MODEL_ALIAS       8
%define RTE_MODEL_ALIAS_LEN   16
%define RTE_ENABLED           24
%define RTE_ENDPOINT_FAMILIES 32    ; AF_EPF_* bitmask
%define RTE_POLICY            40    ; AF_POLICY_*
%define RTE_FB_ENABLED        48
%define RTE_FB_MAX_ATTEMPTS   56
%define RTE_FB_RETRYABLE      64    ; AF_RETRY_* bitmask
%define RTE_TARGETS           72    ; af_cfg_route_target*
%define RTE_TARGET_COUNT      80
%define RTE_SIZE              88

; --- af_cfg_env_pair (16 bytes) --------------------------------------------
%define ENVP_NAME 0                 ; char* variable name given to the child
%define ENVP_ENV  8                 ; char* variable name read from our own env
%define ENVP_SIZE 16

; --- af_cfg_mcp (240 bytes) ------------------------------------------------
%define MCP_ID              0
%define MCP_DISPLAY_NAME    8
%define MCP_TRANSPORT       16
%define MCP_ENABLED         24
%define MCP_REQUIRED        32
%define MCP_COMMAND         40      ; stdio: absolute executable path
%define MCP_ARGS            48      ; stdio: char** literal argument vector
%define MCP_ARG_COUNT       56
%define MCP_CWD             64
%define MCP_ENV_ALLOW       72      ; char** allowlisted inherited variables
%define MCP_ENV_ALLOW_COUNT 80
%define MCP_ENV_PAIRS       88      ; af_cfg_env_pair*
%define MCP_ENV_PAIR_COUNT  96
%define MCP_URL             104     ; streamable_http
%define MCP_AUTH            112     ; AUTH_SIZE
%define MCP_PROTO_PREFERRED 136     ; AF_ERA_*
%define MCP_PROTO_LEGACY    144     ; AF_MCP_LEGACY_* bitmask
%define MCP_RESTART_MODE    152
%define MCP_MAX_RESTARTS    160
%define MCP_WINDOW_MS       168
%define MCP_BACKOFF_MS      176
%define MCP_MAX_BACKOFF_MS  184
%define MCP_STARTUP_TIMEOUT 192
%define MCP_SHUTDOWN_GRACE  200
%define MCP_TIMEOUTS        208     ; TMO_SIZE
%define MCP_ALLOW_INSECURE  232
%define MCP_SIZE            240

; --- af_config (392 bytes + embedded arena) --------------------------------
%define CFG_REFCOUNT            0
%define CFG_REVISION            8
%define CFG_HASH                16   ; FNV-1a 64 of the raw file bytes
%define CFG_SCHEMA_VERSION      24

%define CFG_LST_HOST            32
%define CFG_LST_PORT            40
%define CFG_LST_AUTH            48   ; AUTH_SIZE
%define CFG_LST_HDR_MAX         72
%define CFG_LST_BODY_MAX        80
%define CFG_LST_IDLE_MS         88
%define CFG_LST_EXPOSE_UNAVAIL  96
%define CFG_LST_IS_LOOPBACK     104

%define CFG_CTL_SOCKET_PATH     112
%define CFG_CTL_MODE            120
%define CFG_CTL_FRAME_MAX       128

%define CFG_STO_DB_PATH         136
%define CFG_STO_JOURNAL_MODE    144
%define CFG_STO_BUSY_MS         152
%define CFG_STO_RETENTION_DAYS  160
%define CFG_STO_STORE_PAYLOADS  168

%define CFG_LOG_LEVEL           176
%define CFG_LOG_FORMAT          184
%define CFG_LOG_DESTINATION     192
%define CFG_LOG_FILE_PATH       200
%define CFG_LOG_INC_REQ_META    208
%define CFG_LOG_INC_PAYLOADS    216
%define CFG_LOG_REDACT          224  ; char**
%define CFG_LOG_REDACT_COUNT    232

%define CFG_LIM_MAX_ACTIVE      240
%define CFG_LIM_MAX_QUEUED      248
%define CFG_LIM_JSON_DEPTH      256
%define CFG_LIM_JSON_STR_MAX    264
%define CFG_LIM_SSE_EVENT_MAX   272
%define CFG_LIM_MCP_FRAME_MAX   280
%define CFG_LIM_STDERR_LINE_MAX 288

%define CFG_PROVIDERS           296
%define CFG_PROVIDER_COUNT      304
%define CFG_ROUTES              312
%define CFG_ROUTE_COUNT         320
%define CFG_MCP_SERVERS         328
%define CFG_MCP_COUNT           336

%define CFG_ARENA               344  ; embedded af_arena (48 bytes)
%define CFG_SIZE                392

; --- af_cfg_error (72 bytes) -----------------------------------------------
; A rejection carries three things a person can act on: the af_status code, the
; RFC 6901 JSON Pointer of the offending location, and a short message. The
; message never contains a value, only a rule, so a rejected configuration can
; be logged without leaking whatever the operator put in the file.
%define CFGERR_CODE    0
%define CFGERR_POINTER 8     ; af_buffer, 32 bytes
%define CFGERR_MESSAGE 40    ; af_buffer, 32 bytes
%define CFGERR_SIZE    72

%endif ; ASMFLOW_CONFIG_INC
