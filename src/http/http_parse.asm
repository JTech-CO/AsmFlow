; AsmFlow — the llhttp callback surface and the request policy applied to it.
;
; llhttp reports syntax; everything that follows is AsmFlow's (ADR 0006). The
; callbacks here accumulate the request target, the header currently being read,
; and the body, and enforce the rules a parser generator has no opinion about:
; what a header may say, how large the pieces may be, and which framing
; combinations are refusable.
;
; Three properties are load-bearing.
;
; Nothing is captured by pointer. llhttp may deliver one header value in as many
; callbacks as there are TCP segments, and the bytes it points at belong to the
; read buffer, which is consumed as soon as the parse returns. Every span is
; therefore appended into a bounded buffer. This is also what makes the
; one-byte-fragment corpus in HARNESS.md M5 DoD 6 produce the same result as the
; whole-request one: there is no code path that assumes a token arrived at once.
;
; The framing rules are AsmFlow's own, not the library's. llhttp with leniency
; off already refuses several of these, but a request-smuggling defence that
; depends on a library's default is a defence that a version bump can remove.
; Duplicate Content-Length, Content-Length together with Transfer-Encoding, and
; a transfer coding other than chunked are each rejected here, and the smuggling
; corpus proves it against this code rather than against llhttp.
;
; The first refusal wins and the parse stops. A message that has already been
; judged is not parsed further, so a body arriving after a rejected header
; section cannot change the answer.

        bits 64
        default rel

%include "asmflow.inc"
%include "http.inc"

        extern af_buf_append
        extern af_buf_clear_secure
        extern af_buf_data
        extern af_buf_len
        extern af_buf_append_byte

        extern af_mem_eq
        extern af_mem_eq_ci
        extern af_cstr_len

        extern af_llhttp_method
        extern af_llhttp_http_major
        extern af_llhttp_http_minor
        extern af_llhttp_should_keep_alive
        extern af_llhttp_upgrade

        extern af_http_dispatch

        section .rodata

h_content_length:   db "content-length", 0
h_transfer_encoding: db "transfer-encoding", 0
h_content_type:     db "content-type", 0
v_chunked:          db "chunked", 0
v_application_json: db "application/json", 0

p_healthz:   db "/healthz", 0
p_readyz:    db "/readyz", 0
p_models:    db "/v1/models", 0
p_responses: db "/v1/responses", 0
p_chat:      db "/v1/chat/completions", 0

        section .data.rel.ro progbits align=8

; The whole routing table. An unlisted path is a 404; there is no prefix match
; and no fallthrough, because a gateway that serves what it was not configured
; to serve is a gateway with an attack surface nobody wrote down.
endpoint_table:
        dq p_healthz,   8,  AF_EP_HEALTHZ
        dq p_readyz,    7,  AF_EP_READYZ
        dq p_models,    10, AF_EP_MODELS
        dq p_responses, 13, AF_EP_RESPONSES
        dq p_chat,      20, AF_EP_CHAT
endpoint_table_end:
%define ENDPOINT_COUNT ((endpoint_table_end - endpoint_table) / 24)

        section .text

; ---------------------------------------------------------------------------
; af_http_fault(af_http_conn *c, u64 error_id) -> void
;
; Records the failure to answer with. The first one wins: once a message has
; been refused, a later rule finding a second problem must not overwrite the
; reason the client is about to be told.
; ---------------------------------------------------------------------------
        global af_http_fault
af_http_fault:
        test    rdi, rdi
        jz      .done
        test    qword [rdi + HC_FLAGS], HC_F_FAULT
        jnz     .done
        or      qword [rdi + HC_FLAGS], HC_F_FAULT
        mov     [rdi + HC_FAULT], rsi
.done:
        ret

; ---------------------------------------------------------------------------
; af_http_has_fault(af_http_conn *c) -> i64 (1 = yes)
; ---------------------------------------------------------------------------
        global af_http_has_fault
af_http_has_fault:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        test    qword [rdi + HC_FLAGS], HC_F_FAULT
        jz      .done
        mov     eax, 1
.done:
        ret

