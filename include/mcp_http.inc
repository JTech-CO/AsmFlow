; AsmFlow — policy-neutral MCP outbound HTTP reactor layout.
;
; This header describes transport storage only.  The modern and legacy MCP
; adapters own request construction, version/era decisions, JSON-RPC meaning,
; sessions, and inventory policy.  The reactor owns libcurl handles while they
; are registered and bounded byte buffers while a transfer slot is live.
;
; One configured server may have one request POST and, only in the legacy
; adapter, one long-lived GET.  The schema accepts 256 MCP servers, so the fixed
; table admits exactly that worst case without an unbounded allocation.

%ifndef ASMFLOW_MCP_HTTP_INC
%define ASMFLOW_MCP_HTTP_INC

%include "curl.inc"

; --- capacity and hard limits ----------------------------------------------

%define AF_MCP_HTTP_MAX_SERVERS        256
%define AF_MCP_HTTP_XFERS_PER_SERVER   2
%define AF_MCP_HTTP_MAX_TRANSFERS      (AF_MCP_HTTP_MAX_SERVERS * AF_MCP_HTTP_XFERS_PER_SERVER)

%define AF_MCP_HTTP_HEADER_DEFAULT     (64 * 1024)
%define AF_MCP_HTTP_BODY_DEFAULT       (4 * 1024 * 1024)
%define AF_MCP_HTTP_EVENT_DEFAULT      (1024 * 1024)

%define AF_MCP_HTTP_HEADER_HARD_MAX    (1024 * 1024)
%define AF_MCP_HTTP_BODY_HARD_MAX      (64 * 1024 * 1024)
%define AF_MCP_HTTP_EVENT_HARD_MAX     (16 * 1024 * 1024)
%define AF_MCP_HTTP_EVENT_COUNT_MAX    1024

%define AF_MCP_HTTP_URL_MAX            4096
%define AF_MCP_HTTP_CTYPE_MAX          512
%define AF_MCP_HTTP_PROTOCOL_MAX       128
%define AF_MCP_HTTP_SESSION_MAX        4096
%define AF_MCP_HTTP_BUFFER_SIZE        32

; Not a CURLcode.  A locally cancelled transfer never enters libcurl's DONE
; queue, so the completion hook receives this out-of-band value and reads the
; precise af_status from HX_CAUSE.
%define AF_MCP_HTTP_CURL_CANCELLED      -1

; --- adapter/method tags ----------------------------------------------------
; These are dispatch tags only.  Their meaning remains in src/mcp adapters.

%define AF_MCP_HTTP_ADAPTER_UNKNOWN     0
%define AF_MCP_HTTP_ADAPTER_MODERN      1
%define AF_MCP_HTTP_ADAPTER_LEGACY      2

%define AF_MCP_HTTP_METHOD_POST         0
%define AF_MCP_HTTP_METHOD_GET          1

; Modern and legacy adapter state are different owned types. The modern type
; cannot physically carry session/GET state; only the legacy allocation owns
; session and resumability buffers (ADR 0004).
%define MH_CHILD       0
%define MH_GENERATION  8
%define MH_SIZE        16

%define LH_CHILD       0
%define LH_GENERATION  8
%define LH_FLAGS       16
%define LH_RETRY_MS    24
%define LH_SESSION     32      ; af_buffer
%define LH_LAST_EVENT  64      ; af_buffer
%define LH_SIZE        96

%define AF_MCP_LH_F_INITIALIZED 1
%define AF_MCP_LH_F_GET_STARTED 2

; --- transfer state --------------------------------------------------------

%define AF_MCP_HTTP_X_FREE              0
%define AF_MCP_HTTP_X_BUILDING          1
%define AF_MCP_HTTP_X_ACTIVE            2
%define AF_MCP_HTTP_X_COMPLETING        3

; --- transfer flags --------------------------------------------------------

%define AF_MCP_HTTP_F_ADDED             1
%define AF_MCP_HTTP_F_CANCELLED         2
%define AF_MCP_HTTP_F_HEADERS_DONE      4
%define AF_MCP_HTTP_F_CONTENT_JSON      8
%define AF_MCP_HTTP_F_CONTENT_SSE       16
%define AF_MCP_HTTP_F_OVERFLOW          32
%define AF_MCP_HTTP_F_STATUS_SEEN       64
%define AF_MCP_HTTP_F_IN_CALLBACK       128
%define AF_MCP_HTTP_F_CANCEL_PENDING    256
%define AF_MCP_HTTP_F_CTYPE_SEEN        512
%define AF_MCP_HTTP_F_PROTOCOL_SEEN     1024
%define AF_MCP_HTTP_F_SESSION_SEEN      2048
%define AF_MCP_HTTP_F_DUP_HEADER        4096
%define AF_MCP_HTTP_F_FINAL_SEEN        8192
%define AF_MCP_HTTP_F_NOTIFICATION      16384
%define AF_MCP_HTTP_F_INITIALIZED       32768
%define AF_MCP_HTTP_F_CANCEL_NOTICE     65536

; --- af_mcp_http_transfer (432 bytes) --------------------------------------
;
; Ownership while HX_STATE != FREE:
;   engine, child, call               BORROWED
;   config                            RETAINED by adapter, released by slot
;   easy                              OWNED; borrowed by multi while ADDED
;   slist                             OWNED; borrowed by easy until easy free
;   url/body/response/carry/event/... OWNED af_buffer payloads
;
; Slot allocation creates EASY and every bounded buffer.  Adapter code fills
; CHILD, CALL, GENERATION, ADAPTER_KIND, METHOD, BODY, and SLIST while BUILDING,
; then configures/adds EASY to HE_MULTI, sets ADDED, and publishes ACTIVE.  The
; generation lets policy reject a completion belonging to an obsolete server
; incarnation without dereferencing stale call state.
;
; SSE is deliberately a bounded aggregate at this layer: write callbacks append
; raw bytes to SSE_CARRY, and the era adapter incrementally decodes the complete
; request-scoped response after curl completion using SSE_EVENT as its bounded
; workspace.  A legacy advisory GET is likewise finite at BODY_LIMIT; policy
; may reopen it only after completion, never from inside a curl callback.

%define HX_STATE             0
%define HX_ENGINE            8
%define HX_EASY              16
%define HX_SLIST             24
%define HX_CHILD             32
%define HX_CALL              40
%define HX_GENERATION        48
%define HX_ADAPTER_KIND      56
%define HX_METHOD            64
%define HX_FLAGS             72
%define HX_CURL_RESULT       80
%define HX_CAUSE             88
%define HX_HTTP_STATUS       96
%define HX_HEADER_BYTES      104
%define HX_BODY_BYTES        112
%define HX_HEADER_LINES      120
%define HX_SSE_EVENTS        128
%define HX_SLOT              136
%define HX_HEADER_LIMIT      144
%define HX_BODY_LIMIT        152
%define HX_EVENT_LIMIT       160

%define HX_BODY              168   ; request body; CURLOPT_POSTFIELDS BORROWS it
%define HX_RESPONSE          200   ; JSON response bytes
%define HX_SSE_CARRY         232   ; raw request-scoped SSE bytes not yet consumed
%define HX_SSE_EVENT         264   ; one bounded decoded/framed event workspace
%define HX_CONTENT_TYPE      296   ; trimmed response Content-Type
%define HX_PROTOCOL          328   ; trimmed MCP-Protocol-Version response value
%define HX_SESSION           360   ; legacy session header; modern policy ignores it
%define HX_URL               392   ; stable CURLOPT_URL storage, never arena-backed
%define HX_CONFIG            424   ; RETAINED af_config snapshot, or NULL
%define HX_SIZE              432

; --- af_mcp_http_engine ----------------------------------------------------
;
; HE_SUP and HE_LOOP are BORROWED and must outlive the engine.  curl global
; setup is deliberately absent: the daemon owns that process-wide lifetime.

%define HE_MULTI             0
%define HE_TIMER_FD          8
%define HE_LOOP              16
%define HE_SUP               24
%define HE_RUNNING           32
%define HE_ACTIVE            40
%define HE_MAX_ACTIVE        48
%define HE_STARTED           56
%define HE_TOTAL             64
%define HE_COMPLETED         72
%define HE_CANCELLED         80
%define HE_FAILED            88
%define HE_LAST_MULTI        96
%define HE_HEADER_LIMIT      104
%define HE_BODY_LIMIT        112
%define HE_EVENT_LIMIT       120
%define HE_TRANSFERS         128
%define HE_SIZE              (HE_TRANSFERS + AF_MCP_HTTP_MAX_TRANSFERS * HX_SIZE)

%endif ; ASMFLOW_MCP_HTTP_INC
