; AsmFlow — deterministic keyboard-to-command mapping.
;
; The caller translates terminal input to Unicode/KEY_* integers.  This module
; has no ncurses dependency and writes the caller-owned event only on success.

        bits 64
        default rel

%include "asmflow.inc"
%include "tui.inc"

        section .text

; af_tui_keymap(i64 key, af_tui_key_event *out) -> af_status
        global af_tui_keymap
af_tui_keymap:
        AF_ENTER 0
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rsi

        cmp     rdi, '1'
        jb      .not_screen
        cmp     rdi, '7'
        ja      .not_screen
        mov     qword [rbx + TKE_COMMAND], AF_TUI_CMD_SCREEN
        sub     rdi, '0'
        mov     [rbx + TKE_ARGUMENT], rdi
        AF_LEAVE_OK

.not_screen:
        cmp     rdi, 9                         ; Tab
        je      .focus_next
        cmp     rdi, AF_TUI_KEY_BTAB
        je      .focus_prev
        cmp     rdi, 'j'
        je      .row_next
        cmp     rdi, AF_TUI_KEY_DOWN
        je      .row_next
        cmp     rdi, AF_TUI_KEY_RIGHT
        je      .row_next
        cmp     rdi, 'k'
        je      .row_prev
        cmp     rdi, AF_TUI_KEY_UP
        je      .row_prev
        cmp     rdi, AF_TUI_KEY_LEFT
        je      .row_prev
        cmp     rdi, 10                        ; LF/Enter
        je      .open
        cmp     rdi, 13                        ; CR/Enter
        je      .open
        cmp     rdi, AF_TUI_KEY_ENTER
        je      .open
        cmp     rdi, 27                        ; Escape
        je      .back
        cmp     rdi, '/'
        je      .filter
        cmp     rdi, ':'
        je      .palette
        cmp     rdi, '?'
        je      .help
        cmp     rdi, 'r'
        je      .refresh
        cmp     rdi, ' '
        je      .toggle
        cmp     rdi, 'q'
        je      .quit
        AF_LEAVE_ERR AF_E_NOTFOUND

.focus_next:
        mov     eax, AF_TUI_CMD_FOCUS_NEXT
        jmp     .command
.focus_prev:
        mov     eax, AF_TUI_CMD_FOCUS_PREV
        jmp     .command
.row_next:
        mov     eax, AF_TUI_CMD_ROW_NEXT
        jmp     .command
.row_prev:
        mov     eax, AF_TUI_CMD_ROW_PREV
        jmp     .command
.open:
        mov     eax, AF_TUI_CMD_OPEN
        jmp     .command
.back:
        mov     eax, AF_TUI_CMD_BACK
        jmp     .command
.filter:
        mov     eax, AF_TUI_CMD_FILTER
        jmp     .command
.palette:
        mov     eax, AF_TUI_CMD_PALETTE
        jmp     .command
.help:
        mov     eax, AF_TUI_CMD_HELP
        jmp     .command
.refresh:
        mov     eax, AF_TUI_CMD_REFRESH
        jmp     .command
.toggle:
        mov     eax, AF_TUI_CMD_TOGGLE_SELECT
        jmp     .command
.quit:
        mov     eax, AF_TUI_CMD_QUIT
.command:
        mov     [rbx + TKE_COMMAND], rax
        mov     qword [rbx + TKE_ARGUMENT], 0
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

        global af_tui_key_event_struct_size
af_tui_key_event_struct_size:
        mov     eax, TKE_SIZE
        ret
