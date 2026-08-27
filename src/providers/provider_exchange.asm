; AsmFlow — one upstream request, from dispatch to the last byte.
;
; Until M6 every response was written inside `af_http_dispatch` and the
; connection was answered before the dispatcher returned. An upstream call
; cannot work that way, so a generation request now *suspends*: the dispatcher
; starts an exchange and returns having written nothing, the connection is
; marked HC_F_UPSTREAM, and the response is produced later from the callbacks
; libcurl drives. Everything in this file exists to make that suspension safe.
;
; Four rules are the substance of it.
;
; The commit point is real (docs/API_CONTRACT.md 8). A streamed response has to
; send its head before the first event, so from that moment the status is
; decided and no fallback can occur. A non-streamed response accumulates and
; commits at the end, which is what keeps its fallback window open for the
; whole transfer. AF_PX_F_COMMITTED records which of the two happened rather
; than leaving it to be re-derived.
;
; A client that disappears must cancel the transfer, not merely be ignored.
; `af_prov_conn_detach` clears the exchange's connection pointer and the write
; callback then refuses the next chunk, which is how libcurl learns to stop —
; the alternative is a provider being billed for tokens nobody will read.
;
; Backpressure is checked BEFORE the bytes are consumed. libcurl re-delivers
; whatever a paused write callback did not take, so a callback that buffered
; the data and then paused would deliver it twice. Checking first makes
; double-delivery impossible rather than merely unlikely.
;
; A response is framed by what it is, not by what is convenient. Streaming uses
; chunked transfer coding because its length is unknowable when the head is
; written, and that keeps the connection reusable afterwards; a non-streamed
; response has a length by the time anything is queued and states it.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "config.inc"
%include "runtime.inc"
%include "json.inc"
%include "http.inc"
%include "provider.inc"

        extern af_mem_zero
        extern af_mem_eq_ci
        extern af_cstr_len

        extern af_buf_init
        extern af_buf_free
        extern af_buf_clear
        extern af_buf_data
        extern af_buf_len
        extern af_buf_append
        extern af_buf_append_byte
        extern af_buf_append_cstr

        extern af_monotonic_ns

        extern af_config_retain
        extern af_config_release

        extern af_json_parse
        extern af_json_doc_root
        extern af_json_doc_free
        extern af_json_type

        extern af_http_write_head
        extern af_http_commit
        extern af_http_send_error
        extern af_http_conn_flush
        extern af_http_conn_resume

        extern af_curl_easy_new
        extern af_curl_easy_free
        extern af_curl_multi_add
        extern af_curl_multi_remove
        extern af_curl_set_url
        extern af_curl_set_protocols
        extern af_curl_set_follow_location
        extern af_curl_set_tls_verify
        extern af_curl_set_nosignal
        extern af_curl_set_post
        extern af_curl_set_headers
        extern af_curl_set_connect_timeout_ms
        extern af_curl_set_timeout_ms
        extern af_curl_set_low_speed
        extern af_curl_set_accept_encoding
        extern af_curl_pause
        extern af_curl_response_code
        extern af_curl_connect_time_us
        extern af_curl_slist_free

        extern af_prov_slot_alloc
        extern af_prov_slot_release
        extern af_prov_build_url
        extern af_prov_build_headers
        extern af_prov_rewrite_body
        extern af_prov_wants_stream
        extern af_prov_provider_supports
        extern af_prov_family_bit
        extern af_prov_protocols
        extern af_prov_classify_curl
        extern af_prov_classify_status
        extern af_prov_error_id
        extern af_prov_sse_feed
        extern af_prov_sse_finish

        section .rodata

h_content_type: db "content-type", 0
%define CONTENT_TYPE_LEN 12

s_event_stream: db "text/event-stream", 0
%define EVENT_STREAM_LEN 17

s_last_chunk:   db "0", 13, 10, 13, 10, 0
s_crlf:         db 13, 10, 0
hex_digits:     db "0123456789abcdef"

        section .text

; ---------------------------------------------------------------------------
; af_prov_pick_target(af_config *cfg, af_cfg_route *route, i64 family,
;                     i64 wants_stream, af_cfg_provider **out_provider)
;   -> af_cfg_route_target * (NULL when nothing is eligible)
;
; M6 picks the eligible target with the lowest `priority`, which is what
; `policy: priority` means. Round-robin and least-latency are M7's; putting
; them here now would mean writing a scheduler with no health signal to
; schedule against.
; ---------------------------------------------------------------------------
        global af_prov_pick_target
af_prov_pick_target:
        AF_ENTER 64
;   [rsp +  0]  family        [rsp + 16]  out_provider
;   [rsp +  8]  wants_stream  [rsp + 24]  best target      [rsp + 32] best provider
        test    rdi, rdi
        jz      .none
        test    rsi, rsi
        jz      .none
        mov     rbx, rdi                        ; config
        mov     r12, rsi                        ; route
        mov     [rsp], rdx
        mov     [rsp + 8], rcx
        mov     [rsp + 16], r8
        mov     qword [rsp + 24], 0
        mov     qword [rsp + 32], 0

        ; The route has to serve this endpoint family at all.
        mov     rdi, [rsp]
        call    af_prov_family_bit
        test    [r12 + RTE_ENDPOINT_FAMILIES], rax
        jz      .none

        xor     r13, r13                        ; target index
