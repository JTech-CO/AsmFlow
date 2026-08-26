; AsmFlow — asmflowd entry point.
;
; The daemon owns every piece of mutable state: listeners, upstream
; connections, health, MCP children, and the single SQLite writer
; (ARCHITECTURE.md §2). This file does argument handling only; it must not
; touch the terminal, the database, or the network before a subcommand asks
; for it, so that `--version` and `--help` stay side-effect free (M1 DoD 2).

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
        extern af_daemon_run
        extern af_daemon_check_config

%define AF_FD_STDOUT 1
%define AF_FD_STDERR 2

        section .rodata

msg_version_prefix:
        db      AF_DAEMON_NAME, " "
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
        db      AF_DAEMON_NAME, " - ", AF_PRODUCT_NAME, " gateway and MCP supervisor daemon", 10
        db      10
        db      "Usage:", 10
        db      "  ", AF_DAEMON_NAME, " [options]", 10
        db      10
        db      "Options:", 10
        db      "  --config PATH     Configuration file to load.", 10
        db      "                    Default: ${XDG_CONFIG_HOME}/asmflow/asmflow.json", 10
        db      "  --check-config    Validate the configuration and exit without", 10
        db      "                    binding a listener or opening the database.", 10
        db      "  --version, -V     Print the version and exit.", 10
        db      "  --help, -h        Print this help and exit.", 10
        db      10
        db      "Exit codes:", 10
        db      "  0   success", 10
        db      "  2   usage error", 10
        db      "  3   configuration rejected", 10
        db      "  4   storage or migration failure", 10
        db      "  5   listener or control socket failure", 10
        db      "  70  internal error", 10
        db      10
        db      "The data plane binds to loopback unless the configuration sets another", 10
        db      "host together with an authentication policy. Secrets are read from the", 10
        db      "environment through configuration references only; they are never", 10
        db      "accepted on the command line.", 10
        db      10
        db      "See docs/API_CONTRACT.md and docs/CONFIGURATION.md.", 10
msg_usage_len equ $ - msg_usage

msg_err_prefix:
        db      AF_DAEMON_NAME, ": "
msg_err_prefix_len equ $ - msg_err_prefix

msg_err_unknown_option:
        db      "unknown option: "
msg_err_unknown_option_len equ $ - msg_err_unknown_option

msg_err_config_needs_value:
        db      "--config requires a path argument", 10
msg_err_config_needs_value_len equ $ - msg_err_config_needs_value

msg_err_hint:
        db      10, "Run '", AF_DAEMON_NAME, " --help' for usage.", 10
msg_err_hint_len equ $ - msg_err_hint

msg_newline:
        db      10

opt_version_long:  db "--version", 0
opt_version_short: db "-V", 0
opt_help_long:     db "--help", 0
opt_help_short:    db "-h", 0
opt_config:        db "--config", 0
opt_check_config:  db "--check-config", 0

        section .text

; ---------------------------------------------------------------------------
; main(int argc, char **argv, char **envp) -> int
;
; Registers: rbx = argc, r12 = argv, r13 = argument index,
;            r14 = --config value (BORROWED from argv, NULL when unset),
;            r15 = mode flags.
; ---------------------------------------------------------------------------
%define MODE_CHECK_CONFIG 1

        global main
main:
        AF_ENTER 16                     ; [rsp+0]: size_t out-param for af_*_str
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, 1                  ; skip argv[0]
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
        lea     rsi, [opt_check_config]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_check_config

        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_config]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_config

        jmp     .unknown_option

.do_check_config:
        or      r15, MODE_CHECK_CONFIG
        inc     r13
        jmp     .next_arg

.do_config:
        inc     r13
        cmp     r13, rbx
        jae     .config_needs_value
        mov     r14, [r12 + r13 * 8]
        inc     r13
        jmp     .next_arg

.args_done:
        test    r15, MODE_CHECK_CONFIG
        jnz     .run_check_config
        mov     rdi, r14
        call    af_daemon_run
        jmp     .exit_status

.run_check_config:
        mov     rdi, r14
        call    af_daemon_check_config
.exit_status:
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

.config_needs_value:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_prefix]
        mov     rdx, msg_err_prefix_len
        call    af_out_bytes
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_config_needs_value]
        mov     rdx, msg_err_config_needs_value_len
        call    af_out_bytes

.usage_error:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_err_hint]
        mov     rdx, msg_err_hint_len
        call    af_out_bytes
        mov     edi, AF_EXIT_USAGE
        call    af_sys_exit_group
        ud2