; ---------------------------------------------------------------------------
; af_http_resolve_endpoint(const char *target, u64 len) -> u64 (AF_EP_*)
;
; The path is the target up to the first '?'. It is compared as raw bytes: no
; percent-decoding, no '.' or '..' collapsing, no trailing-slash tolerance. A
; gateway that normalises before it matches has to be right about every
; normalisation, and the endpoint list is short enough that exact bytes are the
; simpler contract. `/v1%2Fmodels` is therefore an unknown path, which is the
; answer that cannot surprise anybody.
;
; A target that does not begin with '/' — the absolute form a proxy would see —
; is AF_EP_UNKNOWN. AsmFlow is an origin server for its own endpoints.
; ---------------------------------------------------------------------------
        global af_http_resolve_endpoint
af_http_resolve_endpoint:
        AF_ENTER 32
        xor     eax, eax                        ; AF_EP_UNKNOWN
        test    rdi, rdi
        jz      .done
        test    rsi, rsi
        jz      .done
        mov     rbx, rdi                        ; target
        mov     r12, rsi                        ; length
        cmp     byte [rbx], '/'
        jne     .done

        ; Cut at the query separator.
        xor     rcx, rcx
.scan:
        cmp     rcx, r12
        jae     .scanned
        cmp     byte [rbx + rcx], '?'
        je      .scanned
        inc     rcx
        jmp     .scan
.scanned:
        mov     r13, rcx                        ; path length

        xor     r14, r14
.match:
        cmp     r14, ENDPOINT_COUNT
        jae     .unknown
        lea     rax, [endpoint_table]
        mov     rcx, r14
        imul    rcx, rcx, 24
        add     rax, rcx
        cmp     [rax + 8], r13
        jne     .next
        mov     r15, rax
        mov     rdi, rbx
        mov     rsi, [rax]
        mov     rdx, r13
        call    af_mem_eq
        test    rax, rax
        jnz     .hit
.next:
        inc     r14
        jmp     .match
.hit:
        mov     rax, [r15 + 16]
        AF_LEAVE
.unknown:
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_parse_u64(const char *s, u64 len, u64 *out) -> af_status
;
; Digits and nothing else. A Content-Length of "12 ", "+12", "0x0c", or "12\r"
; is not a number here; RFC 9110 allows exactly DIGIT, and everything a lenient
; reading would accept is a way for two intermediaries to disagree about where
; a message ends.
; ---------------------------------------------------------------------------
        global af_http_parse_u64
af_http_parse_u64:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        cmp     rsi, 20                         ; no decimal u64 is longer
        ja      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        xor     r14, r14                        ; accumulator
        xor     r15, r15                        ; cursor
.loop:
        cmp     r15, r12
        jae     .parsed
        movzx   ecx, byte [rbx + r15]
        sub     ecx, '0'
        cmp     ecx, 9
        ja      .invalid
        ; A full-width multiply, so an overflow is a fact reported by the
        ; hardware rather than a bound this code has to get right.
        mov     rax, r14
        mov     rsi, 10
        mul     rsi                             ; rdx:rax = accumulator * 10
        test    rdx, rdx
        jnz     .invalid
        add     rax, rcx
        jc      .invalid
        mov     r14, rax
        inc     r15
        jmp     .loop
.parsed:
        mov     [r13], r14
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_http_buffer_is_ci(af_buffer *b, const char *token) -> i64 (1 = equal)
;
; Header names are case-insensitive (RFC 9110 5.1), and so are the two header
; values compared this way: the transfer coding and the media type.
;
; These take the buffer rather than the connection so a caller has to say which
; buffer it means. The alternative — a helper that always reads "the current
; header value" — is how a media-type check ends up examining whichever header
; happened to arrive last.
; ---------------------------------------------------------------------------
        global af_http_buffer_is_ci
af_http_buffer_is_ci:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, r12
        call    af_cstr_len
        mov     r13, rax
        mov     rdi, rbx
        call    af_buf_len
        cmp     rax, r13
        jne     .no
        mov     rdi, rbx
        call    af_buf_data
        test    rax, rax
        jz      .no
        mov     rdi, rax
        mov     rsi, r12
        mov     rdx, r13
        call    af_mem_eq_ci
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_buffer_starts_ci(af_buffer *b, const char *prefix) -> i64
;
; For a value that may carry parameters: `application/json` and
; `application/json; charset=utf-8` are the same media type.
; ---------------------------------------------------------------------------
        global af_http_buffer_starts_ci
