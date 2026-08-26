; AsmFlow — request correlation identifiers.
;
; Request IDs are ULIDs: a 48-bit millisecond timestamp followed by 80 bits of
; kernel randomness, rendered as 26 Crockford base-32 characters. The format is
; what docs/API_CONTRACT.md 7 already shows in the error envelope, and it has two
; properties the gateway needs: identifiers sort by creation time, which makes a
; request log readable without a join, and they carry no host or sequence
; information that would leak topology.
;
; Randomness comes from getrandom(2) with no fallback. If the kernel cannot
; supply entropy the request is rejected rather than served with a predictable
; identifier, because IDs appear in responses and logs that cross trust
; boundaries.

        bits 64
        default rel

%include "asmflow.inc"

        extern af_sys_getrandom
        extern af_status_from_errno
        extern af_realtime_ms

%define AF_ID_LEN 26

        section .rodata
; Crockford base 32: no I, L, O, or U, so a transcribed identifier cannot be
; confused with 1, 0, or V.
crockford: db "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

        section .text

; ---------------------------------------------------------------------------
; af_id_generate(char *out26) -> af_status
;
; Ownership: `out26` is BORROWED and must have room for 26 bytes. No terminator
; is written.
; ---------------------------------------------------------------------------
        global af_id_generate
af_id_generate:
        AF_ENTER 48
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi                ; output

        lea     rdi, [rsp]
        call    af_realtime_ms
        test    rax, rax
        js      .done
        mov     r12, [rsp]
        mov     rax, 0x0000FFFFFFFFFFFF
        and     r12, rax                ; 48-bit timestamp

        ; 10 bytes of randomness -> two 40-bit halves.
        lea     rdi, [rsp + 16]
        mov     rsi, 10
        xor     edx, edx                ; flags: block until initialised
        call    af_sys_getrandom
        cmp     rax, 10
        jne     .entropy_failed

        ; Assemble the two 40-bit groups big-endian from the 10 random bytes.
        xor     r13, r13
        xor     ecx, ecx
.hi_loop:
        shl     r13, 8
        movzx   eax, byte [rsp + 16 + rcx]
        or      r13, rax
        inc     rcx
        cmp     rcx, 5
        jb      .hi_loop

        xor     r14, r14
        mov     ecx, 5
.lo_loop:
        shl     r14, 8
        movzx   eax, byte [rsp + 16 + rcx]
        or      r14, rax
        inc     rcx
        cmp     rcx, 10
        jb      .lo_loop

        lea     r15, [crockford]

        ; Characters 0..9: the 48-bit timestamp, most significant group first.
        ; The first character carries only 3 significant bits (48 = 9*5 + 3).
        xor     ecx, ecx
.ts_loop:
        mov     rax, 45
        mov     rdx, rcx
        imul    rdx, rdx, 5
        sub     rax, rdx                ; shift = 45 - 5*i
        mov     rdx, r12
        mov     r8, rcx                 ; preserve the index across the shift
        mov     rcx, rax
        shr     rdx, cl
        mov     rcx, r8
        and     rdx, 31
        movzx   eax, byte [r15 + rdx]
        mov     [rbx + rcx], al
        inc     rcx
        cmp     rcx, 10
        jb      .ts_loop

        ; Characters 10..17: the high 40 random bits.
        xor     ecx, ecx
.hi_enc:
        mov     rax, 35
        mov     rdx, rcx
        imul    rdx, rdx, 5
        sub     rax, rdx
        mov     rdx, r13
        mov     r8, rcx
        mov     rcx, rax
        shr     rdx, cl
        mov     rcx, r8
        and     rdx, 31
        movzx   eax, byte [r15 + rdx]
        mov     [rbx + rcx + 10], al
        inc     rcx
        cmp     rcx, 8
        jb      .hi_enc

        ; Characters 18..25: the low 40 random bits.
        xor     ecx, ecx
.lo_enc:
        mov     rax, 35
        mov     rdx, rcx
        imul    rdx, rdx, 5
        sub     rax, rdx
        mov     rdx, r14
        mov     r8, rcx
        mov     rcx, rax
        shr     rdx, cl
        mov     rcx, r8
        and     rdx, 31
        movzx   eax, byte [r15 + rdx]
        mov     [rbx + rcx + 18], al
        inc     rcx
        cmp     rcx, 8
        jb      .lo_enc

        xor     eax, eax
.done:
        AF_LEAVE
.entropy_failed:
        mov     rax, AF_E_SYS
        AF_LEAVE
.invalid:
        mov     rax, AF_E_INVALID
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_id_len() -> u64
; ---------------------------------------------------------------------------
        global af_id_len
af_id_len:
        mov     eax, AF_ID_LEN
        ret

; ---------------------------------------------------------------------------
; af_id_is_valid_ulid(const char *s, u64 len) -> i64 (1 = yes)
;
; Exactly 26 Crockford characters, and the first one no greater than '7' so the
; value fits in 128 bits.
; ---------------------------------------------------------------------------
        global af_id_is_valid_ulid
af_id_is_valid_ulid:
        cmp     rsi, AF_ID_LEN
        jne     .no
        movzx   eax, byte [rdi]
        cmp     al, '0'
        jb      .no
        cmp     al, '7'
        ja      .no
        xor     ecx, ecx
.loop:
        cmp     rcx, rsi
        jae     .yes
        movzx   eax, byte [rdi + rcx]
        cmp     al, '0'
        jb      .no
        cmp     al, '9'
        jbe     .next
        cmp     al, 'A'
        jb      .no
        cmp     al, 'Z'
        ja      .no
        cmp     al, 'I'
        je      .no
        cmp     al, 'L'
        je      .no
        cmp     al, 'O'
        je      .no
        cmp     al, 'U'
        je      .no
.next:
        inc     rcx
        jmp     .loop
.yes:
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_id_is_valid_client_ref(const char *s, u64 len) -> i64 (1 = yes)
;
; Validation for a caller-supplied X-Request-Id. The header is echoed into
; responses and logs, so the charset is restricted to bytes that cannot smuggle
; a header break, a control sequence into an operator's terminal, or a
; delimiter into a structured log line (SECURITY_MODEL.md 17).
; ---------------------------------------------------------------------------
        global af_id_is_valid_client_ref
af_id_is_valid_client_ref:
        test    rsi, rsi
        jz      .no
        cmp     rsi, 64
        ja      .no
        xor     ecx, ecx
.loop:
        cmp     rcx, rsi
        jae     .yes
        movzx   eax, byte [rdi + rcx]
        cmp     al, '0'
        jb      .punct
        cmp     al, '9'
        jbe     .next
        cmp     al, 'A'
        jb      .no
        cmp     al, 'Z'
        jbe     .next
        ; '_' (0x5F) sits between 'Z' and 'a', so it has to be admitted here
        ; rather than with the other punctuation below '0'.
        cmp     al, '_'
        je      .next
        cmp     al, 'a'
        jb      .no
        cmp     al, 'z'
        jbe     .next
        jmp     .no
.punct:
        cmp     al, '-'
        je      .next
        cmp     al, '.'
        je      .next
        cmp     al, '_'
        je      .next
        jmp     .no
.next:
        inc     rcx
        jmp     .loop
.yes:
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret
