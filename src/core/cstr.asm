; AsmFlow — NUL-terminated and counted string primitives.
;
; These are pure functions over BORROWED memory. Nothing here allocates, and
; nothing here reads past the length the caller supplied.

        bits 64
        default rel

%include "asmflow.inc"

        section .text

; ---------------------------------------------------------------------------
; af_cstr_len(const char *s) -> size_t
;
; Byte length excluding the terminator. A NULL argument returns 0 so that
; callers can treat "absent" and "empty" alike where the contract allows it.
; ---------------------------------------------------------------------------
        global af_cstr_len
af_cstr_len:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
.loop:
        cmp     byte [rdi + rax], 0
        je      .done
        inc     rax
        jmp     .loop
.done:
        ret

; ---------------------------------------------------------------------------
; af_mem_eq(const void *a, const void *b, size_t n) -> i64 (1 = equal)
;
; Byte-wise comparison with an early exit. Not constant time: never use it for
; token comparison. See af_mem_eq_ct.
; ---------------------------------------------------------------------------
        global af_mem_eq
af_mem_eq:
        xor     ecx, ecx
.loop:
        cmp     rcx, rdx
        jae     .equal
        mov     al, [rdi + rcx]
        cmp     al, [rsi + rcx]
        jne     .differ
        inc     rcx
        jmp     .loop
.equal:
        mov     eax, 1
        ret
.differ:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_mem_eq_ct(const void *a, const void *b, size_t n) -> i64 (1 = equal)
;
; Constant-time for a fixed n: it always inspects every byte and accumulates
; differences instead of branching out early. Used for bearer-token comparison
; (SECURITY_MODEL.md §7). The length itself is not hidden; callers compare
; lengths separately and pass equal-length buffers.
; ---------------------------------------------------------------------------
        global af_mem_eq_ct
af_mem_eq_ct:
        xor     ecx, ecx
        xor     r8d, r8d                ; difference accumulator
.loop:
        cmp     rcx, rdx
        jae     .done
        mov     al, [rdi + rcx]
        xor     al, [rsi + rcx]
        or      r8b, al
        inc     rcx
        jmp     .loop
.done:
        xor     eax, eax
        test    r8b, r8b
        sete    al
        movzx   eax, al
        ret

; ---------------------------------------------------------------------------
; af_cstr_eq(const char *a, const char *b) -> i64 (1 = equal)
; ---------------------------------------------------------------------------
        global af_cstr_eq
af_cstr_eq:
        xor     ecx, ecx
.loop:
        mov     al, [rdi + rcx]
        mov     dl, [rsi + rcx]
        cmp     al, dl
        jne     .differ
        test    al, al
        jz      .equal
        inc     rcx
        jmp     .loop
.equal:
        mov     eax, 1
        ret
.differ:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_cstr_starts_with(const char *s, const char *prefix) -> i64 (1 = yes)
; ---------------------------------------------------------------------------
        global af_cstr_starts_with
af_cstr_starts_with:
        xor     ecx, ecx
.loop:
        mov     dl, [rsi + rcx]
        test    dl, dl
        jz      .yes
        mov     al, [rdi + rcx]
        cmp     al, dl
        jne     .no
        inc     rcx
        jmp     .loop
.yes:
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_ascii_lower(u8 c) -> u8
; ---------------------------------------------------------------------------
        global af_ascii_lower
af_ascii_lower:
        movzx   eax, dil
        cmp     al, 'A'
        jb      .done
        cmp     al, 'Z'
        ja      .done
        add     al, 32
.done:
        ret

; ---------------------------------------------------------------------------
; af_mem_eq_ci(const void *a, const void *b, size_t n) -> i64 (1 = equal)
;
; ASCII case-insensitive comparison, used for HTTP header names and the
; redaction registry (SECURITY_MODEL.md §16). Only A-Z/a-z are folded; no
; locale is consulted, which is what the HTTP grammar requires.
; ---------------------------------------------------------------------------
        global af_mem_eq_ci
af_mem_eq_ci:
        xor     ecx, ecx
.loop:
        cmp     rcx, rdx
        jae     .equal
        movzx   eax, byte [rdi + rcx]
        movzx   r8d, byte [rsi + rcx]
        cmp     al, 'A'
        jb      .a_done
        cmp     al, 'Z'
        ja      .a_done
        add     al, 32
.a_done:
        cmp     r8b, 'A'
        jb      .b_done
        cmp     r8b, 'Z'
        ja      .b_done
        add     r8b, 32
