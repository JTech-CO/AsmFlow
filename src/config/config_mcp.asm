; AsmFlow — MCP server configuration.
;
; The schema models `mcp_servers[]` as a `oneOf` over two transports, so the
; permitted key set depends on `transport`. Reading it first and then sweeping
; against that variant's list is what makes a stdio entry carrying `url`, or an
; HTTP entry carrying `command`, a rejection rather than a silently ignored
; field — which matters because those two fields are the difference between
; launching a local process and contacting a remote host.
;
; SECURITY_MODEL.md 11 is enforced here at load time, not at spawn time:
;
;   * `command` must be an absolute path, so the executable does not depend on
;     PATH at the moment of exec;
;   * `args` are literal strings that will be passed as an argument vector, so
;     nothing in them is ever interpreted;
;   * the child environment starts from an allowlist, so a variable the operator
;     did not name cannot leak into a third-party process.

        bits 64
        default rel

%include "asmflow.inc"
%include "json.inc"
%include "config.inc"

        extern af_arena_calloc
        extern af_cstr_len
        extern af_cstr_eq

        extern af_json_array_at
        extern af_json_string_of
        extern af_json_type
        extern af_json_iter_begin
        extern af_json_iter_key
        extern af_json_iter_key_len
        extern af_json_iter_value
        extern af_json_iter_next

        extern af_cfg_check_keys
        extern af_cfg_err_push_index
        extern af_cfg_err_push_key
        extern af_cfg_err_truncate
        extern af_cfg_err_depth
        extern af_cfg_fail_here

        extern af_cfg_req_str
        extern af_cfg_req_int
        extern af_cfg_req_bool
        extern af_cfg_opt_bool
        extern af_cfg_req_enum
        extern af_cfg_req_obj
        extern af_cfg_req_arr

        extern af_cfg_intern
        extern af_cfg_id_valid
        extern af_cfg_env_name_valid
        extern af_cfg_url_check
        extern af_cfg_load_auth
        extern af_cfg_load_timeouts
        extern af_cfg_load_secret_ref
        extern af_cfg_bitmask_from_array
        extern af_cfg_find_duplicate

        extern k_mcp_servers
        extern k_id, k_display_name, k_transport, k_enabled, k_required
        extern k_command, k_args, k_cwd, k_env_allow, k_env, k_protocol
        extern k_restart, k_startup_timeout_ms, k_shutdown_grace_ms
        extern k_url, k_auth, k_timeouts, k_allow_insecure
        extern k_preferred, k_legacy, k_mode, k_max_restarts
        extern k_window_ms, k_backoff_ms, k_max_backoff_ms

        extern tbl_transport, tbl_restart, tbl_mcp_preferred, tbl_mcp_legacy
        extern keys_mcp_stdio, keys_mcp_http, keys_protocol, keys_restart

        extern m_bad_id, m_dup_id, m_bad_url, m_bad_env, m_cmd_absolute
        extern m_backoff, m_bad_enum_value, m_bad_path, m_dup_entry

        section .rodata

m_mcp_embedded_nul: db "embedded NUL is not permitted in a process string", 0
m_mcp_env_collision: db "env_allow and env names must be disjoint", 0

        section .text

; ---------------------------------------------------------------------------
; af_cfg_load_mcp_servers(json_t *root, af_config *cfg, af_cfg_error *err)
;   -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_load_mcp_servers
af_cfg_load_mcp_servers:
        AF_ENTER 128
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 40], rax

        mov     rdi, rbx
        lea     rsi, [k_mcp_servers]
        xor     edx, edx
        mov     rcx, AF_MAX_MCP_SERVERS
        mov     r8, r13
        lea     r9, [rsp + 16]
        call    af_cfg_req_arr
        test    rax, rax
        js      .done

        mov     rax, [rsp + 24]
        mov     [r12 + CFG_MCP_COUNT], rax
        test    rax, rax
        jz      .finish

        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, rax
        mov     rdx, MCP_SIZE
        call    af_arena_calloc
        test    rax, rax
        jz      .nomem
        mov     [r12 + CFG_MCP_SERVERS], rax

        mov     qword [rsp + 32], 0
