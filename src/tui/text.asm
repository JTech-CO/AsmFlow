; AsmFlow — bounded terminal-safe UTF-8 sanitisation.
;
; Input and output spans are BORROWED and must not overlap.  Valid printable
; UTF-8 is copied byte-for-byte.  Invalid sequences become U+FFFD, C0/DEL
; controls become visible `\\xHH`, and C1 controls become visible `\\u00HH`.
; Consequently no ESC or other remote terminal control byte survives.

        bits 64
        default rel

%include "asmflow.inc"
%include "tui.inc"

        section .rodata
hex_digits: db "0123456789ABCDEF"

        section .text

; Private strict decoder, same contract as canvas.asm's private decoder:
; rax=scalar, rdx=consumed bytes, rcx=valid.
_af_tui_text_decode:
        movzx   eax, byte [rdi]
        cmp     eax, 0x80
        jb      .ascii
        cmp     eax, 0xc2
        jb      .invalid
        cmp     eax, 0xdf
        jbe     .two
        cmp     eax, 0xef
        jbe     .three
        cmp     eax, 0xf4
        jbe     .four
        jmp     .invalid
.ascii:
        mov     edx, 1
        mov     ecx, 1
        ret
.two:
        cmp     rsi, 2
        jb      .invalid
        movzx   r8d, byte [rdi + 1]
        mov     r9d, r8d
        and     r9d, 0xc0
        cmp     r9d, 0x80
        jne     .invalid
        and     eax, 0x1f
        shl     eax, 6
        and     r8d, 0x3f
        or      eax, r8d
        mov     edx, 2
        mov     ecx, 1
        ret
.three:
        cmp     rsi, 3
        jb      .invalid
        movzx   r8d, byte [rdi + 1]
        movzx   r9d, byte [rdi + 2]
        mov     r10d, r8d
        and     r10d, 0xc0
        cmp     r10d, 0x80
        jne     .invalid
        mov     r10d, r9d
        and     r10d, 0xc0
        cmp     r10d, 0x80
        jne     .invalid
        movzx   r10d, byte [rdi]
        cmp     r10d, 0xe0
        jne     .three_not_e0
        cmp     r8d, 0xa0
        jb      .invalid
.three_not_e0:
        cmp     r10d, 0xed
        jne     .three_build
        cmp     r8d, 0x9f
        ja      .invalid
.three_build:
        mov     eax, r10d
        and     eax, 0x0f
        shl     eax, 12
        and     r8d, 0x3f
        shl     r8d, 6
        or      eax, r8d
        and     r9d, 0x3f
        or      eax, r9d
        mov     edx, 3
        mov     ecx, 1
        ret
.four:
        cmp     rsi, 4
        jb      .invalid
        movzx   r8d, byte [rdi + 1]
        movzx   r9d, byte [rdi + 2]
        movzx   r10d, byte [rdi + 3]
        mov     r11d, r8d
        and     r11d, 0xc0
        cmp     r11d, 0x80
        jne     .invalid
        mov     r11d, r9d
        and     r11d, 0xc0
        cmp     r11d, 0x80
        jne     .invalid
        mov     r11d, r10d
        and     r11d, 0xc0
        cmp     r11d, 0x80
        jne     .invalid
        movzx   r11d, byte [rdi]
        cmp     r11d, 0xf0
        jne     .four_not_f0
        cmp     r8d, 0x90
        jb      .invalid
.four_not_f0:
        cmp     r11d, 0xf4
        jne     .four_build
        cmp     r8d, 0x8f
        ja      .invalid
.four_build:
        mov     eax, r11d
        and     eax, 0x07
        shl     eax, 18
        and     r8d, 0x3f
        shl     r8d, 12
        or      eax, r8d
        and     r9d, 0x3f
        shl     r9d, 6
        or      eax, r9d
        and     r10d, 0x3f
        or      eax, r10d
        mov     edx, 4
        mov     ecx, 1
        ret
.invalid:
        mov     eax, 0xfffd
        mov     edx, 1
        xor     ecx, ecx
        ret

; Private: scalar/valid -> sanitized encoded length.
; edi=scalar, esi=valid, edx=original sequence length.
_af_tui_text_output_len:
        test    esi, esi
        jz      .replacement
        cmp     edi, 0x20
        jb      .c0
        cmp     edi, 0x7f
        je      .c0
        cmp     edi, 0x80
        jb      .copy
        cmp     edi, 0x9f
        jbe     .c1
.copy:
        mov     eax, edx
        ret
.replacement:
        mov     eax, 3
        ret
.c0:
        mov     eax, 4
        ret
