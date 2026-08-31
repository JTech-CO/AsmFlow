; AsmFlow — configuration entry points.
;
; Order matters and is fixed here:
;
;   1. bounded JSON parse (byte, depth, string, and element ceilings)
;   2. plaintext-credential sweep over the whole document
;   3. unknown-key sweep at the root
;   4. schema_version
;   5. the five scalar sections
;   6. providers, then routes (which resolve against providers), then MCP
;
; Secret resolution is deliberately NOT part of loading. A configuration can be
; structurally valid while an environment variable is missing, and the two
; failures mean different things: one is a bad file, the other is a bad
; deployment. `--check-config` reports both; readiness depends on both.

        bits 64
        default rel

%include "asmflow.inc"
%include "json.inc"
%include "config.inc"
%include "fileio.inc"

%define CFG_STAT_SIZE     144
%define CFG_STAT_MODE_OFF 24
%define CFG_S_IFMT        0o170000
%define CFG_S_IFREG       0o100000

        extern af_alloc
        extern af_free
        extern af_mem_zero
        extern af_cstr_len
        extern af_buf_init
        extern af_buf_free
        extern af_buf_reserve
        extern af_buf_append
        extern af_buf_data
        extern af_buf_len

        extern af_sys_open
        extern af_sys_close
        extern af_sys_fstat
        extern af_read_some
        extern af_status_from_errno

        extern af_json_parse
        extern af_json_doc_free
        extern af_json_doc_root
        extern af_json_type

        extern af_config_new
        extern af_config_release
        extern af_cfg_check_keys
        extern af_cfg_reject_plaintext
        extern af_cfg_err_fail
        extern af_cfg_req_int

        extern af_cfg_load_listener
        extern af_cfg_load_control
        extern af_cfg_load_storage
        extern af_cfg_load_logging
        extern af_cfg_load_limits
        extern af_cfg_load_providers
        extern af_cfg_load_routes
        extern af_cfg_load_mcp_servers

        extern af_cfg_getenv
        extern af_cfg_expand_path

        extern af_cfg_err_push_key
        extern af_cfg_err_push_index

        extern k_schema_version, k_listener, k_auth, k_providers
        extern k_mcp_servers, k_env
        extern keys_root
        extern m_not_object
        extern m_schema_version
        extern m_missing_secret

        section .rodata
default_config_rel: db "${XDG_CONFIG_HOME}/asmflow/asmflow.json", 0
default_config_rel_len equ $ - default_config_rel - 1

m_json_syntax: db "the file is not valid JSON", 0
m_json_depth:  db "JSON nesting exceeds the permitted depth", 0
m_json_size:   db "the file or one of its strings exceeds the permitted size", 0

        section .text

; ---------------------------------------------------------------------------
; af_config_parse(const char *buf, u64 len, af_cfg_error *err,
;                 af_config **out) -> af_status
;
; Ownership: `buf` is BORROWED. On success `*out` holds one reference that the
; caller releases with af_config_release. On failure nothing is written to
; `*out` and no snapshot exists.
; ---------------------------------------------------------------------------
        global af_config_parse