.entry_loop:
        mov     rax, [rsp + 32]
        cmp     rax, [r12 + CFG_MCP_COUNT]
        jae     .finish

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 48], rax
        mov     rdi, r13
        mov     rsi, [rsp + 32]
        call    af_cfg_err_push_index

        mov     rdi, [rsp + 16]
        mov     rsi, [rsp + 32]
        lea     rdx, [rsp + 56]
        call    af_json_array_at
        test    rax, rax
        js      .done
        mov     r14, [rsp + 56]         ; server object

        mov     rax, [rsp + 32]
        imul    rax, rax, MCP_SIZE
        add     rax, [r12 + CFG_MCP_SERVERS]
        mov     r15, rax
        mov     qword [r15 + MCP_PROTO_PREFERRED], AF_ERA_MODERN

        ; The transport decides which key set is permitted.
        mov     rdi, r14
        lea     rsi, [k_transport]
        lea     rdx, [tbl_transport]
        mov     rcx, r13
        lea     r8, [r15 + MCP_TRANSPORT]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done

        cmp     qword [r15 + MCP_TRANSPORT], AF_TRANSPORT_STDIO
        jne     .http_keys
        lea     rsi, [keys_mcp_stdio]
        jmp     .sweep
.http_keys:
        lea     rsi, [keys_mcp_http]
.sweep:
        mov     rdi, r14
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        ; --- fields common to both transports ---
        mov     rdi, r14
        lea     rsi, [k_id]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_id_valid
        test    rax, rax
        jz      .bad_id
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + MCP_ID]
        call    af_cfg_intern
        test    rax, rax
        js      .done
        mov     rdi, [r12 + CFG_MCP_SERVERS]
        mov     rsi, [rsp + 32]
        mov     rdx, MCP_SIZE
        mov     rcx, MCP_ID
        mov     r8, [r15 + MCP_ID]
        call    af_cfg_find_duplicate
        test    rax, rax
        jnz     .duplicate_id

        mov     rdi, r14
        lea     rsi, [k_display_name]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .bad_name
        cmp     rax, 128
        ja      .bad_name
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + MCP_DISPLAY_NAME]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_enabled]
        mov     rdx, r13
        lea     rcx, [r15 + MCP_ENABLED]
        call    af_cfg_req_bool
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_required]
        mov     rdx, r13
        lea     rcx, [r15 + MCP_REQUIRED]
        call    af_cfg_req_bool
        test    rax, rax
        js      .done

        ; protocol
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_protocol]
        mov     rdx, r13
        lea     rcx, [rsp + 64]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        mov     rsi, r13
        mov     rdx, r15
        call    af_cfg_load_protocol
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        cmp     qword [r15 + MCP_TRANSPORT], AF_TRANSPORT_STDIO
        je      .stdio_fields
        jmp     .http_fields

