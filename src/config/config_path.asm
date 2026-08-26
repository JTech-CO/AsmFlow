; AsmFlow — allowlisted path expansion.
;
; docs/CONFIGURATION.md 5: "Only a small allowlisted variable expansion is
; permitted for XDG paths. Arbitrary shell expansion, command substitution, and
; `~user` expansion are forbidden."
;
; This is the whole implementation of that sentence. The grammar accepted here
; is `${NAME}` for five specific names and nothing else. `$VAR`, `$(cmd)`,
; backticks, and `~` are all rejected rather than passed through, because a
; configuration path becomes a socket path, a database path, and a log path,
; and any of those reaching a shell would be a command-injection surface.
;
; The result must be absolute and must contain no `..` component: a relative or
; climbing path in a daemon that may run from an arbitrary working directory is
; not a convenience, it is an ambiguity about which file is being opened.

        bits 64
        default rel

%include "asmflow.inc"
%include "config.inc"

        extern af_buf_init
        extern af_buf_free
        extern af_buf_append
        extern af_buf_append_byte
        extern af_buf_append_cstr
        extern af_buf_data
        extern af_buf_len
        extern af_cstr_len
        extern af_mem_eq
        extern af_cfg_getenv
        extern af_cfg_intern
        extern af_sys_getuid
        extern af_u64_to_dec

%define PATH_MAX_BYTES 4096

        section .rodata
var_home:        db "HOME", 0
var_config_home: db "XDG_CONFIG_HOME", 0
var_state_home:  db "XDG_STATE_HOME", 0
var_data_home:   db "XDG_DATA_HOME", 0
var_runtime_dir: db "XDG_RUNTIME_DIR", 0

suffix_config:  db "/.config", 0
suffix_state:   db "/.local/state", 0
suffix_data:    db "/.local/share", 0
prefix_run_user: db "/run/user/", 0

dotdot: db "/../"
dotdot_len equ 4
dotdot_tail: db "/.."

        section .text

; ---------------------------------------------------------------------------
; af_cfg_lookup_xdg(const char *name, u64 name_len, af_buffer *out)
;   -> af_status
;
; Appends the value of one allowlisted variable to `out`, applying the
; XDG Base Directory default when the variable is unset. AF_E_CFG_PATH for a
; name that is not on the list, or when a needed default cannot be derived.
; ---------------------------------------------------------------------------
        global af_cfg_lookup_xdg
af_cfg_lookup_xdg:
        AF_ENTER 48
        mov     rbx, rdi                ; name
        mov     r12, rsi                ; name length
        mov     r13, rdx                ; out buffer

        ; HOME: no default; the process genuinely does not know where to put
        ; user state without it.
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [var_home]
        mov     rcx, 4
        call    af_cfg_name_is
        test    rax, rax
        jnz     .home

        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [var_config_home]
        mov     rcx, 15
        call    af_cfg_name_is
        test    rax, rax
        jnz     .config_home

        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [var_state_home]
        mov     rcx, 14
        call    af_cfg_name_is
        test    rax, rax
        jnz     .state_home

        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [var_data_home]
        mov     rcx, 13
        call    af_cfg_name_is
        test    rax, rax
        jnz     .data_home

        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [var_runtime_dir]
        mov     rcx, 15
        call    af_cfg_name_is
        test    rax, rax
        jnz     .runtime_dir

        AF_LEAVE_ERR AF_E_CFG_PATH

.home:
        lea     rdi, [var_home]
        call    af_cfg_getenv
        test    rax, rax
        jz      .no_home
        mov     rdi, r13
        mov     rsi, rax
        call    af_buf_append_cstr
        AF_LEAVE

.config_home:
        lea     rdi, [var_config_home]
        lea     rsi, [suffix_config]
        jmp     .home_relative

.state_home:
        lea     rdi, [var_state_home]
        lea     rsi, [suffix_state]
        jmp     .home_relative

.data_home:
        lea     rdi, [var_data_home]
        lea     rsi, [suffix_data]

; Common tail: use the variable when set, otherwise $HOME plus a fixed suffix.
.home_relative:
        mov     r14, rsi                ; default suffix
        call    af_cfg_getenv
        test    rax, rax
        jz      .use_home_default
        mov     rdi, r13
        mov     rsi, rax
        call    af_buf_append_cstr
        AF_LEAVE
.use_home_default:
        lea     rdi, [var_home]
        call    af_cfg_getenv
        test    rax, rax
        jz      .no_home
        mov     rdi, r13
        mov     rsi, rax
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, r14
        call    af_buf_append_cstr
        AF_LEAVE

; XDG_RUNTIME_DIR has no portable fallback in the specification, but a daemon
; that cannot place its control socket is unusable, so /run/user/<uid> is used
; and the caller still has to prove the directory is private before binding.
.runtime_dir:
        lea     rdi, [var_runtime_dir]
        call    af_cfg_getenv
        test    rax, rax
        jz      .runtime_default
        mov     rdi, r13
        mov     rsi, rax
        call    af_buf_append_cstr
        AF_LEAVE
.runtime_default:
        mov     rdi, r13
        lea     rsi, [prefix_run_user]
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
        call    af_sys_getuid
        mov     rdi, rax
        lea     rsi, [rsp]
        mov     rdx, 32
        lea     rcx, [rsp + 32]
        call    af_u64_to_dec
        test    rax, rax
        js      .done
        mov     rdi, r13
        lea     rsi, [rsp]
        mov     rdx, [rsp + 32]
        call    af_buf_append
        AF_LEAVE

