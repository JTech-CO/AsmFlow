; AsmFlow — heap allocation wrapper.
;
; Every heap allocation in the runtime goes through this file. That gives three
; things the raw libc calls cannot:
;
;   * a live-allocation counter, so the unit-test runner can fail any test that
;     leaks even a single block without waiting for Valgrind;
;   * deterministic allocation-failure injection, which is what M2 DoD 5 tests
;     ("inject an allocation failure at index N and prove there is no double
;     free, leak, or state corruption");
;   * a single place where an allocation size is checked before it reaches the
;     allocator.
;
; The daemon is single-threaded by design (ADR 0002), so the counters are plain
; globals with no synchronisation.
;
; Ownership vocabulary used throughout: a pointer returned by af_alloc,
; af_calloc, or af_realloc is TRANSFERRED to the caller and must be released
; exactly once with af_free.

        bits 64
        default rel

%include "asmflow.inc"

        extern malloc
        extern realloc
        extern free
        extern af_mem_zero
        extern af_mul_size
        extern af_panic

        section .data

; Failure injection. `fail_at` counts allocation attempts; when it reaches zero
; the next attempt fails and the counter latches at -1 (disabled) so a single
; injected failure does not cascade into every later allocation.
af_alloc_fail_at:       dq -1
af_alloc_attempts:      dq 0
af_alloc_live_blocks:   dq 0
af_alloc_live_bytes:    dq 0
af_alloc_total_blocks:  dq 0
af_alloc_failures:      dq 0

        section .rodata
msg_free_underflow: db "af_free: live block counter underflow", 0
msg_bad_header:     db "af_free: allocation header magic mismatch", 0

; Each block carries a 16-byte header so that af_free can maintain the live-byte
; count and detect a pointer that did not come from this allocator. The header
; is deliberately checked in every build, not only debug: a corrupted header
; means memory is already being written out of bounds, and continuing would turn
; a contained defect into arbitrary heap corruption.
%define AF_ALLOC_MAGIC 0x41534d464c4f5721   ; "ASMFLOW!"
%define AF_ALLOC_HDR   16

        section .text

; ---------------------------------------------------------------------------
; af_alloc_should_fail() -> i64 (1 = fail this attempt)
;
; Private. Increments the attempt counter and consults the injection point.
; ---------------------------------------------------------------------------
af_alloc_should_fail:
        mov     rax, [af_alloc_attempts]
        inc     rax
        mov     [af_alloc_attempts], rax
        mov     rcx, [af_alloc_fail_at]
        cmp     rcx, 0
        jl      .no                     ; injection disabled
        cmp     rax, rcx
        jne     .no
        mov     qword [af_alloc_fail_at], -1
        inc     qword [af_alloc_failures]
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_alloc(u64 size) -> void * (NULL on failure)
;
; A zero size returns NULL with no allocation: the runtime never has a
; legitimate reason to allocate nothing, and returning a unique non-NULL pointer
; would hide the caller's arithmetic bug.
; ---------------------------------------------------------------------------
        global af_alloc
af_alloc:
        AF_ENTER 16
        mov     [rsp], rdi              ; requested size
        test    rdi, rdi
        jz      .fail
        call    af_alloc_should_fail
        test    rax, rax
        jnz     .fail

        mov     rdi, [rsp]
        add     rdi, AF_ALLOC_HDR
        jc      .fail                   ; header addition wrapped
        call    malloc wrt ..plt
        test    rax, rax
        jz      .count_failure

        mov     rcx, [rsp]
        mov     rdx, AF_ALLOC_MAGIC
        mov     [rax], rdx              ; header[0]: magic
        mov     [rax + 8], rcx          ; header[1]: payload size
        inc     qword [af_alloc_live_blocks]
        inc     qword [af_alloc_total_blocks]
        add     [af_alloc_live_bytes], rcx
        add     rax, AF_ALLOC_HDR
        AF_LEAVE
.count_failure:
        inc     qword [af_alloc_failures]
.fail:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_calloc(u64 count, u64 size) -> void * (NULL on failure)
;
; The product is checked before it reaches the allocator (invariant 7).
; ---------------------------------------------------------------------------
        global af_calloc
af_calloc:
        AF_ENTER 16
        lea     rdx, [rsp]
        call    af_mul_size
        test    rax, rax
        js      .fail
        mov     rdi, [rsp]
        call    af_alloc
        test    rax, rax
        jz      .fail
        mov     rbx, rax
        mov     rdi, rax
        mov     rsi, [rsp]
        call    af_mem_zero
        mov     rax, rbx
        AF_LEAVE
.fail:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_realloc(void *p, u64 new_size) -> void * (NULL on failure)
;
; On failure the original block is left untouched and still owned by the caller,
; which is what makes the "allocation failure at every index" test able to unwind
; cleanly instead of leaking the old pointer.
; ---------------------------------------------------------------------------
        global af_realloc
af_realloc:
        AF_ENTER 16
        test    rdi, rdi
        jnz     .have_block
        mov     rdi, rsi
        call    af_alloc
        AF_LEAVE
.have_block:
        test    rsi, rsi
        jz      .fail                   ; realloc-to-zero is a caller bug
        mov     [rsp], rsi              ; new payload size
        mov     rbx, rdi                ; payload pointer
        sub     rbx, AF_ALLOC_HDR       ; block pointer
        mov     rax, AF_ALLOC_MAGIC
        cmp     [rbx], rax
        jne     .bad_header
        mov     r12, [rbx + 8]          ; old payload size

        call    af_alloc_should_fail
        test    rax, rax
        jnz     .fail

        mov     rdi, rbx
        mov     rsi, [rsp]
        add     rsi, AF_ALLOC_HDR
        jc      .fail
        call    realloc wrt ..plt
        test    rax, rax
        jz      .count_failure

        mov     rcx, [rsp]
        mov     [rax + 8], rcx
        sub     [af_alloc_live_bytes], r12
        add     [af_alloc_live_bytes], rcx
        add     rax, AF_ALLOC_HDR
        AF_LEAVE
.count_failure:
        inc     qword [af_alloc_failures]
.fail:
        xor     eax, eax
        AF_LEAVE
.bad_header:
        lea     rdi, [msg_bad_header]
        lea     rsi, [af_alloc_file]
        mov     rdx, __?LINE?__
        mov     rcx, rbx
        call    af_panic

; ---------------------------------------------------------------------------
; af_free(void *p) -> void
;
; NULL is accepted and ignored so that a single cleanup label can release every
; optional field of a partially constructed object.
; ---------------------------------------------------------------------------
        global af_free
af_free:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        sub     rbx, AF_ALLOC_HDR
        mov     rax, AF_ALLOC_MAGIC
        cmp     [rbx], rax
        jne     .bad_header
        mov     r12, [rbx + 8]          ; payload size

        ; Poison the header so a second free of the same pointer is a loud
        ; panic instead of a silent double free.
        mov     qword [rbx], 0

        mov     rax, [af_alloc_live_blocks]
        test    rax, rax
        jz      .underflow
        dec     rax
        mov     [af_alloc_live_blocks], rax
        sub     [af_alloc_live_bytes], r12

        mov     rdi, rbx
        call    free wrt ..plt
.done:
        AF_LEAVE
.underflow:
        lea     rdi, [msg_free_underflow]
        lea     rsi, [af_alloc_file]
        mov     rdx, __?LINE?__
        xor     ecx, ecx
        call    af_panic
.bad_header:
        lea     rdi, [msg_bad_header]
        lea     rsi, [af_alloc_file]
        mov     rdx, __?LINE?__
        mov     rcx, rbx
        call    af_panic

; ---------------------------------------------------------------------------
; af_alloc_size(const void *p) -> u64
;
; Payload size recorded in the header. Zero for NULL.
; ---------------------------------------------------------------------------
        global af_alloc_size
af_alloc_size:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi - 8]
.done:
        ret

