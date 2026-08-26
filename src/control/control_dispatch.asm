; AsmFlow — control request dispatch and response framing.
;
; One frame in, one frame out. The envelope is fixed by docs/API_CONTRACT.md 9:
;
;   {"id":"ctl-1","ok":true,"result":{...}}
;   {"id":"ctl-1","ok":false,"error":{"code":"...","message":"...","field":"..."}}
;
; The `id` is echoed from the request whenever one could be read, because a
; client correlates by it and a response it cannot match is a response it cannot
; use. A frame so malformed that no id could be recovered gets a null id, which
; is still a valid frame the client can log.
;
; Method handlers write only the `result` value. The envelope around it is
; produced here, once, so no handler can emit a response shaped differently from
; every other.

        bits 64
        default rel

%include "asmflow.inc"
%include "json.inc"
%include "jsonw.inc"
%include "control.inc"
%include "runtime.inc"

        extern af_json_parse
        extern af_json_doc_free
        extern af_json_doc_root
        extern af_json_type
        extern af_json_get_string
        extern af_json_get_object
        extern af_json_member

        extern af_jw_init
        extern af_jw_begin_object
        extern af_jw_end_object
        extern af_jw_key
        extern af_jw_string_n
        extern af_jw_null
        extern af_jw_bool
        extern af_jw_member_string
        extern af_jw_member_bool
        extern af_jw_finish
        extern af_jw_status

        extern af_buf_len
        extern af_ctl_frame_finish
        extern af_ctl_conn_outbox
        extern af_ctl_conn_server
        extern af_ctl_server_frame_max

        extern af_ctl_method_lookup
        extern af_ctl_method_invoke

        extern af_cstr_len
        extern af_mem_eq

        section .rodata
k_id:      db "id", 0
k_method:  db "method", 0
k_params:  db "params", 0
k_ok:      db "ok", 0
k_result:  db "result", 0
k_error:   db "error", 0
k_code:    db "code", 0
k_message: db "message", 0
k_field:   db "field", 0

; Wire codes, in AF_CTLERR_* order.
e_invalid_json:  db "invalid_json", 0
e_frame_large:   db "frame_too_large", 0
e_unknown_method: db "unknown_method", 0
e_invalid_params: db "invalid_params", 0
e_cursor_stale:  db "cursor_stale", 0
e_state:         db "invalid_state", 0
e_internal:      db "internal_error", 0
e_not_found:     db "not_found", 0
e_unconfirmed:   db "confirmation_required", 0
e_unsupported:   db "unsupported_in_this_build", 0

m_invalid_json:  db "The frame is not a JSON object.", 0
m_frame_large:   db "The frame exceeds the configured maximum.", 0
m_unknown_method: db "No such method.", 0
m_invalid_params: db "The parameters do not satisfy the method's contract.", 0
m_cursor_stale:  db "The pagination cursor no longer matches a live snapshot.", 0
m_state:         db "The command is not valid in the current state.", 0
m_internal:      db "The daemon could not complete the command.", 0
m_not_found:     db "No object with that identifier.", 0
m_unconfirmed:   db "This command requires an explicit confirmation.", 0
m_unsupported:   db "The subsystem this method reports on is not wired in this build.", 0

m_no_method:     db "The frame has no 'method' string.", 0
m_bad_utf8:      db "The frame is not valid UTF-8.", 0

        section .data.rel.ro progbits align=8 write
        align 8
        global af_ctl_error_codes
af_ctl_error_codes:
        dq e_invalid_json, e_frame_large, e_unknown_method, e_invalid_params
        dq e_cursor_stale, e_state, e_internal, e_not_found, e_unconfirmed
        dq e_unsupported
        align 8
        global af_ctl_error_messages
af_ctl_error_messages:
        dq m_invalid_json, m_frame_large, m_unknown_method, m_invalid_params
        dq m_cursor_stale, m_state, m_internal, m_not_found, m_unconfirmed
        dq m_unsupported

        section .text