.scan:
        cmp     r13, [r12 + RTE_TARGET_COUNT]
        jae     .chosen
        mov     r14, r13
        imul    r14, r14, RTG_SIZE
        add     r14, [r12 + RTE_TARGETS]

        mov     rax, [r14 + RTG_PROVIDER_INDEX]
        cmp     rax, 0
        jl      .next
        cmp     rax, [rbx + CFG_PROVIDER_COUNT]
        jae     .next
        imul    rax, rax, PRV_SIZE
        add     rax, [rbx + CFG_PROVIDERS]
        mov     r15, rax

        mov     rdi, r15
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_prov_provider_supports
        test    rax, rax
        jz      .next

        cmp     qword [rsp + 24], 0
        je      .take
        mov     rax, [rsp + 24]
        mov     rax, [rax + RTG_PRIORITY]
        cmp     [r14 + RTG_PRIORITY], rax
        jge     .next                           ; signed: lower priority wins
.take:
        mov     [rsp + 24], r14
        mov     [rsp + 32], r15
.next:
        inc     r13
        jmp     .scan

.chosen:
        mov     rax, [rsp + 24]
        test    rax, rax
        jz      .none
        mov     rcx, [rsp + 16]
        test    rcx, rcx
        jz      .done
        mov     rdx, [rsp + 32]
        mov     [rcx], rdx
.done:
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_exchange_start(af_prov_engine *e, af_http_conn *c, af_cfg_route *route,
;                        i64 family, json_t *root) -> af_status
;
; AF_OK means the request is in flight and the connection is suspended. A
; negative status means nothing was started and the caller still owes the
; client a response; the AF_HERR_* to use is written through `out_error`.
; ---------------------------------------------------------------------------
        global af_prov_exchange_start
af_prov_exchange_start:
        AF_ENTER 128
;   [rsp +  0]  engine     [rsp + 32]  root        [rsp + 64]  provider
;   [rsp +  8]  conn       [rsp + 40]  exchange    [rsp + 72]  target
;   [rsp + 16]  route      [rsp + 48]  config      [rsp + 80]  wants_stream
;   [rsp + 24]  family     [rsp + 56]  easy handle
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        mov     [rsp], rdi
        mov     [rsp + 8], rsi
        mov     [rsp + 16], rdx
        mov     [rsp + 24], rcx
        mov     [rsp + 32], r8
        mov     qword [rsp + 40], 0
        mov     qword [rsp + 56], 0

        mov     rbx, rsi                        ; conn
        mov     r12, [rbx + HC_SERVER]
        test    r12, r12
        jz      .invalid
        mov     rax, [r12 + HS_RT]
        test    rax, rax
        jz      .invalid
        mov     rax, [rax + RT_CONFIG]
        test    rax, rax
        jz      .invalid
        mov     [rsp + 48], rax

        mov     rdi, [rsp + 32]
        call    af_prov_wants_stream
        mov     [rsp + 80], rax

        mov     rdi, [rsp + 48]
        mov     rsi, [rsp + 16]
        mov     rdx, [rsp + 24]
        mov     rcx, [rsp + 80]
        lea     r8, [rsp + 64]
        call    af_prov_pick_target
        test    rax, rax
        jz      .no_target
        mov     [rsp + 72], rax

        mov     rdi, [rsp]
        call    af_prov_slot_alloc
        test    rax, rax
        jz      .at_capacity
        mov     r13, rax
        mov     [rsp + 40], r13

        mov     rax, [rsp + 8]
        mov     [r13 + PX_CONN], rax
        mov     rax, [rsp + 16]
        mov     [r13 + PX_ROUTE], rax
        mov     rax, [rsp + 72]
        mov     [r13 + PX_TARGET], rax
        mov     rax, [rsp + 64]
        mov     [r13 + PX_PROVIDER], rax
        mov     rax, [rsp + 24]
        mov     [r13 + PX_FAMILY], rax
        cmp     qword [rsp + 80], 0
        je      .no_stream_flag
        or      qword [r13 + PX_FLAGS], AF_PX_F_STREAM