; --- stdio ------------------------------------------------------------------
.stdio_fields:
        mov     rdi, r14
        lea     rsi, [k_command]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .bad_command
        cmp     rax, 4096
        ja      .bad_command
        ; JSON strings carry an explicit byte length while execve consumes a
        ; NUL-terminated C string. Refuse any embedded NUL before interning can
        ; turn a validated value into a shorter command.
        mov     rdi, [rsp]
        call    af_cstr_len
        cmp     rax, [rsp + 8]
        jne     .bad_command_nul
        mov     rcx, [rsp]
        cmp     byte [rcx], '/'
        jne     .bad_command
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + MCP_COMMAND]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        ; args: literal strings, never a shell fragment
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_args]
        xor     edx, edx
        mov     rcx, 128
        mov     r8, r13
        lea     r9, [rsp + 80]
        call    af_cfg_req_arr
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 80]
        mov     rsi, [rsp + 88]
        mov     rdx, r12
        mov     rcx, r13
        lea     r8, [r15 + MCP_ARGS]
        mov     r9, 4096
        call    af_cfg_load_string_vector
        test    rax, rax
        js      .done
        mov     rax, [rsp + 88]
        mov     [r15 + MCP_ARG_COUNT], rax
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        ; cwd
        mov     rdi, r14
        lea     rsi, [k_cwd]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .bad_cwd
        cmp     rax, 4096
        ja      .bad_cwd
        mov     rdi, [rsp]
        call    af_cstr_len
        cmp     rax, [rsp + 8]
        jne     .bad_cwd_nul
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + MCP_CWD]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        ; env_allow: variable names inherited from our environment
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_env_allow]
        xor     edx, edx
        mov     rcx, 128
        mov     r8, r13
        lea     r9, [rsp + 80]
        call    af_cfg_req_arr
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 80]
        mov     rsi, [rsp + 88]
        mov     rdx, r12
        mov     rcx, r13
        lea     r8, [r15 + MCP_ENV_ALLOW]
        call    af_cfg_load_env_name_vector
        test    rax, rax
        js      .done
        mov     rax, [rsp + 88]
        mov     [r15 + MCP_ENV_ALLOW_COUNT], rax
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        ; env: {CHILD_VAR: SecretRef}
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_env]
        mov     rdx, r13
        lea     rcx, [rsp + 64]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        mov     rsi, r12
        mov     rdx, r13
        mov     rcx, r15
        call    af_cfg_load_env_pairs
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        ; restart policy
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_restart]
        mov     rdx, r13
        lea     rcx, [rsp + 64]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        mov     rsi, r13
        mov     rdx, r15
        call    af_cfg_load_restart
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        mov     rdi, r14
        lea     rsi, [k_startup_timeout_ms]
        mov     rdx, 100
        mov     rcx, 600000
        mov     r8, r13
        lea     r9, [r15 + MCP_STARTUP_TIMEOUT]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_shutdown_grace_ms]
        xor     edx, edx
        mov     rcx, 600000
        mov     r8, r13
        lea     r9, [r15 + MCP_SHUTDOWN_GRACE]
        call    af_cfg_req_int
        test    rax, rax
        js      .done
        jmp     .entry_done

; --- streamable http --------------------------------------------------------
.http_fields:
        mov     rdi, r14
        lea     rsi, [k_allow_insecure]
        mov     rdx, r13
        lea     rcx, [r15 + MCP_ALLOW_INSECURE]
        xor     r8d, r8d
        call    af_cfg_opt_bool
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_url]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .bad_url
        cmp     rax, 2048
        ja      .bad_url
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        mov     rdx, [r15 + MCP_ALLOW_INSECURE]
        xor     ecx, ecx
        call    af_cfg_url_check
        test    rax, rax
        js      .bad_url
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + MCP_URL]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_auth]
        mov     rdx, r13
        lea     rcx, [rsp + 64]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        lea     rsi, [r12 + CFG_ARENA]
        mov     rdx, r13
        lea     rcx, [r15 + MCP_AUTH]
        call    af_cfg_load_auth
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_timeouts]
        mov     rdx, r13
        lea     rcx, [rsp + 64]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        mov     rsi, r13
        lea     rdx, [r15 + MCP_TIMEOUTS]
        call    af_cfg_load_timeouts
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

.entry_done:
        mov     rdi, r13
        mov     rsi, [rsp + 48]
        call    af_cfg_err_truncate
        inc     qword [rsp + 32]
        jmp     .entry_loop

.finish:
        mov     rdi, r13
        mov     rsi, [rsp + 40]
        call    af_cfg_err_truncate
        AF_LEAVE_OK

.bad_id:
        mov     rdi, r13
        lea     rsi, [k_id]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_id]
        call    af_cfg_fail_here
        AF_LEAVE
.duplicate_id:
        mov     rdi, r13
        lea     rsi, [k_id]
        mov     rdx, AF_E_CFG_DUPLICATE
        lea     rcx, [m_dup_id]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_name:
        mov     rdi, r13
        lea     rsi, [k_display_name]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_enum_value]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_command:
        mov     rdi, r13
        lea     rsi, [k_command]
        mov     rdx, AF_E_CFG_PATH
        lea     rcx, [m_cmd_absolute]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_command_nul:
        mov     rdi, r13
        lea     rsi, [k_command]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_mcp_embedded_nul]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_cwd:
        mov     rdi, r13
        lea     rsi, [k_cwd]
        mov     rdx, AF_E_CFG_PATH
        lea     rcx, [m_bad_path]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_cwd_nul:
        mov     rdi, r13
        lea     rsi, [k_cwd]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_mcp_embedded_nul]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_url:
        mov     rdi, r13
        lea     rsi, [k_url]
        mov     rdx, AF_E_CFG_URL
        lea     rcx, [m_bad_url]
        call    af_cfg_fail_here
        AF_LEAVE
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_protocol(json_t *obj, af_cfg_error *err, af_cfg_mcp *server)
;   -> af_status
;
; `preferred` has exactly one permitted value today. Keeping it an enum rather
; than a free string means a server pinned to a future revision is a rejection
; with a clear message, not a silent downgrade.
; ---------------------------------------------------------------------------
        global af_cfg_load_protocol
