; AsmFlow — checked size arithmetic (HARNESS.md M2 DoD 4).
;
; Every case is a boundary: max-1, max, max+1. TEST_STRATEGY.md 3 requires that
; shape for every limit in the system, and this is where the shape is
; established.

        bits 64
        default rel

%include "asmflow.inc"
%include "test.inc"

%define AF_TEST_TAG checked

        extern af_add_size
        extern af_sub_size
        extern af_mul_size
        extern af_add_size3
        extern af_grow_size
        extern af_align_up

%define U64_MAX 0xFFFFFFFFFFFFFFFF

        section .text

AF_TEST "checked/add_size_boundaries"
        ; below the boundary
        mov     rdi, U64_MAX
        dec     rdi
        mov     rsi, 1
        lea     rdx, [rsp]
        call    af_add_size
        AF_CHECK_OK rax, "max-1 + 1 should succeed"
        mov     rbx, [rsp]
        mov     r12, U64_MAX
        AF_CHECK_EQ rbx, r12, "max-1 + 1 produced the wrong sum"

        ; exactly at the boundary
        mov     rdi, U64_MAX
        mov     rsi, 0
        lea     rdx, [rsp]
        call    af_add_size
        AF_CHECK_OK rax, "max + 0 should succeed"

        ; one past the boundary
        mov     rdi, U64_MAX
        mov     rsi, 1
        mov     qword [rsp], 0xDEAD
        lea     rdx, [rsp]
        call    af_add_size
        AF_CHECK_ERR rax, AF_E_OVERFLOW, "max + 1 must report overflow"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 0xDEAD, "a failed add must not write its out-parameter"
AF_TEST_END

AF_TEST "checked/sub_size_rejects_underflow"
        mov     rdi, 5
        mov     rsi, 5
        lea     rdx, [rsp]
        call    af_sub_size
        AF_CHECK_OK rax, "5 - 5 should succeed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 0, "5 - 5 should be 0"

        mov     rdi, 5
        mov     rsi, 6
        mov     qword [rsp], 0xBEEF
        lea     rdx, [rsp]
        call    af_sub_size
        AF_CHECK_ERR rax, AF_E_OVERFLOW, "5 - 6 must report underflow"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 0xBEEF, "a failed subtract must not write its out-parameter"
AF_TEST_END

AF_TEST "checked/mul_size_boundaries"
        mov     rdi, 0
        mov     rsi, U64_MAX
        lea     rdx, [rsp]
        call    af_mul_size
        AF_CHECK_OK rax, "0 * max should succeed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 0, "0 * max should be 0"

        ; 2^32 * 2^31 fits; 2^32 * 2^32 does not.
        mov     rdi, 0x100000000
        mov     rsi, 0x80000000
        lea     rdx, [rsp]
        call    af_mul_size
        AF_CHECK_OK rax, "2^32 * 2^31 should fit"

        mov     rdi, 0x100000000
        mov     rsi, 0x100000000
        mov     qword [rsp], 0xF00D
        lea     rdx, [rsp]
        call    af_mul_size
        AF_CHECK_ERR rax, AF_E_OVERFLOW, "2^32 * 2^32 must report overflow"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 0xF00D, "a failed multiply must not write its out-parameter"
AF_TEST_END

AF_TEST "checked/add_size3_detects_overflow_in_either_step"
        mov     rdi, 1
        mov     rsi, 2
        mov     rdx, 3
        lea     rcx, [rsp]
        call    af_add_size3
        AF_CHECK_OK rax, "1 + 2 + 3 should succeed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 6, "1 + 2 + 3 should be 6"

        ; overflow in the first addition
        mov     rdi, U64_MAX
        mov     rsi, 1
        mov     rdx, 0
        lea     rcx, [rsp]
        call    af_add_size3
        AF_CHECK_ERR rax, AF_E_OVERFLOW, "overflow in the first step must be caught"

        ; overflow only in the second addition
        mov     rdi, U64_MAX
        mov     rsi, 0
        mov     rdx, 1
        lea     rcx, [rsp]
        call    af_add_size3
        AF_CHECK_ERR rax, AF_E_OVERFLOW, "overflow in the second step must be caught"
AF_TEST_END

AF_TEST "checked/grow_size_doubles_then_clamps"
        ; first growth from empty uses the floor, not zero
        mov     rdi, 0
        mov     rsi, 1
        mov     rdx, 1048576
        lea     rcx, [rsp]
        call    af_grow_size
        AF_CHECK_OK rax, "growing from empty should succeed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 64, "the first growth should use the 64-byte floor"

        ; doubling
        mov     rdi, 100
        mov     rsi, 150
        mov     rdx, 1048576
        lea     rcx, [rsp]
        call    af_grow_size
        AF_CHECK_OK rax, "doubling should succeed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 200, "100 should double to 200"

        ; doubling is not enough, so the requirement wins
        mov     rdi, 100
        mov     rsi, 500
        mov     rdx, 1048576
        lea     rcx, [rsp]
        call    af_grow_size
        AF_CHECK_OK rax, "growing to the requirement should succeed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 500, "the requirement should win over doubling"

        ; clamped to max rather than refused
        mov     rdi, 600
        mov     rsi, 700
        mov     rdx, 1000
        lea     rcx, [rsp]
        call    af_grow_size
        AF_CHECK_OK rax, "growth past max should clamp, not fail"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 1000, "growth should clamp to max"

        ; the requirement itself exceeds max
        mov     rdi, 600
        mov     rsi, 1001
        mov     rdx, 1000
        lea     rcx, [rsp]
        call    af_grow_size
        AF_CHECK_ERR rax, AF_E_LIMIT, "a requirement past max must report the limit"
AF_TEST_END

AF_TEST "checked/align_up_rejects_bad_alignment_and_overflow"
        mov     rdi, 0
        mov     rsi, 8
        lea     rdx, [rsp]
        call    af_align_up
        AF_CHECK_OK rax, "aligning zero should succeed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 0, "zero is already aligned"

        mov     rdi, 1
        mov     rsi, 8
        lea     rdx, [rsp]
        call    af_align_up
        AF_CHECK_OK rax, "aligning one should succeed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 8, "1 should round up to 8"

        mov     rdi, 8
        mov     rsi, 8
        lea     rdx, [rsp]
        call    af_align_up
        AF_CHECK_OK rax, "an already-aligned value should succeed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 8, "8 should stay 8"

        mov     rdi, 1
        mov     rsi, 0
        lea     rdx, [rsp]
        call    af_align_up
        AF_CHECK_ERR rax, AF_E_INVALID, "zero alignment must be rejected"

        mov     rdi, 1
        mov     rsi, 6
        lea     rdx, [rsp]
        call    af_align_up
        AF_CHECK_ERR rax, AF_E_INVALID, "a non-power-of-two alignment must be rejected"

        mov     rdi, U64_MAX
        mov     rsi, 16
        lea     rdx, [rsp]
        call    af_align_up
        AF_CHECK_ERR rax, AF_E_OVERFLOW, "rounding past the top must report overflow"
AF_TEST_END