; ---------------------------------------------------------------------------
; af_ctl_error_code_name(i64 code) -> const char * (STATIC)
; ---------------------------------------------------------------------------
        global af_ctl_error_code_name
af_ctl_error_code_name:
        cmp     rdi, AF_CTLERR_COUNT
        jae     .internal
        cmp     rdi, 0
        jl      .internal
        lea     rax, [af_ctl_error_codes]
        mov     rax, [rax + rdi * 8]
        ret
.internal:
        lea     rax, [e_internal]
        ret

        global af_ctl_error_code_message
af_ctl_error_code_message:
        cmp     rdi, AF_CTLERR_COUNT
        jae     .internal
        cmp     rdi, 0
        jl      .internal
        lea     rax, [af_ctl_error_messages]
        mov     rax, [rax + rdi * 8]
        ret
.internal:
        lea     rax, [m_internal]
        ret

; ---------------------------------------------------------------------------
; af_ctl_begin_envelope(af_json_writer *w, const char *id, u64 id_len)
;   -> af_status
;
; Private. Opens the response object and writes the correlation id. A NULL id
; writes JSON null: the client still gets a frame it can parse and log.
; ---------------------------------------------------------------------------
af_ctl_begin_envelope:
        AF_ENTER 16
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     [rsp + 8], rdx
        mov     rdi, rbx
        call    af_jw_begin_object
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [k_id]
        call    af_jw_key
        test    rax, rax
        js      .done
        cmp     qword [rsp], 0
        je      .null_id
        mov     rdi, rbx
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_jw_string_n
        AF_LEAVE
.null_id:
        mov     rdi, rbx
        call    af_jw_null
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_write_error(af_ctl_conn *c, const char *id, u64 id_len, i64 code,
;                    const char *field_or_null) -> af_status
;
; Serialises a complete error frame into the connection's outbox.
; ---------------------------------------------------------------------------
        global af_ctl_write_error
af_ctl_write_error:
        AF_ENTER 160
        mov     rbx, rdi                ; connection
        mov     [rsp + 96], rsi         ; id
        mov     [rsp + 104], rdx        ; id length
        mov     [rsp + 112], rcx        ; code
        mov     [rsp + 120], r8         ; field

        mov     rdi, rbx
        call    af_ctl_conn_outbox
        mov     r12, rax
        mov     rdi, rbx
        call    af_ctl_conn_server
        mov     r13, rax
        mov     rdi, r13
        call    af_ctl_server_frame_max
        mov     r14, rax

        mov     rdi, r12
        call    af_buf_len
        mov     r15, rax                ; where this frame starts

        lea     rdi, [rsp]              ; af_json_writer
        mov     rsi, r12
        call    af_jw_init
        test    rax, rax
        js      .done

        lea     rdi, [rsp]
        mov     rsi, [rsp + 96]
        mov     rdx, [rsp + 104]
        call    af_ctl_begin_envelope

        lea     rdi, [rsp]
        lea     rsi, [k_ok]
        xor     edx, edx
        call    af_jw_member_bool

        lea     rdi, [rsp]
        lea     rsi, [k_error]
        call    af_jw_key
        lea     rdi, [rsp]
        call    af_jw_begin_object

        mov     rdi, [rsp + 112]
        call    af_ctl_error_code_name
        mov     rdx, rax
        lea     rdi, [rsp]
        lea     rsi, [k_code]
        call    af_jw_member_string

        mov     rdi, [rsp + 112]
        call    af_ctl_error_code_message
        mov     rdx, rax
        lea     rdi, [rsp]
        lea     rsi, [k_message]
        call    af_jw_member_string

        cmp     qword [rsp + 120], 0
        je      .no_field
        lea     rdi, [rsp]
        lea     rsi, [k_field]
        mov     rdx, [rsp + 120]
        call    af_jw_member_string
