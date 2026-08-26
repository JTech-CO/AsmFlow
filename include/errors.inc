; AsmFlow — result and error contract.
;
; Convention
; ----------
; Every exported AsmFlow function that can fail returns an `af_status` in rax:
;
;   rax == 0            success (AF_OK)
;   rax <  0            failure; the value is one of the AF_E_* codes below
;
; Functions that produce a value take a caller-owned out-pointer as their last
; argument and write it only on success. Functions that return a pointer
; directly document NULL as their sole failure indication and are used only
; where the caller cannot act on a specific code.
;
; Codes are stable: they appear in logs, control-plane errors, and tests. Never
; renumber an existing code; append instead.

%ifndef ASMFLOW_ERRORS_INC
%define ASMFLOW_ERRORS_INC

%define AF_OK                    0

; --- generic (-1 .. -19) ---------------------------------------------------
%define AF_E_INVALID            -1      ; malformed argument or state
%define AF_E_NOMEM              -2      ; allocation failed
%define AF_E_OVERFLOW           -3      ; checked size arithmetic overflowed
%define AF_E_LIMIT              -4      ; configured maximum exceeded
%define AF_E_NOTFOUND           -5      ; lookup miss
%define AF_E_EXISTS             -6      ; duplicate key
%define AF_E_AGAIN              -7      ; would block; retry when readable
%define AF_E_EOF                -8      ; peer closed cleanly
%define AF_E_INTR               -9      ; interrupted by signal
%define AF_E_CLOSED             -10     ; object already finalized
%define AF_E_UNSUPPORTED        -11     ; recognized but not implemented
%define AF_E_INTERNAL           -12     ; invariant violation caught at runtime
%define AF_E_TIMEOUT            -13     ; deadline elapsed
%define AF_E_CANCELLED          -14     ; caller-initiated cancellation
%define AF_E_PERM               -15     ; permission/ownership check failed
%define AF_E_RANGE              -16     ; value outside the contract range

; --- syscall/platform (-20 .. -39) -----------------------------------------
%define AF_E_SYS                -20     ; errno captured in the platform layer
%define AF_E_ADDR               -21     ; address parse/bind failure
%define AF_E_PIPE               -22     ; write to a closed pipe
%define AF_E_SPAWN              -23     ; fork/exec failure
%define AF_E_SIGNAL             -24     ; signal handling failure

; --- JSON / configuration (-40 .. -69) -------------------------------------
%define AF_E_JSON_PARSE         -40     ; syntax error
%define AF_E_JSON_TYPE          -41     ; wrong JSON type at a pointer
%define AF_E_JSON_DEPTH         -42     ; nesting exceeded json_max_depth
%define AF_E_JSON_SIZE          -43     ; document or string exceeded a limit
%define AF_E_CFG_SCHEMA         -44     ; schema-equivalent rule rejected
%define AF_E_CFG_UNKNOWN_KEY    -45     ; unknown key where none are allowed
%define AF_E_CFG_MISSING_KEY    -46     ; required key absent
%define AF_E_CFG_PLAINTEXT      -47     ; plaintext secret rejected
%define AF_E_CFG_SECRET_MISSING -48     ; referenced environment variable unset
%define AF_E_CFG_REF            -49     ; cross-reference target does not exist
%define AF_E_CFG_VERSION        -50     ; unsupported schema_version
%define AF_E_CFG_DUPLICATE      -51     ; duplicate id or model_alias
%define AF_E_CFG_URL            -52     ; base_url violates URL policy
%define AF_E_CFG_PATH           -53     ; path policy violation

; --- storage (-70 .. -89) --------------------------------------------------
%define AF_E_DB                 -70     ; generic sqlite failure
%define AF_E_DB_BUSY            -71     ; SQLITE_BUSY after busy_timeout
%define AF_E_DB_MIGRATION       -72     ; migration failed and was rolled back
%define AF_E_DB_SCHEMA          -73     ; on-disk schema newer than this build
%define AF_E_DB_READONLY        -74     ; write attempted on a read-only handle

