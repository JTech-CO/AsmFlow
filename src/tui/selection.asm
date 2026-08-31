; AsmFlow — stable-ID selection across refresh/reorder/removal.
;
; IDs and row arrays are BORROWED.  No pointer is retained.  When the selected
; ID disappears, the row now occupying the old sorted position wins; if that
; position is past the new end, the previous (last) row wins.  This makes the
; whitepaper's "nearest row" rule deterministic.

        bits 64
        default rel

%include "asmflow.inc"
%include "tui.inc"

        section .text

; ---------------------------------------------------------------------------
; af_tui_selection_find(id_bytes, id_len, rows, row_count) -> i64 index/-1
; ---------------------------------------------------------------------------
        global af_tui_selection_find
af_tui_selection_find:
        test    rdi, rdi
        jz      .not_found
        test    rsi, rsi
        jz      .not_found
        test    rdx, rdx
        jz      .not_found
        cmp     rcx, AF_TUI_MODEL_MAX_ROWS
        ja      .not_found
        xor     r8d, r8d
.row:
        cmp     r8, rcx
        jae     .not_found
        mov     rax, r8
        imul    rax, TID_SIZE
        add     rax, rdx
        cmp     [rax + TID_LEN], rsi
        jne     .next
        mov     r9, [rax + TID_PTR]
        test    r9, r9
        jz      .next
        xor     r10d, r10d
.byte:
        cmp     r10, rsi
        jae     .found
        mov     r11b, [rdi + r10]
        cmp     r11b, [r9 + r10]
        jne     .next
        inc     r10
        jmp     .byte
.next:
        inc     r8
        jmp     .row
.found:
        mov     rax, r8
        ret
.not_found:
        mov     rax, -1
        ret

; ---------------------------------------------------------------------------
; af_tui_selection_resolve(old_id, old_id_len, new_rows, new_count,
;                          old_index, out_index) -> af_status
; ---------------------------------------------------------------------------
        global af_tui_selection_resolve
af_tui_selection_resolve:
        AF_ENTER 0
        test    r9, r9
        jz      .invalid
        test    rcx, rcx
        jz      .not_found
        cmp     rcx, AF_TUI_MODEL_MAX_ROWS
        ja      .limit
        test    rdx, rdx
        jz      .invalid
        mov     rbx, rcx
        mov     r12, r8
        mov     r13, r9
        call    af_tui_selection_find
        cmp     rax, -1
        jne     .store
        mov     rax, r12
        cmp     rax, rbx
        jb      .store
        mov     rax, rbx
        dec     rax
.store:
        mov     [r13], rax
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

        global af_tui_id_struct_size
af_tui_id_struct_size:
        mov     eax, TID_SIZE
        ret