; ---------------------------------------------------------------------------
; Test and diagnostic accessors.
;
; af_alloc_live_count / af_alloc_live_byte_count feed the per-test leak check in
; the unit-test runner. af_alloc_inject_failure_at is test-only and is never
; called from a product path.
; ---------------------------------------------------------------------------
        global af_alloc_live_count
af_alloc_live_count:
        mov     rax, [af_alloc_live_blocks]
        ret

        global af_alloc_live_byte_count
af_alloc_live_byte_count:
        mov     rax, [af_alloc_live_bytes]
        ret

        global af_alloc_total_count
af_alloc_total_count:
        mov     rax, [af_alloc_total_blocks]
        ret

        global af_alloc_attempt_count
af_alloc_attempt_count:
        mov     rax, [af_alloc_attempts]
        ret

; af_alloc_inject_failure_at(i64 attempt_index) -> void
;   attempt_index < 0 disables injection. The index counts every attempt since
;   process start, so tests reset the counter first.
        global af_alloc_inject_failure_at
af_alloc_inject_failure_at:
        mov     [af_alloc_fail_at], rdi
        ret

; af_alloc_reset_counters() -> void
        global af_alloc_reset_counters
af_alloc_reset_counters:
        mov     qword [af_alloc_attempts], 0
        mov     qword [af_alloc_failures], 0
        mov     qword [af_alloc_fail_at], -1
        ret

        section .rodata
af_alloc_file: db __?FILE?__, 0