af_http_buffer_starts_ci:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, r12
        call    af_cstr_len
        mov     r13, rax
        mov     rdi, rbx
        call    af_buf_len
        cmp     rax, r13
        jb      .no
        mov     rdi, rbx
        call    af_buf_data
        test    rax, rax
        jz      .no
        mov     rdi, rax
        mov     rsi, r12
        mov     rdx, r13
        call    af_mem_eq_ci
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_header_is(af_http_conn *c, const char *lowercase_name) -> i64
; ---------------------------------------------------------------------------
        global af_http_header_is
af_http_header_is:
        AF_ENTER 0
        lea     rdi, [rdi + HC_NAME]
        call    af_http_buffer_is_ci
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_ctype_is(af_http_conn *c, const char *media_type) -> i64
;
; The stored Content-Type, not whichever header was read most recently.
; ---------------------------------------------------------------------------
        global af_http_ctype_is
af_http_ctype_is:
        AF_ENTER 0
        lea     rdi, [rdi + HC_CTYPE]
        call    af_http_buffer_starts_ci
        AF_LEAVE

; ===========================================================================
; The llhttp callbacks. Each returns 0 to continue or -1 to stop the parse.
; A -1 always follows a recorded fault, so the connection knows what to answer.
; ===========================================================================

; ---------------------------------------------------------------------------
; af_http_cb_message_begin(af_http_conn *c) -> int
; ---------------------------------------------------------------------------
        global af_http_cb_message_begin
af_http_cb_message_begin:
        AF_ENTER 0
        mov     rbx, rdi
        mov     rdi, rbx
        call    af_http_reset_message
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_reset_message(af_http_conn *c) -> void
;
; Clears everything scoped to one message and keeps everything scoped to the
; connection. Buffers are cleared rather than freed, so a keep-alive client does
; not make the heap churn once per request.
; ---------------------------------------------------------------------------
        global af_http_reset_message
af_http_reset_message:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi

        lea     rdi, [rbx + HC_TARGET]
        call    af_buf_clear_secure
        lea     rdi, [rbx + HC_NAME]
        call    af_buf_clear_secure
        lea     rdi, [rbx + HC_VALUE]
        call    af_buf_clear_secure
        lea     rdi, [rbx + HC_BODY]
        call    af_buf_clear_secure
        lea     rdi, [rbx + HC_AUTH]
        call    af_buf_clear_secure
        lea     rdi, [rbx + HC_CTYPE]
        call    af_buf_clear_secure

        mov     qword [rbx + HC_METHOD], 0
        mov     qword [rbx + HC_ENDPOINT], AF_EP_UNKNOWN
        mov     qword [rbx + HC_HEADER_BYTES], 0
        mov     qword [rbx + HC_BODY_BYTES], 0
        mov     qword [rbx + HC_CONTENT_LENGTH], -1
        mov     qword [rbx + HC_FAULT], 0

        ; Keep only what belongs to the connection rather than the message.
        mov     rax, [rbx + HC_FLAGS]
        and     rax, HC_F_CLOSING | HC_F_BUFFERS_READY
        mov     [rbx + HC_FLAGS], rax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_cb_url(af_http_conn *c, const char *at, u64 len) -> int
; ---------------------------------------------------------------------------
        global af_http_cb_url
af_http_cb_url:
        AF_ENTER 16
        mov     rbx, rdi
        lea     rdi, [rbx + HC_TARGET]
        call    af_buf_append
        test    rax, rax
        js      .too_large
        xor     eax, eax
        AF_LEAVE
.too_large:
        mov     rdi, rbx
        mov     rsi, AF_HERR_HEADERS_TOO_LARGE
        call    af_http_fault
        mov     eax, -1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_cb_header_field(af_http_conn *c, const char *at, u64 len) -> int
;
; A value already accumulated means llhttp has moved on to the next header, so
; the previous pair is finished. llhttp 9 signals that with
; on_header_value_complete, but relying on a completion callback for the state
; machine's correctness would leave the pair-clearing dependent on a callback
; that a future version might merge; clearing on the next name is idempotent
; and independent of that.
; ---------------------------------------------------------------------------
        global af_http_cb_header_field
af_http_cb_header_field:
        AF_ENTER 32
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     [rsp + 8], rdx

        lea     rdi, [rbx + HC_VALUE]
        call    af_buf_len
        test    rax, rax
        jz      .append
        lea     rdi, [rbx + HC_NAME]
        call    af_buf_clear_secure
        lea     rdi, [rbx + HC_VALUE]
        call    af_buf_clear_secure
