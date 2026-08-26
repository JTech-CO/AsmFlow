; AsmFlow — bounded buffer behaviour (HARNESS.md M2 DoD 4).

        bits 64
        default rel

%include "asmflow.inc"
%include "test.inc"

%define AF_TEST_TAG buffer

        extern af_buf_init
        extern af_buf_free
        extern af_buf_clear
        extern af_buf_reserve
        extern af_buf_append
        extern af_buf_append_byte
        extern af_buf_append_cstr
        extern af_buf_append_u64
        extern af_buf_consume
        extern af_buf_take
        extern af_buf_data
        extern af_buf_len
        extern af_buf_cap
        extern af_buf_max
        extern af_free
        extern af_mem_eq

%define U64_MAX 0xFFFFFFFFFFFFFFFF

        section .rodata
lorem:      db "the quick brown fox", 0
lorem_len   equ 19
prefix_abc: db "abc"
suffix_def: db "def"

        section .text

AF_TEST "buffer/init_rejects_a_zero_maximum", 64
        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, 0
        call    af_buf_init
        AF_CHECK_ERR rax, AF_E_INVALID, "zero must not be accepted as unlimited"
AF_TEST_END

AF_TEST "buffer/append_boundary_minus_one_boundary_plus_one", 64
        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, 16                 ; ceiling
        call    af_buf_init
        AF_CHECK_OK rax, "af_buf_init failed"

        ; boundary - 1
        mov     rdi, rbx
        lea     rsi, [prefix_abc]
        mov     rdx, 3
        call    af_buf_append
        AF_CHECK_OK rax, "appending below the ceiling should succeed"

        ; up to exactly the boundary
        mov     r13, 0
.fill:
        mov     rdi, rbx
        mov     rsi, 'x'
        call    af_buf_append_byte
        AF_CHECK_OK rax, "filling to the ceiling should succeed"
        inc     r13
        cmp     r13, 13
        jb      .fill

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 16, "the buffer should sit exactly at its ceiling"

        ; boundary + 1
        mov     rdi, rbx
        mov     rsi, 'y'
        call    af_buf_append_byte
        AF_CHECK_ERR rax, AF_E_LIMIT, "one byte past the ceiling must be refused"

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 16, "a refused append must not change the length"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "buffer/reserve_reports_overflow_separately_from_limit", 64
        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, U64_MAX
        call    af_buf_init
        AF_CHECK_OK rax, "af_buf_init failed"

        mov     rdi, rbx
        mov     rsi, 'a'
        call    af_buf_append_byte
        AF_CHECK_OK rax, "the first byte should append"

        ; len is 1, so len + (2^64 - 1) wraps: that is overflow, not a limit.
        mov     rdi, rbx
        mov     rsi, U64_MAX
        call    af_buf_reserve
        AF_CHECK_ERR rax, AF_E_OVERFLOW, "a wrapping reservation must report overflow"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "buffer/append_zero_bytes_is_a_no_op", 64
        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, 1024
        call    af_buf_init

        mov     rdi, rbx
        xor     esi, esi                ; NULL source
        xor     edx, edx                ; zero length
        call    af_buf_append
        AF_CHECK_OK rax, "appending nothing should succeed even with a NULL source"

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "appending nothing should not change the length"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "buffer/contents_survive_growth", 128
        lea     rbx, [rsp + 64]
        mov     rdi, rbx
        mov     rsi, 65536
        call    af_buf_init

        mov     r13, 0
.rounds:
        mov     rdi, rbx
        lea     rsi, [lorem]
        mov     rdx, lorem_len
        call    af_buf_append
        AF_CHECK_OK rax, "append during growth failed"
        inc     r13
        cmp     r13, 100
        jb      .rounds

        mov     rdi, rbx
        call    af_buf_len
        mov     r14, rax
        mov     r15, lorem_len * 100
        AF_CHECK_EQ r14, r15, "the accumulated length is wrong"

        ; Spot-check the first and last copies.
        mov     rdi, rbx
        call    af_buf_data
        mov     r12, rax
        mov     rdi, r12
        lea     rsi, [lorem]
        mov     rdx, lorem_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the first copy was corrupted by growth"

        mov     rdi, r12
        add     rdi, lorem_len * 99
        lea     rsi, [lorem]
        mov     rdx, lorem_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the last copy was corrupted by growth"

        mov     rdi, rbx
        call    af_buf_cap
        mov     r12, rax
        AF_CHECK_TRUE r12, "capacity should be non-zero after growth"

        mov     rdi, rbx
        call    af_buf_free
        mov     rdi, rbx
        call    af_buf_data
        AF_CHECK_EQ rax, 0, "af_buf_free should clear the data pointer"
AF_TEST_END

AF_TEST "buffer/consume_shifts_the_remainder", 128
        lea     rbx, [rsp + 64]
        mov     rdi, rbx
        mov     rsi, 1024
        call    af_buf_init

        mov     rdi, rbx
        lea     rsi, [prefix_abc]
        mov     rdx, 3
        call    af_buf_append
        mov     rdi, rbx
        lea     rsi, [suffix_def]
        mov     rdx, 3
        call    af_buf_append

        mov     rdi, rbx
        mov     rsi, 3
        call    af_buf_consume
        AF_CHECK_OK rax, "consuming the parsed prefix should succeed"

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 3, "consume should leave the remainder length"

        mov     rdi, rbx
        call    af_buf_data
        mov     rdi, rax
        lea     rsi, [suffix_def]
        mov     rdx, 3
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "consume should shift the remainder to the front"

        ; consuming everything
        mov     rdi, rbx
        mov     rsi, 3
        call    af_buf_consume
        AF_CHECK_OK rax, "consuming the remainder should succeed"
        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "the buffer should be empty"

        ; consuming past the end is a range error, not a silent clamp
        mov     rdi, rbx
        mov     rsi, 1
        call    af_buf_consume
        AF_CHECK_ERR rax, AF_E_RANGE, "over-consuming must report a range error"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "buffer/take_transfers_ownership_and_resets", 128
        lea     rbx, [rsp + 64]
        mov     rdi, rbx
        mov     rsi, 1024
        call    af_buf_init

        mov     rdi, rbx
        lea     rsi, [lorem]
        mov     rdx, lorem_len
        call    af_buf_append

        mov     rdi, rbx
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_buf_take
        AF_CHECK_OK rax, "af_buf_take failed"

        mov     r12, [rsp]              ; transferred pointer
        mov     r13, [rsp + 8]          ; transferred length
        AF_CHECK_NE r12, 0, "af_buf_take returned a NULL pointer"
        AF_CHECK_EQ r13, lorem_len, "af_buf_take returned the wrong length"

        mov     rdi, r12
        lea     rsi, [lorem]
        mov     rdx, lorem_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the transferred payload is wrong"

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "af_buf_take should leave the buffer empty"
        mov     rdi, rbx
        call    af_buf_cap
        AF_CHECK_EQ rax, 0, "af_buf_take should leave no capacity behind"

        ; The caller now owns the block.
        mov     rdi, r12
        call    af_free
        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "buffer/append_u64_and_cstr", 128
        lea     rbx, [rsp + 64]
        mov     rdi, rbx
        mov     rsi, 1024
        call    af_buf_init

        mov     rdi, rbx
        mov     rsi, 0
        call    af_buf_append_u64
        AF_CHECK_OK rax, "appending zero failed"

        mov     rdi, rbx
        mov     rsi, 18446744073709551615
        call    af_buf_append_u64
        AF_CHECK_OK rax, "appending the maximum failed"

        mov     rdi, rbx
        call    af_buf_len
        ; "0" plus the 20 digits of 2^64-1
        AF_CHECK_EQ rax, 21, "the decimal rendering has the wrong length"

        mov     rdi, rbx
        call    af_buf_data
        mov     r12, rax
        movzx   r13, byte [r12]
        AF_CHECK_EQ r13, '0', "zero should render as a single '0'"
        movzx   r13, byte [r12 + 1]
        AF_CHECK_EQ r13, '1', "2^64-1 should start with '1'"
        movzx   r13, byte [r12 + 20]
        AF_CHECK_EQ r13, '5', "2^64-1 should end with '5'"

        mov     rdi, rbx
        call    af_buf_clear
        mov     rdi, rbx
        lea     rsi, [lorem]
        call    af_buf_append_cstr
        AF_CHECK_OK rax, "appending a C string failed"
        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, lorem_len, "the C string length is wrong"

        ; A NULL C string appends nothing rather than faulting.
        mov     rdi, rbx
        xor     esi, esi
        call    af_buf_append_cstr
        AF_CHECK_OK rax, "a NULL C string should append nothing"
        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, lorem_len, "a NULL C string changed the length"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "buffer/free_is_idempotent", 64
        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, 1024
        call    af_buf_init
        mov     rdi, rbx
        mov     rsi, 'z'
        call    af_buf_append_byte

        mov     rdi, rbx
        call    af_buf_free
        mov     rdi, rbx
        call    af_buf_free
        mov     rdi, rbx
        call    af_buf_free
        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "repeated frees should leave an empty buffer"
AF_TEST_END
