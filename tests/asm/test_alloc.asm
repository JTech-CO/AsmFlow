; AsmFlow — allocator wrapper and failure injection (HARNESS.md M2 DoD 5).

        bits 64
        default rel

%include "asmflow.inc"
%include "test.inc"

%define AF_TEST_TAG alloc

        extern af_alloc
        extern af_calloc
        extern af_realloc
        extern af_free
        extern af_alloc_size
        extern af_alloc_live_count
        extern af_alloc_live_byte_count
        extern af_alloc_attempt_count
        extern af_alloc_inject_failure_at
        extern af_alloc_reset_counters
        extern af_buf_init
        extern af_buf_append
        extern af_buf_len
        extern af_buf_data
        extern af_buf_free

        section .text

AF_TEST "alloc/round_trip_updates_the_live_counters"
        call    af_alloc_live_count
        mov     r14, rax                ; baseline

        mov     rdi, 128
        call    af_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "af_alloc returned NULL for a valid size"

        mov     rdi, rbx
        call    af_alloc_size
        mov     r12, rax
        AF_CHECK_EQ r12, 128, "the block header recorded the wrong payload size"

        call    af_alloc_live_count
        mov     r13, rax
        sub     r13, r14
        AF_CHECK_EQ r13, 1, "one live block should be outstanding"

        mov     rdi, rbx
        call    af_free
        call    af_alloc_live_count
        AF_CHECK_EQ rax, r14, "freeing should restore the baseline"
AF_TEST_END

AF_TEST "alloc/zero_size_is_rejected_rather_than_papered_over"
        mov     rdi, 0
        call    af_alloc
        AF_CHECK_EQ rax, 0, "a zero-size allocation must return NULL"
AF_TEST_END

AF_TEST "alloc/payload_is_sixteen_byte_aligned"
        mov     rdi, 1
        call    af_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "af_alloc returned NULL"
        mov     r12, rbx
        and     r12, 15
        AF_CHECK_EQ r12, 0, "the payload pointer was not 16-byte aligned"
        mov     rdi, rbx
        call    af_free
AF_TEST_END

AF_TEST "alloc/calloc_zeroes_and_checks_the_product"
        mov     rdi, 16
        mov     rsi, 8
        call    af_calloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "af_calloc returned NULL"

        xor     r12, r12
        xor     ecx, ecx
.scan:
        cmp     rcx, 128
        jae     .scanned
        movzx   eax, byte [rbx + rcx]
        or      r12, rax
        inc     rcx
        jmp     .scan
.scanned:
        AF_CHECK_EQ r12, 0, "af_calloc left non-zero bytes"
        mov     rdi, rbx
        call    af_free

        ; A product that overflows must fail rather than allocate a short block.
        mov     rdi, 0x100000000
        mov     rsi, 0x100000000
        call    af_calloc
        AF_CHECK_EQ rax, 0, "an overflowing product must return NULL"
AF_TEST_END

AF_TEST "alloc/realloc_preserves_contents_and_updates_the_size"
        mov     rdi, 16
        call    af_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "af_alloc returned NULL"
        mov     byte [rbx], 0x5A
        mov     byte [rbx + 15], 0xA5

        mov     rdi, rbx
        mov     rsi, 256
        call    af_realloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "af_realloc returned NULL"

        movzx   r12, byte [rbx]
        AF_CHECK_EQ r12, 0x5A, "af_realloc lost the first byte"
        movzx   r12, byte [rbx + 15]
        AF_CHECK_EQ r12, 0xA5, "af_realloc lost the last byte"

        mov     rdi, rbx
        call    af_alloc_size
        AF_CHECK_EQ rax, 256, "af_realloc did not record the new size"

        mov     rdi, rbx
        call    af_free
AF_TEST_END

AF_TEST "alloc/injection_fails_exactly_one_attempt"
        call    af_alloc_reset_counters
        mov     rdi, 1                  ; fail the very next attempt
        call    af_alloc_inject_failure_at

        mov     rdi, 64
        call    af_alloc
        AF_CHECK_EQ rax, 0, "the injected attempt should have failed"

        ; The injection point latches off, so the next attempt succeeds. Without
        ; that, a single injected failure would cascade and the unwind path
        ; under test would never actually run.
        mov     rdi, 64
        call    af_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "injection should not persist past one attempt"
        mov     rdi, rbx
        call    af_free
        call    af_alloc_reset_counters
AF_TEST_END

AF_TEST "alloc/injection_at_every_index_leaves_no_leak", 160
        ; Walk the injection point across the first eight allocation attempts of
        ; a buffer workload. Whatever fails, the workload must end with the same
        ; live-block count it started with (M2 DoD 5).
        call    af_alloc_live_count
        mov     r15, rax                ; baseline

        mov     r14, 1                  ; injection index
.next_index:
        call    af_alloc_reset_counters
        mov     rdi, r14
        call    af_alloc_inject_failure_at

        lea     rbx, [rsp + 96]         ; af_buffer
        mov     rdi, rbx
        mov     rsi, 65536
        call    af_buf_init

        mov     r13, 0                  ; append round
.append:
        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, 64
        call    af_buf_append
        inc     r13
        cmp     r13, 8
        jb      .append

        mov     rdi, rbx
        call    af_buf_free

        call    af_alloc_live_count
        AF_CHECK_EQ rax, r15, "an injected allocation failure leaked a block"

        inc     r14
        cmp     r14, 9
        jb      .next_index

        call    af_alloc_reset_counters
AF_TEST_END

AF_TEST "alloc/failed_append_leaves_the_buffer_unchanged", 128
        lea     rbx, [rsp + 64]
        mov     rdi, rbx
        mov     rsi, 65536
        call    af_buf_init
        AF_CHECK_OK rax, "af_buf_init failed"

        call    af_alloc_reset_counters
        mov     rdi, 1
        call    af_alloc_inject_failure_at

        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, 32
        call    af_buf_append
        AF_CHECK_ERR rax, AF_E_NOMEM, "the append should have reported AF_E_NOMEM"

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "a failed append must not change the length"
        mov     rdi, rbx
        call    af_buf_data
        AF_CHECK_EQ rax, 0, "a failed append must not install a data pointer"

        call    af_alloc_reset_counters
        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END