.c1:
        mov     eax, 6
        ret

; ---------------------------------------------------------------------------
; af_tui_sanitize_utf8(src, len, dst_or_null, capacity, out_len) -> af_status
;
; {NULL,0} for the destination is a size query.  Capacity failure is atomic.
; ---------------------------------------------------------------------------
        global af_tui_sanitize_utf8
af_tui_sanitize_utf8:
        AF_ENTER 96
        test    r8, r8
        jz      .invalid
        cmp     rsi, AF_TUI_TEXT_MAX_BYTES
        ja      .limit
        test    rsi, rsi
        jz      .source_ok
        test    rdi, rdi
        jz      .invalid
.source_ok:
        test    rdx, rdx
        jnz     .destination_ok
        test    rcx, rcx
        jnz     .invalid
.destination_ok:
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r15, r8
        mov     qword [rsp], 0                 ; input offset
        mov     qword [rsp + 8], 0             ; required output
.measure:
        mov     rax, [rsp]
        cmp     rax, r12
        jae     .measured
        lea     rdi, [rbx + rax]
        mov     rsi, r12
        sub     rsi, rax
        call    _af_tui_text_decode
        mov     [rsp + 16], rdx                ; consumed
        mov     edi, eax
        mov     esi, ecx
        call    _af_tui_text_output_len
        add     [rsp + 8], rax
        jc      .overflow
        mov     rax, [rsp + 16]
        add     [rsp], rax
        jc      .overflow
        jmp     .measure
.measured:
        test    r13, r13
        jz      .success
        cmp     r14, [rsp + 8]
        jb      .limit
        mov     qword [rsp], 0                 ; input offset
        mov     qword [rsp + 24], 0            ; output offset
.emit:
        mov     rax, [rsp]
        cmp     rax, r12
        jae     .success
        lea     rdi, [rbx + rax]
        mov     rsi, r12
        sub     rsi, rax
        call    _af_tui_text_decode
        mov     [rsp + 16], rdx                ; consumed
        mov     [rsp + 32], rax                ; scalar
        mov     [rsp + 40], rcx                ; valid
        mov     rax, [rsp + 24]
        lea     r11, [r13 + rax]
        cmp     qword [rsp + 40], 0
        je      .emit_replacement
        mov     eax, [rsp + 32]
        cmp     eax, 0x20
        jb      .emit_c0
        cmp     eax, 0x7f
        je      .emit_c0
        cmp     eax, 0x80
        jb      .emit_copy
        cmp     eax, 0x9f
        jbe     .emit_c1
.emit_copy:
        mov     rcx, [rsp + 16]
        mov     rax, [rsp]
        lea     rsi, [rbx + rax]
        xor     eax, eax
.copy_loop:
        cmp     rax, rcx
        jae     .copied
        mov     dl, [rsi + rax]
        mov     [r11 + rax], dl
        inc     rax
        jmp     .copy_loop
.copied:
        add     [rsp + 24], rcx
        jmp     .advance
.emit_replacement:
        mov     byte [r11], 0xef
        mov     byte [r11 + 1], 0xbf
        mov     byte [r11 + 2], 0xbd
        add     qword [rsp + 24], 3
        jmp     .advance
.emit_c0:
        mov     byte [r11], '\'
        mov     byte [r11 + 1], 'x'
        mov     eax, [rsp + 32]
        mov     ecx, eax
        shr     ecx, 4
        and     ecx, 0x0f
        lea     rsi, [hex_digits]
        mov     dl, [rsi + rcx]
        mov     [r11 + 2], dl
        and     eax, 0x0f
        mov     dl, [rsi + rax]
        mov     [r11 + 3], dl
        add     qword [rsp + 24], 4
        jmp     .advance
.emit_c1:
        mov     byte [r11], '\'
        mov     byte [r11 + 1], 'u'
        mov     byte [r11 + 2], '0'
        mov     byte [r11 + 3], '0'
        mov     eax, [rsp + 32]
        mov     ecx, eax
        shr     ecx, 4
        and     ecx, 0x0f
        lea     rsi, [hex_digits]
        mov     dl, [rsi + rcx]
        mov     [r11 + 4], dl
        and     eax, 0x0f
        mov     dl, [rsi + rax]
        mov     [r11 + 5], dl
        add     qword [rsp + 24], 6
.advance:
        mov     rax, [rsp + 16]
        add     [rsp], rax
        jmp     .emit
.success:
        mov     rax, [rsp + 8]
        mov     [r15], rax
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.overflow:
        AF_LEAVE_ERR AF_E_OVERFLOW
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
