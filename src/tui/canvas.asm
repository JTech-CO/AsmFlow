; AsmFlow — bounded Unicode-scalar presentation canvas.
;
; The canvas owns nothing.  `TC_CELLS` is caller-owned u32 storage and every
; input/output byte span is BORROWED for the call.  There is no allocation and
; no terminal I/O.  Text is clipped at the right edge between Unicode scalars;
; invalid UTF-8 becomes U+FFFD and terminal control scalars become '?'.

        bits 64
        default rel

%include "asmflow.inc"
%include "tui.inc"

        extern wcwidth

        section .text

; ---------------------------------------------------------------------------
; _af_tui_safe_scalar(u32 cp) -> u32
;
; Private.  A scalar stored by a hostile/corrupt caller is made render-safe at
; the final encoding boundary too.  Controls never reach a canonical dump.
; ---------------------------------------------------------------------------
_af_tui_safe_scalar:
        mov     eax, edi
        cmp     eax, 0x10ffff
        ja      .replacement
        cmp     eax, 0xd800
        jb      .controls
        cmp     eax, 0xdfff
        jbe     .replacement
.controls:
        cmp     eax, 0x20
        jb      .question
        cmp     eax, 0x7f
        jb      .done
        cmp     eax, 0x9f
        jbe     .question
.done:
        ret
.question:
        mov     eax, '?'
        ret
.replacement:
        mov     eax, 0xfffd
        ret

; ---------------------------------------------------------------------------
; _af_tui_decode_one(const u8 *s, u64 remaining)
;   -> rax=scalar, rdx=bytes consumed, rcx=valid(1/0)
;
; Private strict UTF-8 decoder.  Invalid/short/overlong/surrogate input consumes
; exactly one byte, ensuring deterministic forward progress.
; ---------------------------------------------------------------------------
_af_tui_decode_one:
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

; Private: safe scalar in edi -> encoded byte length in rax.
_af_tui_utf8_len:
        call    _af_tui_safe_scalar
        cmp     eax, 0x80
        jb      .one
        cmp     eax, 0x800
        jb      .two
        cmp     eax, 0x10000
        jb      .three
        mov     eax, 4
        ret
.one:
        mov     eax, 1
        ret
.two:
        mov     eax, 2
        ret
.three:
        mov     eax, 3
        ret

; Private: _af_tui_encode_utf8(u32 cp, u8 *dst) -> bytes in rax.
_af_tui_encode_utf8:
        push    rbx
        mov     rbx, rsi
        call    _af_tui_safe_scalar
        mov     edi, eax
        cmp     eax, 0x80
        jb      .one
        cmp     eax, 0x800
        jb      .two
        cmp     eax, 0x10000
        jb      .three
        mov     ecx, eax
        shr     ecx, 18
        or      cl, 0xf0
        mov     [rbx], cl
        mov     ecx, eax
        shr     ecx, 12
        and     cl, 0x3f
        or      cl, 0x80
        mov     [rbx + 1], cl
        mov     ecx, eax
        shr     ecx, 6
        and     cl, 0x3f
        or      cl, 0x80
        mov     [rbx + 2], cl
        and     al, 0x3f
        or      al, 0x80
        mov     [rbx + 3], al
        mov     eax, 4
        pop     rbx
        ret
.three:
        mov     ecx, eax
        shr     ecx, 12
        or      cl, 0xe0
        mov     [rbx], cl
        mov     ecx, eax
        shr     ecx, 6
        and     cl, 0x3f
        or      cl, 0x80
        mov     [rbx + 1], cl
        and     al, 0x3f
        or      al, 0x80
        mov     [rbx + 2], al
        mov     eax, 3
        pop     rbx
        ret
.two:
        mov     ecx, eax
        shr     ecx, 6
        or      cl, 0xc0
        mov     [rbx], cl
        and     al, 0x3f
        or      al, 0x80
        mov     [rbx + 1], al
        mov     eax, 2
        pop     rbx
        ret
.one:
        mov     [rbx], al
        mov     eax, 1
        pop     rbx
        ret

; ---------------------------------------------------------------------------
; af_tui_canvas_init(af_tui_canvas *c, u32 *cells, u64 capacity_cells,
;                    u64 width, u64 height) -> af_status
; ---------------------------------------------------------------------------
        global af_tui_canvas_init
af_tui_canvas_init:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rcx, rcx
        jz      .invalid
        test    r8, r8
        jz      .invalid
        cmp     rcx, AF_TUI_MAX_COLUMNS
        ja      .limit
        cmp     r8, AF_TUI_MAX_ROWS
        ja      .limit
        mov     r9, rdx
        mov     rax, rcx
        mul     r8
        test    rdx, rdx
        jnz     .overflow
        cmp     rax, AF_TUI_MAX_CELLS
        ja      .limit
        cmp     r9, rax
        jb      .limit
        mov     [rdi + TC_CELLS], rsi
        mov     [rdi + TC_WIDTH], rcx
        mov     [rdi + TC_HEIGHT], r8
        mov     [rdi + TC_CAPACITY], r9
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.overflow:
        AF_LEAVE_ERR AF_E_OVERFLOW
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

