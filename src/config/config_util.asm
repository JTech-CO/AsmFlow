; AsmFlow — configuration validation primitives.
;
; The patterns here are the runtime half of config/asmflow.schema.json. The
; schema is the contract; this file applies the identical rules directly, so
; the daemon never depends on a JSON Schema library at runtime and a
; schema-valid file is exactly a runtime-valid file (HARNESS.md M3 DoD 8, and
; the warning against skipping the assembly validator).
;
; Everything here is pure: no allocation except the explicit arena interning,
; no global state, no side effects.

        bits 64
        default rel

%include "asmflow.inc"
%include "config.inc"

        extern af_arena_alloc
        extern af_mem_copy
        extern af_mem_eq
        extern af_cstr_len
        extern af_add_size
        extern getenv
        extern af_sys_getuid

        section .text

; ---------------------------------------------------------------------------
; af_cfg_intern(af_arena *arena, const char *src, u64 len, char **out)
;   -> af_status
;
; Copies `len` bytes into the snapshot arena and appends a NUL. Ownership: the
; result is BORROWED from the arena and lives exactly as long as the snapshot.
; The terminator is not optional: these strings are handed to libcurl, SQLite,
; and execve, none of which take a length.
; ---------------------------------------------------------------------------
        global af_cfg_intern
af_cfg_intern:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        test    rcx, rcx
        jz      .invalid
        mov     rbx, rdi                ; arena
        mov     r12, rsi                ; src
        mov     r13, rdx                ; len
        mov     r14, rcx                ; out

        mov     rdi, r13
        mov     rsi, 1
        lea     rdx, [rsp]
        call    af_add_size
        test    rax, rax
        js      .done

        mov     rdi, rbx
        mov     rsi, [rsp]
        mov     rdx, 1
        call    af_arena_alloc
        test    rax, rax
        jz      .nomem
        mov     r15, rax

        test    r13, r13
        jz      .terminate
        mov     rdi, r15
        mov     rsi, r12
        mov     rdx, r13
        call    af_mem_copy
.terminate:
        mov     byte [r15 + r13], 0
        mov     [r14], r15
        AF_LEAVE_OK
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_id_valid(const char *s, u64 len) -> i64 (1 = valid)
;
; Schema `$defs/id`: ^[a-z0-9][a-z0-9._-]{0,63}$
;
; Identifiers appear in file paths, log fields, and control-protocol responses,
; so the character set is deliberately narrower than "anything JSON allows".
; ---------------------------------------------------------------------------
; These validators are written as call-free leaves. A function that issues a
; `call` has to establish the uniform frame first, because at entry rsp is
; 8 mod 16 and calling from there would break invariant 4; inlining the
; character tests keeps them honest and fast at the same time.
        global af_cfg_id_valid
af_cfg_id_valid:
        test    rsi, rsi
        jz      .no
        cmp     rsi, 64
        ja      .no
        ; The first character must be a lowercase letter or a digit.
        movzx   eax, byte [rdi]
        cmp     al, 'a'
        jb      .first_digit
        cmp     al, 'z'
        jbe     .first_ok
        jmp     .no
.first_digit:
        cmp     al, '0'
        jb      .no
        cmp     al, '9'
        ja      .no
.first_ok:
        mov     rcx, 1
.loop:
        cmp     rcx, rsi
        jae     .yes
        movzx   eax, byte [rdi + rcx]
        cmp     al, 'a'
        jb      .check_digit_or_punct
        cmp     al, 'z'
        jbe     .next
        jmp     .no
.check_digit_or_punct:
        cmp     al, '0'
        jb      .check_punct
        cmp     al, '9'
        jbe     .next
        jmp     .no
.check_punct:
        cmp     al, '.'
        je      .next
        cmp     al, '_'
        je      .next
        cmp     al, '-'
        je      .next
        jmp     .no
.next:
        inc     rcx
        jmp     .loop
.yes:
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_cfg_env_name_valid(const char *s, u64 len) -> i64 (1 = valid)
;
; Schema `$defs/envName`: ^[A-Z_][A-Z0-9_]*$ with maxLength 128.
; ---------------------------------------------------------------------------
        global af_cfg_env_name_valid
af_cfg_env_name_valid:
        test    rsi, rsi
        jz      .no
        cmp     rsi, 128
        ja      .no
        movzx   eax, byte [rdi]
        cmp     al, '_'
        je      .first_ok
        cmp     al, 'A'
        jb      .no
        cmp     al, 'Z'
        ja      .no
.first_ok:
        mov     rcx, 1
.loop:
        cmp     rcx, rsi
        jae     .yes
        movzx   eax, byte [rdi + rcx]
        cmp     al, '_'
        je      .next
        cmp     al, 'A'
        jb      .digit
        cmp     al, 'Z'
        jbe     .next
        jmp     .no
.digit:
        cmp     al, '0'
        jb      .no
        cmp     al, '9'
        ja      .no
.next:
        inc     rcx
        jmp     .loop
.yes:
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_cfg_model_alias_valid(const char *s, u64 len) -> i64 (1 = valid)
;
; Schema `$defs/route/model_alias`: ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$
;
; The alias is what a client sends as `model`, so it is compared against
; untrusted input on every request; keeping it to this set means the comparison
; never has to consider encoding.
; ---------------------------------------------------------------------------
        global af_cfg_model_alias_valid
af_cfg_model_alias_valid:
        test    rsi, rsi
        jz      .no
        cmp     rsi, 128
        ja      .no
        movzx   eax, byte [rdi]
        cmp     al, '0'
        jb      .no
        cmp     al, '9'
        jbe     .first_ok
        cmp     al, 'A'
        jb      .no
        cmp     al, 'Z'
        jbe     .first_ok
        cmp     al, 'a'
        jb      .no
        cmp     al, 'z'
        ja      .no
.first_ok:
        mov     rcx, 1
.loop:
        cmp     rcx, rsi
        jae     .yes
        movzx   eax, byte [rdi + rcx]
        cmp     al, '0'
        jb      .punct
        cmp     al, '9'
        jbe     .next
        cmp     al, 'A'
        jb      .punct
        cmp     al, 'Z'
        jbe     .next
        cmp     al, 'a'
        jb      .punct
        cmp     al, 'z'
        jbe     .next
        jmp     .no
.punct:
        cmp     al, '.'
        je      .next
        cmp     al, '_'
        je      .next
        cmp     al, ':'
        je      .next
        cmp     al, '/'
        je      .next
        cmp     al, '-'
        je      .next
        jmp     .no
.next:
        inc     rcx
        jmp     .loop
.yes:
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_cfg_header_name_valid(const char *s, u64 len) -> i64 (1 = valid)
;
; Schema `$defs/auth/header`: ^[A-Za-z0-9-]{1,64}$
;
; This is also the guard that keeps a configured header name from carrying a
; colon, CR, or LF into an outbound request.
; ---------------------------------------------------------------------------
        global af_cfg_header_name_valid
af_cfg_header_name_valid:
        test    rsi, rsi
        jz      .no
        cmp     rsi, 64
        ja      .no
        xor     ecx, ecx
.loop:
        cmp     rcx, rsi
        jae     .yes
        movzx   eax, byte [rdi + rcx]
        cmp     al, '-'
        je      .next
        cmp     al, '0'
        jb      .no
        cmp     al, '9'
        jbe     .next
        cmp     al, 'A'
        jb      .no
        cmp     al, 'Z'
        jbe     .next
        cmp     al, 'a'
        jb      .no
        cmp     al, 'z'
        ja      .no
.next:
        inc     rcx
        jmp     .loop
.yes:
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_cfg_enum_lookup(const char *s, u64 len, const void *table, i64 *out)
;   -> af_status
;
; `table` is an array of {const char *name; i64 value} terminated by a NULL
; name. AF_E_CFG_SCHEMA when the string matches no entry, which is what makes
; an unknown enum value a rejection rather than a silent default.
; ---------------------------------------------------------------------------
        global af_cfg_enum_lookup
af_cfg_enum_lookup:
        AF_ENTER 0
        mov     rbx, rdi                ; s
        mov     r12, rsi                ; len
        mov     r13, rdx                ; table
        mov     r14, rcx                ; out
.loop:
        mov     r15, [r13]
        test    r15, r15
        jz      .not_found
        mov     rdi, r15
        call    af_cstr_len
        cmp     rax, r12
        jne     .advance
        mov     rdi, r15
        mov     rsi, rbx
        mov     rdx, r12
        call    af_mem_eq
        test    rax, rax
        jnz     .found
.advance:
        add     r13, 16
        jmp     .loop
.found:
        test    r14, r14
        jz      .ok
        mov     rax, [r13 + 8]
        mov     [r14], rax
.ok:
        AF_LEAVE_OK
.not_found:
        AF_LEAVE_ERR AF_E_CFG_SCHEMA

; ---------------------------------------------------------------------------
; af_cfg_is_loopback_host(const char *s, u64 len) -> i64 (1 = loopback)
;
; Exactly the three forms the contract names: 127.0.0.1, ::1, localhost. Any
; other 127.0.0.0/8 address is deliberately not treated as loopback here,
; because the listener contract in docs/CONFIGURATION.md 4 lists these three and
; nothing else; an operator using another one has to state an auth policy.
; ---------------------------------------------------------------------------
        global af_cfg_is_loopback_host
af_cfg_is_loopback_host:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi

        cmp     r12, 9
        jne     .try_ipv6
        mov     rdi, rbx
        lea     rsi, [host_127]
        mov     rdx, 9
        call    af_mem_eq
        test    rax, rax
        jnz     .yes
        mov     rdi, rbx
        lea     rsi, [host_localhost]
        mov     rdx, 9
        call    af_mem_eq
        test    rax, rax
        jnz     .yes
        jmp     .no

.try_ipv6:
        cmp     r12, 3
        jne     .no
        mov     rdi, rbx
        lea     rsi, [host_ipv6]
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