.append:
        lea     rdi, [rbx + HC_NAME]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_buf_append
        test    rax, rax
        js      .too_large
        xor     eax, eax
        AF_LEAVE
.too_large:
        mov     rdi, rbx
        mov     rsi, AF_HERR_HEADERS_TOO_LARGE
        call    af_http_fault
        mov     eax, -1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_cb_header_value(af_http_conn *c, const char *at, u64 len) -> int
; ---------------------------------------------------------------------------
        global af_http_cb_header_value
af_http_cb_header_value:
        AF_ENTER 16
        mov     rbx, rdi
        lea     rdi, [rbx + HC_VALUE]
        call    af_buf_append
        test    rax, rax
        js      .too_large
        xor     eax, eax
        AF_LEAVE
.too_large:
        mov     rdi, rbx
        mov     rsi, AF_HERR_HEADERS_TOO_LARGE
        call    af_http_fault
        mov     eax, -1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_cb_header_field_complete(af_http_conn *c) -> int
; ---------------------------------------------------------------------------
        global af_http_cb_header_field_complete
af_http_cb_header_field_complete:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_http_cb_header_value_complete(af_http_conn *c) -> int
;
; One complete header pair. This is where the framing rules are applied.
; ---------------------------------------------------------------------------
        global af_http_cb_header_value_complete
af_http_cb_header_value_complete:
        AF_ENTER 32
        mov     rbx, rdi

        ; --- Content-Length ---
        mov     rdi, rbx
        lea     rsi, [h_content_length]
        call    af_http_header_is
        test    rax, rax
        jz      .not_content_length

        ; A second Content-Length is refused whatever it says. RFC 9110 permits
        ; a repeat with an identical value, but "identical" is exactly the
        ; judgement two intermediaries can make differently, and no legitimate
        ; client sends one.
        test    qword [rbx + HC_FLAGS], HC_F_HAVE_CL
        jnz     .smuggling
        test    qword [rbx + HC_FLAGS], HC_F_HAVE_TE
        jnz     .smuggling

        lea     rdi, [rbx + HC_VALUE]
        call    af_buf_data
        mov     r12, rax
        lea     rdi, [rbx + HC_VALUE]
        call    af_buf_len
        mov     rdi, r12
        mov     rsi, rax
        lea     rdx, [rsp]
        call    af_http_parse_u64
        test    rax, rax
        js      .smuggling
        mov     rax, [rsp]
        mov     [rbx + HC_CONTENT_LENGTH], rax
        or      qword [rbx + HC_FLAGS], HC_F_HAVE_CL
        jmp     .ok

.not_content_length:
        ; --- Transfer-Encoding ---
        mov     rdi, rbx
        lea     rsi, [h_transfer_encoding]
        call    af_http_header_is
        test    rax, rax
        jz      .not_transfer_encoding
        test    qword [rbx + HC_FLAGS], HC_F_HAVE_TE
        jnz     .smuggling
        test    qword [rbx + HC_FLAGS], HC_F_HAVE_CL
        jnz     .smuggling
        ; The only coding AsmFlow implements. Anything else — identity, gzip, a
        ; list ending in chunked — is refused rather than guessed at.
        lea     rdi, [rbx + HC_VALUE]
        lea     rsi, [v_chunked]
        call    af_http_buffer_is_ci
        test    rax, rax
        jz      .smuggling
        or      qword [rbx + HC_FLAGS], HC_F_HAVE_TE
        jmp     .ok

.not_transfer_encoding:
        ; --- Content-Type ---
        mov     rdi, rbx
        lea     rsi, [h_content_type]
        call    af_http_header_is
        test    rax, rax
        jz      .not_content_type
        lea     rdi, [rbx + HC_VALUE]
        call    af_buf_data
        mov     r12, rax
        lea     rdi, [rbx + HC_VALUE]
        call    af_buf_len
        mov     r13, rax
        lea     rdi, [rbx + HC_CTYPE]
        mov     rsi, r12
        mov     rdx, r13
        call    af_buf_append
        test    rax, rax
        js      .too_large
        or      qword [rbx + HC_FLAGS], HC_F_HAVE_CTYPE
        jmp     .ok