.no_stream_flag:

        ; The snapshot is retained for the exchange's whole life. A reload that
        ; lands mid-transfer must not free the provider record this handle's
        ; URL and credential came from.
        mov     rdi, [rsp + 48]
        call    af_config_retain
        mov     [r13 + PX_CONFIG], rax

        mov     rax, [rsp + 48]
        mov     rax, [rax + CFG_LIM_SSE_EVENT_MAX]
        mov     [r13 + PX_SSE_LIMIT], rax

        call    af_monotonic_ns
        mov     [r13 + PX_STARTED_NS], rax

        lea     rdi, [r13 + PX_URL]
        mov     rsi, 4096
        call    af_buf_init
        test    rax, rax
        js      .fail
        lea     rdi, [r13 + PX_BODY]
        mov     rsi, AF_PROV_REQUEST_MAX
        call    af_buf_init
        test    rax, rax
        js      .fail
        lea     rdi, [r13 + PX_RESPONSE]
        mov     rsi, AF_PROV_RESPONSE_MAX
        call    af_buf_init
        test    rax, rax
        js      .fail
        lea     rdi, [r13 + PX_CARRY]
        mov     rsi, AF_PROV_RESPONSE_MAX
        call    af_buf_init
        test    rax, rax
        js      .fail
        lea     rdi, [r13 + PX_CTYPE]
        mov     rsi, 512
        call    af_buf_init
        test    rax, rax
        js      .fail

        lea     rdi, [r13 + PX_URL]
        mov     rsi, [rsp + 64]
        mov     rdx, [rsp + 24]
        call    af_prov_build_url
        test    rax, rax
        js      .fail

        mov     rax, [rsp + 72]
        lea     rdi, [r13 + PX_BODY]
        mov     rsi, [rsp + 32]
        mov     rdx, [rax + RTG_UPSTREAM_MODEL]
        call    af_prov_rewrite_body
        test    rax, rax
        js      .fail

        mov     rdi, r13
        call    af_prov_build_headers
        test    rax, rax
        js      .fail

        mov     rdi, r13
        call    af_curl_easy_new
        test    rax, rax
        jz      .nomem
        mov     [r13 + PX_EASY], rax
        mov     [rsp + 56], rax

        mov     rdi, r13
        call    af_prov_configure_easy
        test    rax, rax
        js      .fail

        mov     rax, [rsp]
        mov     rdi, [rax + PE_MULTI]
        mov     rsi, [r13 + PX_EASY]
        call    af_curl_multi_add
        test    eax, eax
        jnz     .curl_failed
        or      qword [r13 + PX_FLAGS], AF_PX_F_ADDED
        mov     qword [r13 + PX_STATE], AF_PX_ACTIVE

        ; The connection is suspended only once the transfer is genuinely in
        ; flight, so a failure above leaves it exactly as the dispatcher found
        ; it and the ordinary error path still applies.
        mov     [rbx + HC_EXCHANGE], r13
        or      qword [rbx + HC_FLAGS], HC_F_UPSTREAM
        AF_LEAVE_OK

.curl_failed:
        mov     rax, AF_E_UP_CONNECT_FAILED
        jmp     .fail
.nomem:
        mov     rax, AF_E_NOMEM
.fail:
        mov     [rsp + 88], rax
        mov     rdi, [rsp + 40]
        test    rdi, rdi
        jz      .fail_done
        call    af_prov_exchange_dispose
.fail_done:
        mov     rax, [rsp + 88]
        AF_LEAVE
.no_target:
        AF_LEAVE_ERR AF_E_ROUTE_NO_TARGET
.at_capacity:
        AF_LEAVE_ERR AF_E_ROUTE_CAPACITY
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_prov_configure_easy(af_prov_exchange *x) -> af_status
;
; Every option that matters is set explicitly, including the ones libcurl would
; default the way we want. A security property that depends on a default is a
; property of a libcurl version rather than of AsmFlow.
; ---------------------------------------------------------------------------
        global af_prov_configure_easy
af_prov_configure_easy:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, [rbx + PX_EASY]
        test    r12, r12
        jz      .invalid
        mov     r13, [rbx + PX_PROVIDER]
        test    r13, r13
        jz      .invalid

        lea     rdi, [rbx + PX_URL]
        call    af_buf_data
        test    rax, rax
        jz      .invalid
        mov     rdi, r12
        mov     rsi, rax
        call    af_curl_set_url
        test    eax, eax
        jnz     .curl_failed

        mov     rdi, r12
        call    af_prov_protocols
        mov     rsi, rax
        mov     rdi, r12
        call    af_curl_set_protocols
        test    eax, eax
        jnz     .curl_failed

        ; A gateway that followed redirects would let a provider point it at a
        ; host the operator never configured, carrying the provider credential.
        mov     rdi, r12
        xor     esi, esi
        call    af_curl_set_follow_location
        test    eax, eax
        jnz     .curl_failed

        ; TLS verification is on unless the operator explicitly allowed
        ; insecure private HTTP for this provider, and even then only the
        ; scheme changes: `allow_insecure_private_http` permits plain HTTP to a
        ; private address, it does not permit an unverified certificate.
        mov     rdi, r12
        mov     esi, 1
        mov     edx, 1
        call    af_curl_set_tls_verify
        test    eax, eax
        jnz     .curl_failed

        mov     rdi, r12
        mov     esi, 1
        call    af_curl_set_nosignal
        test    eax, eax
        jnz     .curl_failed

        ; No Accept-Encoding at all. AsmFlow forwards upstream bytes unchanged,
        ; and asking for a compressed body would mean libcurl decompressing it
        ; into a shape the byte-count assertions no longer describe.
        mov     rdi, r12
        xor     esi, esi
        call    af_curl_set_accept_encoding
        test    eax, eax
        jnz     .curl_failed

        lea     rdi, [rbx + PX_BODY]
        call    af_buf_len
        mov     r14, rax
        lea     rdi, [rbx + PX_BODY]
        call    af_buf_data
        mov     rdi, r12
        mov     rsi, rax
        mov     rdx, r14
        call    af_curl_set_post
        test    eax, eax
        jnz     .curl_failed

        mov     rdi, r12
        mov     rsi, [rbx + PX_SLIST]
        call    af_curl_set_headers
        test    eax, eax
        jnz     .curl_failed

        mov     rdi, r12
        mov     rsi, [r13 + PRV_TIMEOUTS + TMO_CONNECT_MS]
        call    af_curl_set_connect_timeout_ms
        test    eax, eax
        jnz     .curl_failed

        mov     rdi, r12
        mov     rsi, [r13 + PRV_TIMEOUTS + TMO_REQUEST_MS]
        call    af_curl_set_timeout_ms
        test    eax, eax
        jnz     .curl_failed

        ; `idle_stream_ms` becomes libcurl's stall detector: fewer than one
        ; byte per second for that many seconds ends the transfer. A stream
        ; that is open but silent is the failure this exists to catch, and a
        ; total timeout cannot express it.
        mov     rax, [r13 + PRV_TIMEOUTS + TMO_IDLE_MS]
        xor     edx, edx
        mov     rcx, 1000
        div     rcx
        test    rax, rax
        jnz     .idle_ready
        mov     eax, 1
