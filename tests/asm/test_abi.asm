; AsmFlow — ABI conformance tests (HARNESS.md M2 DoD 1-3).

        bits 64
        default rel

%include "asmflow.inc"
%include "test.inc"

%define AF_TEST_TAG abi

        extern af_abi_probe_alignment
        extern af_abi_call
        extern af_abi_call_result
        extern af_abi_bad_callee
        extern af_abi_good_callee
        extern af_abi_alignment_at_locals

        extern af_ffi_check_args
        extern af_ffi_check_variadic
        extern af_ffi_struct_offsets_match

        extern af_cstr_len
        extern af_mem_eq
        extern af_add_size
        extern af_buf_init
        extern af_buf_append
        extern af_buf_free

        section .rodata
sample_text: db "abi-sample", 0

        section .text

; ---------------------------------------------------------------------------
; The AF_ENTER macro must leave rsp 16-byte aligned for every local size, not
; only the multiples of 16 that happen to appear in today's call sites.
; ---------------------------------------------------------------------------
AF_TEST "abi/enter_aligns_stack_for_every_local_size"
        xor     ebx, ebx
.loop:
        mov     rdi, rbx
        call    af_abi_alignment_at_locals
        mov     r12, rax
        AF_CHECK_EQ r12, 0, "AF_ENTER left rsp misaligned before a call"
        inc     rbx
        cmp     rbx, 12
        jb      .loop
AF_TEST_END

; ---------------------------------------------------------------------------
; A probe that never reports corruption proves nothing, so the harness is
; checked against a function that is deliberately wrong.
; ---------------------------------------------------------------------------
AF_TEST "abi/probe_detects_a_non_conforming_callee"
        lea     rdi, [af_abi_bad_callee]
        lea     rsi, [rsp]
        mov     qword [rsp], 0
        mov     qword [rsp + 8], 0
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 24], 0
        mov     qword [rsp + 32], 0
        mov     qword [rsp + 40], 0
        call    af_abi_call
        mov     rbx, rax
        ; bit0 rbx, bit2 r13, bit4 r15 = 1 + 4 + 16
        AF_CHECK_EQ rbx, 21, "harness did not report the expected clobbers"
AF_TEST_END

; ---------------------------------------------------------------------------
; A conforming callee must come back clean, and must have received its six
; arguments in the System V order.
; ---------------------------------------------------------------------------
AF_TEST "abi/conforming_callee_preserves_registers_and_argument_order"
        mov     qword [rsp], 1
        mov     qword [rsp + 8], 2
        mov     qword [rsp + 16], 4
        mov     qword [rsp + 24], 8
        mov     qword [rsp + 32], 16
        mov     qword [rsp + 40], 32
        lea     rdi, [af_abi_good_callee]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 48]
        call    af_abi_call_result
        mov     rbx, rax
        mov     r12, [rsp + 48]
        AF_CHECK_EQ rbx, 0, "conforming callee reported register corruption"
        AF_CHECK_EQ r12, 63, "arguments did not arrive in rdi,rsi,rdx,rcx,r8,r9"
AF_TEST_END