.not_content_type:
        ; --- the credential header, whichever one the policy names ---
        mov     r12, [rbx + HC_SERVER]
        test    r12, r12
        jz      .ok
        mov     rsi, [r12 + HS_AUTH_HEADER]
        test    rsi, rsi
        jz      .ok
        mov     rdi, rbx
        call    af_http_header_is
        test    rax, rax
        jz      .ok
        ; A repeated credential header is refused: choosing one of two would be
        ; a decision about which intermediary to believe.
        test    qword [rbx + HC_FLAGS], HC_F_HAVE_AUTH
        jnz     .smuggling
        lea     rdi, [rbx + HC_VALUE]
        call    af_buf_data
        mov     r13, rax
        lea     rdi, [rbx + HC_VALUE]
        call    af_buf_len
        mov     r14, rax
        lea     rdi, [rbx + HC_AUTH]
        mov     rsi, r13
        mov     rdx, r14
        call    af_buf_append
        test    rax, rax
        js      .too_large
        or      qword [rbx + HC_FLAGS], HC_F_HAVE_AUTH

.ok:
        xor     eax, eax
        AF_LEAVE
.smuggling:
        mov     rdi, rbx
        mov     rsi, AF_HERR_SMUGGLING
        call    af_http_fault
        mov     eax, -1
        AF_LEAVE
.too_large:
        mov     rdi, rbx
        mov     rsi, AF_HERR_HEADERS_TOO_LARGE
        call    af_http_fault
        mov     eax, -1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_cb_headers_complete(af_http_conn *c) -> int
;
; The request line and the header section are now known. This is the last point
; at which a request can be refused without having read its body, which is why
; the declared length is checked here rather than after the bytes arrive.
; ---------------------------------------------------------------------------
        global af_http_cb_headers_complete
af_http_cb_headers_complete:
        AF_ENTER 32
        mov     rbx, rdi
        or      qword [rbx + HC_FLAGS], HC_F_HEADERS_DONE

        lea     rdi, [rbx + HC_PARSER]
        call    af_llhttp_method
        movsxd  rax, eax
        mov     [rbx + HC_METHOD], rax

        ; HTTP/1.1 and HTTP/1.0 only. llhttp with strict version handling
        ; already refuses most of the alternatives; this makes the accepted set
        ; AsmFlow's statement rather than the library's.
        lea     rdi, [rbx + HC_PARSER]
        call    af_llhttp_http_major
        cmp     eax, 1
        jne     .bad_version
        lea     rdi, [rbx + HC_PARSER]
        call    af_llhttp_http_minor
        cmp     eax, 1
        ja      .bad_version

        ; An upgrade is not something a JSON gateway offers.
        lea     rdi, [rbx + HC_PARSER]
        call    af_llhttp_upgrade
        test    eax, eax
        jnz     .no_upgrade

        lea     rdi, [rbx + HC_PARSER]
        call    af_llhttp_should_keep_alive
        test    eax, eax
        jz      .no_keep_alive
        or      qword [rbx + HC_FLAGS], HC_F_KEEP_ALIVE
.no_keep_alive:

        lea     rdi, [rbx + HC_TARGET]
        call    af_buf_data
        mov     r12, rax
        lea     rdi, [rbx + HC_TARGET]
        call    af_buf_len
        mov     r13, rax

        ; Origin form only. An absolute-form target is what a proxy is sent, and
        ; honouring one is how a front end that routes by Host and a back end
        ; that routes by URI end up serving two different requests from the same
        ; bytes. It is refused as a malformed request rather than answered as an
        ; unknown path, because the form is the problem, not the path.
        test    r12, r12
        jz      .bad_target
        test    r13, r13
        jz      .bad_target
        cmp     byte [r12], '/'
        jne     .bad_target

        mov     rdi, r12
        mov     rsi, r13
        call    af_http_resolve_endpoint
        mov     [rbx + HC_ENDPOINT], rax

        ; Refuse an oversized body on its declaration rather than on its
        ; arrival. Reading sixty-four megabytes in order to say they were too
        ; many is the denial of service the limit exists to prevent.
        mov     r12, [rbx + HC_SERVER]
        test    r12, r12
        jz      .accepted
        mov     rax, [rbx + HC_CONTENT_LENGTH]
        cmp     rax, 0
        jl      .accepted
        cmp     rax, [r12 + HS_BODY_MAX]
        ja      .body_too_large

.accepted:
        xor     eax, eax
        AF_LEAVE