.no_home:
        AF_LEAVE_ERR AF_E_CFG_PATH
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_name_is(const char *a, u64 a_len, const char *b, u64 b_len) -> i64
; ---------------------------------------------------------------------------
        global af_cfg_name_is
af_cfg_name_is:
        AF_ENTER 0
        cmp     rsi, rcx
        jne     .no
        mov     r8, rdx                 ; b
        mov     rdx, rsi                ; length
        mov     rsi, r8
        call    af_mem_eq
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_expand_path(af_arena *arena, const char *src, u64 len, char **out)
;   -> af_status
;
; Ownership: the expanded string is interned into `arena` and BORROWED by the
; caller for the arena's lifetime.
; ---------------------------------------------------------------------------
        global af_cfg_expand_path
af_cfg_expand_path:
        AF_ENTER 64
        test    rdi, rdi
        jz      .invalid
        test    rcx, rcx
        jz      .invalid
        mov     rbx, rdi                ; arena
        mov     r12, rsi                ; src
        mov     r13, rdx                ; len
        mov     r14, rcx                ; out

        lea     rdi, [rsp + 16]         ; scratch af_buffer
        mov     rsi, PATH_MAX_BYTES
        call    af_buf_init
        test    rax, rax
        js      .done

        xor     r15, r15                ; cursor
.loop:
        cmp     r15, r13
        jae     .expanded
        movzx   eax, byte [r12 + r15]

        cmp     al, '$'
        je      .dollar
        cmp     al, '`'
        je      .bad_path               ; command substitution
        cmp     al, 0
        je      .bad_path               ; embedded NUL
        cmp     al, 10
        je      .bad_path
        cmp     al, 13
        je      .bad_path

        lea     rdi, [rsp + 16]
        movzx   esi, al
        call    af_buf_append_byte
        test    rax, rax
        js      .cleanup_err
        inc     r15
        jmp     .loop

.dollar:
        ; Only `${NAME}` is accepted. `$VAR` and `$(cmd)` are rejected outright
        ; rather than passed through, so there is no second interpretation of
        ; the string anywhere downstream.
        lea     rax, [r15 + 1]
        cmp     rax, r13
        jae     .bad_path
        cmp     byte [r12 + rax], '{'
        jne     .bad_path
        add     rax, 1                  ; first byte of NAME
        mov     [rsp], rax              ; name start
        mov     rcx, rax
.find_close:
        cmp     rcx, r13
        jae     .bad_path
        cmp     byte [r12 + rcx], '}'
        je      .have_name
        inc     rcx
        jmp     .find_close
.have_name:
        mov     rax, rcx
        sub     rax, [rsp]
        test    rax, rax
        jz      .bad_path
        mov     [rsp + 8], rcx          ; index of '}'
        mov     rdi, r12
        add     rdi, [rsp]
        mov     rsi, rax
        lea     rdx, [rsp + 16]
        call    af_cfg_lookup_xdg
        test    rax, rax
        js      .cleanup_err
        mov     r15, [rsp + 8]
        inc     r15
        jmp     .loop

.expanded:
        lea     rdi, [rsp + 16]
        call    af_buf_data
        mov     [rsp], rax
        lea     rdi, [rsp + 16]
        call    af_buf_len
        mov     [rsp + 8], rax

        ; An expanded path must be absolute and must not climb.
        test    rax, rax
        jz      .cleanup_bad
        mov     rcx, [rsp]
        cmp     byte [rcx], '/'
        jne     .cleanup_bad

        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_path_has_dotdot
        test    rax, rax
        jnz     .cleanup_bad

        mov     rdi, rbx
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        mov     rcx, r14
        call    af_cfg_intern
        mov     [rsp + 8], rax
        lea     rdi, [rsp + 16]
        call    af_buf_free
        mov     rax, [rsp + 8]
        AF_LEAVE

.cleanup_bad:
        lea     rdi, [rsp + 16]
        call    af_buf_free
        AF_LEAVE_ERR AF_E_CFG_PATH
.cleanup_err:
        mov     [rsp + 8], rax
        lea     rdi, [rsp + 16]
        call    af_buf_free
        mov     rax, [rsp + 8]
        AF_LEAVE
.bad_path:
        lea     rdi, [rsp + 16]
        call    af_buf_free
        AF_LEAVE_ERR AF_E_CFG_PATH
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_path_has_dotdot(const char *p, u64 len) -> i64 (1 = contains "..")
;
; Component-wise: matches "/../", a trailing "/..", and a leading "../".
; ---------------------------------------------------------------------------
        global af_cfg_path_has_dotdot
af_cfg_path_has_dotdot:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi

        ; leading "../"
        cmp     r12, 3
        jb      .check_interior
        mov     rdi, rbx
        lea     rsi, [dotdot + 1]       ; "../"
        mov     rdx, 3
        call    af_mem_eq
        test    rax, rax
        jnz     .yes

.check_interior:
        cmp     r12, 4
        jb      .check_tail
        xor     r13, r13
.scan:
        mov     rax, r12
        sub     rax, 4
        cmp     r13, rax
        ja      .check_tail
        lea     rdi, [rbx + r13]
        lea     rsi, [dotdot]
        mov     rdx, dotdot_len
        call    af_mem_eq
        test    rax, rax
        jnz     .yes
        inc     r13
        jmp     .scan

.check_tail:
        cmp     r12, 3
        jb      .no
        lea     rdi, [rbx + r12 - 3]
        lea     rsi, [dotdot_tail]
        mov     rdx, 3
        call    af_mem_eq
        test    rax, rax
        jnz     .yes
.no:
        xor     eax, eax
        AF_LEAVE
.yes:
        mov     eax, 1
        AF_LEAVE
