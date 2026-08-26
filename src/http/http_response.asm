; AsmFlow — HTTP response construction.
;
; Every byte a client sees is produced here. A response is written into the
; connection's outbox as one unit: status line, the headers the contract
; requires, the length, and the body. Nothing streams yet, so the length is
; always known before the first byte is queued and a partially written response
; can never be misframed.
;
; The error catalogue below is the whole set of failures AsmFlow can answer
; with. Keeping it in one table rather than choosing a status and a sentence at
; each call site is what makes docs/API_CONTRACT.md 7 checkable: the contract is
; a table, and so is this.
;
; No message contains anything from the request. A rejection is emitted before
; the request has been trusted for anything, so echoing a path, a header, or a
; field value back would turn a malformed request into a way to place chosen
; bytes in a response. The `param` field names a field; it never quotes one.

        bits 64
        default rel

%include "asmflow.inc"
%include "http.inc"
%include "jsonw.inc"

        extern af_buf_append_byte
        extern af_buf_append_cstr
        extern af_buf_append_u64

        extern af_jw_init
        extern af_jw_finish
        extern af_jw_begin_object
        extern af_jw_end_object
        extern af_jw_key
        extern af_jw_string
        extern af_jw_null
        extern af_jw_member_string
        extern af_jw_member_bool

        section .rodata

s_http11:       db "HTTP/1.1 ", 0
s_crlf:         db 13, 10, 0
s_ctype_json:   db "Content-Type: application/json", 13, 10, 0
s_ctype_sse:    db "Content-Type: text/event-stream", 13, 10, 0
s_clen:         db "Content-Length: ", 0
s_nosniff:      db "X-Content-Type-Options: nosniff", 13, 10, 0
s_nostore:      db "Cache-Control: no-store", 13, 10, 0
s_reqid:        db "X-AsmFlow-Request-Id: ", 0
s_conn_close:   db "Connection: close", 13, 10, 0
s_conn_alive:   db "Connection: keep-alive", 13, 10, 0
s_allow_get:    db "Allow: GET", 13, 10, 0
s_allow_post:   db "Allow: POST", 13, 10, 0

; Reason phrases for the statuses AsmFlow emits, and one fallback so an
; unlisted status still produces a syntactically valid status line.
r_200: db "OK", 0
r_400: db "Bad Request", 0
r_401: db "Unauthorized", 0
r_404: db "Not Found", 0
r_405: db "Method Not Allowed", 0
r_408: db "Request Timeout", 0
r_411: db "Length Required", 0
r_413: db "Content Too Large", 0
r_415: db "Unsupported Media Type", 0
r_431: db "Request Header Fields Too Large", 0
r_500: db "Internal Server Error", 0
r_503: db "Service Unavailable", 0
r_505: db "HTTP Version Not Supported", 0
r_other: db "Error", 0

; The `type` values from docs/API_CONTRACT.md 7, indexed by AF_ERRCLASS_*.
c_request:  db "asmflow_request_error", 0
c_auth:     db "asmflow_auth_error", 0
c_route:    db "asmflow_route_error", 0
c_state:    db "asmflow_state_error", 0
c_capacity: db "asmflow_capacity_error", 0
c_upstream: db "asmflow_upstream_error", 0
c_routing:  db "asmflow_routing_error", 0

