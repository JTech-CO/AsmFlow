; AsmFlow — JSON-RPC over a child's pipes.
;
; What arrives on stdout is one message per line. This file decides what each
; one is, matches responses to the requests that asked for them, and keeps the
; result until the supervisor collects it.
;
; The strictness here is deliberate and is the substance of M8 DoD 6. A line
; that does not parse, or parses into something that is not a JSON-RPC message,
; is counted as protocol contamination and rejected with AF_E_MCP_PROTOCOL.
; The framing caller propagates that failure into the supervisor's stop path:
; accepting stdout noise would keep a corrupted session READY and hide a server
; writing logs to the protocol pipe, the most common MCP integration failure.
;
; AsmFlow answers nothing a server asks of it. Sampling and elicitation are
; deferred (docs/MCP_COMPATIBILITY.md 7), so a server-initiated request is
; recorded and left unanswered rather than being given a plausible reply — a
; supervisor that improvised answers would be an agent runtime, which is the
; thing this project is explicitly not.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "json.inc"
%include "jsonw.inc"
%include "config.inc"
%include "mcp.inc"

        extern af_mem_zero
        extern af_cstr_len
        extern af_mem_eq
        extern af_add_size
        extern af_mul_size

        extern af_buf_init
        extern af_buf_free
        extern af_buf_clear
        extern af_buf_data
        extern af_buf_len
        extern af_buf_append
        extern af_buf_append_cstr

        extern af_json_parse
        extern af_json_doc_root
        extern af_json_doc_free
        extern af_json_type
        extern af_json_member
        extern af_json_get_integer
        extern af_json_get_string
        extern af_json_string_of

        extern af_jsonc_dump
        extern af_jsonc_dump_free

        extern af_jw_init
        extern af_jw_finish
        extern af_jw_begin_object
        extern af_jw_end_object
        extern af_jw_key
        extern af_jw_string
        extern af_jw_uint
        extern af_jw_raw

        extern af_mcp_send
        extern af_mcp_transport_request
        extern af_mcp_transport_notify
        extern af_mcp_http_cancel_call
        extern af_monotonic_now

        section .rodata

k_jsonrpc: db "jsonrpc", 0
k_id:      db "id", 0
k_method:  db "method", 0
k_params:  db "params", 0
k_result:  db "result", 0
k_error:   db "error", 0
k_code:    db "code", 0
k_message: db "message", 0
k_request_id: db "requestId", 0
k_reason:     db "reason", 0
v_two:     db "2.0", 0
m_cancelled: db "notifications/cancelled", 0
v_timeout_reason: db "request timeout", 0
%define V_TWO_LEN 3
%define AF_MCP_CANCEL_FRAME_MAX 512

        section .text

; ---------------------------------------------------------------------------
; af_mcp_call_alloc(af_mcp_child *child, i64 kind, u64 deadline_ns)
;   -> af_mcp_call * (NULL when the table is full)
;
; The id is per process rather than per daemon, so a response arriving from a
; restarted server cannot be matched to a request made of the previous one.
; ---------------------------------------------------------------------------
        global af_mcp_call_alloc
af_mcp_call_alloc:
        AF_ENTER 48
        test    rdi, rdi
        jz      .none
        mov     rbx, rdi
        mov     [rsp], rsi                      ; kind
        mov     [rsp + 8], rdx                  ; deadline

        xor     r12, r12
.scan:
        cmp     r12, AF_MCP_MAX_CALLS
        jae     .none
        mov     r13, r12
        imul    r13, r13, CL_SIZE
        add     r13, rbx
        add     r13, MC_CALLS
        cmp     qword [r13 + CL_STATE], AF_MCP_CALL_FREE
        je      .found
        inc     r12
        jmp     .scan

