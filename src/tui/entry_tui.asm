; AsmFlow — asmflow-tui entry point.
;
; The TUI is a separate binary that reaches the daemon only through the
; Unix-domain control socket (ARCHITECTURE.md §2). It never links storage or
; provider internals and never opens the SQLite database
; (AGENTS.md invariant 14).
;
; Terminal discipline: nothing in this file touches termios or ncurses.
; `--version` and `--help` must leave the terminal exactly as they found it
; (M1 DoD 2), so screen initialisation happens only inside af_tui_run, which
; installs its restore handler before the first mode change.

        bits 64
        default rel

%include "asmflow.inc"

        extern af_out_cstr
        extern af_out_bytes
        extern af_cstr_eq
        extern af_sys_exit_group
        extern af_version_str
        extern af_build_target_str
        extern af_build_mode_str
        extern af_tui_run

%define AF_FD_STDOUT 1
%define AF_FD_STDERR 2

        section .rodata

msg_version_prefix:
        db      AF_TUI_NAME, " "
msg_version_prefix_len equ $ - msg_version_prefix

msg_version_mid:
        db      " ("
msg_version_mid_len equ $ - msg_version_mid

msg_version_sep:
        db      ", "
msg_version_sep_len equ $ - msg_version_sep

msg_version_suffix:
        db      ")", 10
msg_version_suffix_len equ $ - msg_version_suffix

msg_usage:
        db      AF_TUI_NAME, " - ", AF_PRODUCT_NAME, " operator console", 10
        db      10
        db      "Usage:", 10
        db      "  ", AF_TUI_NAME, " [options]", 10
        db      10
        db      "Options:", 10
        db      "  --socket PATH     Control socket to connect to.", 10
        db      "                    Default: ${XDG_RUNTIME_DIR}/asmflow/control.sock", 10
        db      "  --mono            Force monochrome rendering.", 10
        db      "  --version, -V     Print the version and exit.", 10
        db      "  --help, -h        Print this help and exit.", 10
        db      10
        db      "Environment:", 10
        db      "  NO_COLOR          When set, disables colour exactly like --mono.", 10
        db      10
        db      "The console reads and changes daemon state through the control socket", 10
        db      "only. It never opens the database directly, and it does not display", 10
        db      "secrets, prompts, or responses on its default screens.", 10
        db      10
        db      "See docs/DESIGN_WHITEPAPER_KR.md and docs/API_CONTRACT.md.", 10
msg_usage_len equ $ - msg_usage

msg_err_prefix:
        db      AF_TUI_NAME, ": "
msg_err_prefix_len equ $ - msg_err_prefix

msg_err_unknown_option:
        db      "unknown option: "
msg_err_unknown_option_len equ $ - msg_err_unknown_option

msg_err_socket_needs_value:
        db      "--socket requires a path argument", 10
msg_err_socket_needs_value_len equ $ - msg_err_socket_needs_value

msg_err_hint:
        db      10, "Run '", AF_TUI_NAME, " --help' for usage.", 10
msg_err_hint_len equ $ - msg_err_hint

msg_newline:
        db      10

opt_version_long:  db "--version", 0
opt_version_short: db "-V", 0
opt_help_long:     db "--help", 0
opt_help_short:    db "-h", 0
opt_socket:        db "--socket", 0
opt_mono:          db "--mono", 0

        section .text

; ---------------------------------------------------------------------------
; main(int argc, char **argv, char **envp) -> int
;
; Registers: rbx = argc, r12 = argv, r13 = index,
;            r14 = --socket value (BORROWED, NULL when unset), r15 = flags.
; ---------------------------------------------------------------------------
%define TUI_FLAG_MONO 1

        global main
main:
        AF_ENTER 16                     ; [rsp+0]: size_t out-param for af_*_str
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, 1
        xor     r14, r14
        xor     r15, r15

.next_arg:
        cmp     r13, rbx
        jae     .args_done
        mov     rdi, [r12 + r13 * 8]

        lea     rsi, [opt_version_long]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_version
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_version_short]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_version

        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_help_long]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_help
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_help_short]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_help

        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_mono]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_mono

        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_socket]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_socket

        jmp     .unknown_option

.do_mono:
        or      r15, TUI_FLAG_MONO
        inc     r13
        jmp     .next_arg

.do_socket:
        inc     r13
        cmp     r13, rbx
        jae     .socket_needs_value
        mov     r14, [r12 + r13 * 8]
        inc     r13
        jmp     .next_arg

.args_done:
        mov     rdi, r14
        mov     rsi, r15
        call    af_tui_run
        mov     rdi, rax
        call    af_sys_exit_group
        ud2

; --- --version -------------------------------------------------------------
.do_version:
        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_version_prefix]
        mov     rdx, msg_version_prefix_len
        call    af_out_bytes

        lea     rdi, [rsp]
        call    af_version_str
        mov     rsi, rax
        mov     rdx, [rsp]
        mov     edi, AF_FD_STDOUT
        call    af_out_bytes

        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_version_mid]
        mov     rdx, msg_version_mid_len
        call    af_out_bytes

        lea     rdi, [rsp]
        call    af_build_target_str
        mov     rsi, rax
        mov     rdx, [rsp]
        mov     edi, AF_FD_STDOUT
        call    af_out_bytes

        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_version_sep]
        mov     rdx, msg_version_sep_len
        call    af_out_bytes

        lea     rdi, [rsp]
        call    af_build_mode_str
        mov     rsi, rax
        mov     rdx, [rsp]
        mov     edi, AF_FD_STDOUT
        call    af_out_bytes

        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_version_suffix]
        mov     rdx, msg_version_suffix_len
        call    af_out_bytes

        mov     edi, AF_EXIT_OK
        call    af_sys_exit_group
        ud2

; --- --help ----------------------------------------------------------------
.do_help:
        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_usage]
        mov     rdx, msg_usage_len
        call    af_out_bytes
        mov     edi, AF_EXIT_OK
        call    af_sys_exit_group
        ud2

; --- errors ----------------------------------------------------------------
.unknown_option:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_prefix]
        mov     rdx, msg_err_prefix_len
        call    af_out_bytes
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_unknown_option]
        mov     rdx, msg_err_unknown_option_len
        call    af_out_bytes
        mov     edi, AF_FD_STDERR
        mov     rsi, [r12 + r13 * 8]
        call    af_out_cstr
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_newline]
        mov     rdx, 1
        call    af_out_bytes
        jmp     .usage_error

.socket_needs_value:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_prefix]
        mov     rdx, msg_err_prefix_len
        call    af_out_bytes
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_socket_needs_value]
        mov     rdx, msg_err_socket_needs_value_len
        call    af_out_bytes

.usage_error:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_hint]
        mov     rdx, msg_err_hint_len
        call    af_out_bytes
        mov     edi, AF_EXIT_USAGE
        call    af_sys_exit_group
        ud2