.idle_ready:
        mov     rdi, r12
        mov     esi, 1
        mov     rdx, rax
        call    af_curl_set_low_speed
        test    eax, eax
        jnz     .curl_failed
        AF_LEAVE_OK

.curl_failed:
        AF_LEAVE_ERR AF_E_UP_CONNECT_FAILED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_prov_on_header(void *user, const char *at, u64 len) -> i64
;
; libcurl's header callback: once per header line, including the status line
; and the empty line that ends the block. Returning anything other than `len`
; fails the transfer.
; ---------------------------------------------------------------------------
        global af_prov_on_header
af_prov_on_header:
        AF_ENTER 32
        test    rdi, rdi
        jz      .abort
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     [rsp], r13

        cmp     qword [rbx + PX_STATE], AF_PX_ACTIVE
        jne     .abort
        cmp     qword [rbx + PX_CONN], 0
        je      .abort

        ; The empty line ends the header block. Two bytes for CRLF, one for a
        ; bare LF; anything shorter is not a line at all.
        cmp     r13, 2
        ja      .not_blank
        test    r13, r13
        jz      .accept
        movzx   eax, byte [r12]
        cmp     al, 13
        je      .blank
        cmp     al, 10
        je      .blank
        jmp     .not_blank

.blank:
        mov     rdi, rbx
        call    af_prov_headers_complete
        test    rax, rax
        js      .abort
        jmp     .accept

.not_blank:
        ; A status line begins a response; a second one means libcurl is
        ; showing us an interim 1xx block, and what came before it describes a
        ; response that no longer applies.
        cmp     r13, 5
        jb      .maybe_ctype
        mov     rdi, r12
        lea     rsi, [s_http_prefix]
        mov     rdx, 5
        call    af_mem_eq_ci
        test    rax, rax
        jz      .maybe_ctype
        lea     rdi, [rbx + PX_CTYPE]
        call    af_buf_clear
        and     qword [rbx + PX_FLAGS], ~AF_PX_F_UPSTREAM_SSE
        or      qword [rbx + PX_FLAGS], AF_PX_F_STATUS_SEEN
        jmp     .accept

.maybe_ctype:
        cmp     r13, CONTENT_TYPE_LEN + 1
        jbe     .accept
        mov     rdi, r12
        lea     rsi, [h_content_type]
        mov     rdx, CONTENT_TYPE_LEN
        call    af_mem_eq_ci
        test    rax, rax
        jz      .accept
        cmp     byte [r12 + CONTENT_TYPE_LEN], ':'
        jne     .accept

        ; The value, with leading spaces and the trailing CRLF removed.
        lea     r14, [r12 + CONTENT_TYPE_LEN + 1]
        mov     r15, r13
        sub     r15, CONTENT_TYPE_LEN + 1
.trim_left:
        test    r15, r15
        jz      .ctype_ready
        movzx   eax, byte [r14]
        cmp     al, ' '
        je      .eat_left
        cmp     al, 9
        jne     .trim_right
.eat_left:
        inc     r14
        dec     r15
        jmp     .trim_left
.trim_right:
        test    r15, r15
        jz      .ctype_ready
        movzx   eax, byte [r14 + r15 - 1]
        cmp     al, 13
        je      .eat_right
        cmp     al, 10
        je      .eat_right
        cmp     al, ' '
        je      .eat_right
        cmp     al, 9
        jne     .ctype_ready
.eat_right:
        dec     r15
        jmp     .trim_right
.ctype_ready:
        lea     rdi, [rbx + PX_CTYPE]
        call    af_buf_clear
        lea     rdi, [rbx + PX_CTYPE]
        mov     rsi, r14
        mov     rdx, r15
        call    af_buf_append

.accept:
        mov     rax, [rsp]
        AF_LEAVE
.abort:
        mov     rax, AF_PROV_TAKE_ABORT
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_headers_complete(af_prov_exchange *x) -> af_status
;
; The upstream response's shape is now known, so the shape of ours is decided.
; Only a streamed success writes a head here; everything else waits, because
; everything else can still change its mind about the status it will send.
; ---------------------------------------------------------------------------
        global af_prov_headers_complete