; --- catalogue strings -----------------------------------------------------
e_unknown_path:      db "unknown_path", 0
m_unknown_path:      db "No such endpoint.", 0
e_method:            db "method_not_allowed", 0
m_method_get:        db "This endpoint accepts GET.", 0
m_method_post:       db "This endpoint accepts POST.", 0
e_headers_large:     db "headers_too_large", 0
m_headers_large:     db "The request header section exceeds the configured limit.", 0
e_body_large:        db "body_too_large", 0
m_body_large:        db "The request body exceeds the configured limit.", 0
e_length_required:   db "length_required", 0
m_length_required:   db "This endpoint requires a declared request body.", 0
e_ctype:             db "unsupported_content_type", 0
m_ctype:             db "This endpoint accepts application/json.", 0
e_invalid_json:      db "invalid_json", 0
m_invalid_json:      db "The request body is not valid JSON within the configured limits.", 0
e_invalid_field:     db "invalid_field", 0
m_invalid_field:     db "A request field has the wrong type.", 0
m_missing_model:     db "The request must name a model alias.", 0
e_missing_token:     db "missing_token", 0
m_missing_token:     db "This listener requires a credential.", 0
e_invalid_token:     db "invalid_token", 0
m_invalid_token:     db "The supplied credential was not accepted.", 0
e_malformed:         db "malformed_request", 0
m_malformed:         db "The request is not well-formed HTTP/1.1.", 0
e_smuggling:         db "conflicting_framing", 0
m_smuggling:         db "Conflicting or duplicated message framing headers.", 0
e_timeout:           db "request_timeout", 0
m_timeout:           db "The connection was idle longer than the configured timeout.", 0
e_not_ready:         db "not_ready", 0
m_not_ready:         db "The daemon is not ready to accept requests.", 0
e_unknown_alias:     db "unknown_model_alias", 0
m_unknown_alias:     db "No route is configured for that model alias.", 0
e_route_disabled:    db "route_disabled", 0
m_route_disabled:    db "That route is disabled.", 0
e_unsupported_build: db "unsupported_in_this_build", 0
m_unsupported_build: db "The upstream data plane is not present in this build.", 0
e_version:           db "unsupported_http_version", 0
m_version:           db "This listener speaks HTTP/1.1.", 0
e_internal:          db "internal_error", 0
m_internal:          db "The request could not be completed.", 0

p_model: db "model", 0

k_error:     db "error", 0
k_message:   db "message", 0
k_type:      db "type", 0
k_param:     db "param", 0
k_code:      db "code", 0
k_asmflow:   db "asmflow", 0
k_requestid: db "request_id", 0
k_retryable: db "retryable", 0

        section .data.rel.ro progbits align=8

status_table:
        dq 200, r_200
        dq 400, r_400
        dq 401, r_401
        dq 404, r_404
        dq 405, r_405
        dq 408, r_408
        dq 411, r_411
        dq 413, r_413
        dq 415, r_415
        dq 431, r_431
        dq 500, r_500
        dq 503, r_503
        dq 505, r_505
status_table_end:
%define STATUS_COUNT ((status_table_end - status_table) / 16)

class_table:
        dq c_request
        dq c_auth
        dq c_route
        dq c_state
        dq c_capacity
        dq c_upstream
        dq c_routing

; The catalogue, in AF_HERR_* order.
;
;    status  class                 code                 message              param    retry  head flags
        global af_http_error_table
af_http_error_table:
        dq 404, AF_ERRCLASS_ROUTE,    e_unknown_path,      m_unknown_path,      0,       0, 0
        dq 405, AF_ERRCLASS_REQUEST,  e_method,            m_method_get,        0,       0, AF_HEAD_ALLOW_GET
        dq 405, AF_ERRCLASS_REQUEST,  e_method,            m_method_post,       0,       0, AF_HEAD_ALLOW_POST
        dq 431, AF_ERRCLASS_REQUEST,  e_headers_large,     m_headers_large,     0,       0, 0
        dq 413, AF_ERRCLASS_REQUEST,  e_body_large,        m_body_large,        0,       0, 0
        dq 411, AF_ERRCLASS_REQUEST,  e_length_required,   m_length_required,   0,       0, 0
        dq 415, AF_ERRCLASS_REQUEST,  e_ctype,             m_ctype,             0,       0, 0
        dq 400, AF_ERRCLASS_REQUEST,  e_invalid_json,      m_invalid_json,      0,       0, 0
        dq 400, AF_ERRCLASS_REQUEST,  e_invalid_field,     m_invalid_field,     p_model, 0, 0
        dq 400, AF_ERRCLASS_REQUEST,  e_invalid_field,     m_missing_model,     p_model, 0, 0
        dq 401, AF_ERRCLASS_AUTH,     e_missing_token,     m_missing_token,     0,       0, 0
        dq 401, AF_ERRCLASS_AUTH,     e_invalid_token,     m_invalid_token,     0,       0, 0
        dq 400, AF_ERRCLASS_REQUEST,  e_malformed,         m_malformed,         0,       0, 0
        dq 400, AF_ERRCLASS_REQUEST,  e_smuggling,         m_smuggling,         0,       0, 0
        dq 408, AF_ERRCLASS_REQUEST,  e_timeout,           m_timeout,           0,       0, 0
        dq 503, AF_ERRCLASS_ROUTING,  e_not_ready,         m_not_ready,         0,       1, 0
        dq 404, AF_ERRCLASS_ROUTE,    e_unknown_alias,     m_unknown_alias,     p_model, 0, 0
        dq 503, AF_ERRCLASS_ROUTING,  e_route_disabled,    m_route_disabled,    p_model, 0, 0
        dq 503, AF_ERRCLASS_STATE,    e_unsupported_build, m_unsupported_build, 0,       0, 0
        dq 505, AF_ERRCLASS_REQUEST,  e_version,           m_version,           0,       0, 0
        dq 500, AF_ERRCLASS_STATE,    e_internal,          m_internal,          0,       0, 0