.found:
        lea     rdi, [r13 + CL_RESULT]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        test    rax, rax
        js      .none
        inc     qword [rbx + MC_NEXT_ID]
        mov     rax, [rbx + MC_NEXT_ID]
        mov     [r13 + CL_ID], rax
        mov     rax, [rsp]
        mov     [r13 + CL_KIND], rax
        mov     rax, [rsp + 8]
        mov     [r13 + CL_DEADLINE], rax
        mov     qword [r13 + CL_STATUS], 0
        mov     qword [r13 + CL_ERROR_CODE], 0
        mov     qword [r13 + CL_STATE], AF_MCP_CALL_PENDING
        mov     rax, r13
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_call_find(af_mcp_child *child, u64 id) -> af_mcp_call *
; ---------------------------------------------------------------------------
        global af_mcp_call_find
af_mcp_call_find:
        AF_ENTER 16
        test    rdi, rdi
        jz      .none
        mov     rbx, rdi
        mov     r12, rsi
        xor     rcx, rcx
.scan:
        cmp     rcx, AF_MCP_MAX_CALLS
        jae     .none
        mov     rax, rcx
        imul    rax, rax, CL_SIZE
        add     rax, rbx
        add     rax, MC_CALLS
        cmp     qword [rax + CL_STATE], AF_MCP_CALL_FREE
        je      .next
        cmp     qword [rax + CL_ID], r12
        je      .done
.next:
        inc     rcx
        jmp     .scan
.done:
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_call_release(af_mcp_call *call) -> void
; ---------------------------------------------------------------------------
        global af_mcp_call_release
af_mcp_call_release:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        cmp     qword [rbx + CL_STATE], AF_MCP_CALL_FREE
        je      .done
        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_free
        mov     rdi, rbx
        mov     rsi, CL_SIZE
        call    af_mem_zero
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_calls_release(af_mcp_child *child) -> void
;
; Every in-flight call is invalidated when the process ends
; (docs/MCP_COMPATIBILITY.md 4). A response cannot arrive from a process that
; no longer exists, and a call left pending would be waited on forever.
; ---------------------------------------------------------------------------
        global af_mcp_calls_release
af_mcp_calls_release:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        xor     r12, r12
.loop:
        cmp     r12, AF_MCP_MAX_CALLS
        jae     .done
        mov     rax, r12
        imul    rax, rax, CL_SIZE
        add     rax, rbx
        add     rax, MC_CALLS
        mov     rdi, rax
        call    af_mcp_call_release
        inc     r12
        jmp     .loop
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_request(af_mcp_child *child, const char *method, const char *params,
;                i64 kind, u64 timeout_ms) -> af_mcp_call *
;
; `params` is a JSON object as text, or NULL for none. It is written through
; the writer's literal form: the callers below build small, fixed documents,
; and re-encoding them field by field would mean this file knowing the shape of
; every request AsmFlow makes.
; ---------------------------------------------------------------------------
        global af_mcp_request
af_mcp_request:
        AF_ENTER 160
;   [rsp +  0]  child      [rsp + 32]  af_json_writer
;   [rsp +  8]  method     [rsp + 96]  af_buffer for the line
;   [rsp + 16]  params     [rsp + 128] kind
;   [rsp + 24]  call       [rsp + 136] timeout milliseconds
;                         [rsp + 144] timeout nanoseconds
;                         [rsp + 152] deadline
%define RQ_W   32
%define RQ_BUF 96
        test    rdi, rdi
        jz      .none
        test    rsi, rsi
        jz      .none
        mov     [rsp], rdi
        mov     [rsp + 8], rsi
        mov     [rsp + 16], rdx
        mov     [rsp + 128], rcx
        mov     [rsp + 136], r8
        mov     rbx, rdi

        call    af_monotonic_now
        mov     [rsp + 152], rax
        cmp     qword [rsp + 136], 0
        jz      .no_deadline
        mov     rdi, [rsp + 136]
        mov     rsi, NS_PER_MS
        lea     rdx, [rsp + 144]
        call    af_mul_size
        test    rax, rax
        js      .none
        mov     rdi, [rsp + 152]
        mov     rsi, [rsp + 144]
        lea     rdx, [rsp + 152]
        call    af_add_size
        test    rax, rax
        js      .none
        mov     r12, [rsp + 152]
        jmp     .have_deadline
