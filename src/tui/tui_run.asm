; AsmFlow — asmflow-tui runtime shell.
;
; Terminal ownership lives here and nowhere else. The rule is that the restore
; path is installed BEFORE the first mode change, so that a signal or a panic
; between initialisation and the first frame still leaves the terminal with
; echo and the cursor restored (M10 DoD 6).

        bits 64
        default rel

%include "asmflow.inc"

        extern af_out_bytes

%define AF_FD_STDERR 2

        section .rodata

msg_notice:
        db      "asmflow-tui: the operator console is not wired in this build.", 10
        db      "asmflow-tui: see PROGRESS.md for the milestone that enables it.", 10
msg_notice_len equ $ - msg_notice

        section .text

; ---------------------------------------------------------------------------
; af_tui_run(const char *socket_path_or_null, u64 flags) -> int exit code
;
; Ownership: `socket_path_or_null` is BORROWED from argv.
; ---------------------------------------------------------------------------
        global af_tui_run
af_tui_run:
        AF_ENTER 0
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_notice]
        mov     rdx, msg_notice_len
        call    af_out_bytes
        mov     eax, AF_EXIT_OK
        AF_LEAVE