af_http_error_table_end:

        section .text

; ---------------------------------------------------------------------------
; af_http_error_def(u64 id) -> const af_http_error_def *
;
; Out of range answers with the internal-error entry rather than NULL: a caller
; that reached here has already decided to fail, and handing it a null pointer
; would turn a wrong error id into a crash.
; ---------------------------------------------------------------------------
        global af_http_error_def
af_http_error_def:
        cmp     rdi, AF_HERR_COUNT
        jae     .fallback
        lea     rax, [af_http_error_table]
        imul    rdi, rdi, HED_SIZE
        add     rax, rdi
        ret
.fallback:
        lea     rax, [af_http_error_table]
        add     rax, AF_HERR_INTERNAL * HED_SIZE
        ret

; ---------------------------------------------------------------------------
; af_http_error_count() -> u64
;
; So a test can walk the whole catalogue instead of a list it maintains itself.
; ---------------------------------------------------------------------------
        global af_http_error_count
af_http_error_count:
        mov     rax, (af_http_error_table_end - af_http_error_table) / HED_SIZE
        ret

; ---------------------------------------------------------------------------
; af_http_reason(u64 status) -> const char *
; ---------------------------------------------------------------------------
        global af_http_reason
af_http_reason:
        xor     ecx, ecx
        lea     rdx, [status_table]
.loop:
        cmp     rcx, STATUS_COUNT
        jae     .other
        mov     rax, rcx
        shl     rax, 4
        add     rax, rdx
        cmp     [rax], rdi
        je      .found
        inc     rcx
        jmp     .loop
.found:
        mov     rax, [rax + 8]
        ret
.other:
        lea     rax, [r_other]
        ret

; ---------------------------------------------------------------------------
; af_http_error_class_name(u64 class) -> const char *
; ---------------------------------------------------------------------------
        global af_http_error_class_name
af_http_error_class_name:
        cmp     rdi, AF_ERRCLASS_COUNT
        jae     .fallback
        lea     rax, [class_table]
        mov     rax, [rax + rdi * 8]
        ret
.fallback:
        lea     rax, [c_state]
        ret

; ---------------------------------------------------------------------------
; af_http_write_head(af_buffer *out, u64 status, u64 body_len,
;                    const char *request_id_or_null, i64 keep_alive,
;                    u64 head_flags) -> af_status
; ---------------------------------------------------------------------------
        global af_http_write_head
af_http_write_head:
        AF_ENTER 48
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi                        ; out
        mov     [rsp], rsi                      ; status
        mov     [rsp + 8], rdx                  ; body length
        mov     [rsp + 16], rcx                 ; request id
        mov     [rsp + 24], r8                  ; keep alive
        mov     [rsp + 32], r9                  ; head flags

        mov     rdi, rbx
        lea     rsi, [s_http11]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, [rsp]
        call    af_buf_append_u64
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     esi, ' '
        call    af_buf_append_byte
        test    rax, rax
        js      .done
        mov     rdi, [rsp]
        call    af_http_reason
        mov     rdi, rbx
        mov     rsi, rax
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [s_crlf]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done

        mov     rdi, rbx
        test    qword [rsp + 32], AF_HEAD_SSE
        jz      .json_ctype
        lea     rsi, [s_ctype_sse]
        jmp     .emit_ctype
