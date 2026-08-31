; AsmFlow -- non-interactive control client entry point.
;
; argv strings are BORROWED process-lifetime storage.  Parsing and all usage
; decisions happen before `af_ctl_cli_run` is allowed to resolve or connect a
; socket, so malformed local input cannot reach the daemon.

        bits 64
        default rel

%include "asmflow.inc"
%include "control_client.inc"

        extern af_out_bytes
        extern af_cstr_eq
        extern af_sys_exit_group
        extern af_version_str
        extern af_build_target_str
        extern af_build_mode_str
        extern af_ctl_cli_run

%define CTL_FD_STDOUT 1
%define CTL_FD_STDERR 2

%define CTLE_MODE_SEEN   1
%define CTLE_SOCKET_SEEN 2

        section .rodata

ctle_opt_socket:        db "--socket", 0
ctle_opt_json:          db "--json", 0
ctle_opt_table:         db "--table", 0
ctle_opt_help_long:     db "--help", 0
ctle_opt_help_short:    db "-h", 0
ctle_opt_version_long:  db "--version", 0
ctle_opt_version_short: db "-V", 0

ctle_usage:
        db AF_CTL_NAME, " - ", AF_PRODUCT_NAME, " control client", 10
        db 10
        db "Usage:", 10
        db "  ", AF_CTL_NAME, " [--socket PATH] [--json|--table] METHOD [PARAMS_JSON]", 10
        db 10
        db "Options:", 10
        db "  --socket PATH  Connect to PATH instead of the runtime control socket.", 10
        db "  --json         Write the full response envelope as one JSON line.", 10
        db "  --table        Write deterministic human-readable output (default).", 10
        db "  --version, -V  Print the version and exit.", 10
        db "  --help, -h     Print this help and exit.", 10
        db 10
        db "PARAMS_JSON, when present, must be a bounded JSON object.", 10
ctle_usage_len equ $ - ctle_usage

ctle_usage_hint:
        db "Usage: ", AF_CTL_NAME
        db " [--socket PATH] [--json|--table] METHOD [PARAMS_JSON]", 10
ctle_usage_hint_len equ $ - ctle_usage_hint

ctle_err_unknown: db AF_CTL_NAME, ": unknown option or extra argument.", 10
ctle_err_unknown_len equ $ - ctle_err_unknown
ctle_err_socket_value: db AF_CTL_NAME, ": --socket requires one PATH.", 10
ctle_err_socket_value_len equ $ - ctle_err_socket_value
ctle_err_mode: db AF_CTL_NAME, ": choose exactly one of --json and --table.", 10
ctle_err_mode_len equ $ - ctle_err_mode
ctle_err_method: db AF_CTL_NAME, ": METHOD is required.", 10
ctle_err_method_len equ $ - ctle_err_method
ctle_version_prefix: db AF_CTL_NAME, " "
ctle_version_prefix_len equ $ - ctle_version_prefix
ctle_version_mid: db " ("
ctle_version_mid_len equ $ - ctle_version_mid
ctle_version_sep: db ", "
ctle_version_sep_len equ $ - ctle_version_sep
ctle_version_suffix: db ")", 10
ctle_version_suffix_len equ $ - ctle_version_suffix

        section .text

; main(int argc, char **argv, char **envp) -> int
;
; rbx=argc, r12=argv, r13=index, r14=socket (BORROWED), r15=flags.
; Locals: +0 mode, +8 method (BORROWED), +16 params (BORROWED), +24 length.
        global main
main:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, 1
        xor     r14d, r14d
        xor     r15d, r15d
        mov     qword [rsp], AF_CTL_MODE_TABLE
        mov     qword [rsp + 8], 0
        mov     qword [rsp + 16], 0

.options:
        cmp     r13, rbx
        jae     .missing_method
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [ctle_opt_help_long]
        call    af_cstr_eq
        test    rax, rax
        jnz     .help
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [ctle_opt_help_short]
        call    af_cstr_eq
        test    rax, rax
        jnz     .help
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [ctle_opt_version_long]
        call    af_cstr_eq
        test    rax, rax
        jnz     .version
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [ctle_opt_version_short]
        call    af_cstr_eq
        test    rax, rax
        jnz     .version
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [ctle_opt_socket]
        call    af_cstr_eq
        test    rax, rax
        jnz     .socket
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [ctle_opt_json]
        call    af_cstr_eq
        test    rax, rax
        jnz     .json
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [ctle_opt_table]
        call    af_cstr_eq
        test    rax, rax
        jnz     .table

        ; Before METHOD, a leading '-' is an unknown option.  This prevents a
        ; typo from becoming an arbitrary daemon method.
        mov     rax, [r12 + r13 * 8]
        cmp     byte [rax], '-'
        je      .unknown
        mov     [rsp + 8], rax
        inc     r13
        cmp     r13, rbx
        jae     .run
        mov     rax, [r12 + r13 * 8]
        mov     [rsp + 16], rax
        inc     r13
        cmp     r13, rbx
        jb      .unknown
        jmp     .run