af_cfg_load_protocol:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi                ; error
        mov     r13, rdx                ; server

        mov     rdi, rbx
        lea     rsi, [keys_protocol]
        mov     rdx, r12
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_preferred]
        lea     rdx, [tbl_mcp_preferred]
        mov     rcx, r12
        lea     r8, [r13 + MCP_PROTO_PREFERRED]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done

        mov     rdi, r12
        call    af_cfg_err_depth
        mov     [rsp + 32], rax
        mov     rdi, rbx
        lea     rsi, [k_legacy]
        xor     edx, edx
        mov     rcx, 8
        mov     r8, r12
        lea     r9, [rsp + 16]
        call    af_cfg_req_arr
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 16]
        mov     rsi, [rsp + 24]
        lea     rdx, [tbl_mcp_legacy]
        mov     rcx, r12
        lea     r8, [r13 + MCP_PROTO_LEGACY]
        call    af_cfg_bitmask_from_array
        test    rax, rax
        js      .done
        mov     rdi, r12
        mov     rsi, [rsp + 32]
        call    af_cfg_err_truncate
        AF_LEAVE_OK
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_restart(json_t *obj, af_cfg_error *err, af_cfg_mcp *server)
;   -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_load_restart
af_cfg_load_restart:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, rbx
        lea     rsi, [keys_restart]
        mov     rdx, r12
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_mode]
        lea     rdx, [tbl_restart]
        mov     rcx, r12
        lea     r8, [r13 + MCP_RESTART_MODE]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_max_restarts]
        xor     edx, edx
        mov     rcx, 100
        mov     r8, r12
        lea     r9, [r13 + MCP_MAX_RESTARTS]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_window_ms]
        mov     rdx, 1000
        mov     rcx, 86400000
        mov     r8, r12
        lea     r9, [r13 + MCP_WINDOW_MS]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_backoff_ms]
        xor     edx, edx
        mov     rcx, 3600000
        mov     r8, r12
        lea     r9, [r13 + MCP_BACKOFF_MS]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_max_backoff_ms]
        xor     edx, edx
        mov     rcx, 3600000
        mov     r8, r12
        lea     r9, [r13 + MCP_MAX_BACKOFF_MS]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        ; A ceiling below the floor would make the backoff schedule
        ; contradictory, so it is a rejection rather than a clamp.
        mov     rax, [r13 + MCP_MAX_BACKOFF_MS]
        cmp     rax, [r13 + MCP_BACKOFF_MS]
        jb      .bad_backoff
        AF_LEAVE_OK
.bad_backoff:
        mov     rdi, r12
        lea     rsi, [k_max_backoff_ms]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_backoff]
        call    af_cfg_fail_here
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_string_vector(json_t *array, u64 count, af_config *cfg,
;                           af_cfg_error *err, char ***out, u64 max_len)
;   -> af_status
;
; Interns an array of strings into a `char **` in the snapshot arena. Used for
; `args`, whose members are handed to execve verbatim.
; ---------------------------------------------------------------------------
        global af_cfg_load_string_vector
af_cfg_load_string_vector:
        AF_ENTER 80
        mov     rbx, rdi                ; array
        mov     [rsp + 40], rsi         ; count
        mov     r12, rdx                ; config
        mov     r13, rcx                ; error
        mov     r14, r8                 ; out
        mov     [rsp + 48], r9          ; max element length

        mov     qword [r14], 0
        cmp     qword [rsp + 40], 0
        je      .ok

        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp + 40]
        mov     rdx, 8
        call    af_arena_calloc
        test    rax, rax
        jz      .nomem
        mov     [r14], rax
        mov     r15, rax

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 56], rax

        mov     qword [rsp + 32], 0
