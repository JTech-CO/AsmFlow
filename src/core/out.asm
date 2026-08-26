; AsmFlow — unbuffered process output helpers.
;
; The runtime does not use C stdio. Startup diagnostics, `--version`, `--help`,
; and the structured logger all go through af_write_all so that ordering is
; exact, no buffered bytes are lost on abnormal exit, and no FILE* state is
; shared with linked C libraries.

        bits 64
        default rel

%include "asmflow.inc"

        extern af_write_all
        extern af_cstr_len
        extern af_u64_to_dec

%define AF_FD_STDOUT 1
%define AF_FD_STDERR 2

        section .text

; ---------------------------------------------------------------------------
; af_out_cstr(int fd, const char *s) -> af_status
;
; Ownership: `s` is BORROWED.
; ---------------------------------------------------------------------------
        global af_out_cstr
af_out_cstr:
        AF_ENTER 0
        mov     rbx, rdi                ; fd
        mov     r12, rsi                ; s
        mov     rdi, r12
        call    af_cstr_len
        mov     rdx, rax
        mov     rdi, rbx
        mov     rsi, r12
        call    af_write_all
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_out_bytes(int fd, const void *p, size_t n) -> af_status
; ---------------------------------------------------------------------------
        global af_out_bytes
af_out_bytes:
        AF_ENTER 0
        call    af_write_all
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_out_u64(int fd, u64 value) -> af_status
; ---------------------------------------------------------------------------
        global af_out_u64
af_out_u64:
        AF_ENTER 48
        mov     rbx, rdi                ; fd
        mov     rdi, rsi                ; value
        lea     rsi, [rsp]              ; digit buffer
        mov     rdx, 32
        lea     rcx, [rsp + 32]         ; out_len slot
        call    af_u64_to_dec
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, [rsp + 32]
        call    af_write_all
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_out_i64(int fd, i64 value) -> af_status
; ---------------------------------------------------------------------------
        global af_out_i64
af_out_i64:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        test    r12, r12
        jns     .positive
        mov     rdi, rbx
        lea     rsi, [af_minus_sign]
        mov     rdx, 1
        call    af_write_all
        test    rax, rax
        js      .done
        neg     r12
.positive:
        mov     rdi, rbx
        mov     rsi, r12
        call    af_out_u64
.done:
        AF_LEAVE

        section .rodata
af_minus_sign: db "-"
