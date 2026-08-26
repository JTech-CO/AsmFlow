; AsmFlow — deliberately fatal scenarios.
;
; Some invariants are enforced by ending the process: a use-after-finalize
; arena, a double free, a corrupted allocation header. Those cannot be asserted
; from inside the test binary that they kill, so each one lives here behind an
; identifier and is driven from tests/test_asm_crash.py, which runs the binary
; as a child and asserts it died the way it was supposed to.
;
; A scenario that returns normally is itself a failure: it means the guard that
; was supposed to catch the violation is gone.

        bits 64
        default rel

%include "asmflow.inc"

        extern af_arena_init
        extern af_arena_alloc
        extern af_arena_finalize
        extern af_arena_set_guard_mode
        extern af_alloc
        extern af_free
        extern af_out_bytes
        extern af_sys_exit_group

%define AF_FD_STDOUT 1
%define AF_FD_STDERR 2

%define CRASH_ARENA_ALLOC_AFTER_FINALIZE 1
%define CRASH_ARENA_READ_AFTER_FINALIZE  2
%define CRASH_DOUBLE_FREE                3
%define CRASH_FREE_BAD_POINTER           4

        section .rodata
msg_survived: db "crash scenario returned without dying", 10
msg_survived_len equ $ - msg_survived
msg_unknown: db "unknown crash scenario", 10
msg_unknown_len equ $ - msg_unknown

        section .text

; ---------------------------------------------------------------------------
; af_test_run_crash(u64 scenario) -> does not return on success
;
; Exits with status 20 if the scenario failed to trigger, which the Python
; driver treats as a failed test rather than a pass.
; ---------------------------------------------------------------------------
        global af_test_run_crash
af_test_run_crash:
        AF_ENTER 96
        mov     rbx, rdi

        cmp     rbx, CRASH_ARENA_ALLOC_AFTER_FINALIZE
        je      .alloc_after_finalize
        cmp     rbx, CRASH_ARENA_READ_AFTER_FINALIZE
        je      .read_after_finalize
        cmp     rbx, CRASH_DOUBLE_FREE
        je      .double_free
        cmp     rbx, CRASH_FREE_BAD_POINTER
        je      .free_bad_pointer

        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_unknown]
        mov     rdx, msg_unknown_len
        call    af_out_bytes
        mov     edi, 21
        call    af_sys_exit_group

; Allocating from a finalized arena is a programming error the debug build
; refuses to tolerate.
.alloc_after_finalize:
        lea     r12, [rsp]
        mov     rdi, r12
        mov     rsi, 4096
        mov     rdx, 1048576
        call    af_arena_init
        mov     rdi, r12
        mov     rsi, 64
        mov     rdx, 8
        call    af_arena_alloc
        mov     rdi, r12
        call    af_arena_finalize
        mov     rdi, r12
        mov     rsi, 64
        mov     rdx, 8
        call    af_arena_alloc          ; must not return
        jmp     .survived

; Holding a pointer past finalization is the mistake guard mode exists to catch:
; the chunk's pages are revoked, so the first touch faults at the address the
; caller was actually handed.
.read_after_finalize:
        mov     rdi, 1
        call    af_arena_set_guard_mode
        lea     r12, [rsp]
        mov     rdi, r12
        mov     rsi, 4096
        mov     rdx, 1048576
        call    af_arena_init
        mov     rdi, r12
        mov     rsi, 64
        mov     rdx, 8
        call    af_arena_alloc
        mov     r13, rax                ; the pointer that must not survive
        mov     byte [r13], 1           ; writable before finalization
        mov     rdi, r12
        call    af_arena_finalize
        movzx   eax, byte [r13]         ; must fault
        mov     [rsp + 64], rax
        jmp     .survived

.double_free:
        mov     rdi, 64
        call    af_alloc
        mov     r12, rax
        mov     rdi, r12
        call    af_free
        mov     rdi, r12
        call    af_free                 ; must not return
        jmp     .survived

.free_bad_pointer:
        lea     rdi, [rsp + 64]         ; stack memory, never allocated
        call    af_free                 ; must not return
        jmp     .survived

.survived:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_survived]
        mov     rdx, msg_survived_len
        call    af_out_bytes
        mov     edi, 20
        call    af_sys_exit_group
        ud2