.no_deadline:
        xor     r12, r12
.have_deadline:
        mov     rdi, rbx
        mov     rsi, [rsp + 128]
        mov     rdx, r12
        call    af_mcp_call_alloc
        test    rax, rax
        jz      .none
        mov     r13, rax
        mov     [rsp + 24], r13

        lea     rdi, [rsp + RQ_BUF]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        test    rax, rax
        js      .release

        lea     rdi, [rsp + RQ_W]
        lea     rsi, [rsp + RQ_BUF]
        call    af_jw_init
        lea     rdi, [rsp + RQ_W]
        call    af_jw_begin_object
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_jsonrpc]
        call    af_jw_key
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [v_two]
        call    af_jw_string
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_id]
        call    af_jw_key
        lea     rdi, [rsp + RQ_W]
        mov     rsi, [r13 + CL_ID]
        call    af_jw_uint
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_method]
        call    af_jw_key
        lea     rdi, [rsp + RQ_W]
        mov     rsi, [rsp + 8]
        call    af_jw_string

        cmp     qword [rsp + 16], 0
        je      .no_params
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_params]
        call    af_jw_key
        mov     rdi, [rsp + 16]
        call    af_cstr_len
        mov     r14, rax
        lea     rdi, [rsp + RQ_W]
        mov     rsi, [rsp + 16]
        mov     rdx, r14
        call    af_jw_raw
.no_params:
        lea     rdi, [rsp + RQ_W]
        call    af_jw_end_object
        lea     rdi, [rsp + RQ_W]
        call    af_jw_finish
        test    rax, rax
        js      .free_buffer

        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_len
        mov     r14, rax
        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_data
        mov     rdi, [rsp]
        mov     rsi, [rsp + 24]
        mov     rdx, [rsp + 8]
        mov     rcx, rax
        mov     r8, r14
        call    af_mcp_transport_request
        mov     r15, rax

        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_free
        test    r15, r15
        js      .release
        mov     rax, [rsp + 24]
        AF_LEAVE

.free_buffer:
        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_free
.release:
        mov     rdi, [rsp + 24]
        call    af_mcp_call_release
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_notify(af_mcp_child *child, const char *method, const char *params)
;   -> af_status
;
; A message with no id, and therefore no answer. The legacy `initialized`
; handshake is one.
; ---------------------------------------------------------------------------
        global af_mcp_notify
af_mcp_notify:
        AF_ENTER 128
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     [rsp], rdi
        mov     [rsp + 8], rsi
        mov     [rsp + 16], rdx

        lea     rdi, [rsp + RQ_BUF]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        test    rax, rax
        js      .done

        lea     rdi, [rsp + RQ_W]
        lea     rsi, [rsp + RQ_BUF]
        call    af_jw_init
        lea     rdi, [rsp + RQ_W]
        call    af_jw_begin_object
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_jsonrpc]
        call    af_jw_key
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [v_two]
        call    af_jw_string
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_method]
        call    af_jw_key
        lea     rdi, [rsp + RQ_W]
        mov     rsi, [rsp + 8]
        call    af_jw_string
        cmp     qword [rsp + 16], 0
        je      .no_params
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_params]
        call    af_jw_key
        mov     rdi, [rsp + 16]
        call    af_cstr_len
        mov     r14, rax
        lea     rdi, [rsp + RQ_W]
        mov     rsi, [rsp + 16]
        mov     rdx, r14
        call    af_jw_raw
.no_params:
        lea     rdi, [rsp + RQ_W]
        call    af_jw_end_object
        lea     rdi, [rsp + RQ_W]
        call    af_jw_finish
        test    rax, rax
        js      .free_buffer

        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_len
        mov     r14, rax
        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_data
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        mov     rdx, rax
        mov     rcx, r14
        call    af_mcp_transport_notify
        mov     r15, rax
        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_free
        mov     rax, r15
        AF_LEAVE