.no_field:
        lea     rdi, [rsp]
        call    af_jw_end_object
        lea     rdi, [rsp]
        call    af_jw_end_object
        lea     rdi, [rsp]
        call    af_jw_finish
        test    rax, rax
        js      .done

        mov     rdi, r12
        mov     rsi, r15
        mov     rdx, r14
        call    af_ctl_frame_finish
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_write_protocol_error(af_ctl_conn *c, af_status cause) -> af_status
;
; For failures that happen before a request could be read at all: an oversized
; frame, or one that is not valid UTF-8. There is no id to echo.
; ---------------------------------------------------------------------------
        global af_ctl_write_protocol_error
af_ctl_write_protocol_error:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, AF_CTLERR_INVALID_JSON
        cmp     rsi, AF_E_CTL_FRAME_LARGE
        jne     .have_code
        mov     r12, AF_CTLERR_FRAME_TOO_LARGE
.have_code:
        mov     rdi, rbx
        xor     esi, esi
        xor     edx, edx
        mov     rcx, r12
        xor     r8d, r8d
        call    af_ctl_write_error
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_dispatch_frame(af_ctl_conn *c, const char *frame, u64 len)
;   -> af_status
;
; Parses one request and writes exactly one response. A malformed request is an
; error frame, not a closed connection: an operator typing into a socket should
; get told what was wrong.
;
; Locals:
;   [rsp +   0] af_json_limits (32 bytes)
;   [rsp +  32] af_json_doc (32 bytes)
;   [rsp +  64] id pointer / length
;   [rsp +  80] method pointer / length
;   [rsp +  96] params object
;   [rsp + 104] handler
; ---------------------------------------------------------------------------
        global af_ctl_dispatch_frame
af_ctl_dispatch_frame:
        AF_ENTER 128
        mov     rbx, rdi                ; connection
        mov     r12, rsi                ; frame
        mov     r13, rdx                ; length
        mov     qword [rsp + 64], 0
        mov     qword [rsp + 72], 0
        mov     qword [rsp + 96], 0

        mov     rdi, rbx
        call    af_ctl_conn_server
        mov     r14, rax
        mov     rdi, r14
        call    af_ctl_server_frame_max
        mov     r15, rax

        ; A control frame is operator input on a 0600 socket, but it is still
        ; parsed under explicit ceilings: the invariant is about every untrusted
        ; input, not about untrusted senders.
        mov     [rsp], r15              ; max bytes
        mov     qword [rsp + 8], 32     ; max depth
        mov     rax, r15
        mov     [rsp + 16], rax         ; max string
        mov     qword [rsp + 24], 4096  ; max elements

        mov     rdi, r12
        mov     rsi, r13
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        test    rax, rax
        js      .invalid_json

        lea     rdi, [rsp + 32]
        call    af_json_doc_root
        mov     r12, rax                ; request object
        mov     rdi, r12
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .invalid_json_doc

        ; The id is optional in shape but essential in practice; a missing one
        ; is echoed as null rather than refused, so a client that forgot it
        ; still learns what happened.
        mov     rdi, r12
        lea     rsi, [k_id]
        lea     rdx, [rsp + 64]
        lea     rcx, [rsp + 72]
        call    af_json_get_string

        mov     rdi, r12
        lea     rsi, [k_method]
        lea     rdx, [rsp + 80]
        lea     rcx, [rsp + 88]
        call    af_json_get_string
        test    rax, rax
        js      .no_method

        mov     rdi, r12
        lea     rsi, [k_params]
        lea     rdx, [rsp + 96]
        call    af_json_get_object
        cmp     rax, AF_E_JSON_TYPE
        je      .bad_params

        mov     rdi, [rsp + 80]
        mov     rsi, [rsp + 88]
        call    af_ctl_method_lookup
        test    rax, rax
        jz      .unknown_method
        mov     [rsp + 104], rax

        mov     rdi, rbx
        mov     rsi, [rsp + 104]
        mov     rdx, [rsp + 96]
        lea     rcx, [rsp + 64]
        call    af_ctl_method_invoke
        mov     [rsp + 112], rax
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        mov     rax, [rsp + 112]
        AF_LEAVE

