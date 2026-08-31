; AsmFlow — structured secret-header redaction.
;
; Redaction is driven by the semantic field name, never by a broad regular
; expression over arbitrary output.  The registry is derived directly from the
; immutable configuration snapshot: built-ins, operator additions, and every
; listener/provider/MCP authentication header are checked case-insensitively.
;
; Values and names are BORROWED only for the duration of a call.  Output is
; appended to a caller-owned bounded af_buffer; this module retains nothing.

        bits 64
        default rel

%include "asmflow.inc"
%include "config.inc"

        extern af_cstr_len
        extern af_mem_eq_ci
        extern af_buf_append

        section .rodata

redacted_value: db "[REDACTED]"
redacted_value_len equ $ - redacted_value

h_authorization:       db "authorization", 0
h_proxy_authorization: db "proxy-authorization", 0
h_cookie:              db "cookie", 0
h_set_cookie:          db "set-cookie", 0

        section .data.rel.ro progbits align=8 write
        align 8
redact_defaults:
        dq h_authorization
        dq h_proxy_authorization
        dq h_cookie
        dq h_set_cookie
        dq 0

        section .text

; af_redact_name_eq(const char *name, u64 name_len, const char *candidate)
;   -> i64 (1 when equal under ASCII case folding)
;
; Leaf-like comparison helper.  All pointers are BORROWED.
af_redact_name_eq:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        test    r13, r13
        jz      .no
        mov     rdi, r13
        call    af_cstr_len
        cmp     rax, r12
        jne     .no
        mov     rdi, rbx
        mov     rsi, r13
        mov     rdx, r12
        call    af_mem_eq_ci
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; af_redact_header_sensitive(const af_config *cfg, const char *name,
;                            u64 name_len) -> i64
;
; `cfg` may be NULL, in which case only the non-optional built-in registry is
; consulted.  This predicate is exported so diagnostics/log tests can prove a
; classification without manufacturing a value buffer.
        global af_redact_header_sensitive
af_redact_header_sensitive:
        AF_ENTER 32
        test    rsi, rsi
        jz      .no
        test    rdx, rdx
        jz      .no
        mov     rbx, rdi                ; config, nullable
        mov     r12, rsi                ; name
        mov     r13, rdx                ; name length

        lea     r14, [redact_defaults]
.default_loop:
        mov     r15, [r14]
        test    r15, r15
        jz      .configured
        mov     rdi, r12
        mov     rsi, r13
        mov     rdx, r15
        call    af_redact_name_eq
        test    rax, rax
        jnz     .yes
        add     r14, 8
        jmp     .default_loop

.configured:
        test    rbx, rbx
        jz      .no

        ; Operator-provided structured header names.
        xor     r14, r14
.log_loop:
        cmp     r14, [rbx + CFG_LOG_REDACT_COUNT]
        jae     .listener
        mov     rax, [rbx + CFG_LOG_REDACT]
        mov     rdx, [rax + r14 * 8]
        mov     rdi, r12
        mov     rsi, r13
        call    af_redact_name_eq
        test    rax, rax
        jnz     .yes
        inc     r14
        jmp     .log_loop

.listener:
        mov     rdx, [rbx + CFG_LST_AUTH + AUTH_HEADER]
        test    rdx, rdx
        jz      .providers
        mov     rdi, r12
        mov     rsi, r13
        call    af_redact_name_eq
        test    rax, rax
        jnz     .yes

.providers:
        xor     r14, r14
.provider_loop:
        cmp     r14, [rbx + CFG_PROVIDER_COUNT]
        jae     .mcp
        mov     rax, r14
        imul    rax, rax, PRV_SIZE
        add     rax, [rbx + CFG_PROVIDERS]
        mov     rdx, [rax + PRV_AUTH + AUTH_HEADER]
        test    rdx, rdx
        jz      .next_provider
        mov     rdi, r12
        mov     rsi, r13
        call    af_redact_name_eq
        test    rax, rax
        jnz     .yes
.next_provider:
        inc     r14
        jmp     .provider_loop

.mcp:
        xor     r14, r14
.mcp_loop:
        cmp     r14, [rbx + CFG_MCP_COUNT]
        jae     .no
        mov     rax, r14
        imul    rax, rax, MCP_SIZE
        add     rax, [rbx + CFG_MCP_SERVERS]
        mov     rdx, [rax + MCP_AUTH + AUTH_HEADER]
        test    rdx, rdx
        jz      .next_mcp
        mov     rdi, r12
        mov     rsi, r13
        call    af_redact_name_eq
        test    rax, rax
        jnz     .yes
.next_mcp:
        inc     r14
        jmp     .mcp_loop

.yes:
        mov     eax, 1
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; af_redact_header_value(const af_config *cfg, const char *name, u64 name_len,
;                        const char *value, u64 value_len, af_buffer *out)
;   -> af_status
;
; The sixth SysV argument is in r9.  A sensitive field appends exactly the
; constant marker and never reads its value bytes; a non-sensitive field
; appends the provided bytes.  The buffer's existing max is the output limit.
        global af_redact_header_value
af_redact_header_value:
        AF_ENTER 32
        test    rsi, rsi
        jz      .invalid
        test    r9, r9
        jz      .invalid
        test    r8, r8
        jz      .value_ok
        test    rcx, rcx
        jz      .invalid
.value_ok:
        mov     rbx, rcx                ; value, nullable only at len 0
        mov     r12, r8                 ; value length
        mov     r13, r9                 ; caller-owned output
        ; rdi/rsi/rdx already form the classification arguments.
        call    af_redact_header_sensitive
        test    rax, rax
        jz      .plain
        mov     rdi, r13
        lea     rsi, [redacted_value]
        mov     rdx, redacted_value_len
        call    af_buf_append
        AF_LEAVE
.plain:
        mov     rdi, r13
        mov     rsi, rbx
        mov     rdx, r12
        call    af_buf_append
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