.socket:
        test    r15, CTLE_SOCKET_SEEN
        jnz     .socket_error
        inc     r13
        cmp     r13, rbx
        jae     .socket_error
        mov     r14, [r12 + r13 * 8]
        or      r15, CTLE_SOCKET_SEEN
        inc     r13
        jmp     .options

.json:
        test    r15, CTLE_MODE_SEEN
        jnz     .mode_error
        mov     qword [rsp], AF_CTL_MODE_JSON
        or      r15, CTLE_MODE_SEEN
        inc     r13
        jmp     .options

.table:
        test    r15, CTLE_MODE_SEEN
        jnz     .mode_error
        mov     qword [rsp], AF_CTL_MODE_TABLE
        or      r15, CTLE_MODE_SEEN
        inc     r13
        jmp     .options

.run:
        mov     rdi, r14
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        mov     rcx, [rsp + 16]
        call    af_ctl_cli_run
        mov     rdi, rax
        call    af_sys_exit_group
        ud2

.help:
        mov     edi, CTL_FD_STDOUT
        lea     rsi, [ctle_usage]
        mov     rdx, ctle_usage_len
        call    af_out_bytes
        mov     edi, AF_EXIT_OK
        call    af_sys_exit_group
        ud2

.version:
        mov     edi, CTL_FD_STDOUT
        lea     rsi, [ctle_version_prefix]
        mov     rdx, ctle_version_prefix_len
        call    af_out_bytes
        lea     rdi, [rsp + 24]
        call    af_version_str
        mov     rsi, rax
        mov     rdx, [rsp + 24]
        mov     edi, CTL_FD_STDOUT
        call    af_out_bytes
        mov     edi, CTL_FD_STDOUT
        lea     rsi, [ctle_version_mid]
        mov     rdx, ctle_version_mid_len
        call    af_out_bytes
        lea     rdi, [rsp + 24]
        call    af_build_target_str
        mov     rsi, rax
        mov     rdx, [rsp + 24]
        mov     edi, CTL_FD_STDOUT
        call    af_out_bytes
        mov     edi, CTL_FD_STDOUT
        lea     rsi, [ctle_version_sep]
        mov     rdx, ctle_version_sep_len
        call    af_out_bytes
        lea     rdi, [rsp + 24]
        call    af_build_mode_str
        mov     rsi, rax
        mov     rdx, [rsp + 24]
        mov     edi, CTL_FD_STDOUT
        call    af_out_bytes
        mov     edi, CTL_FD_STDOUT
        lea     rsi, [ctle_version_suffix]
        mov     rdx, ctle_version_suffix_len
        call    af_out_bytes
        mov     edi, AF_EXIT_OK
        call    af_sys_exit_group
        ud2

.unknown:
        mov     edi, CTL_FD_STDERR
        lea     rsi, [ctle_err_unknown]
        mov     rdx, ctle_err_unknown_len
        call    af_out_bytes
        jmp     .usage_error
.socket_error:
        mov     edi, CTL_FD_STDERR
        lea     rsi, [ctle_err_socket_value]
        mov     rdx, ctle_err_socket_value_len
        call    af_out_bytes
        jmp     .usage_error
.mode_error:
        mov     edi, CTL_FD_STDERR
        lea     rsi, [ctle_err_mode]
        mov     rdx, ctle_err_mode_len
        call    af_out_bytes
        jmp     .usage_error
.missing_method:
        mov     edi, CTL_FD_STDERR
        lea     rsi, [ctle_err_method]
        mov     rdx, ctle_err_method_len
        call    af_out_bytes
.usage_error:
        mov     edi, CTL_FD_STDERR
        lea     rsi, [ctle_usage_hint]
        mov     rdx, ctle_usage_hint_len
        call    af_out_bytes
        mov     edi, AF_EXIT_USAGE
        call    af_sys_exit_group
        ud2