; ---------------------------------------------------------------------------
; Representative exported functions, exercised through the harness so that
; register preservation is proven dynamically and not only by inspection.
; scripts/abi_audit.py covers the remaining exports statically.
; ---------------------------------------------------------------------------
AF_TEST "abi/exported_primitives_preserve_callee_saved_registers"
        ; af_cstr_len(sample_text)
        lea     rax, [sample_text]
        mov     [rsp], rax
        mov     qword [rsp + 8], 0
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 24], 0
        mov     qword [rsp + 32], 0
        mov     qword [rsp + 40], 0
        lea     rdi, [af_cstr_len]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 48]
        call    af_abi_call_result
        AF_CHECK_EQ rax, 0, "af_cstr_len corrupted a callee-saved register"
        mov     rbx, [rsp + 48]
        AF_CHECK_EQ rbx, 10, "af_cstr_len returned the wrong length"

        ; af_add_size(7, 9, &out)
        mov     qword [rsp], 7
        mov     qword [rsp + 8], 9
        lea     rax, [rsp + 56]
        mov     [rsp + 16], rax
        lea     rdi, [af_add_size]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 48]
        call    af_abi_call_result
        AF_CHECK_EQ rax, 0, "af_add_size corrupted a callee-saved register"
        mov     rbx, [rsp + 56]
        AF_CHECK_EQ rbx, 16, "af_add_size produced the wrong sum"

        ; af_mem_eq(sample_text, sample_text, 10)
        lea     rax, [sample_text]
        mov     [rsp], rax
        mov     [rsp + 8], rax
        mov     qword [rsp + 16], 10
        lea     rdi, [af_mem_eq]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 48]
        call    af_abi_call_result
        AF_CHECK_EQ rax, 0, "af_mem_eq corrupted a callee-saved register"
        mov     rbx, [rsp + 48]
        AF_CHECK_EQ rbx, 1, "af_mem_eq did not report equality"
AF_TEST_END

; ---------------------------------------------------------------------------
; asm -> C direction: argument order, widths, stack arguments, and the variadic
; vector-register count in al.
; ---------------------------------------------------------------------------
AF_TEST "abi/assembly_calls_c_with_correct_arguments"
        mov     rdi, 1
        mov     rsi, 2
        mov     rdx, 3
        mov     rcx, 4
        mov     r8, 5
        mov     r9, 6
        ; Two stack arguments. Pushing 16 bytes keeps rsp 16-byte aligned, so
        ; the call site stays conforming.
        sub     rsp, 16
        mov     qword [rsp], 7
        mov     qword [rsp + 8], 8
        xor     eax, eax
        call    af_ffi_check_args wrt ..plt
        add     rsp, 16
        mov     rbx, rax
        AF_CHECK_EQ rbx, 1, "C callee did not receive the expected arguments"
AF_TEST_END

AF_TEST "abi/assembly_calls_a_variadic_c_function"
        mov     rdi, 3                  ; argument count
        mov     rsi, 100
        mov     rdx, 200
        mov     rcx, 300
        xor     eax, eax                ; no vector registers used
        call    af_ffi_check_variadic wrt ..plt
        mov     rbx, rax
        AF_CHECK_EQ rbx, 600, "variadic C call returned the wrong total"
AF_TEST_END

; ---------------------------------------------------------------------------
; Structure offsets are duplicated between assembly and the C ABI manifest.
; They are asserted equal here so that a layout change in one has to be made in
; the other before the tests pass.
; ---------------------------------------------------------------------------
AF_TEST "abi/struct_offsets_agree_between_assembly_and_c"
        call    af_ffi_struct_offsets_match wrt ..plt
        mov     rbx, rax
        AF_CHECK_EQ rbx, 0, "assembly and C disagree about a structure layout"
AF_TEST_END

; ---------------------------------------------------------------------------
; A C callback boundary in practice: a buffer is filled through the assembly API
; while sentinels sit in callee-saved registers, which is the shape every
; libcurl and llhttp callback will take.
; ---------------------------------------------------------------------------
AF_TEST "abi/buffer_api_survives_a_callback_style_call", 128
        lea     rbx, [rsp + 64]         ; af_buffer
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "af_buf_init failed"

        mov     [rsp], rbx
        lea     rax, [sample_text]
        mov     [rsp + 8], rax
        mov     qword [rsp + 16], 10
        mov     qword [rsp + 24], 0
        mov     qword [rsp + 32], 0
        mov     qword [rsp + 40], 0
        lea     rdi, [af_buf_append]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 48]
        call    af_abi_call_result
        AF_CHECK_EQ rax, 0, "af_buf_append corrupted a callee-saved register"
        mov     r12, [rsp + 48]
        AF_CHECK_OK r12, "af_buf_append failed"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END
