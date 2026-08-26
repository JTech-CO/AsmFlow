; AsmFlow — request-scoped arena (HARNESS.md M2 DoD 6).
;
; The use-after-finalize case is not testable in-process: it is designed to end
; the process. tests/test_asm_crash.py drives it through the runner's --crash
; mode and asserts the process actually dies.

        bits 64
        default rel

%include "asmflow.inc"
%include "test.inc"

%define AF_TEST_TAG arena

        extern af_arena_init
        extern af_arena_alloc
        extern af_arena_calloc
        extern af_arena_reset
        extern af_arena_finalize
        extern af_arena_total_bytes
        extern af_arena_alloc_count
        extern af_alloc_live_count

%define ARENA_BYTES 64

        section .text

AF_TEST "arena/init_validates_its_arguments", 128
        lea     rbx, [rsp]
        mov     rdi, 0
        mov     rsi, 4096
        mov     rdx, 65536
        call    af_arena_init
        AF_CHECK_ERR rax, AF_E_INVALID, "a NULL arena must be rejected"

        mov     rdi, rbx
        mov     rsi, 4096
        mov     rdx, 0
        call    af_arena_init
        AF_CHECK_ERR rax, AF_E_INVALID, "a zero ceiling must be rejected"
AF_TEST_END

AF_TEST "arena/allocations_are_aligned_and_distinct", 128
        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, 4096
        mov     rdx, 1048576
        call    af_arena_init
        AF_CHECK_OK rax, "af_arena_init failed"

        mov     rdi, rbx
        mov     rsi, 1
        mov     rdx, 8
        call    af_arena_alloc
        mov     r12, rax
        AF_CHECK_NE r12, 0, "the first arena allocation failed"
        mov     r13, r12
        and     r13, 7
        AF_CHECK_EQ r13, 0, "an 8-byte aligned request was not 8-byte aligned"

        mov     rdi, rbx
        mov     rsi, 1
        mov     rdx, 64
        call    af_arena_alloc
        mov     r13, rax
        AF_CHECK_NE r13, 0, "the 64-byte aligned allocation failed"
        mov     r14, r13
        and     r14, 63
        AF_CHECK_EQ r14, 0, "a 64-byte aligned request was not 64-byte aligned"
        AF_CHECK_NE r13, r12, "two allocations returned the same address"

        mov     rdi, rbx
        call    af_arena_alloc_count
        AF_CHECK_EQ rax, 2, "the allocation counter is wrong"

        mov     rdi, rbx
        call    af_arena_finalize
AF_TEST_END

AF_TEST "arena/zero_size_and_null_arena_are_refused", 128
        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, 4096
        mov     rdx, 65536
        call    af_arena_init

        mov     rdi, rbx
        mov     rsi, 0
        mov     rdx, 8
        call    af_arena_alloc
        AF_CHECK_EQ rax, 0, "a zero-size arena allocation must return NULL"

        mov     rdi, 0
        mov     rsi, 8
        mov     rdx, 8
        call    af_arena_alloc
        AF_CHECK_EQ rax, 0, "a NULL arena must return NULL"

        mov     rdi, rbx
        call    af_arena_finalize
AF_TEST_END

AF_TEST "arena/growth_spans_chunks_and_respects_the_ceiling", 128
        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, 4096               ; small chunks force several of them
        mov     rdx, 32768              ; ceiling
        call    af_arena_init
        AF_CHECK_OK rax, "af_arena_init failed"

        mov     r13, 0
.fill:
        mov     rdi, rbx
        mov     rsi, 512
        mov     rdx, 8
        call    af_arena_alloc
        test    rax, rax
        jz      .exhausted
        inc     r13
        cmp     r13, 1000
        jb      .fill
.exhausted:
        AF_CHECK_TRUE r13, "no allocation succeeded at all"

        mov     rdi, rbx
        call    af_arena_total_bytes
        mov     r14, rax
        mov     r15, 32768
        AF_CHECK_TRUE r14, "the arena reserved nothing"
        cmp     r14, r15
        jbe     .within
        AF_CHECK_EQ r14, r15, "the arena exceeded its ceiling"
.within:
        ; The next allocation must keep failing rather than intermittently
        ; succeeding once the ceiling is reached.
        mov     rdi, rbx
        mov     rsi, 512
        mov     rdx, 8
        call    af_arena_alloc
        AF_CHECK_EQ rax, 0, "the arena allocated past its ceiling"

        mov     rdi, rbx
        call    af_arena_finalize
AF_TEST_END

AF_TEST "arena/single_allocation_larger_than_a_chunk", 128
        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, 4096
        mov     rdx, 1048576
        call    af_arena_init

        mov     rdi, rbx
        mov     rsi, 100000             ; far larger than one chunk
        mov     rdx, 8
        call    af_arena_alloc
        mov     r12, rax
        AF_CHECK_NE r12, 0, "an oversized single allocation should still succeed"

        ; Prove the whole span is writable.
        mov     byte [r12], 1
        mov     byte [r12 + 99999], 2
        movzx   r13, byte [r12]
        AF_CHECK_EQ r13, 1, "the start of the oversized block is not writable"
        movzx   r13, byte [r12 + 99999]
        AF_CHECK_EQ r13, 2, "the end of the oversized block is not writable"

        mov     rdi, rbx
        call    af_arena_finalize
AF_TEST_END

AF_TEST "arena/calloc_zeroes_and_reset_reuses", 128
        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, 4096
        mov     rdx, 1048576
        call    af_arena_init

        mov     rdi, rbx
        mov     rsi, 32
        mov     rdx, 8
        call    af_arena_calloc
        mov     r12, rax
        AF_CHECK_NE r12, 0, "af_arena_calloc failed"

        xor     r13, r13
        xor     ecx, ecx
.scan:
        cmp     rcx, 256
        jae     .scanned
        movzx   eax, byte [r12 + rcx]
        or      r13, rax
        inc     rcx
        jmp     .scan
.scanned:
        AF_CHECK_EQ r13, 0, "af_arena_calloc left non-zero bytes"

        mov     rdi, rbx
        call    af_arena_reset
        mov     rdi, rbx
        call    af_arena_total_bytes
        AF_CHECK_EQ rax, 0, "reset should release every chunk"
        mov     rdi, rbx
        call    af_arena_alloc_count
        AF_CHECK_EQ rax, 0, "reset should clear the allocation counter"

        ; The arena stays usable after a reset.
        mov     rdi, rbx
        mov     rsi, 16
        mov     rdx, 8
        call    af_arena_alloc
        AF_CHECK_NE rax, 0, "the arena should be usable after a reset"

        mov     rdi, rbx
        call    af_arena_finalize
AF_TEST_END

AF_TEST "arena/finalize_releases_every_chunk", 128
        call    af_alloc_live_count
        mov     r15, rax

        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, 4096
        mov     rdx, 1048576
        call    af_arena_init

        mov     r13, 0
.fill:
        mov     rdi, rbx
        mov     rsi, 500
        mov     rdx, 8
        call    af_arena_alloc
        AF_CHECK_NE rax, 0, "arena allocation failed while filling"
        inc     r13
        cmp     r13, 50
        jb      .fill

        mov     rdi, rbx
        call    af_arena_finalize
        call    af_alloc_live_count
        AF_CHECK_EQ rax, r15, "finalize left chunks allocated"
AF_TEST_END