; ---------------------------------------------------------------------------
; af_tui_canvas_clear(af_tui_canvas *c, u32 scalar) -> af_status
; ---------------------------------------------------------------------------
        global af_tui_canvas_clear
af_tui_canvas_clear:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     edi, esi
        call    _af_tui_safe_scalar
        cmp     eax, esi
        jne     .invalid
        mov     r8, [rbx + TC_WIDTH]
        mov     rcx, [rbx + TC_HEIGHT]
        test    r8, r8
        jz      .invalid
        test    rcx, rcx
        jz      .invalid
        imul    r8, rcx
        cmp     r8, [rbx + TC_CAPACITY]
        ja      .invalid
        mov     rdx, [rbx + TC_CELLS]
        test    rdx, rdx
        jz      .invalid
        xor     ecx, ecx
.loop:
        cmp     rcx, r8
        jae     .done
        mov     [rdx + rcx * TC_CELL_SIZE], eax
        inc     rcx
        jmp     .loop
.done:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_tui_canvas_put_ascii(c, x, y, bytes, len, out_columns) -> af_status
;
; The right edge clips successfully and reports the number of cells written.
; ---------------------------------------------------------------------------
        global af_tui_canvas_put_ascii
af_tui_canvas_put_ascii:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    r9, r9
        jz      .invalid
        test    r8, r8
        jz      .empty_source_ok
        test    rcx, rcx
        jz      .invalid
.empty_source_ok:
        mov     rbx, rdi
        cmp     rsi, [rbx + TC_WIDTH]
        jae     .range
        cmp     rdx, [rbx + TC_HEIGHT]
        jae     .range
        mov     [rsp], r9
        mov     r12, rcx
        mov     r13, r8
        mov     r14, [rbx + TC_WIDTH]
        sub     r14, rsi
        cmp     r13, r14
        cmova   r13, r14
        mov     rax, rdx
        mul     qword [rbx + TC_WIDTH]
        test    rdx, rdx
        jnz     .invalid
        add     rax, rsi
        jc      .invalid
        add     rax, r13
        cmp     rax, [rbx + TC_CAPACITY]
        ja      .invalid
        sub     rax, r13
        mov     r15, [rbx + TC_CELLS]
        test    r15, r15
        jz      .invalid
        lea     r15, [r15 + rax * TC_CELL_SIZE]
        xor     ecx, ecx
.copy:
        cmp     rcx, r13
        jae     .done
        movzx   eax, byte [r12 + rcx]
        cmp     eax, 0x20
        jb      .replace
        cmp     eax, 0x7e
        jbe     .store
.replace:
        mov     eax, '?'
.store:
        mov     [r15 + rcx * TC_CELL_SIZE], eax
        inc     rcx
        jmp     .copy
.done:
        mov     rax, [rsp]
        mov     [rax], r13
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.range:
        AF_LEAVE_ERR AF_E_RANGE

; ---------------------------------------------------------------------------
; af_tui_canvas_put_utf8(c, x, y, bytes, len, out_columns) -> af_status
;
; Scalars use the active locale's wcwidth. Width-2 scalars reserve a second
; continuation cell, so clipping and later columns agree with the terminal.
; Zero-width/indeterminate scalars conservatively consume one cell: this may
; leave padding but can never cause horizontal wrap. UTF-8 is never bisected.
; ---------------------------------------------------------------------------
        global af_tui_canvas_put_utf8
af_tui_canvas_put_utf8:
        AF_ENTER 64
        test    rdi, rdi
        jz      .invalid
        test    r9, r9
        jz      .invalid
        cmp     r8, AF_TUI_TEXT_MAX_BYTES
        ja      .limit
        test    r8, r8
        jz      .source_ok
        test    rcx, rcx
        jz      .invalid
.source_ok:
        mov     rbx, rdi
        cmp     rsi, [rbx + TC_WIDTH]
        jae     .range
        cmp     rdx, [rbx + TC_HEIGHT]
        jae     .range
        mov     [rsp], r9
        mov     r12, rcx
        mov     r13, r8
        mov     r14, [rbx + TC_WIDTH]
        sub     r14, rsi                       ; available cells
        mov     rax, rdx
        mul     qword [rbx + TC_WIDTH]
        test    rdx, rdx
        jnz     .invalid
        add     rax, rsi
        jc      .invalid
        cmp     rax, [rbx + TC_CAPACITY]
        jae     .invalid
        mov     r15, [rbx + TC_CELLS]
        test    r15, r15
        jz      .invalid
        lea     r15, [r15 + rax * TC_CELL_SIZE]
        mov     qword [rsp + 8], 0             ; source byte offset
        mov     qword [rsp + 16], 0            ; columns written