.bad_target:
        mov     rdi, rbx
        mov     rsi, AF_HERR_MALFORMED
        call    af_http_fault
        mov     eax, -1
        AF_LEAVE
.bad_version:
        mov     rdi, rbx
        mov     rsi, AF_HERR_VERSION
        call    af_http_fault
        mov     eax, -1
        AF_LEAVE
.no_upgrade:
        mov     rdi, rbx
        mov     rsi, AF_HERR_MALFORMED
        call    af_http_fault
        mov     eax, -1
        AF_LEAVE
.body_too_large:
        mov     rdi, rbx
        mov     rsi, AF_HERR_BODY_TOO_LARGE
        call    af_http_fault
        mov     eax, -1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_cb_body(af_http_conn *c, const char *at, u64 len) -> int
;
; The ceiling is applied to what has accumulated, not to what was declared. A
; chunked request declares nothing, so the running total is the only thing there
; is to check — the same reason the control plane's frame ceiling counts bytes
; received rather than bytes framed.
; ---------------------------------------------------------------------------
        global af_http_cb_body
af_http_cb_body:
        AF_ENTER 32
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     [rsp + 8], rdx

        mov     r12, [rbx + HC_SERVER]
        mov     rax, [rbx + HC_BODY_BYTES]
        add     rax, rdx
        jc      .too_large
        test    r12, r12
        jz      .store
        cmp     rax, [r12 + HS_BODY_MAX]
        ja      .too_large
.store:
        mov     [rbx + HC_BODY_BYTES], rax
        lea     rdi, [rbx + HC_BODY]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_buf_append
        test    rax, rax
        js      .too_large
        xor     eax, eax
        AF_LEAVE
.too_large:
        mov     rdi, rbx
        mov     rsi, AF_HERR_BODY_TOO_LARGE
        call    af_http_fault
        mov     eax, -1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_cb_message_complete(af_http_conn *c) -> int
;
; The request is whole. The response is produced here, inside the parse, so a
; pipelined batch answers in order by construction: llhttp reaches the second
; message only after the first one's bytes are already in the outbox.
;
; Returning 0 lets the parse continue into whatever else arrived in the same
; read. It is the outbox ceiling, not a per-message pause, that bounds how much
; a pipelining client can make the daemon hold: an append that does not fit
; fails, which ends the connection the same way any other protocol error does.
; ---------------------------------------------------------------------------
        global af_http_cb_message_complete
af_http_cb_message_complete:
        AF_ENTER 16
        mov     rbx, rdi
        or      qword [rbx + HC_FLAGS], HC_F_MESSAGE_DONE

        mov     rdi, rbx
        call    af_http_dispatch
        test    rax, rax
        js      .failed

        inc     qword [rbx + HC_REQUESTS]
        mov     rax, [rbx + HC_SERVER]
        test    rax, rax
        jz      .no_server
        inc     qword [rax + HS_REQUESTS]
.no_server:

        ; A request the dispatcher handed to a provider has NOT been answered.
        ; Resetting here would clear the flags its answer still depends on —
        ; keep-alive among them — and would unmark the suspension, so the next
        ; pipelined request would be parsed and dispatched before the first one
        ; had produced a byte. Pausing stops the parse with the state intact;
        ; af_http_conn_resume lifts it once the exchange has answered.
        test    qword [rbx + HC_FLAGS], HC_F_UPSTREAM
        jnz     .suspended

        ; A client that asked to close, or a request that was refused, gets the
        ; response it is owed and then the connection ends. Continuing to parse
        ; after that would mean reading a request nobody will answer.
        test    qword [rbx + HC_FLAGS], HC_F_KEEP_ALIVE
        jz      .close_after
        test    qword [rbx + HC_FLAGS], HC_F_FAULT
        jnz     .close_after

        mov     rdi, rbx
        call    af_http_reset_message
        xor     eax, eax
        AF_LEAVE

.suspended:
        mov     eax, AF_HPE_PAUSED
        AF_LEAVE
.close_after:
        or      qword [rbx + HC_FLAGS], HC_F_CLOSING
        mov     eax, -1
        AF_LEAVE
.failed:
        mov     rdi, rbx
        mov     rsi, AF_HERR_INTERNAL
        call    af_http_fault
        or      qword [rbx + HC_FLAGS], HC_F_CLOSING
        mov     eax, -1
        AF_LEAVE
