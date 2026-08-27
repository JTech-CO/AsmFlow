; AsmFlow — upstream provider engine layout.
;
; The gateway talks to providers through libcurl's multi interface, driven from
; the daemon's own epoll loop. There is no second reactor and no thread: an
; upstream socket is a loop source exactly like the listener, the control
; socket, and the signal descriptor (ADR 0002, ADR 0011).
;
; The shape of a request is therefore split in two. `af_http_dispatch` runs to
; completion as it always did, but for a generation endpoint it now ends by
; starting an exchange and returning without a response. The response is
; written later, from the callbacks libcurl drives, and the connection is
; suspended in between.
;
; Ownership: the engine owns the exchange table and every libcurl handle in it.
; An exchange BORROWS its connection and RELEASES it by clearing the pointer
; when the client goes away, so a completing transfer can always tell whether
; there is still anyone to answer.

%ifndef ASMFLOW_PROVIDER_INC
%define ASMFLOW_PROVIDER_INC

; --- capacity ---------------------------------------------------------------
; A hard ceiling on concurrent upstream transfers, independent of what the
; configuration asks for. `limits.max_active_requests` may lower it and can
; never raise it, so the table below is a fixed size and the loop's source
; table cannot be exhausted by upstream sockets alone.
%define AF_PROV_MAX_EXCHANGES 64

; How much of an upstream response AsmFlow will hold for a non-streaming
; request. A streaming request never accumulates more than one event.
%define AF_PROV_RESPONSE_MAX (16 * 1024 * 1024)

; The outbox depth at which a slow client causes the upstream transfer to be
; paused, and the depth at which it is resumed. Two marks rather than one, so a
; client draining a byte at a time does not produce a pause/resume per byte.
;
; Both are well under the outbox's own ceiling, and that gap is the point: a
; high-water mark equal to the ceiling would mean the append that ought to
; trigger the pause is the append that has already failed. Backpressure has to
; engage before the buffer is full, or it is not backpressure.
%define AF_PROV_PAUSE_HIGH (256 * 1024)
%define AF_PROV_PAUSE_LOW  (64 * 1024)

; The largest request body AsmFlow will rewrite and forward. The listener's own
; body ceiling applies first; this bounds the rewritten copy.
%define AF_PROV_REQUEST_MAX (16 * 1024 * 1024)

; --- libcurl enumerators ----------------------------------------------------
; Mirrored from <curl/curl.h> and asserted against the linked library at
; startup by af_prov_check_ordinals, in the order af_curl_poll_ordinals and
; af_curl_error_ordinals report them (ADR 0007). A mismatch stops the daemon.

%define AF_CURL_POLL_NONE   0
%define AF_CURL_POLL_IN     1
%define AF_CURL_POLL_OUT    2
%define AF_CURL_POLL_INOUT  3
%define AF_CURL_POLL_REMOVE 4

%define AF_CURL_SOCKET_TIMEOUT -1

%define AF_CURL_CSELECT_IN  0x01
%define AF_CURL_CSELECT_OUT 0x02
%define AF_CURL_CSELECT_ERR 0x04

; The CURLE_* codes provider_error.asm classifies. Anything not listed is an
; unclassified upstream failure, which is deliberately not retryable.
%define AF_CURLE_OK                  0
%define AF_CURLE_RESOLVE_PROXY       5
%define AF_CURLE_RESOLVE_HOST        6
%define AF_CURLE_CONNECT             7
%define AF_CURLE_TIMEDOUT            28
%define AF_CURLE_SSL_CONNECT         35
%define AF_CURLE_PEER_VERIFY         60
%define AF_CURLE_SSL_CACERT_BADFILE  77
%define AF_CURLE_SSL_ISSUER          83
%define AF_CURLE_GOT_NOTHING         52
%define AF_CURLE_PARTIAL_FILE        18
%define AF_CURLE_RECV                56
%define AF_CURLE_SEND                55
%define AF_CURLE_WRITE               23
%define AF_CURLE_ABORTED_BY_CALLBACK 42
%define AF_CURLE_UNSUPPORTED_PROTO   1

%define AF_CURLM_OK 0

; How many ordinals each accessor reports. The counts are part of the contract
; with the shim: a shorter array would be a buffer overrun, so the assembly
; states the length it allocated and the C side writes exactly that many.
%define AF_CURL_POLL_ORDINALS  9
%define AF_CURL_ERROR_ORDINALS 16
%define AF_CURL_MULTI_ORDINALS 3