.b_done:
        cmp     al, r8b
        jne     .differ
        inc     rcx
        jmp     .loop
.equal:
        mov     eax, 1
        ret
.differ:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_mem_copy(void *dst, const void *src, size_t n) -> void *dst
;
; Forward copy; the caller guarantees the regions do not overlap. Bounds are
; the caller's responsibility because every call site in the runtime reaches
; this through a checked buffer API.
; ---------------------------------------------------------------------------
        global af_mem_copy
af_mem_copy:
        mov     rax, rdi
        test    rdx, rdx
        jz      .done
        mov     rcx, rdx
        cmp     rcx, 8
        jb      .bytes
.qwords:
        mov     r8, [rsi]
        mov     [rdi], r8
        add     rsi, 8
        add     rdi, 8
        sub     rcx, 8
        cmp     rcx, 8
        jae     .qwords
        test    rcx, rcx
        jz      .done
.bytes:
        mov     r8b, [rsi]
        mov     [rdi], r8b
        inc     rsi
        inc     rdi
        dec     rcx
        jnz     .bytes
.done:
        ret

; ---------------------------------------------------------------------------
; af_mem_zero(void *dst, size_t n) -> void
;
; Used to wipe credential buffers on replacement and shutdown
; (SECURITY_MODEL.md §6). Written byte-wise through a volatile-equivalent
; store sequence so the assembler cannot elide it.
; ---------------------------------------------------------------------------
        global af_mem_zero
af_mem_zero:
        test    rsi, rsi
        jz      .done
        xor     eax, eax
.loop:
        mov     byte [rdi], 0
        inc     rdi
        dec     rsi
        jnz     .loop
.done:
        ret

; ---------------------------------------------------------------------------
; af_u64_to_dec(u64 value, char *buf, size_t buf_len, size_t *out_len)
;   -> af_status
;
; Writes the unsigned decimal form of `value` at the START of `buf` and stores
; the length. `buf` must hold at least 20 bytes. No terminator is written; the
; caller composes counted output. Ownership: BORROWED.
; ---------------------------------------------------------------------------
        global af_u64_to_dec
af_u64_to_dec:
        ; A leaf, but it still uses the uniform frame, and the argument check
        ; happens inside it so that every exit is an AF_LEAVE. A hand-rolled
        ; prologue or an early bare `ret` is exactly the one-off that
        ; scripts/abi_audit.py exists to refuse.
        AF_ENTER 32
        cmp     rdx, 20
        jb      .too_small
        lea     r8, [rsp]               ; scratch digits, reversed
        xor     r9d, r9d                ; digit count
        mov     rax, rdi
        mov     r10, 10
.digits:
        xor     edx, edx
        div     r10                     ; rax = quotient, rdx = remainder
        add     dl, '0'
        mov     [r8 + r9], dl
        inc     r9
        test    rax, rax
        jnz     .digits
        ; reverse into the caller's buffer
        mov     rdx, r9                 ; length
        xor     eax, eax                ; output index
.reverse:
        mov     r11, r9
        sub     r11, rax
        dec     r11
        mov     r10b, [r8 + r11]
        mov     [rsi + rax], r10b
        inc     rax
        cmp     rax, rdx
        jb      .reverse
        mov     [rcx], rdx
        xor     eax, eax
        AF_LEAVE
.too_small:
        mov     rax, AF_E_LIMIT
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_dec_to_u64(const char *s, size_t len, u64 *out) -> af_status
;
; Strict: the whole span must be ASCII digits, `len` must be non-zero, and any
; overflow past 2^64-1 is rejected rather than wrapped (invariant 7).
; ---------------------------------------------------------------------------
        global af_dec_to_u64
af_dec_to_u64:
        test    rsi, rsi
        jz      .invalid
        mov     r9, rdx                 ; out pointer; `mul` clobbers rdx
        xor     eax, eax                ; accumulator
        xor     ecx, ecx                ; index
        mov     r10, 10
.loop:
        cmp     rcx, rsi
        jae     .done
        movzx   r8d, byte [rdi + rcx]
        sub     r8b, '0'
        cmp     r8b, 9                  ; unsigned: also rejects bytes below '0'
        ja      .invalid
        mul     r10                     ; rdx:rax = rax * 10
        test    rdx, rdx
        jnz     .overflow
        add     rax, r8
        jc      .overflow
        inc     rcx
        jmp     .loop
.done:
        mov     [r9], rax
        xor     eax, eax
        ret
.invalid:
        mov     rax, AF_E_INVALID
        ret
.overflow:
        mov     rax, AF_E_OVERFLOW
        ret