af_config_parse:
        AF_ENTER 128
        test    rdi, rdi
        jz      .invalid
        test    rcx, rcx
        jz      .invalid
        mov     rbx, rdi                ; buffer
        mov     r12, rsi                ; length
        mov     r13, rdx                ; error
        mov     r14, rcx                ; out

        ; Bootstrap limits. The document has not been read yet, so the ceilings
        ; that apply to it are the hard maxima from include/asmflow.inc rather
        ; than anything the file itself claims. A file cannot widen the limits
        ; used to parse it.
        mov     qword [rsp + 0],  AF_MAX_CONFIG_BYTES
        mov     qword [rsp + 8],  AF_MAX_JSON_DEPTH
        mov     qword [rsp + 16], AF_MAX_CONFIG_BYTES
        mov     qword [rsp + 24], 4096

        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]         ; af_json_doc
        call    af_json_parse
        test    rax, rax
        js      .parse_failed

        lea     rdi, [rsp + 32]
        call    af_json_doc_root
        mov     r15, rax                ; root

        mov     rdi, r15
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .not_object

        ; Credentials first: a file carrying a plaintext secret is refused for
        ; that reason, not for whatever else happens to be wrong with it.
        mov     rdi, r15
        mov     rsi, r13
        call    af_cfg_reject_plaintext
        test    rax, rax
        js      .release_doc

        mov     rdi, r15
        lea     rsi, [keys_root]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .release_doc

        mov     rdi, r15
        lea     rsi, [k_schema_version]
        mov     rdx, 1
        mov     rcx, 1
        mov     r8, r13
        lea     r9, [rsp + 64]
        call    af_cfg_req_int
        test    rax, rax
        js      .release_doc

        lea     rdi, [rsp + 72]
        call    af_config_new
        test    rax, rax
        js      .release_doc
        mov     rax, [rsp + 72]
        mov     qword [rax + CFG_SCHEMA_VERSION], 1

        ; Each section writes only into the new snapshot, so a failure part-way
        ; through discards a snapshot nobody has seen.
        mov     rdi, r15
        mov     rsi, [rsp + 72]
        mov     rdx, r13
        call    af_cfg_load_listener
        test    rax, rax
        js      .release_config

        mov     rdi, r15
        mov     rsi, [rsp + 72]
        mov     rdx, r13
        call    af_cfg_load_control
        test    rax, rax
        js      .release_config

        mov     rdi, r15
        mov     rsi, [rsp + 72]
        mov     rdx, r13
        call    af_cfg_load_storage
        test    rax, rax
        js      .release_config

        mov     rdi, r15
        mov     rsi, [rsp + 72]
        mov     rdx, r13
        call    af_cfg_load_logging
        test    rax, rax
        js      .release_config

        mov     rdi, r15
        mov     rsi, [rsp + 72]
        mov     rdx, r13
        call    af_cfg_load_limits
        test    rax, rax
        js      .release_config

        mov     rdi, r15
        mov     rsi, [rsp + 72]
        mov     rdx, r13
        call    af_cfg_load_providers
        test    rax, rax
        js      .release_config

        ; Routes resolve their targets against the provider table, so they must
        ; follow it.
        mov     rdi, r15
        mov     rsi, [rsp + 72]
        mov     rdx, r13
        call    af_cfg_load_routes
        test    rax, rax
        js      .release_config

        mov     rdi, r15
        mov     rsi, [rsp + 72]
        mov     rdx, r13
        call    af_cfg_load_mcp_servers
        test    rax, rax
        js      .release_config

        ; A content hash lets a reload report "nothing changed" without keeping
        ; the file, and lets diagnostics identify a configuration without
        ; disclosing it.
        mov     rdi, rbx
        mov     rsi, r12
        call    af_config_hash_bytes
        mov     rcx, [rsp + 72]
        mov     [rcx + CFG_HASH], rax

        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        mov     rax, [rsp + 72]
        mov     [r14], rax
        AF_LEAVE_OK

.release_config:
        mov     [rsp + 80], rax
        mov     rdi, [rsp + 72]
        call    af_config_release
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        mov     rax, [rsp + 80]
        AF_LEAVE

.release_doc:
        mov     [rsp + 80], rax
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        mov     rax, [rsp + 80]
        AF_LEAVE

.not_object:
        mov     rdi, r13
        mov     rsi, AF_E_CFG_SCHEMA
        lea     rdx, [m_not_object]
        call    af_cfg_err_fail
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        AF_LEAVE_ERR AF_E_CFG_SCHEMA

; A syntax, depth, or size failure never produced a document, so the only thing
; to do is record why. The message distinguishes the three, because "invalid
; JSON" and "nested too deeply" call for different fixes.
.parse_failed:
        mov     [rsp + 80], rax
        cmp     rax, AF_E_JSON_DEPTH
        je      .say_depth
        cmp     rax, AF_E_JSON_SIZE
        je      .say_size
        lea     rdx, [m_json_syntax]
        jmp     .say
.say_depth:
        lea     rdx, [m_json_depth]
        jmp     .say
.say_size:
        lea     rdx, [m_json_size]
.say:
        mov     rdi, r13
        mov     rsi, [rsp + 80]
        call    af_cfg_err_fail
        mov     rax, [rsp + 80]
        AF_LEAVE

.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_config_hash_bytes(const void *p, u64 n) -> u64
;
; FNV-1a over the raw file. Not a security primitive: it identifies a
; configuration revision in logs and diagnostics, where a cryptographic hash
; would imply a guarantee the project does not make (SECURITY_MODEL.md 15,
; "avoid custom cryptography").
; ---------------------------------------------------------------------------
        global af_config_hash_bytes
af_config_hash_bytes:
        mov     rax, 0xcbf29ce484222325 ; FNV offset basis
        mov     r9, 0x00000100000001B3  ; FNV prime
        xor     ecx, ecx
.loop:
        cmp     rcx, rsi
        jae     .done
        movzx   r8d, byte [rdi + rcx]
        xor     rax, r8
        mul     r9
        inc     rcx
        jmp     .loop
.done:
        ret