af_prov_headers_complete:
        AF_ENTER 48
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, [rbx + PX_CONN]
        test    r12, r12
        jz      .invalid

        mov     rdi, [rbx + PX_EASY]
        call    af_curl_response_code
        mov     [rbx + PX_STATUS], rax

        ; Is the upstream actually streaming? The media type decides, not what
        ; the client asked for: a provider that answered a stream request with
        ; a plain JSON body is answering a different question, and forwarding
        ; it as events would invent framing that was never sent.
        lea     rdi, [rbx + PX_CTYPE]
        call    af_buf_len
        cmp     rax, EVENT_STREAM_LEN
        jb      .not_sse
        mov     [rsp], rax
        lea     rdi, [rbx + PX_CTYPE]
        call    af_buf_data
        test    rax, rax
        jz      .not_sse
        mov     rdi, rax
        lea     rsi, [s_event_stream]
        mov     rdx, EVENT_STREAM_LEN
        call    af_mem_eq_ci
        test    rax, rax
        jz      .not_sse
        or      qword [rbx + PX_FLAGS], AF_PX_F_UPSTREAM_SSE
.not_sse:

        test    qword [rbx + PX_FLAGS], AF_PX_F_STREAM
        jz      .wait
        test    qword [rbx + PX_FLAGS], AF_PX_F_UPSTREAM_SSE
        jz      .wait
        mov     rax, [rbx + PX_STATUS]
        cmp     rax, 200
        jb      .wait
        cmp     rax, 300
        jae     .wait

        ; From here the response is committed: the status is on the wire and
        ; no other target can be tried (docs/API_CONTRACT.md 8).
        lea     rdi, [r12 + HC_OUTBOX]
        mov     rsi, [rbx + PX_STATUS]
        xor     edx, edx
        lea     rcx, [r12 + HC_REQUEST_ID]
        mov     r8, 1
        mov     r9, AF_HEAD_SSE | AF_HEAD_CHUNKED | AF_HEAD_NO_STORE
        call    af_http_write_head
        test    rax, rax
        js      .done
        or      qword [rbx + PX_FLAGS], AF_PX_F_HEAD_SENT | AF_PX_F_COMMITTED
        or      qword [r12 + HC_FLAGS], HC_F_RESPONDED
        mov     rdi, r12
        call    af_http_conn_flush
.wait:
        xor     eax, eax
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_prov_on_write(void *user, const char *at, u64 len) -> i64
;
; libcurl's write callback. Returns the byte count it consumed, or a sentinel:
; AF_PROV_TAKE_PAUSE to be re-offered the same bytes later, AF_PROV_TAKE_ABORT
; to end the transfer.
; ---------------------------------------------------------------------------
        global af_prov_on_write
af_prov_on_write:
        AF_ENTER 32
        test    rdi, rdi
        jz      .abort
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     [rsp], r13

        cmp     qword [rbx + PX_STATE], AF_PX_ACTIVE
        jne     .abort
        mov     r14, [rbx + PX_CONN]
        test    r14, r14
        jz      .abort                          ; the client is gone

        ; Backpressure, decided before a byte is taken. libcurl re-offers what
        ; a paused callback did not consume, so consuming and then pausing
        ; would deliver the same bytes twice.
        test    qword [rbx + PX_FLAGS], AF_PX_F_HEAD_SENT
        jz      .no_backpressure
        lea     rdi, [r14 + HC_OUTBOX]
        call    af_buf_len
        sub     rax, [r14 + HC_OUT_CURSOR]
        jc      .no_backpressure
        cmp     rax, AF_PROV_PAUSE_HIGH
        jb      .no_backpressure
        or      qword [rbx + PX_FLAGS], AF_PX_F_PAUSED
        mov     rax, AF_PROV_TAKE_PAUSE
        AF_LEAVE
.no_backpressure:

        add     [rbx + PX_BODY_BYTES], r13

        test    qword [rbx + PX_FLAGS], AF_PX_F_HEAD_SENT
        jz      .accumulate

        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        call    af_prov_sse_feed
        test    rax, rax
        js      .abort
        mov     rax, [rsp]
        AF_LEAVE

.accumulate:
        ; Not streaming to the client: hold the body until the status and the
        ; length are both known. The ceiling is the buffer's own maximum, so
        ; the refusal happens here rather than after the allocation.
        lea     rdi, [rbx + PX_RESPONSE]
        mov     rsi, r12
        mov     rdx, r13
        call    af_buf_append
        test    rax, rax
        js      .overflow
        mov     rax, [rsp]
        AF_LEAVE

.overflow:
        or      qword [rbx + PX_FLAGS], AF_PX_F_OVERFLOW
.abort:
        mov     rax, AF_PROV_TAKE_ABORT
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_emit_chunk(af_prov_exchange *x, const char *p, u64 n) -> af_status
;
; One chunk of a chunked response: the length in hex, the bytes, and the CRLF
; that closes it. Written straight into the connection's outbox and flushed, so
; an event reaches the client as soon as it is complete.
; ---------------------------------------------------------------------------
        global af_prov_emit_chunk
af_prov_emit_chunk:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rdx, rdx
        jz      .ok                             ; an empty chunk would end the body
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, [rbx + PX_CONN]
        test    r14, r14
        jz      .cancelled

        lea     rdi, [r14 + HC_OUTBOX]
        mov     rsi, r13
        call    af_prov_append_hex
        test    rax, rax
        js      .done
        lea     rdi, [r14 + HC_OUTBOX]
        lea     rsi, [s_crlf]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
        lea     rdi, [r14 + HC_OUTBOX]
        mov     rsi, r12
        mov     rdx, r13
        call    af_buf_append
        test    rax, rax
        js      .done
        lea     rdi, [r14 + HC_OUTBOX]
        lea     rsi, [s_crlf]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done

        mov     rdi, r14
        call    af_http_conn_flush
.ok:
        xor     eax, eax
.done:
        AF_LEAVE
.cancelled:
        AF_LEAVE_ERR AF_E_UP_CANCELLED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_prov_append_hex(af_buffer *b, u64 value) -> af_status
;
; Lower-case hex with no leading zeros, which is what a chunk size is. Zero is
; written as a single "0" rather than as nothing.
; ---------------------------------------------------------------------------
        global af_prov_append_hex
af_prov_append_hex:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi

        lea     r13, [rsp]                      ; digits, most significant last
        xor     r14, r14
        test    r12, r12
        jnz     .convert
        mov     byte [r13], '0'
        mov     r14, 1
        jmp     .emit
.convert:
        lea     r15, [hex_digits]
.convert_loop:
        test    r12, r12
        jz      .emit
        mov     rax, r12
        and     rax, 15
        movzx   eax, byte [r15 + rax]
        mov     [r13 + r14], al
        inc     r14
        shr     r12, 4
        jmp     .convert_loop
.emit:
        ; The digits came out least significant first, so they go back in
        ; reverse.
        mov     rcx, r14
.emit_loop:
        test    rcx, rcx
        jz      .ok
        dec     rcx
        mov     [rsp + 24], rcx
        movzx   esi, byte [r13 + rcx]
        mov     rdi, rbx
        call    af_buf_append_byte
        test    rax, rax
        js      .done
        mov     rcx, [rsp + 24]
        jmp     .emit_loop
.ok:
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_conn_drained(af_http_conn *c) -> void
;
; The client's outbox has emptied enough to take more. Called from the flush
; path rather than polled, so a resumed transfer starts again on the same turn
; the space appeared.
; ---------------------------------------------------------------------------
        global af_prov_conn_drained
af_prov_conn_drained:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, [rbx + HC_EXCHANGE]
        test    r12, r12
        jz      .done
        test    qword [r12 + PX_FLAGS], AF_PX_F_PAUSED
        jz      .done

        lea     rdi, [rbx + HC_OUTBOX]
        call    af_buf_len
        sub     rax, [rbx + HC_OUT_CURSOR]
        jc      .resume
        cmp     rax, AF_PROV_PAUSE_LOW
        jae     .done
.resume:
        and     qword [r12 + PX_FLAGS], ~AF_PX_F_PAUSED
        mov     rdi, [r12 + PX_EASY]
        test    rdi, rdi
        jz      .done
        xor     esi, esi
        call    af_curl_pause
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_conn_detach(af_http_conn *c) -> void
;
; The client is going away, so the transfer is cancelled — now, not when
; libcurl next happens to ask.
;
; Refusing the next write callback would be enough for a stream, because a
; stream produces write callbacks. It is not enough for anything else: a
; request whose provider has accepted it and gone quiet produces no callbacks
; at all, so a cancellation expressed only as a flag would sit there until the
; provider's own timeout expired — with the client long gone and the tokens
; still being generated and billed (HARNESS.md M6 DoD 5). Removing the handle
; from the multi and cleaning it up closes the upstream connection immediately,
; which is what a cancellation means.
;
; This runs from the loop, never from inside a libcurl callback: the callers
; are connection release and the hangup path, both of which are reached from
; the event dispatcher.
; ---------------------------------------------------------------------------
        global af_prov_conn_detach
af_prov_conn_detach:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, [rbx + HC_EXCHANGE]
        mov     qword [rbx + HC_EXCHANGE], 0
        and     qword [rbx + HC_FLAGS], ~HC_F_UPSTREAM
        test    r12, r12
        jz      .done
        mov     qword [r12 + PX_CONN], 0
        or      qword [r12 + PX_FLAGS], AF_PX_F_CANCELLED
        mov     rax, [r12 + PX_ENGINE]
        test    rax, rax
        jz      .dispose
        inc     qword [rax + PE_CANCELLED]
.dispose:
        mov     rdi, r12
        call    af_prov_exchange_dispose
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_exchange_finish(af_prov_exchange *x, i64 curl_result) -> void
;
; The transfer has ended. Everything the client is going to be told is decided
; here, and the slot is returned before this function leaves.
; ---------------------------------------------------------------------------
        global af_prov_exchange_finish
af_prov_exchange_finish:
        AF_ENTER 64
;   [rsp +  0]  curl result   [rsp + 16]  the connection
;   [rsp +  8]  af_status     [rsp + 24]  AF_HERR_* to answer with
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     qword [rsp + 16], 0
        cmp     qword [rbx + PX_STATE], AF_PX_ACTIVE
        jne     .dispose
        mov     qword [rbx + PX_STATE], AF_PX_FINISHING

        mov     rdi, [rbx + PX_EASY]
        call    af_curl_connect_time_us
        mov     rdi, [rsp]
        mov     rsi, rax
        call    af_prov_classify_curl
        mov     [rsp + 32], rax                 ; the transport verdict
        mov     [rsp + 8], rax
        test    rax, rax
        js      .have_status

        ; The transport succeeded, so there IS a response. Its status is
        ; classified for the record and for the failure counter, but it does
        ; not decide whether the client sees it: an upstream error body says
        ; more than a generic one, and whether this particular body can be
        ; relayed is af_prov_deliver_buffered's judgement to make
        ; (docs/API_CONTRACT.md 7). Turning every non-2xx into AsmFlow's own
        ; 502 here would throw away the provider's explanation.
        mov     rdi, [rbx + PX_STATUS]
        call    af_prov_classify_status
        mov     [rsp + 8], rax
.have_status:
        mov     rax, [rsp + 8]
        mov     [rbx + PX_RESULT], rax

        mov     r12, [rbx + PX_CONN]
        mov     [rsp + 16], r12
        test    r12, r12
        jz      .dispose                        ; nobody left to answer

        cmp     qword [rsp + 8], 0
        jge     .counted
        mov     rax, [rbx + PX_ENGINE]
        test    rax, rax
        jz      .counted
        inc     qword [rax + PE_FAILED]
.counted:

        ; A committed stream cannot change its mind. Whatever happened, the
        ; client already has a 200 and some events; the honest ending is a
        ; correct chunked terminator, and the failure is recorded rather than
        ; announced (docs/API_CONTRACT.md 8).
        test    qword [rbx + PX_FLAGS], AF_PX_F_HEAD_SENT
        jnz     .finish_stream

        ; Only a transport failure leaves nothing to deliver.
        cmp     qword [rsp + 32], 0
        jl      .failed
        mov     rdi, rbx
        call    af_prov_deliver_buffered
        jmp     .detach

.failed:
        mov     rdi, [rsp + 8]
        call    af_prov_error_id
        mov     [rsp + 24], rax
        mov     rdi, r12
        mov     rsi, [rsp + 24]
        call    af_http_send_error
        mov     rdi, r12
        call    af_http_conn_flush
        jmp     .detach

.finish_stream:
        mov     rdi, rbx
        call    af_prov_sse_finish
        lea     rdi, [r12 + HC_OUTBOX]
        lea     rsi, [s_last_chunk]
        call    af_buf_append_cstr
        or      qword [rbx + PX_FLAGS], AF_PX_F_TRAILER_SENT
        mov     rdi, r12
        call    af_http_conn_flush

.detach:
        mov     r12, [rsp + 16]
        mov     qword [r12 + HC_EXCHANGE], 0
        and     qword [r12 + HC_FLAGS], ~HC_F_UPSTREAM
        mov     qword [rbx + PX_CONN], 0

.dispose:
        mov     rdi, rbx
        call    af_prov_exchange_dispose

        ; A pipelined request that arrived while the upstream call was in
        ; flight has been sitting in the inbox unparsed. Now that the
        ; connection is answerable again, it is fed.
        mov     rdi, [rsp + 16]
        test    rdi, rdi
        jz      .done
        call    af_http_conn_resume
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_deliver_buffered(af_prov_exchange *x) -> af_status
;
; A non-streamed upstream response, forwarded to the client.
;
; A 2xx body is passed through unchanged. A non-2xx body is passed through too,
; but only when it parses as a JSON object within the configured limits: an
; upstream error message is more useful to a caller than a generic one, and a
; body that is not JSON is not something to relay under a JSON content type.
; ---------------------------------------------------------------------------
        global af_prov_deliver_buffered
af_prov_deliver_buffered:
        AF_ENTER 128
;   [rsp +  0]  body pointer   [rsp + 16]  connection
;   [rsp +  8]  body length    [rsp + 24]  af_json_limits (32)
;   [rsp + 64]  af_json_doc (32)
%define DLV_LIMITS 24
%define DLV_DOC    64
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, [rbx + PX_CONN]
        test    r12, r12
        jz      .invalid
        mov     [rsp + 16], r12

        lea     rdi, [rbx + PX_RESPONSE]
        call    af_buf_len
        mov     [rsp + 8], rax
        lea     rdi, [rbx + PX_RESPONSE]
        call    af_buf_data
        mov     [rsp], rax

        mov     rax, [rbx + PX_STATUS]
        cmp     rax, 200
        jb      .must_validate
        cmp     rax, 300
        jb      .pass_through
.must_validate:
        cmp     qword [rsp + 8], 0
        je      .not_forwardable
        cmp     qword [rsp], 0
        je      .not_forwardable

        mov     rax, [rbx + PX_CONFIG]
        test    rax, rax
        jz      .not_forwardable
        mov     rcx, [rsp + 8]
        mov     [rsp + DLV_LIMITS + AF_JSONLIM_MAX_BYTES], rcx
        mov     rcx, [rax + CFG_LIM_JSON_DEPTH]
        mov     [rsp + DLV_LIMITS + AF_JSONLIM_MAX_DEPTH], rcx
        mov     rcx, [rax + CFG_LIM_JSON_STR_MAX]
        mov     [rsp + DLV_LIMITS + AF_JSONLIM_MAX_STRING], rcx
        mov     qword [rsp + DLV_LIMITS + AF_JSONLIM_MAX_ELEMS], 100000

        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [rsp + DLV_LIMITS]
        lea     rcx, [rsp + DLV_DOC]
        call    af_json_parse
        test    rax, rax
        js      .not_forwardable
        lea     rdi, [rsp + DLV_DOC]
        call    af_json_doc_root
        mov     rdi, rax
        call    af_json_type
        mov     r13, rax
        lea     rdi, [rsp + DLV_DOC]
        call    af_json_doc_free
        cmp     r13, AF_JSON_OBJECT
        jne     .not_forwardable

.pass_through:
        mov     r12, [rsp + 16]
        lea     rdi, [r12 + HC_RESPONSE]
        call    af_buf_clear
        cmp     qword [rsp + 8], 0
        je      .commit
        lea     rdi, [r12 + HC_RESPONSE]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_buf_append
        test    rax, rax
        js      .not_forwardable
.commit:
        mov     rdi, r12
        mov     rsi, [rbx + PX_STATUS]
        xor     edx, edx
        call    af_http_commit
        or      qword [rbx + PX_FLAGS], AF_PX_F_COMMITTED
        mov     rdi, r12
        call    af_http_conn_flush
        AF_LEAVE_OK

.not_forwardable:
        mov     rdi, [rsp + 16]
        mov     rsi, AF_HERR_UPSTREAM_INVALID
        call    af_http_send_error
        mov     rdi, [rsp + 16]
        call    af_http_conn_flush
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_prov_exchange_abandon(af_prov_exchange *x) -> void
;
; Shutdown, not completion. The transfer is removed from the multi handle and
; every resource released, without producing a response: whoever is shutting
; the daemon down is closing the client's connection too.
; ---------------------------------------------------------------------------
        global af_prov_exchange_abandon
af_prov_exchange_abandon:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, [rbx + PX_CONN]
        test    r12, r12
        jz      .dispose
        mov     qword [r12 + HC_EXCHANGE], 0
        and     qword [r12 + HC_FLAGS], ~HC_F_UPSTREAM
        mov     qword [rbx + PX_CONN], 0
.dispose:
        mov     rdi, rbx
        call    af_prov_exchange_dispose
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_exchange_dispose(af_prov_exchange *x) -> void
;
; Every resource an exchange can hold, released in the one order that is safe:
; out of the multi handle, then the easy handle, then the header list, then the
; buffers, then the configuration reference, then the slot. Freeing an easy
; handle still registered with a multi handle is undefined behaviour, and the
; header list is read by the transfer for as long as the handle exists.
; ---------------------------------------------------------------------------
        global af_prov_exchange_dispose
af_prov_exchange_dispose:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        cmp     qword [rbx + PX_STATE], AF_PX_FREE
        je      .done
        mov     r12, [rbx + PX_ENGINE]

        test    qword [rbx + PX_FLAGS], AF_PX_F_ADDED
        jz      .not_added
        test    r12, r12
        jz      .not_added
        mov     rdi, [r12 + PE_MULTI]
        test    rdi, rdi
        jz      .not_added
        mov     rsi, [rbx + PX_EASY]
        call    af_curl_multi_remove
        and     qword [rbx + PX_FLAGS], ~AF_PX_F_ADDED
.not_added:

        mov     rdi, [rbx + PX_EASY]
        test    rdi, rdi
        jz      .no_easy
        call    af_curl_easy_free
        mov     qword [rbx + PX_EASY], 0
.no_easy:

        mov     rdi, [rbx + PX_SLIST]
        test    rdi, rdi
        jz      .no_slist
        call    af_curl_slist_free
        mov     qword [rbx + PX_SLIST], 0
.no_slist:

        lea     rdi, [rbx + PX_URL]
        call    af_buf_free
        lea     rdi, [rbx + PX_BODY]
        call    af_buf_free
        lea     rdi, [rbx + PX_RESPONSE]
        call    af_buf_free
        lea     rdi, [rbx + PX_CARRY]
        call    af_buf_free
        lea     rdi, [rbx + PX_CTYPE]
        call    af_buf_free

        mov     rdi, [rbx + PX_CONFIG]
        test    rdi, rdi
        jz      .no_config
        call    af_config_release
        mov     qword [rbx + PX_CONFIG], 0
.no_config:

        mov     qword [rbx + PX_STATE], AF_PX_DONE
        mov     rdi, rbx
        call    af_prov_slot_release
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; Accessors for the tests.
; ---------------------------------------------------------------------------
        global af_prov_exchange_flags
af_prov_exchange_flags:
        test    rdi, rdi
        jz      .zero
        mov     rax, [rdi + PX_FLAGS]
        ret
.zero:
        xor     eax, eax
        ret

        global af_prov_exchange_status
af_prov_exchange_status:
        test    rdi, rdi
        jz      .zero
        mov     rax, [rdi + PX_STATUS]
        ret
.zero:
        xor     eax, eax
        ret

        section .rodata
s_http_prefix: db "HTTP/", 0