; What af_prov_on_write and af_prov_on_header may return, mirroring the
; sentinels src/ffi/curl_shim.c defines. A non-negative value is a byte count.
%define AF_PROV_TAKE_PAUSE -1
%define AF_PROV_TAKE_ABORT -2

; --- endpoint families ------------------------------------------------------
; Which upstream path a request is forwarded to. The value is an index into the
; suffix table in provider_adapter.asm.
%define AF_PROV_FAMILY_RESPONSES 0
%define AF_PROV_FAMILY_CHAT      1

; --- exchange state ---------------------------------------------------------
%define AF_PX_FREE      0
%define AF_PX_STARTING  1       ; handle built, not yet handed to the multi
%define AF_PX_ACTIVE    2       ; in flight
%define AF_PX_FINISHING 3       ; reaped, response being completed
%define AF_PX_DONE      4

; --- exchange flags ---------------------------------------------------------
%define AF_PX_F_STREAM       1      ; the client asked for stream: true
%define AF_PX_F_HEAD_SENT    2      ; our response head is in the outbox
%define AF_PX_F_COMMITTED    4      ; a response byte has reached the client
%define AF_PX_F_PAUSED       8      ; libcurl receive is paused for backpressure
%define AF_PX_F_UPSTREAM_SSE 16     ; the upstream answered text/event-stream
%define AF_PX_F_ADDED        32     ; the easy handle is in the multi handle
%define AF_PX_F_CANCELLED    64     ; the client went away first
%define AF_PX_F_TRAILER_SENT 128    ; the terminating chunk has been written
%define AF_PX_F_STATUS_SEEN  256    ; a status line has been parsed
%define AF_PX_F_OVERFLOW     512    ; a ceiling was passed while receiving

; --- af_prov_exchange (304 bytes) -------------------------------------------
; One in-flight upstream request. Fixed size and allocated from a table, so a
; burst of requests cannot fragment the heap and the count of live exchanges is
; exactly the count of occupied slots.
%define PX_STATE          0
%define PX_ENGINE         8
%define PX_CONN           16    ; af_http_conn * — BORROWED, NULL once gone
%define PX_EASY           24
%define PX_SLIST          32
%define PX_CONFIG         40    ; af_config * — a reference is held
%define PX_ROUTE          48    ; af_cfg_route *  (into the snapshot above)
%define PX_TARGET         56    ; af_cfg_route_target *
%define PX_PROVIDER       64    ; af_cfg_provider *
%define PX_FLAGS          72
%define PX_FAMILY         80    ; AF_PROV_FAMILY_*
%define PX_STATUS         88    ; upstream HTTP status, 0 until seen
%define PX_RESULT         96    ; normalised af_status of the failure, or 0
%define PX_URL            104   ; af_buffer
%define PX_BODY           136   ; af_buffer — the rewritten request body
%define PX_RESPONSE       168   ; af_buffer — non-streaming accumulation
%define PX_CARRY          200   ; af_buffer — a partial SSE event across writes
%define PX_CTYPE          232   ; af_buffer — the upstream Content-Type
%define PX_BODY_BYTES     264
%define PX_EVENTS         272   ; SSE events forwarded
%define PX_SLOT           280
%define PX_STARTED_NS     288
%define PX_SSE_LIMIT      296   ; limits.sse_event_max_bytes for this exchange
%define PX_SIZE           304

; --- af_prov_engine ---------------------------------------------------------
%define PE_MULTI          0
%define PE_TIMER_FD       8
%define PE_LOOP           16
%define PE_RT             24    ; af_runtime *
%define PE_RUNNING        32    ; transfers libcurl still has in flight
%define PE_ACTIVE         40    ; exchange slots occupied
%define PE_MAX_ACTIVE     48    ; the configured ceiling, never above the table
%define PE_STARTED        56    ; 1 once curl_global_init has succeeded
%define PE_TOTAL          64    ; exchanges started since boot
%define PE_FAILED         72    ; exchanges that ended in an upstream failure
%define PE_CANCELLED      80    ; exchanges the client abandoned
%define PE_EXCHANGES      88
%define PE_SIZE           (PE_EXCHANGES + AF_PROV_MAX_EXCHANGES * PX_SIZE)

; --- timerfd ----------------------------------------------------------------
; struct itimerspec { struct timespec it_interval; struct timespec it_value; }
%define ITS_INTERVAL_SEC  0
%define ITS_INTERVAL_NSEC 8
%define ITS_VALUE_SEC     16
%define ITS_VALUE_NSEC    24
%define ITS_SIZE          32

%endif ; ASMFLOW_PROVIDER_INC