.json_ctype:
        lea     rsi, [s_ctype_json]
.emit_ctype:
        call    af_buf_append_cstr
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [s_clen]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        call    af_buf_append_u64
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [s_crlf]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done

        ; nosniff on every response. A client that guesses a media type from
        ; the bytes of an error body is a client steerable by whatever produced
        ; the error.
        mov     rdi, rbx
        lea     rsi, [s_nosniff]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done

        test    qword [rsp + 32], AF_HEAD_NO_STORE
        jz      .no_store_done
        mov     rdi, rbx
        lea     rsi, [s_nostore]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
.no_store_done:

        test    qword [rsp + 32], AF_HEAD_ALLOW_GET
        jz      .allow_post
        mov     rdi, rbx
        lea     rsi, [s_allow_get]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
.allow_post:
        test    qword [rsp + 32], AF_HEAD_ALLOW_POST
        jz      .allow_done
        mov     rdi, rbx
        lea     rsi, [s_allow_post]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
.allow_done:

        cmp     qword [rsp + 16], 0
        je      .no_request_id
        mov     rdi, rbx
        lea     rsi, [s_reqid]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, [rsp + 16]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [s_crlf]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
.no_request_id:

        mov     rdi, rbx
        cmp     qword [rsp + 24], 0
        je      .close_header
        lea     rsi, [s_conn_alive]
        jmp     .emit_conn
.close_header:
        lea     rsi, [s_conn_close]
.emit_conn:
        call    af_buf_append_cstr
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [s_crlf]
        call    af_buf_append_cstr
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_http_build_error_body(af_buffer *body, const af_http_error_def *def,
;                          const char *request_id) -> af_status
;
; docs/API_CONTRACT.md 7. `param` is written as JSON null when the failure is
; not about a particular field, so the shape is the same either way and a client
; never has to tell "absent" from "not applicable".
; ---------------------------------------------------------------------------
        global af_http_build_error_body
af_http_build_error_body:
        AF_ENTER (JW_SIZE + 32)
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi                        ; body buffer
        mov     r12, rsi                        ; definition
        mov     r13, rdx                        ; request id

        lea     rdi, [rsp]
        mov     rsi, rbx
        call    af_jw_init
        test    rax, rax
        js      .done

        lea     rdi, [rsp]
        call    af_jw_begin_object
        lea     rdi, [rsp]
        lea     rsi, [k_error]
        call    af_jw_key
        lea     rdi, [rsp]
        call    af_jw_begin_object

        lea     rdi, [rsp]
        lea     rsi, [k_message]
        mov     rdx, [r12 + HED_MESSAGE]
        call    af_jw_member_string

        lea     rdi, [rsp]
        lea     rsi, [k_type]
        call    af_jw_key
        mov     rdi, [r12 + HED_CLASS]
        call    af_http_error_class_name
        lea     rdi, [rsp]
        mov     rsi, rax
        call    af_jw_string

        lea     rdi, [rsp]
        lea     rsi, [k_param]
        call    af_jw_key
        cmp     qword [r12 + HED_PARAM], 0
        je      .param_null
        lea     rdi, [rsp]
        mov     rsi, [r12 + HED_PARAM]
        call    af_jw_string
        jmp     .param_done
.param_null:
        lea     rdi, [rsp]
        call    af_jw_null
.param_done:

        lea     rdi, [rsp]
        lea     rsi, [k_code]
        mov     rdx, [r12 + HED_CODE]
        call    af_jw_member_string

        lea     rdi, [rsp]
        call    af_jw_end_object

        lea     rdi, [rsp]
        lea     rsi, [k_asmflow]
        call    af_jw_key
        lea     rdi, [rsp]
        call    af_jw_begin_object
        lea     rdi, [rsp]
        lea     rsi, [k_requestid]
        mov     rdx, r13
        call    af_jw_member_string
        lea     rdi, [rsp]
        lea     rsi, [k_retryable]
        mov     rdx, [r12 + HED_RETRYABLE]
        call    af_jw_member_bool
        lea     rdi, [rsp]
        call    af_jw_end_object

        lea     rdi, [rsp]
        call    af_jw_end_object
        lea     rdi, [rsp]
        call    af_jw_finish
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