.free_buffer:
        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_free
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_on_message(af_mcp_child *child, const char *line, u64 len)
;   -> af_status
;
; One line from the protocol pipe. A line AsmFlow cannot classify is counted
; and returns AF_E_MCP_PROTOCOL so the supervisor cannot leave a corrupted
; session READY.
; ---------------------------------------------------------------------------
        global af_mcp_on_message
af_mcp_on_message:
        AF_ENTER 192
;   [rsp +   0]  child        [rsp + 32]  the member under inspection
;   [rsp +   8]  line         [rsp + 40]  id
;   [rsp +  16]  length       [rsp + 48]  root
;   [rsp +  64]  af_json_limits
;   [rsp + 128]  af_json_doc
%define MSG_LIMITS 64
%define MSG_DOC    128
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     [rsp], rdi
        mov     [rsp + 8], rsi
        mov     [rsp + 16], rdx
        mov     rbx, rdi
        test    rdx, rdx
        jz      .contaminated

        mov     rax, [rbx + MC_FRAME_MAX]
        test    rax, rax
        jnz     .have_bytes
        mov     rax, [rsp + 16]
.have_bytes:
        mov     [rsp + MSG_LIMITS + AF_JSONLIM_MAX_BYTES], rax
        mov     qword [rsp + MSG_LIMITS + AF_JSONLIM_MAX_DEPTH], 64
        mov     qword [rsp + MSG_LIMITS + AF_JSONLIM_MAX_STRING], 1048576
        mov     qword [rsp + MSG_LIMITS + AF_JSONLIM_MAX_ELEMS], 100000

        mov     rdi, [rsp + 8]
        mov     rsi, [rsp + 16]
        lea     rdx, [rsp + MSG_LIMITS]
        lea     rcx, [rsp + MSG_DOC]
        call    af_json_parse
        test    rax, rax
        js      .contaminated

        lea     rdi, [rsp + MSG_DOC]
        call    af_json_doc_root
        mov     [rsp + 48], rax
        mov     rdi, rax
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .free_and_contaminated

        ; `jsonrpc: "2.0"` or it is not a JSON-RPC message at all.
        mov     rdi, [rsp + 48]
        lea     rsi, [k_jsonrpc]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_json_get_string
        test    rax, rax
        js      .free_and_contaminated
        cmp     qword [rsp + 32], V_TWO_LEN
        jne     .free_and_contaminated
        mov     rdi, [rsp + 24]
        lea     rsi, [v_two]
        mov     rdx, V_TWO_LEN
        call    af_mem_eq
        test    rax, rax
        jz      .free_and_contaminated

        ; Classify by method first. Server-initiated requests legitimately
        ; carry both an id and a method (sampling/elicitation); looking at an
        ; integer id first would misclassify and kill that valid session.
        mov     rdi, [rsp + 48]
        lea     rsi, [k_method]
        lea     rdx, [rsp + 32]
        call    af_json_member
        test    rax, rax
        jns     .request_or_notification

        ; A response has no method, carries an integer id, and contains
        ; exactly one of result/error.
        mov     rdi, [rsp + 48]
        lea     rsi, [k_id]
        lea     rdx, [rsp + 40]
        call    af_json_get_integer
        test    rax, rax
        js      .free_and_contaminated

        mov     rdi, [rsp + 48]
        lea     rsi, [k_result]
        lea     rdx, [rsp + 32]
        call    af_json_member
        test    rax, rax
        js      .response_error_only
        mov     r13, [rsp + 32]

        ; result and error are mutually exclusive, even if the peer supplied
        ; a result that otherwise looked usable.
        mov     rdi, [rsp + 48]
        lea     rsi, [k_error]
        lea     rdx, [rsp + 32]
        call    af_json_member
        test    rax, rax
        jns     .free_and_contaminated
        xor     r14d, r14d
        jmp     .correlate_response

.response_error_only:
        mov     rdi, [rsp + 48]
        lea     rsi, [k_error]
        lea     rdx, [rsp + 32]
        call    af_json_member
        test    rax, rax
        js      .free_and_contaminated
        mov     r13, [rsp + 32]
        ; JSON-RPC 2.0 requires an error object with integer code and string
        ; message. `data` is optional and may have any JSON type.
        mov     rdi, r13
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .free_and_contaminated
        mov     rdi, r13
        lea     rsi, [k_code]
        lea     rdx, [rsp + 56]
        call    af_json_get_integer
        test    rax, rax
        js      .free_and_contaminated
        mov     rdi, r13
        lea     rsi, [k_message]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_json_get_string
        test    rax, rax
        js      .free_and_contaminated
        mov     r14d, 1

.correlate_response:
        mov     rdi, [rsp]
        mov     rsi, [rsp + 40]
        call    af_mcp_call_find
        test    rax, rax
        jz      .free_and_unmatched
        mov     r12, rax
        ; A retained DONE slot is still findable until its owner releases it,
        ; but it is no longer eligible for correlation. Duplicate responses
        ; and responses arriving after a timeout are unmatched session data.
        cmp     qword [r12 + CL_STATE], AF_MCP_CALL_PENDING
        jne     .free_and_unmatched

        test    r14, r14
        jnz     .handle_error
        mov     rdi, r13
        mov     rsi, r12
        call    af_mcp_store_result
        test    rax, rax
        js      .store_failed
        mov     qword [r12 + CL_STATUS], 0
        mov     qword [r12 + CL_STATE], AF_MCP_CALL_DONE
        jmp     .free_and_ok

.handle_error:
        mov     rax, [rsp + 56]
        mov     [r12 + CL_ERROR_CODE], rax
        mov     rdi, r13
        mov     rsi, r12
        call    af_mcp_store_result
        test    rax, rax
        js      .store_failed
        mov     qword [r12 + CL_STATUS], AF_E_MCP_PROTOCOL
        mov     qword [r12 + CL_STATE], AF_MCP_CALL_DONE
        jmp     .free_and_ok

.store_failed:
        ; The response did match this pending call, so complete it with the
        ; storage failure. af_mcp_store_result guarantees the result buffer is
        ; empty on failure; never report success over missing/partial JSON.
        mov     [r12 + CL_STATUS], rax
        mov     qword [r12 + CL_STATE], AF_MCP_CALL_DONE
        jmp     .free_and_ok

.request_or_notification:
        ; A notification, or a request the server is making of AsmFlow. Neither
        ; is answered: sampling and elicitation are deferred, and a supervisor
        ; that improvised a reply would be an agent runtime.
        mov     rdi, [rsp + 48]
        lea     rsi, [k_method]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_json_get_string
        test    rax, rax
        js      .free_and_contaminated
        ; A request/notification cannot also carry response members.  This
        ; catches non-integer-id hybrids that never enter the response path.
        mov     rdi, [rsp + 48]
        lea     rsi, [k_result]
        lea     rdx, [rsp + 32]
        call    af_json_member
        test    rax, rax
        jns     .free_and_contaminated
        mov     rdi, [rsp + 48]
        lea     rsi, [k_error]
        lea     rdx, [rsp + 32]
        call    af_json_member
        test    rax, rax
        jns     .free_and_contaminated

        ; A request id is optional, but when present JSON-RPC permits only a
        ; string, integer number, or the discouraged-but-interoperable null.
        ; Objects, arrays, booleans, and reals cannot be correlated safely.
        mov     rdi, [rsp + 48]
        lea     rsi, [k_id]
        lea     rdx, [rsp + 32]
        call    af_json_member
        cmp     rax, AF_E_NOTFOUND
        je      .check_request_params
        test    rax, rax
        js      .free_and_contaminated
        mov     rdi, [rsp + 32]
        call    af_json_type
        cmp     rax, AF_JSON_STRING
        je      .check_request_params
        cmp     rax, AF_JSON_INTEGER
        je      .check_request_params
        cmp     rax, AF_JSON_NULL
        jne     .free_and_contaminated