.decode:
        mov     rax, [rsp + 8]
        cmp     rax, r13
        jae     .done
        mov     rcx, [rsp + 16]
        cmp     rcx, r14
        jae     .done
        lea     rdi, [r12 + rax]
        mov     rsi, r13
        sub     rsi, rax
        call    _af_tui_decode_one
        add     [rsp + 8], rdx
        mov     edi, eax
        call    _af_tui_safe_scalar
        mov     [rsp + 24], rax                 ; safe scalar
        mov     edi, eax
        AF_CCALL wcwidth
        mov     edx, 1                          ; safe conservative width
        cmp     eax, 1
        je      .width_ready
        cmp     eax, 2
        jne     .indeterminate_width
        mov     edx, 2
        jmp     .width_ready
.indeterminate_width:
        ; In the C/POSIX locale, or for a combining/nonprinting scalar, the
        ; terminal cannot promise a usable column. Render a visible ASCII
        ; replacement rather than letting multibyte output wrap unpredictably.
        mov     qword [rsp + 24], '?'
.width_ready:
        mov     rcx, [rsp + 16]
        mov     rax, rcx
        add     rax, rdx
        cmp     rax, r14
        ja      .done                           ; do not split width-2 scalar
        mov     eax, [rsp + 24]
        mov     [r15 + rcx * TC_CELL_SIZE], eax
        cmp     edx, 2
        jne     .advance
        mov     dword [r15 + rcx * TC_CELL_SIZE + TC_CELL_SIZE], AF_TUI_CELL_CONTINUATION
.advance:
        add     [rsp + 16], rdx
        jmp     .decode
.done:
        mov     rax, [rsp]
        mov     rcx, [rsp + 16]
        mov     [rax], rcx
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.range:
        AF_LEAVE_ERR AF_E_RANGE
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

; ---------------------------------------------------------------------------
; af_tui_canvas_dump(c, dst_or_null, capacity, out_len) -> af_status
;
; Canonical form is every complete row followed by one LF, including the last.
; Passing {NULL,0} is a size query.  Insufficient output is atomic: no byte and
; no out_len value is written.
; ---------------------------------------------------------------------------
        global af_tui_canvas_dump
af_tui_canvas_dump:
        AF_ENTER 64
        test    rdi, rdi
        jz      .invalid
        test    rcx, rcx
        jz      .invalid
        test    rsi, rsi
        jnz     .destination_ok
        test    rdx, rdx
        jnz     .invalid
.destination_ok:
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r8, [rbx + TC_WIDTH]
        mov     r9, [rbx + TC_HEIGHT]
        test    r8, r8
        jz      .invalid
        test    r9, r9
        jz      .invalid
        mov     rax, r8
        mul     r9
        test    rdx, rdx
        jnz     .overflow
        cmp     rax, [rbx + TC_CAPACITY]
        ja      .invalid
        mov     r15, [rbx + TC_CELLS]
        test    r15, r15
        jz      .invalid
        mov     [rsp], rax                     ; total cells
        mov     [rsp + 8], r8                  ; width
        mov     qword [rsp + 16], 0            ; cell index
        mov     qword [rsp + 24], 0            ; required bytes
.measure_cell:
        mov     rcx, [rsp + 16]
        cmp     rcx, [rsp]
        jae     .measured
        mov     edi, [r15 + rcx * TC_CELL_SIZE]
        cmp     edi, AF_TUI_CELL_CONTINUATION
        je      .measure_advance
        call    _af_tui_utf8_len
        add     [rsp + 24], rax
        jc      .overflow
.measure_advance:
        inc     qword [rsp + 16]
        mov     rax, [rsp + 16]
        xor     edx, edx
        div     qword [rsp + 8]
        test    rdx, rdx
        jnz     .measure_cell
        inc     qword [rsp + 24]               ; row LF
        jz      .overflow
        jmp     .measure_cell
.measured:
        test    r12, r12
        jz      .size_query
        cmp     r13, [rsp + 24]
        jb      .limit
        mov     qword [rsp + 16], 0            ; cell index
        mov     qword [rsp + 32], 0            ; output index
.emit_cell:
        mov     rcx, [rsp + 16]
        cmp     rcx, [rsp]
        jae     .emitted
        mov     edi, [r15 + rcx * TC_CELL_SIZE]
        cmp     edi, AF_TUI_CELL_CONTINUATION
        je      .emit_advance
        mov     rsi, r12
        add     rsi, [rsp + 32]
        call    _af_tui_encode_utf8
        add     [rsp + 32], rax
.emit_advance:
        inc     qword [rsp + 16]
        mov     rax, [rsp + 16]
        xor     edx, edx
        div     qword [rsp + 8]
        test    rdx, rdx
        jnz     .emit_cell
        mov     rax, [rsp + 32]
        mov     byte [r12 + rax], 10
        inc     qword [rsp + 32]
        jmp     .emit_cell
.emitted:
.size_query:
        mov     rax, [rsp + 24]
        mov     [r14], rax
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.overflow:
        AF_LEAVE_ERR AF_E_OVERFLOW
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

        global af_tui_canvas_struct_size
af_tui_canvas_struct_size:
        mov     eax, TC_SIZE
        ret
