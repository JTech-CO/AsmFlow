; AsmFlow — fatal invariant violations.
;
; A panic means an invariant that the rest of the code is entitled to assume has
; already been broken; continuing would produce undefined state rather than a
; degraded service. It is therefore never used for input validation, upstream
; failures, or configuration errors, all of which return af_status codes.
;
; The message is written directly with write(2) rather than through the
; structured logger, because the logger itself may be the thing that is broken.
; No secret is ever passed to af_panic: call sites pass a static description and
; numeric context only (SECURITY_MODEL.md 16).

        bits 64
        default rel

%include "asmflow.inc"

        extern af_write_all
        extern af_cstr_len
        extern af_u64_to_dec
        extern af_sys_exit_group
        extern af_sys_getpid

%define AF_FD_STDERR 2

        section .rodata

pfx:        db "asmflow: fatal: "
pfx_len     equ $ - pfx
at_txt:     db " at "
at_txt_len  equ $ - at_txt
colon:      db ":"
nl:         db 10
ctx_txt:    db " context="
ctx_txt_len equ $ - ctx_txt

        section .text

; ---------------------------------------------------------------------------
; af_panic(const char *message, const char *file, u64 line, u64 context)
;   -> does not return
;
; Ownership: `message` and `file` are STATIC. `context` is a numeric aid only.
; ---------------------------------------------------------------------------
        global af_panic
af_panic:
        AF_ENTER 32
        mov     rbx, rdi                ; message
        mov     r12, rsi                ; file
        mov     r13, rdx                ; line
        mov     r14, rcx                ; context

        mov     edi, AF_FD_STDERR
        lea     rsi, [pfx]
        mov     rdx, pfx_len
        call    af_write_all

        mov     rdi, rbx
        call    af_cstr_len
        mov     rdx, rax
        mov     edi, AF_FD_STDERR
        mov     rsi, rbx
        call    af_write_all

        mov     edi, AF_FD_STDERR
        lea     rsi, [at_txt]
        mov     rdx, at_txt_len
        call    af_write_all

        mov     rdi, r12
        call    af_cstr_len
        mov     rdx, rax
        mov     edi, AF_FD_STDERR
        mov     rsi, r12
        call    af_write_all

        mov     edi, AF_FD_STDERR
        lea     rsi, [colon]
        mov     rdx, 1
        call    af_write_all

        mov     rdi, r13
        lea     rsi, [rsp]
        mov     rdx, 24
        lea     rcx, [rsp + 24]
        call    af_u64_to_dec
        mov     edi, AF_FD_STDERR
        lea     rsi, [rsp]
        mov     rdx, [rsp + 24]
        call    af_write_all

        mov     edi, AF_FD_STDERR
        lea     rsi, [ctx_txt]
        mov     rdx, ctx_txt_len
        call    af_write_all

        mov     rdi, r14
        lea     rsi, [rsp]
        mov     rdx, 24
        lea     rcx, [rsp + 24]
        call    af_u64_to_dec
        mov     edi, AF_FD_STDERR
        lea     rsi, [rsp]
        mov     rdx, [rsp + 24]
        call    af_write_all

        mov     edi, AF_FD_STDERR
        lea     rsi, [nl]
        mov     rdx, 1
        call    af_write_all

        ; Trap rather than exit: a core dump from the faulting instruction is
        ; more useful than a clean status, and it cannot be mistaken for an
        ; orderly shutdown by a supervisor.
        ud2