.check_request_params:
        ; params is optional; its structured value is an object (named
        ; arguments) or array (positional arguments), never a scalar.
        mov     rdi, [rsp + 48]
        lea     rsi, [k_params]
        lea     rdx, [rsp + 32]
        call    af_json_member
        cmp     rax, AF_E_NOTFOUND
        je      .record_request
        test    rax, rax
        js      .free_and_contaminated
        mov     rdi, [rsp + 32]
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        je      .record_request
        cmp     rax, AF_JSON_ARRAY
        jne     .free_and_contaminated

.record_request:
        inc     qword [rbx + MC_NOTIFICATIONS]
        jmp     .free_and_ok

.free_and_unmatched:
        ; A response to something nobody asked, or to a request made of a
        ; previous process. Counted rather than ignored: it means the session
        ; is not what AsmFlow believes it to be.
        inc     qword [rbx + MC_UNMATCHED]
.free_and_ok:
        lea     rdi, [rsp + MSG_DOC]
        call    af_json_doc_free
        AF_LEAVE_OK

.free_and_contaminated:
        lea     rdi, [rsp + MSG_DOC]
        call    af_json_doc_free
.contaminated:
        inc     qword [rbx + MC_CONTAMINATED]
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_store_result(json_t *value, af_mcp_call *call) -> af_status
;
; Keeps the member as text. Jansson re-emits it, for the same reason the
; provider adapter uses Jansson to re-emit a request body: a JSON real has no
; decimal text recoverable from a double, and AsmFlow has no business changing
; a value it is only going to show an operator.
; ---------------------------------------------------------------------------
        global af_mcp_store_result
af_mcp_store_result:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rsi
        mov     r12, rdi

        ; A failed dump or append must not expose a result from an earlier
        ; attempt. af_buf_append itself is atomic, so clearing before either
        ; fallible operation leaves the call with either the whole value or no
        ; value at all.
        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_clear

        mov     rdi, r12
        lea     rsi, [rsp + 8]
        call    af_jsonc_dump
        test    rax, rax
        jz      .nomem
        mov     r13, rax

        lea     rdi, [rbx + CL_RESULT]
        mov     rsi, r13
        mov     rdx, [rsp + 8]
        call    af_buf_append
        mov     r14, rax
        mov     rdi, r13
        call    af_jsonc_dump_free
        mov     rax, r14
        AF_LEAVE
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_emit_cancelled(af_mcp_child *child, const af_mcp_call *call)
;   -> af_status
;
; Low-level common encoder for the two stdio era adapters. The wire shape is
; intentionally identical for our non-task requests, but era selection stays
; outside this function so a future revision cannot leak one adapter's state
; into the other. No top-level id or optional _meta is emitted.
; ---------------------------------------------------------------------------
af_mcp_emit_cancelled:
        AF_ENTER 128
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     [rsp], rdi
        mov     [rsp + 8], rsi

        lea     rdi, [rsp + RQ_BUF]
        mov     rsi, AF_MCP_CANCEL_FRAME_MAX
        call    af_buf_init
        test    rax, rax
        js      .done

        lea     rdi, [rsp + RQ_W]
        lea     rsi, [rsp + RQ_BUF]
        call    af_jw_init
        lea     rdi, [rsp + RQ_W]
        call    af_jw_begin_object
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_jsonrpc]
        call    af_jw_key
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [v_two]
        call    af_jw_string
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_method]
        call    af_jw_key
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [m_cancelled]
        call    af_jw_string
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_params]
        call    af_jw_key
        lea     rdi, [rsp + RQ_W]
        call    af_jw_begin_object
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_request_id]
        call    af_jw_key
        lea     rdi, [rsp + RQ_W]
        mov     rax, [rsp + 8]
        mov     rsi, [rax + CL_ID]
        call    af_jw_uint
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [k_reason]
        call    af_jw_key
        lea     rdi, [rsp + RQ_W]
        lea     rsi, [v_timeout_reason]
        call    af_jw_string
        lea     rdi, [rsp + RQ_W]
        call    af_jw_end_object
        lea     rdi, [rsp + RQ_W]
        call    af_jw_end_object
        lea     rdi, [rsp + RQ_W]
        call    af_jw_finish
        test    rax, rax
        js      .free_buffer

        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_len
        mov     r14, rax
        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_data
        mov     rdi, [rsp]
        lea     rsi, [m_cancelled]
        mov     rdx, rax
        mov     rcx, r14
        call    af_mcp_transport_notify
        mov     r15, rax
        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_free
        mov     rax, r15
        AF_LEAVE

