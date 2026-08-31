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
%include "tui.inc"

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
        db      "  --screen NAME     Initial screen: overview, providers, routes,", 10
        db      "                    requests, mcp, logs, or settings.", 10
        db      "  --dump-layout WxH Write a canonical non-interactive layout and exit.", 10
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
        db      "unknown option", 10
msg_err_unknown_option_len equ $ - msg_err_unknown_option

msg_err_socket_needs_value:
        db      "--socket requires a path argument", 10
msg_err_socket_needs_value_len equ $ - msg_err_socket_needs_value

msg_err_hint:
        db      10, "Run '", AF_TUI_NAME, " --help' for usage.", 10
msg_err_hint_len equ $ - msg_err_hint

opt_version_long:  db "--version", 0
opt_version_short: db "-V", 0
opt_help_long:     db "--help", 0
opt_help_short:    db "-h", 0
opt_socket:        db "--socket", 0
opt_mono:          db "--mono", 0
opt_screen:        db "--screen", 0
opt_dump_layout:   db "--dump-layout", 0

screen_overview:   db "overview", 0
screen_providers:  db "providers", 0
screen_routes:     db "routes", 0
screen_requests:   db "requests", 0
screen_mcp:        db "mcp", 0
screen_logs:       db "logs", 0
screen_settings:   db "settings", 0

msg_err_screen_needs_value:
        db      "--screen requires one of overview, providers, routes, requests, mcp, logs, settings", 10
msg_err_screen_needs_value_len equ $ - msg_err_screen_needs_value

msg_err_dump_needs_value:
        db      "--dump-layout requires WIDTHxHEIGHT within 1..512 by 1..256", 10
msg_err_dump_needs_value_len equ $ - msg_err_dump_needs_value

        section .text

; ---------------------------------------------------------------------------
; main(int argc, char **argv, char **envp) -> int
;
; Registers: rbx = argc, r12 = argv, r13 = index,
;            r14 = --socket value (BORROWED, NULL when unset), r15 = flags.
; ---------------------------------------------------------------------------
%define TUI_FLAG_MONO 1
%define TUI_FLAG_DUMP 2

        global main
main:
        AF_ENTER 48                     ; 0=str len, 8=width, 16=height, 24=screen
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, 1
        xor     r14, r14
        xor     r15, r15
        mov     qword [rsp + 8], 0
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 24], AF_TUI_SCREEN_OVERVIEW

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

        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_screen]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_screen

        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_dump_layout]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_dump_layout

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

.do_screen:
        inc     r13
        cmp     r13, rbx
        jae     .screen_needs_value
        mov     rdi, [r12 + r13 * 8]
        call    af_tui_screen_name
        test    rax, rax
        jz      .screen_needs_value
        mov     [rsp + 24], rax
        inc     r13
        jmp     .next_arg

.do_dump_layout:
        inc     r13
        cmp     r13, rbx
        jae     .dump_needs_value
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [rsp + 8]
        lea     rdx, [rsp + 16]
        call    af_tui_parse_dimensions
        test    rax, rax
        js      .dump_needs_value
        or      r15, TUI_FLAG_DUMP
        inc     r13
        jmp     .next_arg

.args_done:
        mov     rdi, r14
        mov     rsi, r15
        mov     rdx, [rsp + 8]
        mov     rcx, [rsp + 16]
        mov     r8, [rsp + 24]
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
        jmp     .usage_error

.screen_needs_value:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_prefix]
        mov     rdx, msg_err_prefix_len
        call    af_out_bytes
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_screen_needs_value]
        mov     rdx, msg_err_screen_needs_value_len
        call    af_out_bytes
        jmp     .usage_error

.dump_needs_value:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_prefix]
        mov     rdx, msg_err_prefix_len
        call    af_out_bytes
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_dump_needs_value]
        mov     rdx, msg_err_dump_needs_value_len
        call    af_out_bytes
        jmp     .usage_error

.usage_error:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_hint]
        mov     rdx, msg_err_hint_len
        call    af_out_bytes
        mov     edi, AF_EXIT_USAGE
        call    af_sys_exit_group
        ud2

; ---------------------------------------------------------------------------
; af_tui_parse_dimensions(const char *text, u64 *out_width, u64 *out_height)
;   -> af_status
;
; The argv span is BORROWED and NUL-terminated. Both products are bounded
; before they are published, so the renderer can safely multiply them later.
; ---------------------------------------------------------------------------
af_tui_parse_dimensions:
        test    rdi, rdi
        jz      .dim_invalid
        test    rsi, rsi
        jz      .dim_invalid
        test    rdx, rdx
        jz      .dim_invalid
        xor     r8d, r8d                 ; width
        xor     r9d, r9d                 ; digit count
.dim_width:
        movzx   eax, byte [rdi]
        cmp     al, 'x'
        je      .dim_separator
        cmp     al, 'X'
        je      .dim_separator
        cmp     al, '0'
        jb      .dim_invalid
        cmp     al, '9'
        ja      .dim_invalid
        imul    r8, r8, 10
        sub     eax, '0'
        add     r8, rax
        cmp     r8, AF_TUI_MAX_COLUMNS
        ja      .dim_range
        inc     r9
        inc     rdi
        jmp     .dim_width
.dim_separator:
        test    r9, r9
        jz      .dim_invalid
        inc     rdi
        xor     r10d, r10d               ; height
        xor     r9d, r9d
.dim_height:
        movzx   eax, byte [rdi]
        test    al, al
        jz      .dim_done
        cmp     al, '0'
        jb      .dim_invalid
        cmp     al, '9'
        ja      .dim_invalid
        imul    r10, r10, 10
        sub     eax, '0'
        add     r10, rax
        cmp     r10, AF_TUI_MAX_ROWS
        ja      .dim_range
        inc     r9
        inc     rdi
        jmp     .dim_height
.dim_done:
        test    r9, r9
        jz      .dim_invalid
        test    r8, r8
        jz      .dim_range
        test    r10, r10
        jz      .dim_range
        mov     [rsi], r8
        mov     [rdx], r10
        xor     eax, eax
        ret
.dim_range:
        mov     rax, AF_E_RANGE
        ret
.dim_invalid:
        mov     rax, AF_E_INVALID
        ret

; af_tui_screen_name(const char *name) -> screen id, or zero.
af_tui_screen_name:
        push    rbx
        mov     rbx, rdi
%macro TRY_SCREEN 2
        mov     rdi, rbx
        lea     rsi, [%1]
        call    af_cstr_eq
        test    rax, rax
        jnz     %%match
        jmp     %%next
%%match:
        mov     eax, %2
        pop     rbx
        ret
%%next:
%endmacro
        TRY_SCREEN screen_overview,  AF_TUI_SCREEN_OVERVIEW
        TRY_SCREEN screen_providers, AF_TUI_SCREEN_PROVIDERS
        TRY_SCREEN screen_routes,    AF_TUI_SCREEN_ROUTES
        TRY_SCREEN screen_requests,  AF_TUI_SCREEN_REQUESTS
        TRY_SCREEN screen_mcp,       AF_TUI_SCREEN_MCP
        TRY_SCREEN screen_logs,      AF_TUI_SCREEN_LOGS
        TRY_SCREEN screen_settings,  AF_TUI_SCREEN_SETTINGS
        xor     eax, eax
        pop     rbx
        ret