; --- HTTP data plane (-90 .. -119) -----------------------------------------
%define AF_E_HTTP_PARSE         -90     ; llhttp rejected the message
%define AF_E_HTTP_HEADERS_LARGE -91     ; request_header_max_bytes exceeded
%define AF_E_HTTP_BODY_LARGE    -92     ; request_body_max_bytes exceeded
%define AF_E_HTTP_METHOD        -93     ; method not allowed for the path
%define AF_E_HTTP_PATH          -94     ; unknown path
%define AF_E_HTTP_CTYPE         -95     ; unsupported Content-Type
%define AF_E_HTTP_AUTH          -96     ; missing or invalid bearer token
%define AF_E_HTTP_SMUGGLE       -97     ; conflicting or duplicated framing
%define AF_E_HTTP_IDLE          -98     ; idle_timeout_ms elapsed
%define AF_E_SSE_EVENT_LARGE    -99     ; sse_event_max_bytes exceeded

; --- upstream provider (-120 .. -149) --------------------------------------
; The subset named in config `fallback.retryable` must map 1:1 onto these codes.
%define AF_E_UP_CONNECT_FAILED  -120
%define AF_E_UP_DNS_FAILED      -121
%define AF_E_UP_CONNECT_TIMEOUT -122
%define AF_E_UP_HTTP_502        -123
%define AF_E_UP_HTTP_503        -124
%define AF_E_UP_HTTP_504        -125
%define AF_E_UP_TLS             -126     ; never retryable: certificate policy
%define AF_E_UP_TIMEOUT         -127     ; request_ms or idle_stream_ms elapsed
%define AF_E_UP_MALFORMED       -128     ; unparseable upstream response
%define AF_E_UP_STATUS          -129     ; other non-2xx passed through
%define AF_E_UP_CANCELLED       -130     ; client disconnected first

; --- routing (-150 .. -169) ------------------------------------------------
%define AF_E_ROUTE_UNKNOWN      -150     ; model alias has no route
%define AF_E_ROUTE_DISABLED     -151     ; route exists but is disabled
%define AF_E_ROUTE_NO_TARGET    -152     ; no eligible candidate
%define AF_E_ROUTE_CAPACITY     -153     ; concurrency or queue exhausted
%define AF_E_ROUTE_COMMITTED    -154     ; fallback attempted after commit
%define AF_E_ROUTE_ATTEMPTS     -155     ; max_attempts reached

; --- MCP (-170 .. -199) ----------------------------------------------------
%define AF_E_MCP_SPAWN          -170
%define AF_E_MCP_PROTOCOL       -171     ; frame is not valid JSON-RPC
%define AF_E_MCP_FRAME_LARGE    -172     ; mcp_frame_max_bytes exceeded
%define AF_E_MCP_ERA            -173     ; era could not be determined
%define AF_E_MCP_VERSION        -174     ; no mutually supported version
%define AF_E_MCP_TIMEOUT        -175
%define AF_E_MCP_CRASH_LOOP     -176     ; restart budget exhausted
%define AF_E_MCP_NOT_READY      -177
%define AF_E_MCP_UNCONFIRMED    -178     ; tool call without confirmed=true
%define AF_E_MCP_CONTAMINATED   -179     ; non-protocol bytes on child stdout
%define AF_E_MCP_HEADER_MISMATCH -180    ; MCP-Protocol-Version != body _meta

; --- control plane (-200 .. -219) ------------------------------------------
%define AF_E_CTL_FRAME_LARGE    -200     ; frame_max_bytes exceeded
%define AF_E_CTL_METHOD         -201     ; unknown method
%define AF_E_CTL_PARAMS         -202     ; invalid params
%define AF_E_CTL_CURSOR_STALE   -203     ; pagination cursor no longer valid
%define AF_E_CTL_STATE          -204     ; command invalid in the current state

%endif ; ASMFLOW_ERRORS_INC