; ---------------------------------------------------------------------------
; af_cfg_url_check(const char *url, u64 len, i64 allow_insecure_private_http,
;                  i64 *out_is_loopback) -> af_status
;
; Applies the provider URL rules from docs/CONFIGURATION.md 9 and the SSRF
; policy in SECURITY_MODEL.md 8:
;
;   * scheme must be http:// or https://
;   * embedded credentials (`user:pass@`) are rejected outright
;   * a fragment is rejected
;   * plain http is accepted only for a loopback host, or with an explicit
;     allow_insecure_private_http
;   * control characters and whitespace anywhere in the URL are rejected
;
; Client requests can never supply a URL, so this runs only over operator
; input; it is still validated strictly because a mistyped scheme is the
; difference between TLS and plaintext credentials on the wire.
; ---------------------------------------------------------------------------
        global af_cfg_url_check
af_cfg_url_check:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi                ; url
        mov     r12, rsi                ; len
        mov     r13, rdx                ; allow_insecure
        mov     r14, rcx                ; out_is_loopback
        test    r14, r14
        jz      .no_out
        mov     qword [r14], 0
.no_out:

        ; Reject any byte outside printable ASCII before parsing structure, so
        ; a CR or a space cannot survive into a request line.
        xor     ecx, ecx
.charscan:
        cmp     rcx, r12
        jae     .charscan_done
        movzx   eax, byte [rbx + rcx]
        cmp     al, 0x21
        jb      .bad_url
        cmp     al, 0x7E
        ja      .bad_url
        cmp     al, '#'
        je      .bad_url                ; fragments are rejected
        inc     rcx
        jmp     .charscan
.charscan_done:

        ; Scheme.
        mov     qword [rsp], 0          ; 1 = https
        cmp     r12, 8
        jb      .maybe_http
        mov     rdi, rbx
        lea     rsi, [scheme_https]
        mov     rdx, 8
        call    af_mem_eq
        test    rax, rax
        jz      .maybe_http
        mov     qword [rsp], 1
        mov     r15, 8                  ; authority starts here
        jmp     .authority
.maybe_http:
        cmp     r12, 7
        jb      .bad_url
        mov     rdi, rbx
        lea     rsi, [scheme_http]
        mov     rdx, 7
        call    af_mem_eq
        test    rax, rax
        jz      .bad_url
        mov     r15, 7

.authority:
        ; The authority ends at the first '/', '?', or end of string.
        mov     rcx, r15
        mov     [rsp + 8], rcx          ; authority start
.find_end:
        cmp     rcx, r12
        jae     .authority_end
        movzx   eax, byte [rbx + rcx]
        cmp     al, '/'
        je      .authority_end
        cmp     al, '?'
        je      .authority_end
        cmp     al, '@'
        je      .bad_credentials
        inc     rcx
        jmp     .find_end
.authority_end:
        mov     [rsp + 16], rcx         ; authority end

        ; Host is the authority without an optional :port suffix.
        mov     rdi, [rsp + 8]
        mov     rsi, rcx
        sub     rsi, rdi
        test    rsi, rsi
        jz      .bad_url
        mov     [rsp + 24], rsi         ; authority length
        ; Scan backwards for ':' to strip a port, stopping at ']' so an IPv6
        ; literal's own colons are not mistaken for a port separator.
        mov     rcx, rsi
.port_scan:
        test    rcx, rcx
        jz      .host_ready
        dec     rcx
        mov     rax, rbx
        add     rax, [rsp + 8]          ; x86 addressing takes two registers
        movzx   edx, byte [rax + rcx]
        cmp     dl, ']'
        je      .host_ready
        cmp     dl, ':'
        jne     .port_scan
        mov     [rsp + 24], rcx         ; host length excludes ":port"
.host_ready:
        mov     rdi, rbx
        add     rdi, [rsp + 8]
        mov     rsi, [rsp + 24]
        test    rsi, rsi
        jz      .bad_url
        call    af_cfg_is_loopback_host
        test    r14, r14
        jz      .after_loopback
        mov     [r14], rax
.after_loopback:
        mov     [rsp + 8], rax          ; is_loopback

        ; Plain http needs either a loopback host or an explicit exception.
        cmp     qword [rsp], 1
        je      .ok
        cmp     qword [rsp + 8], 0
        jne     .ok
        test    r13, r13
        jnz     .ok
        AF_LEAVE_ERR AF_E_CFG_URL
.ok:
        AF_LEAVE_OK
.bad_credentials:
        AF_LEAVE_ERR AF_E_CFG_URL
.bad_url:
        AF_LEAVE_ERR AF_E_CFG_URL
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_cfg_getenv(const char *name) -> const char * (BORROWED from the
;   environment, NULL when unset)
;
; Wrapped rather than called directly so that every environment read in the
; runtime goes through one auditable point.
; ---------------------------------------------------------------------------
        global af_cfg_getenv
af_cfg_getenv:
        AF_ENTER 0
        AF_CCALL getenv
        AF_LEAVE

        section .rodata
scheme_https:   db "https://"
scheme_http:    db "http://"
host_127:       db "127.0.0.1"
host_ipv6:      db "::1"
host_localhost: db "localhost"
