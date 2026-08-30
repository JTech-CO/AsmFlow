; AsmFlow — strict request-scoped MCP SSE decoder.
;
; libcurl may fragment bytes anywhere; the reactor accumulates them under a
; hard aggregate bound and this decoder treats LF as the line boundary, strips
; one preceding CR, ignores comments, joins multiple data fields with LF, and
; dispatches complete events in wire order. A POST must later prove that one
; correlated final response was seen; notifications may precede it.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "mcp.inc"
%include "mcp_http.inc"

        extern af_mem_eq
        extern af_buf_clear
        extern af_buf_data
        extern af_buf_len
        extern af_buf_append
        extern af_buf_append_byte
        extern af_mcp_on_message

        section .rodata
sse_data:  db "data:"
%define SSE_DATA_LEN 5
sse_id:    db "id:"
%define SSE_ID_LEN 3

        section .text

; af_mcp_http_sse_dispatch(x) -> af_status
; Dispatches HX_SSE_EVENT when nonempty and clears it transactionally.
af_mcp_http_sse_dispatch:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        lea     rdi, [rbx + HX_SSE_EVENT]
        call    af_buf_len
        test    rax, rax
        jz      .ok
        cmp     qword [rbx + HX_SSE_EVENTS], AF_MCP_HTTP_EVENT_COUNT_MAX
        jae     .limit
        mov     r12, [rbx + HX_CALL]
        test    r12, r12
        jz      .deliver
        cmp     qword [r12 + CL_STATE], AF_MCP_CALL_PENDING
        jne     .protocol
.deliver:
        mov     rax, [rbx + HX_CHILD]
        test    rax, rax
        jz      .invalid
        mov     r13, [rax + MC_UNMATCHED]
        lea     rdi, [rbx + HX_SSE_EVENT]
        call    af_buf_len
        mov     r14, rax
        lea     rdi, [rbx + HX_SSE_EVENT]
        call    af_buf_data
        mov     rdi, [rbx + HX_CHILD]
        mov     rsi, rax
        mov     rdx, r14
        call    af_mcp_on_message
        test    rax, rax
        js      .done
        mov     rax, [rbx + HX_CHILD]
        cmp     [rax + MC_UNMATCHED], r13
        jne     .protocol
        inc     qword [rbx + HX_SSE_EVENTS]
        test    r12, r12
        jz      .clear_ok
        cmp     qword [r12 + CL_STATE], AF_MCP_CALL_DONE
        jne     .clear_ok
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_FINAL_SEEN
        jnz     .protocol
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_FINAL_SEEN
.clear_ok:
        lea     rdi, [rbx + HX_SSE_EVENT]
        call    af_buf_clear
.ok:
        AF_LEAVE_OK
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.protocol:
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; af_mcp_http_sse_consume(x) -> af_status
        global af_mcp_http_sse_consume
af_mcp_http_sse_consume:
        AF_ENTER 80
; [0] raw ptr, [8] raw len, [16] pos, [24] line start, [32] line len
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        lea     rdi, [rbx + HX_SSE_EVENT]
        call    af_buf_clear
        lea     rdi, [rbx + HX_SSE_CARRY]
        call    af_buf_len
        mov     [rsp + 8], rax
        test    rax, rax
        jz      .ok
        lea     rdi, [rbx + HX_SSE_CARRY]
        call    af_buf_data
        mov     [rsp], rax
        mov     qword [rsp + 16], 0

.next_line:
        mov     rax, [rsp + 16]
        cmp     rax, [rsp + 8]
        jae     .ok
        mov     [rsp + 24], rax
.find_lf:
        cmp     rax, [rsp + 8]
        jae     .truncated
        mov     rcx, [rsp]
        cmp     byte [rcx + rax], 10
        je      .line
        inc     rax
        jmp     .find_lf
.line:
        mov     rcx, rax
        sub     rcx, [rsp + 24]
        test    rcx, rcx
        jz      .line_ready
        mov     rdx, [rsp]
        mov     rsi, [rsp + 24]
        add     rdx, rsi
        cmp     byte [rdx + rcx - 1], 13
        jne     .line_ready
        dec     rcx
.line_ready:
        mov     [rsp + 32], rcx
        inc     rax
        mov     [rsp + 16], rax
        test    rcx, rcx
        jz      .blank
        mov     rdx, [rsp]
        add     rdx, [rsp + 24]
        cmp     byte [rdx], ':'
        je      .next_line
        cmp     rcx, SSE_DATA_LEN
        jb      .maybe_id
        mov     rdi, rdx
        lea     rsi, [sse_data]
        mov     rdx, SSE_DATA_LEN
        call    af_mem_eq
        test    rax, rax
        jz      .maybe_id
        mov     rdx, [rsp]
        add     rdx, [rsp + 24]
        add     rdx, SSE_DATA_LEN
        mov     rcx, [rsp + 32]
        sub     rcx, SSE_DATA_LEN
        test    rcx, rcx
        jz      .append_data
        cmp     byte [rdx], ' '
        jne     .append_data
        inc     rdx
        dec     rcx
.append_data:
        mov     [rsp + 40], rdx
        mov     [rsp + 48], rcx
        lea     rdi, [rbx + HX_SSE_EVENT]
        call    af_buf_len
        test    rax, rax
        jz      .no_join
        lea     rdi, [rbx + HX_SSE_EVENT]
        mov     esi, 10
        call    af_buf_append_byte
        test    rax, rax
        js      .done
.no_join:
        lea     rdi, [rbx + HX_SSE_EVENT]
        mov     rsi, [rsp + 40]
        mov     rdx, [rsp + 48]
        call    af_buf_append
        test    rax, rax
        js      .done
        jmp     .next_line

.maybe_id:
        ; Event IDs are meaningful only to the isolated legacy GET adapter.
        mov     rcx, [rsp + 32]
        cmp     rcx, SSE_ID_LEN
        jb      .next_line
        mov     rdx, [rsp]
        add     rdx, [rsp + 24]
        mov     rdi, rdx
        lea     rsi, [sse_id]
        mov     rdx, SSE_ID_LEN
        call    af_mem_eq
        test    rax, rax
        jz      .next_line
        cmp     qword [rbx + HX_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_LEGACY
        jne     .next_line
        mov     rax, [rbx + HX_CHILD]
        test    rax, rax
        jz      .protocol
        mov     r12, [rax + MC_ADAPTER]
        test    r12, r12
        jz      .protocol
        mov     rdx, [rsp]
        add     rdx, [rsp + 24]
        add     rdx, SSE_ID_LEN
        mov     rcx, [rsp + 32]
        sub     rcx, SSE_ID_LEN
        test    rcx, rcx
        jz      .id_value
        cmp     byte [rdx], ' '
        jne     .id_value
        inc     rdx
        dec     rcx
.id_value:
        lea     rdi, [r12 + LH_LAST_EVENT]
        call    af_buf_clear
        lea     rdi, [r12 + LH_LAST_EVENT]
        mov     rsi, rdx
        mov     rdx, rcx
        call    af_buf_append
        test    rax, rax
        js      .done
        jmp     .next_line

.blank:
        mov     rdi, rbx
        call    af_mcp_http_sse_dispatch
        test    rax, rax
        js      .done
        jmp     .next_line
.truncated:
        mov     rax, AF_E_MCP_PROTOCOL
        jmp     .done
.ok:
        xor     eax, eax
.done:
        AF_LEAVE
.protocol:
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
