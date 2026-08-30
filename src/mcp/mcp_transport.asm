; AsmFlow — transport dispatch below the common JSON-RPC encoder.
;
; JSON-RPC correlation, era validation, and inventory normalization are shared
; by stdio and HTTP. Framing and cancellation are not. This file is the narrow
; seam that keeps the common encoder from knowing about pipes, curl handles,
; sessions, or SSE.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "config.inc"
%include "mcp.inc"

        extern af_mcp_send
        extern af_mcp_http_request
        extern af_mcp_http_notify

        section .text

; af_mcp_transport_request(child, call, method, body, len) -> af_status
        global af_mcp_transport_request
af_mcp_transport_request:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        test    rcx, rcx
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r15, r8
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STDIO
        je      .stdio
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .invalid
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        mov     rcx, r14
        mov     r8, r15
        call    af_mcp_http_request
        AF_LEAVE
.stdio:
        mov     rdi, rbx
        mov     rsi, r14
        mov     rdx, r15
        call    af_mcp_send
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_mcp_transport_notify(child, method, body, len) -> af_status
        global af_mcp_transport_notify
af_mcp_transport_notify:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid_notify
        test    rsi, rsi
        jz      .invalid_notify
        test    rdx, rdx
        jz      .invalid_notify
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STDIO
        je      .stdio_notify
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .invalid_notify
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        mov     rcx, r14
        call    af_mcp_http_notify
        AF_LEAVE
.stdio_notify:
        mov     rdi, rbx
        mov     rsi, r13
        mov     rdx, r14
        call    af_mcp_send
        AF_LEAVE
.invalid_notify:
        AF_LEAVE_ERR AF_E_INVALID