.invalid_json_doc:
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
.invalid_json:
        mov     rdi, rbx
        xor     esi, esi
        xor     edx, edx
        mov     rcx, AF_CTLERR_INVALID_JSON
        xor     r8d, r8d
        call    af_ctl_write_error
        AF_LEAVE_OK

.no_method:
        mov     rdi, rbx
        mov     rsi, [rsp + 64]
        mov     rdx, [rsp + 72]
        mov     rcx, AF_CTLERR_INVALID_PARAMS
        lea     r8, [k_method]
        call    af_ctl_write_error
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        AF_LEAVE_OK

.bad_params:
        mov     rdi, rbx
        mov     rsi, [rsp + 64]
        mov     rdx, [rsp + 72]
        mov     rcx, AF_CTLERR_INVALID_PARAMS
        lea     r8, [k_params]
        call    af_ctl_write_error
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        AF_LEAVE_OK

.unknown_method:
        mov     rdi, rbx
        mov     rsi, [rsp + 64]
        mov     rdx, [rsp + 72]
        mov     rcx, AF_CTLERR_UNKNOWN_METHOD
        lea     r8, [k_method]
        call    af_ctl_write_error
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; af_ctl_write_success_begin(af_ctl_conn *c, af_json_writer *w,
;                            const void *id_pair, u64 *out_start) -> af_status
;
; Opens a success envelope and leaves the writer positioned for the handler to
; produce the `result` value. `id_pair` is the {pointer, length} the dispatcher
; extracted.
; ---------------------------------------------------------------------------
        global af_ctl_write_success_begin
af_ctl_write_success_begin:
        AF_ENTER 32
        mov     rbx, rdi                ; connection
        mov     r12, rsi                ; writer
        mov     r13, rdx                ; id pair
        mov     r14, rcx                ; out start offset

        mov     rdi, rbx
        call    af_ctl_conn_outbox
        mov     r15, rax
        mov     rdi, r15
        call    af_buf_len
        mov     [r14], rax

        mov     rdi, r12
        mov     rsi, r15
        call    af_jw_init
        test    rax, rax
        js      .done

        mov     rdi, r12
        mov     rsi, [r13]
        mov     rdx, [r13 + 8]
        call    af_ctl_begin_envelope
        test    rax, rax
        js      .done

        mov     rdi, r12
        lea     rsi, [k_ok]
        mov     rdx, 1
        call    af_jw_member_bool
        test    rax, rax
        js      .done

        mov     rdi, r12
        lea     rsi, [k_result]
        call    af_jw_key
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_write_success_end(af_ctl_conn *c, af_json_writer *w, u64 start)
;   -> af_status
;
; Closes the envelope and terminates the frame. A response that overflowed the
; ceiling is replaced by an error frame rather than sent truncated.
; ---------------------------------------------------------------------------
        global af_ctl_write_success_end
af_ctl_write_success_end:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, r12
        call    af_jw_end_object
        mov     rdi, r12
        call    af_jw_finish
        test    rax, rax
        js      .overflow

        mov     rdi, rbx
        call    af_ctl_conn_outbox
        mov     r14, rax
        mov     rdi, rbx
        call    af_ctl_conn_server
        mov     rdi, rax
        call    af_ctl_server_frame_max
        mov     rdi, r14
        mov     rsi, r13
        mov     rdx, rax
        call    af_ctl_frame_finish
        test    rax, rax
        js      .overflow
        AF_LEAVE_OK

.overflow:
        ; Roll the partial response back and replace it with something the
        ; client can act on.
        mov     rdi, rbx
        call    af_ctl_conn_outbox
        mov     [rax + 8], r13          ; af_buffer.len = start
        mov     rdi, rbx
        xor     esi, esi
        xor     edx, edx
        mov     rcx, AF_CTLERR_INTERNAL
        xor     r8d, r8d
        call    af_ctl_write_error
        AF_LEAVE_OK