; ---------------------------------------------------------------------------
; af_config_read_file(const char *path, af_buffer *out) -> af_status
;
; Reads a whole configuration file under the AF_MAX_CONFIG_BYTES ceiling.
;
; O_NOFOLLOW: the configuration path names secrets by reference and controls
; where the daemon listens, so a symlink swapped in between deployment and
; startup would redirect all of that. SECURITY_MODEL.md 13 asks for NOFOLLOW
; where the policy applies, and it applies here.
; ---------------------------------------------------------------------------
        global af_config_read_file
af_config_read_file:
        AF_ENTER 192
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi                ; path
        mov     r12, rsi                ; out buffer
        mov     r13, -1                 ; fd

        mov     rdi, r12
        mov     rsi, AF_MAX_CONFIG_BYTES
        call    af_buf_init
        test    rax, rax
        js      .done

        mov     rdi, rbx
        ; O_NONBLOCK prevents a FIFO or device substituted for the config from
        ; hanging startup before its type can be rejected below.  It has no
        ; effect on ordinary regular-file reads.
        mov     rsi, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        xor     edx, edx
        call    af_sys_open
        test    rax, rax
        js      .open_failed
        mov     r13, rax

        ; Validate the already-open descriptor, not a second path lookup.  The
        ; path-level owner/mode policy is daemon-only; this type invariant also
        ; applies to --check-config and every unit caller.
        mov     rdi, r13
        lea     rsi, [rsp + 16]
        call    af_sys_fstat
        test    rax, rax
        js      .fstat_failed
        mov     eax, [rsp + 16 + CFG_STAT_MODE_OFF]
        and     eax, CFG_S_IFMT
        cmp     eax, CFG_S_IFREG
        jne     .wrong_type

.read_loop:
        ; chunk = min(65536, ceiling - length)
        mov     rdi, r12
        call    af_buf_len
        mov     r15, rax                ; current length
        mov     r14, AF_MAX_CONFIG_BYTES
        sub     r14, r15
        jz      .at_ceiling
        cmp     r14, 65536
        jbe     .have_chunk
        mov     r14, 65536
.have_chunk:
        mov     rdi, r12
        mov     rsi, r14
        call    af_buf_reserve
        test    rax, rax
        js      .close_and_free

        mov     rdi, r12
        call    af_buf_data
        add     rax, r15                ; write cursor
        mov     rdi, r13
        mov     rsi, rax
        mov     rdx, r14
        lea     rcx, [rsp]
        call    af_read_some
        cmp     rax, AF_E_EOF
        je      .eof
        test    rax, rax
        js      .close_and_free

        ; The bytes landed inside the buffer's own capacity, so publishing them
        ; is a length update rather than a second copy.
        add     r15, [rsp]
        mov     [r12 + 8], r15          ; af_buffer.len
        jmp     .read_loop

; The buffer is exactly at the ceiling. One more byte would mean the file is
; larger than the contract allows, so read one to find out rather than assuming
; either way.
.at_ceiling:
        mov     rdi, r13
        lea     rsi, [rsp + 16]
        mov     rdx, 1
        lea     rcx, [rsp]
        call    af_read_some
        cmp     rax, AF_E_EOF
        je      .eof
        test    rax, rax
        js      .close_and_free
        mov     rax, AF_E_JSON_SIZE
        jmp     .close_and_free

.eof:
        mov     rdi, r13
        call    af_sys_close
        AF_LEAVE_OK

.close_and_free:
        mov     [rsp + 8], rax
        mov     rdi, r12
        call    af_buf_free
        mov     rdi, r13
        call    af_sys_close
        mov     rax, [rsp + 8]
        AF_LEAVE
.fstat_failed:
        mov     rdi, rax
        call    af_status_from_errno
        mov     [rsp + 8], rax
        jmp     .close_and_free
.wrong_type:
        mov     qword [rsp + 8], AF_E_CFG_PATH
        jmp     .close_and_free
.open_failed:
        mov     [rsp + 8], rax
        mov     rdi, r12
        call    af_buf_free
        mov     rdi, [rsp + 8]
        call    af_status_from_errno
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_config_default_path(af_arena *arena, char **out) -> af_status
;
; ${XDG_CONFIG_HOME}/asmflow/asmflow.json, expanded through the same allowlisted
; path rules as every configured path, so the default and a configured value
; cannot diverge in how they are interpreted.
; ---------------------------------------------------------------------------
        global af_config_default_path
af_config_default_path:
        AF_ENTER 0
        mov     rcx, rsi                ; out
        lea     rsi, [default_config_rel]
        mov     rdx, default_config_rel_len
        call    af_cfg_expand_path
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_config_resolve_secrets(af_config *cfg, af_cfg_error *err) -> af_status
;
; Every SecretRef in the snapshot must name a variable that is actually set.
; This runs after loading and before readiness, so a deployment that forgot to
; export a token fails at startup with the variable named, rather than at the
; first request with an upstream 401.
;
; The values themselves are never copied into the snapshot: only presence is
; checked here, and the value is read again at dispatch time into a dedicated
; buffer (SECURITY_MODEL.md 6).
; ---------------------------------------------------------------------------
        global af_config_resolve_secrets
af_config_resolve_secrets:
        AF_ENTER 64
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi                ; config
        mov     r12, rsi                ; error

        ; listener auth
        lea     rdi, [rbx + CFG_LST_AUTH]
        call    af_cfg_auth_secret_present
        test    rax, rax
        jnz     .listener_ok
        mov     rdi, r12
        lea     rsi, [k_listener]
        call    af_cfg_err_push_key
        mov     rdi, r12
        lea     rsi, [k_auth]
        call    af_cfg_err_push_key
        jmp     .missing
.listener_ok:

        ; provider auth
        xor     r13, r13
.providers:
        cmp     r13, [rbx + CFG_PROVIDER_COUNT]
        jae     .providers_done
        mov     rax, r13
        imul    rax, rax, PRV_SIZE
        add     rax, [rbx + CFG_PROVIDERS]
        lea     rdi, [rax + PRV_AUTH]
        call    af_cfg_auth_secret_present
        test    rax, rax
        jnz     .provider_ok
        mov     rdi, r12
        lea     rsi, [k_providers]
        call    af_cfg_err_push_key
        mov     rdi, r12
        mov     rsi, r13
        call    af_cfg_err_push_index
        mov     rdi, r12
        lea     rsi, [k_auth]
        call    af_cfg_err_push_key
        jmp     .missing
.provider_ok:
        inc     r13
        jmp     .providers
.providers_done:

        ; MCP auth and child environment references
        xor     r13, r13
.servers:
        cmp     r13, [rbx + CFG_MCP_COUNT]
        jae     .servers_done
        mov     rax, r13
        imul    rax, rax, MCP_SIZE
        add     rax, [rbx + CFG_MCP_SERVERS]
        mov     r14, rax
        lea     rdi, [r14 + MCP_AUTH]
        call    af_cfg_auth_secret_present
        test    rax, rax
        jnz     .server_auth_ok
        mov     rdi, r12
        lea     rsi, [k_mcp_servers]
        call    af_cfg_err_push_key
        mov     rdi, r12
        mov     rsi, r13
        call    af_cfg_err_push_index
        mov     rdi, r12
        lea     rsi, [k_auth]
        call    af_cfg_err_push_key
        jmp     .missing
.server_auth_ok:

        xor     r15, r15
.env_pairs:
        cmp     r15, [r14 + MCP_ENV_PAIR_COUNT]
        jae     .env_done
        mov     rax, r15
        imul    rax, rax, ENVP_SIZE
        add     rax, [r14 + MCP_ENV_PAIRS]
        mov     [rsp], rax
        mov     rdi, [rax + ENVP_ENV]
        test    rdi, rdi
        jz      .env_next
        call    af_cfg_getenv
        test    rax, rax
        jnz     .env_next
        mov     rdi, r12
        lea     rsi, [k_mcp_servers]
        call    af_cfg_err_push_key
        mov     rdi, r12
        mov     rsi, r13
        call    af_cfg_err_push_index
        mov     rdi, r12
        lea     rsi, [k_env]
        call    af_cfg_err_push_key
        mov     rax, [rsp]
        mov     rdi, r12
        mov     rsi, [rax + ENVP_NAME]
        call    af_cfg_err_push_key
        jmp     .missing
.env_next:
        inc     r15
        jmp     .env_pairs
.env_done:
        inc     r13
        jmp     .servers
.servers_done:
        AF_LEAVE_OK

.missing:
        mov     rdi, r12
        mov     rsi, AF_E_CFG_SECRET_MISSING
        lea     rdx, [m_missing_secret]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_SECRET_MISSING
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_cfg_auth_secret_present(const void *auth) -> i64 (1 = satisfied)
;
; `none` needs nothing; the other two need their environment variable set.
; ---------------------------------------------------------------------------
        global af_cfg_auth_secret_present
af_cfg_auth_secret_present:
        AF_ENTER 0
        cmp     qword [rdi + AUTH_TYPE], AF_AUTH_NONE
        je      .yes
        mov     rdi, [rdi + AUTH_ENV]
        test    rdi, rdi
        jz      .no
        call    af_cfg_getenv
        test    rax, rax
        jz      .no
.yes:
        mov     eax, 1
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE
