; AsmFlow — overflow-checked size arithmetic.
;
; AGENTS.md invariant 7: all size arithmetic is overflow-checked before an
; allocation or a copy. Every growth path in the runtime routes through these
; functions rather than a bare `add`/`imul`, so a wrapped length can never turn
; into a short allocation followed by a long copy.
;
; These are leaf functions: no call, no allocation, no global state.

        bits 64
        default rel

%include "asmflow.inc"

        section .text

; ---------------------------------------------------------------------------
; af_add_size(u64 a, u64 b, u64 *out) -> af_status
;
; AF_E_OVERFLOW when a + b does not fit in 64 bits. `out` is written only on
; success so a failed check cannot leave a half-updated length behind.
; ---------------------------------------------------------------------------
        global af_add_size
af_add_size:
        mov     rax, rdi
        add     rax, rsi
        jc      .overflow
        mov     [rdx], rax
        xor     eax, eax
        ret
.overflow:
        mov     rax, AF_E_OVERFLOW
        ret

; ---------------------------------------------------------------------------
; af_sub_size(u64 a, u64 b, u64 *out) -> af_status
;
; AF_E_OVERFLOW on underflow. Unsigned subtraction that silently wraps is the
; single most common source of "buffer length looks negative" (HARNESS.md
; runbook row 5), so it is checked in exactly the same way.
; ---------------------------------------------------------------------------
        global af_sub_size
af_sub_size:
        mov     rax, rdi
        sub     rax, rsi
        jc      .overflow
        mov     [rdx], rax
        xor     eax, eax
        ret
.overflow:
        mov     rax, AF_E_OVERFLOW
        ret

; ---------------------------------------------------------------------------
; af_mul_size(u64 a, u64 b, u64 *out) -> af_status
; ---------------------------------------------------------------------------
        global af_mul_size
af_mul_size:
        mov     r8, rdx                 ; out pointer; `mul` clobbers rdx
        mov     rax, rdi
        mul     rsi                     ; rdx:rax = a * b
        test    rdx, rdx
        jnz     .overflow
        mov     [r8], rax
        xor     eax, eax
        ret
.overflow:
        mov     rax, AF_E_OVERFLOW
        ret

; ---------------------------------------------------------------------------
; af_add_size3(u64 a, u64 b, u64 c, u64 *out) -> af_status
;
; Convenience for the very common "header + payload + terminator" shape, so
; call sites do not need two temporaries and two status checks.
; ---------------------------------------------------------------------------
        global af_add_size3
af_add_size3:
        mov     rax, rdi
        add     rax, rsi
        jc      .overflow
        add     rax, rdx
        jc      .overflow
        mov     [rcx], rax
        xor     eax, eax
        ret
.overflow:
        mov     rax, AF_E_OVERFLOW
        ret

; ---------------------------------------------------------------------------
; af_grow_size(u64 current, u64 needed, u64 max, u64 *out) -> af_status
;
; Chooses the next capacity for a bounded dynamic buffer: doubling, but never
; below `needed` and never above `max`.
;
;   AF_E_LIMIT     when `needed` itself exceeds `max`
;   AF_E_OVERFLOW  when doubling would wrap
;
; Clamping to `max` rather than failing lets a buffer fill to exactly its
; configured ceiling before the caller reports the limit error, which is what
; the boundary tests in TEST_STRATEGY.md 3 expect (boundary-1, boundary,
; boundary+1).
; ---------------------------------------------------------------------------
        global af_grow_size
af_grow_size:
        cmp     rsi, rdx
        ja      .limit                  ; needed > max
        mov     rax, rdi
        test    rax, rax
        jnz     .double
        mov     rax, 64                 ; first allocation floor
        jmp     .clamp_needed
.double:
        add     rax, rax
        jc      .overflow
.clamp_needed:
        cmp     rax, rsi
        jae     .clamp_max
        mov     rax, rsi
.clamp_max:
        cmp     rax, rdx
        jbe     .store
        mov     rax, rdx
.store:
        mov     [rcx], rax
        xor     eax, eax
        ret
.limit:
        mov     rax, AF_E_LIMIT
        ret
.overflow:
        mov     rax, AF_E_OVERFLOW
        ret

; ---------------------------------------------------------------------------
; af_align_up(u64 value, u64 alignment, u64 *out) -> af_status
;
; `alignment` must be a non-zero power of two. AF_E_INVALID otherwise,
; AF_E_OVERFLOW when rounding up would wrap.
; ---------------------------------------------------------------------------
        global af_align_up
af_align_up:
        test    rsi, rsi
        jz      .invalid
        mov     rax, rsi
        lea     rcx, [rsi - 1]
        test    rax, rcx
        jnz     .invalid                ; not a power of two
        mov     rax, rdi
        add     rax, rcx
        jc      .overflow
        not     rcx
        and     rax, rcx
        mov     [rdx], rax
        xor     eax, eax
        ret
.invalid:
        mov     rax, AF_E_INVALID
        ret
.overflow:
        mov     rax, AF_E_OVERFLOW
        ret