.loop:
        mov     rax, [rsp + 32]
        cmp     rax, [rsp + 40]
        jae     .ok
        mov     rdi, r13
        mov     rsi, rax
        call    af_cfg_err_push_index
        mov     rdi, rbx
        mov     rsi, [rsp + 32]
        lea     rdx, [rsp + 64]
        call    af_json_array_at
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_json_string_of
        test    rax, rax
        js      .bad_member
        ; argv is a C-string vector. Its JSON byte length must match the first
        ; NUL exactly, otherwise execve would receive only an unchecked prefix.
        mov     rdi, [rsp]
        call    af_cstr_len
        cmp     rax, [rsp + 8]
        jne     .bad_nul
        mov     rax, [rsp + 8]
        cmp     rax, [rsp + 48]
        ja      .bad_member
        mov     rax, [rsp + 32]
        lea     rcx, [r15 + rax * 8]
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_cfg_intern
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 56]
        call    af_cfg_err_truncate
        inc     qword [rsp + 32]
        jmp     .loop
.ok:
        AF_LEAVE_OK
.bad_member:
        mov     rdi, r13
        xor     esi, esi
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_enum_value]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_nul:
        mov     rdi, r13
        xor     esi, esi
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_mcp_embedded_nul]
        call    af_cfg_fail_here
        AF_LEAVE
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_env_name_vector(json_t *array, u64 count, af_config *cfg,
;                             af_cfg_error *err, char ***out) -> af_status
;
; Like af_cfg_load_string_vector, but every member must be a valid environment
; variable name. The allowlist decides what a third-party executable can read
; out of our environment, so a malformed entry is refused rather than skipped.
; ---------------------------------------------------------------------------
        global af_cfg_load_env_name_vector
af_cfg_load_env_name_vector:
        AF_ENTER 80
        mov     rbx, rdi
        mov     [rsp + 40], rsi
        mov     r12, rdx
        mov     r13, rcx
        mov     r14, r8

        mov     qword [r14], 0
        cmp     qword [rsp + 40], 0
        je      .ok

        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp + 40]
        mov     rdx, 8
        call    af_arena_calloc
        test    rax, rax
        jz      .nomem
        mov     [r14], rax
        mov     r15, rax

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 56], rax

        mov     qword [rsp + 32], 0
.loop:
        mov     rax, [rsp + 32]
        cmp     rax, [rsp + 40]
        jae     .ok
        mov     rdi, r13
        mov     rsi, rax
        call    af_cfg_err_push_index
        mov     rdi, rbx
        mov     rsi, [rsp + 32]
        lea     rdx, [rsp + 64]
        call    af_json_array_at
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_json_string_of
        test    rax, rax
        js      .bad_member
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_env_name_valid
        test    rax, rax
        jz      .bad_member
        mov     rax, [rsp + 32]
        lea     rcx, [r15 + rax * 8]
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        ; `uniqueItems: true` on the allowlist.
        mov     rax, [rsp + 32]
        mov     rdi, r15
        mov     rsi, rax
        mov     rdx, 8
        xor     ecx, ecx
        mov     r8, [r15 + rax * 8]
        call    af_cfg_find_duplicate
        test    rax, rax
        jnz     .duplicate

        mov     rdi, r13
        mov     rsi, [rsp + 56]
        call    af_cfg_err_truncate
        inc     qword [rsp + 32]
        jmp     .loop
.ok:
        AF_LEAVE_OK
.bad_member:
        mov     rdi, r13
        xor     esi, esi
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_env]
        call    af_cfg_fail_here
        AF_LEAVE
.duplicate:
        mov     rdi, r13
        xor     esi, esi
        mov     rdx, AF_E_CFG_DUPLICATE
        lea     rcx, [m_dup_entry]
        call    af_cfg_fail_here
        AF_LEAVE
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_env_pairs(json_t *obj, af_config *cfg, af_cfg_error *err,
;                       af_cfg_mcp *server) -> af_status
;
; `env` maps a variable name the child will see onto a SecretRef naming the
; variable we read it from. Both names are validated; the value itself is never
; stored in the snapshot, only the reference (SECURITY_MODEL.md 6).
; ---------------------------------------------------------------------------
        global af_cfg_load_env_pairs
af_cfg_load_env_pairs:
        AF_ENTER 80
        mov     rbx, rdi                ; object
        mov     r12, rsi                ; config
        mov     r13, rdx                ; error
        mov     r14, rcx                ; server

        mov     qword [r14 + MCP_ENV_PAIRS], 0
        mov     qword [r14 + MCP_ENV_PAIR_COUNT], 0

        ; Count first so the vector can be allocated once.
        mov     rdi, rbx
        call    af_json_iter_begin
        mov     r15, rax
        xor     rcx, rcx
        mov     [rsp + 40], rcx
.count_loop:
        test    r15, r15
        jz      .counted
        inc     qword [rsp + 40]
        mov     rdi, rbx
        mov     rsi, r15
        call    af_json_iter_next
        mov     r15, rax
        jmp     .count_loop
.counted:
        mov     rax, [rsp + 40]
        cmp     rax, 128
        ja      .too_many
        test    rax, rax
        jz      .ok

        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, rax
        mov     rdx, ENVP_SIZE
        call    af_arena_calloc
        test    rax, rax
        jz      .nomem
        mov     [r14 + MCP_ENV_PAIRS], rax
        mov     [r14 + MCP_ENV_PAIR_COUNT], rax
        mov     rax, [rsp + 40]
        mov     [r14 + MCP_ENV_PAIR_COUNT], rax

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 48], rax

        mov     qword [rsp + 32], 0
        mov     rdi, rbx
        call    af_json_iter_begin
        mov     r15, rax
.loop:
        test    r15, r15
        jz      .ok
        mov     rdi, r15
        call    af_json_iter_key
        mov     [rsp + 56], rax         ; child-visible variable name

        mov     rdi, r13
        mov     rsi, [rsp + 56]
        call    af_cfg_err_push_key

        mov     rdi, r15
        call    af_json_iter_key_len
        mov     [rsp + 24], rax         ; full JSON key length
        mov     rdi, [rsp + 56]
        mov     rsi, [rsp + 24]
        call    af_cfg_env_name_valid
        test    rax, rax
        jz      .bad_env

        ; A child-visible variable has exactly one source.  If the same name
        ; appeared in env_allow and env, execve would receive duplicate NAME=
        ; entries and the observed value would depend on consumer behaviour.
        mov     qword [rsp + 72], 0
.allow_collision_loop:
        mov     rax, [rsp + 72]
        cmp     rax, [r14 + MCP_ENV_ALLOW_COUNT]
        jae     .allow_disjoint
        mov     rcx, [r14 + MCP_ENV_ALLOW]
        mov     rdi, [rsp + 56]
        mov     rsi, [rcx + rax * 8]
        call    af_cstr_eq
        test    rax, rax
        jnz     .env_collision
        inc     qword [rsp + 72]
        jmp     .allow_collision_loop
.allow_disjoint:

        mov     rax, [rsp + 32]
        imul    rax, rax, ENVP_SIZE
        add     rax, [r14 + MCP_ENV_PAIRS]
        mov     [rsp + 64], rax         ; destination pair

        mov     rdx, [rsp + 24]
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp + 56]
        mov     rcx, [rsp + 64]
        add     rcx, ENVP_NAME
        call    af_cfg_intern
        test    rax, rax
        js      .done

        mov     rdi, r15
        call    af_json_iter_value
        mov     rdi, rax
        lea     rsi, [r12 + CFG_ARENA]
        mov     rdx, r13
        mov     rcx, [rsp + 64]
        add     rcx, ENVP_ENV
        call    af_cfg_load_secret_ref
        test    rax, rax
        js      .done

        mov     rdi, r13
        mov     rsi, [rsp + 48]
        call    af_cfg_err_truncate
        inc     qword [rsp + 32]
        mov     rdi, rbx
        mov     rsi, r15
        call    af_json_iter_next
        mov     r15, rax
        jmp     .loop
.ok:
        AF_LEAVE_OK
.bad_env:
        mov     rdi, r13
        xor     esi, esi
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_env]
        call    af_cfg_fail_here
        AF_LEAVE
.env_collision:
        mov     rdi, r13
        xor     esi, esi
        mov     rdx, AF_E_CFG_DUPLICATE
        lea     rcx, [m_mcp_env_collision]
        call    af_cfg_fail_here
        AF_LEAVE
.too_many:
        mov     rdi, r13
        xor     esi, esi
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_enum_value]
        call    af_cfg_fail_here
        AF_LEAVE
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.done:
        AF_LEAVE
