; AsmFlow — inbound HTTP data plane.
;
; ADR 0006: AsmFlow owns the socket, the connection state, every limit, the
; authentication decision, the dispatch, and the response. llhttp is used only
; for HTTP/1.1 syntax and body framing, through the adapter in
; `src/ffi/llhttp_shim.c`, with every leniency mode off.
;
; ADR 0010: the idle timeout is one timerfd sweeping the connection table, not
; a timer per connection.

%ifndef ASMFLOW_HTTP_INC
%define ASMFLOW_HTTP_INC

; How many clients the listener will hold at once. A bounded table means a peer
; opening sockets in a loop is refused rather than allowed to exhaust the
; process's descriptors, exactly as on the control socket.
%define AF_HTTP_MAX_CLIENTS 128

%define AF_HTTP_READ_CHUNK 65536

; Storage reserved inside each connection for llhttp's parser state. The real
; size is whatever the linked library reports; af_http_server_init asserts it
; fits rather than assuming, so a library that grows its state fails at startup
; with a diagnosable error instead of writing past the field.
%define AF_HTTP_PARSER_MAX 256

; The request target and the current header name and value are bounded on their
; own, so a single enormous token is refused before the header-section ceiling
; would notice it.
%define AF_HTTP_TARGET_MAX 8192
%define AF_HTTP_NAME_MAX   1024
%define AF_HTTP_VALUE_MAX  8192

; How often the idle sweep runs. The timeout is a ceiling on inactivity, so the
; sweep only has to be fine enough that a connection is closed promptly after
; it expires, not exactly at the millisecond.
%define AF_HTTP_IDLE_TICK_MS 250

; --- llhttp enumerators ----------------------------------------------------
; Mirrored here so the assembly can compare against a constant, and asserted in
; tests/asm/test_http.asm against the values the linked library actually
; compiled, exactly as the Jansson ordinals are (ADR 0007). A release that
; renumbered these fails a test rather than silently accepting POST as GET.
%define AF_HTTP_M_DELETE  0
%define AF_HTTP_M_GET     1
%define AF_HTTP_M_HEAD    2
%define AF_HTTP_M_POST    3
%define AF_HTTP_M_PUT     4
%define AF_HTTP_M_CONNECT 5
%define AF_HTTP_M_OPTIONS 6

%define AF_HPE_OK             0
%define AF_HPE_PAUSED         21
%define AF_HPE_PAUSED_UPGRADE 22
%define AF_HPE_USER           24

; The four llhttp verdicts that are specifically about message framing. They are
; reported as `conflicting_framing` rather than as a generic syntax failure,
; because an operator reading a log wants to tell a broken client from something
; probing for a disagreement about where a message ends.
%define AF_HPE_UNEXPECTED_CONTENT_LENGTH 4
%define AF_HPE_INVALID_CONTENT_LENGTH    11
%define AF_HPE_INVALID_CHUNK_SIZE        12
%define AF_HPE_INVALID_TRANSFER_ENCODING 15

; --- endpoints -------------------------------------------------------------
; The whole surface. docs/API_CONTRACT.md 2 is explicit that AsmFlow is a
; gateway rather than a general web server, so an unlisted path is a 404 and
; never a fallthrough.
%define AF_EP_UNKNOWN   0
%define AF_EP_HEALTHZ   1
%define AF_EP_READYZ    2
%define AF_EP_MODELS    3
%define AF_EP_RESPONSES 4
%define AF_EP_CHAT      5
%define AF_EP_COUNT     6

; --- error classes ---------------------------------------------------------
; The `type` field of an AsmFlow-generated error body
; (docs/API_CONTRACT.md 7).
%define AF_ERRCLASS_REQUEST  0
%define AF_ERRCLASS_AUTH     1
%define AF_ERRCLASS_ROUTE    2
%define AF_ERRCLASS_STATE    3
%define AF_ERRCLASS_CAPACITY 4
%define AF_ERRCLASS_UPSTREAM 5
%define AF_ERRCLASS_ROUTING  6
%define AF_ERRCLASS_COUNT    7

; --- the error catalogue ---------------------------------------------------
; Every failure AsmFlow can answer with is one entry in one table in
; `src/http/http_response.asm`, rather than a status and a string chosen at
; each call site. The contract's table in docs/API_CONTRACT.md 7 is then
; something a reader can check against a single place, and
; `tests/test_http_contract.py` asserts the two agree entry by entry.
;
; af_http_error_def:
;   +0  status      the HTTP status to send
;   +8  class       AF_ERRCLASS_*
;   +16 code        the contract's `code` string
;   +24 message     a fixed sentence; never a value from the request
;   +32 param       the offending field, or NULL
;   +40 retryable   what the `asmflow.retryable` hint reports
;   +48 head_flags  AF_HEAD_* for the response headers
%define HED_STATUS     0
%define HED_CLASS      8
%define HED_CODE       16
%define HED_MESSAGE    24
%define HED_PARAM      32
%define HED_RETRYABLE  40
%define HED_HEAD_FLAGS 48
%define HED_SIZE       56

%define AF_HERR_UNKNOWN_PATH      0
%define AF_HERR_METHOD_GET_ONLY   1
%define AF_HERR_METHOD_POST_ONLY  2
%define AF_HERR_HEADERS_TOO_LARGE 3
%define AF_HERR_BODY_TOO_LARGE    4
%define AF_HERR_LENGTH_REQUIRED   5
%define AF_HERR_UNSUPPORTED_CTYPE 6
%define AF_HERR_INVALID_JSON      7
%define AF_HERR_INVALID_FIELD     8
%define AF_HERR_MISSING_MODEL     9
%define AF_HERR_MISSING_TOKEN     10
%define AF_HERR_INVALID_TOKEN     11
%define AF_HERR_MALFORMED         12
%define AF_HERR_SMUGGLING         13
%define AF_HERR_REQUEST_TIMEOUT   14
%define AF_HERR_NOT_READY         15
%define AF_HERR_UNKNOWN_ALIAS     16
%define AF_HERR_ROUTE_DISABLED    17
%define AF_HERR_UNSUPPORTED_BUILD 18
%define AF_HERR_VERSION           19
%define AF_HERR_INTERNAL          20
%define AF_HERR_COUNT             21

; Optional response headers, chosen per response rather than always emitted.
%define AF_HEAD_NO_STORE   1
%define AF_HEAD_ALLOW_GET  2
%define AF_HEAD_ALLOW_POST 4
%define AF_HEAD_SSE        8

; --- af_http_conn ----------------------------------------------------------
; One accepted client. Everything a request needs is inside the slot: a
; keep-alive connection clears these buffers between messages rather than
; freeing and reallocating them, so a long-lived client does not churn the heap
; once per request.
;
;   +0   fd              -1 when the slot is free
;   +8   server          af_http_server * (BORROWED)
;   +16  inbox           af_buffer: bytes read but not yet fed to llhttp
;   +48  outbox          af_buffer: response bytes not yet written
;   +80  out_cursor      how much of the outbox has already been written
;   +88  last_active_ns  monotonic; the idle sweep compares against this
;   +96  method          llhttp method ordinal of the message being parsed
;   +104 endpoint        AF_EP_*, resolved once the target is known
;   +112 header_bytes    raw bytes of the header section seen so far
;   +120 body_bytes      body bytes delivered so far
;   +128 content_length  the declared value, or -1 when none was sent
;   +136 fault           the first af_status that refused this message
;   +144 flags           HC_F_*
;   +152 requests        messages completed on this connection
;   +160 target          af_buffer: the request target, accumulated
;   +192 name            af_buffer: the header field currently being read
;   +224 value           af_buffer: its value
;   +256 body            af_buffer: the request body
;   +288 auth            af_buffer: the credential header's value, if any
;   +320 ctype           af_buffer: Content-Type
;   +352 response        af_buffer: the body being built for this message
;   +384 request_id      27 bytes of ULID text and a NUL
;   +416 parser          llhttp state
%define HC_FD             0
%define HC_SERVER         8
%define HC_INBOX          16
%define HC_OUTBOX         48
%define HC_OUT_CURSOR     80
%define HC_LAST_ACTIVE_NS 88
%define HC_METHOD         96
%define HC_ENDPOINT       104
%define HC_HEADER_BYTES   112
%define HC_BODY_BYTES     120
%define HC_CONTENT_LENGTH 128
%define HC_FAULT          136
%define HC_FLAGS          144
%define HC_REQUESTS       152
%define HC_TARGET         160
%define HC_NAME           192
%define HC_VALUE          224
%define HC_BODY           256
%define HC_AUTH           288
%define HC_CTYPE          320
%define HC_RESPONSE       352
%define HC_REQUEST_ID     384
%define HC_PARSER         416

; ULID text is 26 bytes; the field carries the NUL as well, because the value is
; appended to a header with the C-string helpers.
%define AF_HTTP_REQUEST_ID_MAX 32
%define HC_SIZE           (HC_PARSER + AF_HTTP_PARSER_MAX)

%define HC_F_CLOSING        1     ; write out what is queued, then close
%define HC_F_HEADERS_DONE   2
%define HC_F_MESSAGE_DONE   4
%define HC_F_KEEP_ALIVE     8
%define HC_F_HAVE_CL        16    ; a Content-Length header was seen
%define HC_F_HAVE_TE        32    ; a Transfer-Encoding header was seen
%define HC_F_HAVE_AUTH      64
%define HC_F_HAVE_CTYPE     128
%define HC_F_RESPONDED      256   ; a response for this message is queued
%define HC_F_BUFFERS_READY  512
%define HC_F_FAULT          1024  ; HC_FAULT holds the AF_HERR_* to answer with
%define HC_F_UPGRADE        2048
%define HC_F_DRAINING       4096  ; response sent, reading the rest away

; --- af_http_server --------------------------------------------------------
;   +0   listen_fd
;   +8   timer_fd        the idle sweep
;   +16  loop            af_loop * (BORROWED)
;   +24  rt              the daemon runtime the endpoints read from (BORROWED)
;   +32  header_max      listener.request_header_max_bytes
;   +40  body_max        listener.request_body_max_bytes
;   +48  idle_ms         listener.idle_timeout_ms
;   +56  auth_type       AF_AUTH_*
;   +64  auth_header     char *: the header carrying the credential
;   +72  auth_secret     char *: the resolved secret (BORROWED from the env)
;   +80  auth_secret_len
;   +88  accepted
;   +96  rejected        refused because the table was full
;   +104 requests        messages completed across all connections
;   +112 timed_out       connections closed by the idle sweep
;   +120 port
;   +128 conns
%define HS_LISTEN_FD      0
%define HS_TIMER_FD       8
%define HS_LOOP           16
%define HS_RT             24
%define HS_HEADER_MAX     32
%define HS_BODY_MAX       40
%define HS_IDLE_MS        48
%define HS_AUTH_TYPE      56
%define HS_AUTH_HEADER    64
%define HS_AUTH_SECRET    72
%define HS_AUTH_SECRET_LEN 80
%define HS_ACCEPTED       88
%define HS_REJECTED       96
%define HS_REQUESTS       104
%define HS_TIMED_OUT      112
%define HS_PORT           120
%define HS_CONNS          128
%define HS_SIZE           (HS_CONNS + AF_HTTP_MAX_CLIENTS * HC_SIZE)

%endif ; ASMFLOW_HTTP_INC