.free_buffer:
        mov     r15, rax
        lea     rdi, [rsp + RQ_BUF]
        call    af_buf_free
        mov     rax, r15
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; The two entry points are kept separate even while their current stdio wire
; shape is the same. They are adapters, not a runtime era branch hidden inside
; the encoder.
        global af_mcp_cancel_modern
af_mcp_cancel_modern:
        AF_ENTER 0
        call    af_mcp_emit_cancelled
        AF_LEAVE

        global af_mcp_cancel_legacy
af_mcp_cancel_legacy:
        AF_ENTER 0
        call    af_mcp_emit_cancelled
        AF_LEAVE

; Explicit timeout adapter selection. Legacy initialize is the one request
; that must never be cancelled: it is the fallback handshake, not a running
; non-task operation. Discovery is necessarily modern even before MC_ERA has
; been committed; every other request requires the already-selected era.
af_mcp_cancel_timed_out:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .stdio
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, AF_E_MCP_TIMEOUT
        call    af_mcp_http_cancel_call
        AF_LEAVE
.stdio:
        cmp     qword [r12 + CL_KIND], AF_MCP_CALL_INITIALIZE
        je      .ok
        cmp     qword [r12 + CL_KIND], AF_MCP_CALL_DISCOVER
        je      .modern
        cmp     qword [r12 + CL_KIND], AF_MCP_CALL_COUNT
        jae     .invalid
        cmp     qword [rbx + MC_ERA], AF_ERA_MODERN
        je      .modern
        cmp     qword [rbx + MC_ERA], AF_ERA_LEGACY
        jne     .era
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_cancel_legacy
        AF_LEAVE
.modern:
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_cancel_modern
        AF_LEAVE
.ok:
        AF_LEAVE_OK
.era:
        AF_LEAVE_ERR AF_E_MCP_ERA
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_sweep_calls(af_mcp_child *child, u64 now_ns) -> u64
;
; Abandons calls past their deadline and answers how many, or the first
; cancellation-writer error. A non-initialize timeout first queues the
; era-specific notifications/cancelled frame, then retires the call locally so
; a late response is unmatched. The call is retired even when emission fails;
; the supervisor turns that transport failure into child shutdown.
; ---------------------------------------------------------------------------
        global af_mcp_sweep_calls
af_mcp_sweep_calls:
        AF_ENTER 32
        test    rdi, rdi
        jz      .none
        mov     rbx, rdi
        mov     r12, rsi
        xor     r13, r13
        xor     r14, r14
        mov     qword [rsp], 0                 ; first emission error
.loop:
        cmp     r14, AF_MCP_MAX_CALLS
        jae     .done
        mov     r15, r14
        imul    r15, r15, CL_SIZE
        add     r15, rbx
        add     r15, MC_CALLS
        cmp     qword [r15 + CL_STATE], AF_MCP_CALL_PENDING
        jne     .next
        mov     rax, [r15 + CL_DEADLINE]
        test    rax, rax
        jz      .next                           ; no deadline was set
        cmp     r12, rax
        jb      .next
        mov     rdi, rbx
        mov     rsi, r15
        call    af_mcp_cancel_timed_out
        test    rax, rax
        jns     .retire
        cmp     qword [rsp], 0
        jne     .retire
        mov     [rsp], rax
.retire:
        mov     qword [r15 + CL_STATUS], AF_E_MCP_TIMEOUT
        mov     qword [r15 + CL_STATE], AF_MCP_CALL_DONE
        inc     r13
.next:
        inc     r14
        jmp     .loop
.done:
        cmp     qword [rsp], 0
        jne     .error
        mov     rax, r13
        AF_LEAVE
.error:
        mov     rax, [rsp]
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE
