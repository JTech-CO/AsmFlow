; AsmFlow — control method implementations.
;
; Each handler writes only the `result` value; the envelope is the dispatcher's
; job. Handlers therefore cannot disagree about the response shape.
;
; Two rules apply to everything here.
;
; Nothing that could be a credential is emitted. `config.current` reports the
; NAME of an authentication policy and whether its environment variable is set,
; never a value, and never even the variable's name where that would let a
; reader reconstruct a deployment's secret layout from a diagnostic export
; (SECURITY_MODEL.md 6 and 16).
;
; A method whose subsystem is not built yet says so. Returning an empty list
; would be indistinguishable from "there is nothing", which is a different fact.
; `unsupported_in_this_build` is an honest answer that a console can render.

        bits 64
        default rel

%include "asmflow.inc"
%include "json.inc"
%include "jsonw.inc"
%include "config.inc"
%include "control.inc"
%include "db.inc"
%include "runtime.inc"

        extern af_cstr_len
        extern af_mem_eq
        extern af_monotonic_ns
        extern af_realtime_ms

        extern af_jw_begin_object
        extern af_jw_end_object
        extern af_jw_begin_array
        extern af_jw_end_array
        extern af_jw_key
        extern af_jw_string
        extern af_jw_string_n
        extern af_jw_uint
        extern af_jw_int
        extern af_jw_bool
        extern af_jw_null
        extern af_jw_member_string
        extern af_jw_member_uint
        extern af_jw_member_int
        extern af_jw_member_bool

        extern af_json_get_string
        extern af_json_get_integer

        extern af_ctl_conn_server
        extern af_ctl_server_runtime
        extern af_ctl_server_revision
        extern af_ctl_server_accepted
        extern af_ctl_write_error
        extern af_ctl_write_success_begin
        extern af_ctl_write_success_end

        extern af_version_str
        extern af_build_target_str
        extern af_build_mode_str

        extern af_repo_provider_count
        extern af_repo_route_count
        extern af_repo_mcp_count
        extern af_repo_request_count
        extern af_repo_get_operator_disabled
        extern af_repo_set_operator_disabled
        extern af_repo_adapter_name
        extern af_repo_policy_name
        extern af_repo_transport_name
        extern af_db_is_open

        extern af_cfg_getenv

        section .rodata

; --- method names ----------------------------------------------------------
n_system_version:  db "system.version", 0
n_system_snapshot: db "system.snapshot", 0
n_providers_list:  db "providers.list", 0
n_providers_get:   db "providers.get", 0
n_routes_list:     db "routes.list", 0
n_routes_get:      db "routes.get", 0
n_requests_list:   db "requests.list", 0
n_requests_get:    db "requests.get", 0
n_mcp_list:        db "mcp.list", 0
n_mcp_get:         db "mcp.get", 0
n_mcp_inventory:   db "mcp.inventory", 0
n_logs_tail:       db "logs.tail", 0
n_config_validate: db "config.validate", 0
n_config_current:  db "config.current", 0
n_config_reload:   db "config.reload", 0
n_provider_enable:  db "provider.enable", 0
n_provider_disable: db "provider.disable", 0
n_provider_probe:   db "provider.probe", 0
n_mcp_start:        db "mcp.start", 0
n_mcp_stop:         db "mcp.stop", 0
n_mcp_restart:      db "mcp.restart", 0
n_mcp_reset_loop:   db "mcp.reset_crash_loop", 0
n_mcp_discover:     db "mcp.discover", 0
n_mcp_tool_test:    db "mcp.tool_test", 0
n_diagnostics:      db "diagnostics.export", 0

; --- keys ------------------------------------------------------------------
k_version:        db "version", 0
k_target:         db "target", 0
k_build:          db "build", 0
k_protocol_ver:   db "protocol_version", 0
k_uptime_ms:      db "uptime_ms", 0
k_started_at_ms:  db "started_at_ms", 0
k_revision:       db "revision", 0
k_ready:          db "ready", 0
k_database:       db "database", 0
k_listener:       db "listener", 0
k_control:        db "control", 0
k_counts:         db "counts", 0
k_providers:      db "providers", 0
k_routes:         db "routes", 0
k_mcp_servers:    db "mcp_servers", 0
k_requests:       db "requests", 0
k_connections:    db "connections", 0
k_id:             db "id", 0
k_display_name:   db "display_name", 0
k_adapter:        db "adapter", 0
k_base_url:       db "base_url", 0
k_enabled:        db "enabled", 0
k_required:       db "required", 0
k_max_concurrency: db "max_concurrency", 0
k_capabilities:   db "capabilities", 0
k_operator_disabled: db "operator_disabled", 0
k_auth:           db "auth", 0
k_type:           db "type", 0
k_secret_present: db "secret_present", 0
k_model_alias:    db "model_alias", 0
k_policy:         db "policy", 0
k_endpoint_families: db "endpoint_families", 0
k_targets:        db "targets", 0
k_provider_id:    db "provider_id", 0
k_upstream_model: db "upstream_model", 0
k_priority:       db "priority", 0
k_weight:         db "weight", 0
k_fallback:       db "fallback", 0
k_max_attempts:   db "max_attempts", 0
k_transport:      db "transport", 0
k_host:           db "host", 0
k_port:           db "port", 0
k_loopback:       db "loopback", 0
k_socket_path:    db "socket_path", 0
k_config_hash:    db "config_hash", 0
k_schema_version: db "schema_version", 0
k_store_payloads: db "store_payloads", 0
k_config_path:    db "config_path", 0
k_reload_count:   db "reload_count", 0
k_data:           db "data", 0
k_state:          db "state", 0

v_responses:        db "responses", 0
v_chat_completions: db "chat_completions", 0
v_open:             db "open", 0
v_closed:           db "closed", 0
v_none:             db "none", 0
v_bearer_env:       db "bearer_env", 0
v_header_env:       db "header_env", 0

cap_responses:  db "responses", 0
cap_chat:       db "chat_completions", 0
cap_streaming:  db "streaming", 0
cap_tools:      db "tools", 0
cap_vision:     db "vision", 0
cap_json_schema: db "json_schema", 0

        section .data.rel.ro progbits align=8 write
        align 8
tbl_cap_names:
        dq cap_responses, cap_chat, cap_streaming, cap_tools, cap_vision
        dq cap_json_schema
        align 8
tbl_auth_names:
        dq v_none, v_bearer_env, v_header_env

; The method table: {name, handler}. A NULL handler means the method is part of
; the contract but its subsystem is not built yet, which the dispatcher turns
; into `unsupported_in_this_build` rather than `unknown_method`. The two are
; different facts and a console should show them differently.
        align 8
        global af_ctl_methods
af_ctl_methods:
        dq n_system_version,  af_ctl_m_system_version
        dq n_system_snapshot, af_ctl_m_system_snapshot
        dq n_providers_list,  af_ctl_m_providers_list
        dq n_providers_get,   af_ctl_m_providers_get
        dq n_routes_list,     af_ctl_m_routes_list
        dq n_routes_get,      af_ctl_m_routes_get
        dq n_config_current,  af_ctl_m_config_current
        dq n_mcp_list,        af_ctl_m_mcp_list
        dq n_provider_enable,  af_ctl_m_provider_enable
        dq n_provider_disable, af_ctl_m_provider_disable
        dq n_requests_list,   0
        dq n_requests_get,    0
        dq n_mcp_get,         0
        dq n_mcp_inventory,   0
        dq n_logs_tail,       0
        dq n_config_validate, 0
        dq n_config_reload,   0
        dq n_provider_probe,  0
        dq n_mcp_start,       0
        dq n_mcp_stop,        0
        dq n_mcp_restart,     0
        dq n_mcp_reset_loop,  0
        dq n_mcp_discover,    0
        dq n_mcp_tool_test,   0
        dq n_diagnostics,     0
        dq 0, 0

        section .text

; ---------------------------------------------------------------------------
; af_ctl_method_lookup(const char *name, u64 len) -> const void * (table entry)
;
; Returns the {name, handler} pair, or NULL when the method is not in the
; contract at all.
; ---------------------------------------------------------------------------
        global af_ctl_method_lookup
af_ctl_method_lookup:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        lea     r13, [af_ctl_methods]
.loop:
        mov     r14, [r13]
        test    r14, r14
        jz      .none
        mov     rdi, r14
        call    af_cstr_len
        cmp     rax, r12
        jne     .next
        mov     rdi, r14
        mov     rsi, rbx
        mov     rdx, r12
        call    af_mem_eq
        test    rax, rax
        jnz     .found
.next:
        add     r13, 16
        jmp     .loop
.found:
        mov     rax, r13
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_method_invoke(af_ctl_conn *c, const void *entry, json_t *params,
;                      const void *id_pair) -> af_status
; ---------------------------------------------------------------------------
        global af_ctl_method_invoke
af_ctl_method_invoke:
        AF_ENTER 128
        mov     rbx, rdi                ; connection
        mov     r12, rsi                ; table entry
        mov     r13, rdx                ; params
        mov     r14, rcx                ; id pair

        mov     r15, [r12 + 8]          ; handler
        test    r15, r15
        jz      .unsupported

        ; [rsp + 0 .. 96) af_json_writer, [rsp + 96] frame start
        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, r14
        lea     rcx, [rsp + 96]
        call    af_ctl_write_success_begin
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, r13
        call    r15
        mov     [rsp + 104], rax

        ; A handler that reported a specific failure replaces the whole frame
        ; with an error, rather than shipping a half-written result.
        cmp     qword [rsp + 104], 0
        jl      .handler_failed

        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, [rsp + 96]
        call    af_ctl_write_success_end
        AF_LEAVE

.handler_failed:
        mov     rdi, rbx
        call    af_ctl_conn_outbox_local
        mov     rcx, [rsp + 96]
        mov     [rax + 8], rcx          ; discard the partial result
        mov     rdi, rbx
        mov     rsi, [r14]
        mov     rdx, [r14 + 8]
        mov     rcx, AF_CTLERR_NOT_FOUND
        cmp     qword [rsp + 104], AF_E_NOTFOUND
        je      .emit
        mov     rcx, AF_CTLERR_INVALID_PARAMS
        cmp     qword [rsp + 104], AF_E_CTL_PARAMS
        je      .emit
        mov     rcx, AF_CTLERR_INTERNAL
.emit:
        xor     r8d, r8d
        call    af_ctl_write_error
        AF_LEAVE

.unsupported:
        mov     rdi, rbx
        mov     rsi, [r14]
        mov     rdx, [r14 + 8]
        mov     rcx, AF_CTLERR_UNSUPPORTED
        xor     r8d, r8d
        call    af_ctl_write_error
        AF_LEAVE
.done:
        AF_LEAVE

        extern af_ctl_conn_outbox
af_ctl_conn_outbox_local:
        AF_ENTER 0
        call    af_ctl_conn_outbox
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_runtime_of(af_ctl_conn *c) -> af_runtime * (BORROWED, may be NULL)
; ---------------------------------------------------------------------------
af_ctl_runtime_of:
        AF_ENTER 0
        call    af_ctl_conn_server
        test    rax, rax
        jz      .none
        mov     rdi, rax
        call    af_ctl_server_runtime
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; system.version
; ---------------------------------------------------------------------------
        global af_ctl_m_system_version
af_ctl_m_system_version:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi                ; writer

        mov     rdi, r12
        call    af_jw_begin_object

        lea     rdi, [rsp]
        call    af_version_str
        mov     r13, rax
        mov     rdi, r12
        lea     rsi, [k_version]
        call    af_jw_key
        mov     rdi, r12
        mov     rsi, r13
        mov     rdx, [rsp]
        call    af_jw_string_n

        lea     rdi, [rsp]
        call    af_build_target_str
        mov     r13, rax
        mov     rdi, r12
        lea     rsi, [k_target]
        call    af_jw_key
        mov     rdi, r12
        mov     rsi, r13
        mov     rdx, [rsp]
        call    af_jw_string_n

        lea     rdi, [rsp]
        call    af_build_mode_str
        mov     r13, rax
        mov     rdi, r12
        lea     rsi, [k_build]
        call    af_jw_key
        mov     rdi, r12
        mov     rsi, r13
        mov     rdx, [rsp]
        call    af_jw_string_n

        ; The control contract's own version, which a console negotiates on.
        mov     rdi, r12
        lea     rsi, [k_protocol_ver]
        mov     rdx, 1
        call    af_jw_member_uint

        mov     rdi, r12
        call    af_jw_end_object
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; system.snapshot
;
; The one call a console makes on connect and on every refresh. Counts and
; states only: no identifier that is not already in `providers.list`, and
; nothing derived from a payload.
; ---------------------------------------------------------------------------
        global af_ctl_m_system_snapshot
af_ctl_m_system_snapshot:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi

        mov     rdi, rbx
        call    af_ctl_runtime_of
        mov     r13, rax

        mov     rdi, r12
        call    af_jw_begin_object

        mov     rdi, rbx
        call    af_ctl_conn_server
        mov     r14, rax
        mov     rdi, r14
        call    af_ctl_server_revision
        mov     rdx, rax
        mov     rdi, r12
        lea     rsi, [k_revision]
        call    af_jw_member_uint

        test    r13, r13
        jz      .no_runtime

        mov     rdi, r12
        lea     rsi, [k_ready]
        mov     rdx, [r13 + RT_READY]
        call    af_jw_member_bool

        mov     rdi, r12
        lea     rsi, [k_started_at_ms]
        mov     rdx, [r13 + RT_STARTED_MS]
        call    af_jw_member_uint

        ; Uptime comes from the monotonic clock. Deriving it from wall time
        ; would make it jump when the system clock is corrected.
        lea     rdi, [rsp]
        call    af_monotonic_ns
        test    rax, rax
        js      .no_uptime
        mov     rax, [rsp]
        sub     rax, [r13 + RT_STARTED_NS]
        xor     edx, edx
        mov     rcx, 1000000
        div     rcx
        mov     rdx, rax
        mov     rdi, r12
        lea     rsi, [k_uptime_ms]
        call    af_jw_member_uint
.no_uptime:

        mov     rdi, r12
        lea     rsi, [k_database]
        call    af_jw_key
        mov     rdi, [r13 + RT_DB]
        call    af_db_is_open
        test    rax, rax
        jz      .db_closed
        mov     rdi, r12
        lea     rsi, [v_open]
        call    af_jw_string
        jmp     .db_done
.db_closed:
        mov     rdi, r12
        lea     rsi, [v_closed]
        call    af_jw_string
.db_done:

        mov     rdi, r12
        lea     rsi, [k_reload_count]
        mov     rdx, [r13 + RT_RELOAD_COUNT]
        call    af_jw_member_uint

        ; Counts come from the configuration snapshot rather than the database:
        ; the snapshot is what the daemon is actually routing on, and a stale
        ; database row would report a provider that is no longer live.
        mov     rdi, r12
        lea     rsi, [k_counts]
        call    af_jw_key
        mov     rdi, r12
        call    af_jw_begin_object
        mov     r15, [r13 + RT_CONFIG]
        test    r15, r15
        jz      .no_config
        mov     rdi, r12
        lea     rsi, [k_providers]
        mov     rdx, [r15 + CFG_PROVIDER_COUNT]
        call    af_jw_member_uint
        mov     rdi, r12
        lea     rsi, [k_routes]
        mov     rdx, [r15 + CFG_ROUTE_COUNT]
        call    af_jw_member_uint
        mov     rdi, r12
        lea     rsi, [k_mcp_servers]
        mov     rdx, [r15 + CFG_MCP_COUNT]
        call    af_jw_member_uint
.no_config:
        mov     rdi, r14
        call    af_ctl_server_accepted
        mov     rdx, rax
        mov     rdi, r12
        lea     rsi, [k_connections]
        call    af_jw_member_uint
        mov     rdi, r12
        call    af_jw_end_object

.no_runtime:
        mov     rdi, r12
        call    af_jw_end_object
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; af_ctl_write_capabilities(af_json_writer *w, u64 bits) -> af_status
;
; Private. The capability bitmask as the array of names the contract shows.
; ---------------------------------------------------------------------------
af_ctl_write_capabilities:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        call    af_jw_begin_array
        xor     r13, r13
.loop:
        cmp     r13, 6
        jae     .done
        mov     rax, 1
        mov     rcx, r13
        shl     rax, cl
        test    r12, rax
        jz      .next
        lea     rax, [tbl_cap_names]
        mov     rsi, [rax + r13 * 8]
        mov     rdi, rbx
        call    af_jw_string
.next:
        inc     r13
        jmp     .loop
.done:
        mov     rdi, rbx
        call    af_jw_end_array
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; af_ctl_write_auth(af_json_writer *w, const void *auth) -> af_status
;
; Private. The authentication POLICY, never a credential: the type, and whether
; the referenced environment variable is currently set. An operator debugging a
; 401 needs exactly those two facts and nothing more (SECURITY_MODEL.md 6).
; ---------------------------------------------------------------------------
af_ctl_write_auth:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        call    af_jw_begin_object

        mov     rax, [r12 + AUTH_TYPE]
        cmp     rax, 2
        ja      .unknown_type
        lea     rcx, [tbl_auth_names]
        mov     rdx, [rcx + rax * 8]
        jmp     .write_type
.unknown_type:
        lea     rdx, [v_none]
.write_type:
        mov     rdi, rbx
        lea     rsi, [k_type]
        call    af_jw_member_string

        cmp     qword [r12 + AUTH_TYPE], AF_AUTH_NONE
        je      .no_secret
        mov     rdi, [r12 + AUTH_ENV]
        test    rdi, rdi
        jz      .secret_absent
        call    af_cfg_getenv
        test    rax, rax
        jz      .secret_absent
        mov     rdi, rbx
        lea     rsi, [k_secret_present]
        mov     rdx, 1
        call    af_jw_member_bool
        jmp     .no_secret
.secret_absent:
        mov     rdi, rbx
        lea     rsi, [k_secret_present]
        xor     edx, edx
        call    af_jw_member_bool
.no_secret:
        mov     rdi, rbx
        call    af_jw_end_object
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; af_ctl_write_provider(af_json_writer *w, af_cfg_provider *p, af_db *db)
;   -> af_status
; ---------------------------------------------------------------------------
af_ctl_write_provider:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, rbx
        call    af_jw_begin_object
        mov     rdi, rbx
        lea     rsi, [k_id]
        mov     rdx, [r12 + PRV_ID]
        call    af_jw_member_string
        mov     rdi, rbx
        lea     rsi, [k_display_name]
        mov     rdx, [r12 + PRV_DISPLAY_NAME]
        call    af_jw_member_string
        mov     rdi, [r12 + PRV_ADAPTER]
        call    af_repo_adapter_name
        mov     rdx, rax
        mov     rdi, rbx
        lea     rsi, [k_adapter]
        call    af_jw_member_string

        ; The base URL is operator configuration, not a secret, and an operator
        ; diagnosing a routing problem needs to see which endpoint a provider
        ; points at. Credentials never appear in it: an embedded userinfo
        ; component is refused at load time.
        mov     rdi, rbx
        lea     rsi, [k_base_url]
        mov     rdx, [r12 + PRV_BASE_URL]
        call    af_jw_member_string

        mov     rdi, rbx
        lea     rsi, [k_enabled]
        mov     rdx, [r12 + PRV_ENABLED]
        call    af_jw_member_bool
        mov     rdi, rbx
        lea     rsi, [k_required]
        mov     rdx, [r12 + PRV_REQUIRED]
        call    af_jw_member_bool
        mov     rdi, rbx
        lea     rsi, [k_max_concurrency]
        mov     rdx, [r12 + PRV_MAX_CONCURRENCY]
        call    af_jw_member_uint

        mov     rdi, rbx
        lea     rsi, [k_capabilities]
        call    af_jw_key
        mov     rdi, rbx
        mov     rsi, [r12 + PRV_CAPABILITIES]
        call    af_ctl_write_capabilities

        mov     rdi, rbx
        lea     rsi, [k_auth]
        call    af_jw_key
        mov     rdi, rbx
        lea     rsi, [r12 + PRV_AUTH]
        call    af_ctl_write_auth

        ; Operator state lives in the database, not the configuration: a reload
        ; must not re-enable a provider somebody turned off.
        mov     qword [rsp], 0
        test    r13, r13
        jz      .no_db
        mov     rdi, r13
        mov     rsi, [r12 + PRV_ID]
        lea     rdx, [rsp]
        call    af_repo_get_operator_disabled
.no_db:
        mov     rdi, rbx
        lea     rsi, [k_operator_disabled]
        mov     rdx, [rsp]
        call    af_jw_member_bool

        mov     rdi, rbx
        call    af_jw_end_object
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; providers.list
; ---------------------------------------------------------------------------
        global af_ctl_m_providers_list
af_ctl_m_providers_list:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi

        mov     rdi, rbx
        call    af_ctl_runtime_of
        mov     r13, rax
        mov     rdi, r12
        call    af_jw_begin_array
        test    r13, r13
        jz      .close
        mov     r14, [r13 + RT_CONFIG]
        test    r14, r14
        jz      .close

        xor     r15, r15
.loop:
        cmp     r15, [r14 + CFG_PROVIDER_COUNT]
        jae     .close
        mov     rax, r15
        imul    rax, rax, PRV_SIZE
        add     rax, [r14 + CFG_PROVIDERS]
        mov     rdi, r12
        mov     rsi, rax
        mov     rdx, [r13 + RT_DB]
        call    af_ctl_write_provider
        inc     r15
        jmp     .loop
.close:
        mov     rdi, r12
        call    af_jw_end_array
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; af_ctl_find_provider(af_config *cfg, json_t *params, void **out)
;   -> af_status
;
; Private. Reads a required `provider_id` parameter and resolves it.
; ---------------------------------------------------------------------------
af_ctl_find_provider:
        AF_ENTER 48
        mov     rbx, rdi                ; config
        mov     r12, rsi                ; params
        mov     r13, rdx                ; out
        mov     qword [r13], 0
        test    r12, r12
        jz      .bad_params
        test    rbx, rbx
        jz      .not_found

        mov     rdi, r12
        lea     rsi, [k_provider_id]
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_json_get_string
        test    rax, rax
        js      .bad_params

        xor     r14, r14
.loop:
        cmp     r14, [rbx + CFG_PROVIDER_COUNT]
        jae     .not_found
        mov     rax, r14
        imul    rax, rax, PRV_SIZE
        add     rax, [rbx + CFG_PROVIDERS]
        mov     r15, rax
        mov     rax, [r15 + PRV_ID_LEN]
        cmp     rax, [rsp + 8]
        jne     .next
        mov     rdi, [r15 + PRV_ID]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_mem_eq
        test    rax, rax
        jnz     .found
.next:
        inc     r14
        jmp     .loop
.found:
        mov     [r13], r15
        AF_LEAVE_OK
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.bad_params:
        AF_LEAVE_ERR AF_E_CTL_PARAMS

; ---------------------------------------------------------------------------
; providers.get
; ---------------------------------------------------------------------------
        global af_ctl_m_providers_get
af_ctl_m_providers_get:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx                ; params

        mov     rdi, rbx
        call    af_ctl_runtime_of
        mov     r14, rax
        test    r14, r14
        jz      .not_found
        mov     rdi, [r14 + RT_CONFIG]
        mov     rsi, r13
        lea     rdx, [rsp]
        call    af_ctl_find_provider
        test    rax, rax
        js      .done
        mov     rdi, r12
        mov     rsi, [rsp]
        mov     rdx, [r14 + RT_DB]
        call    af_ctl_write_provider
        AF_LEAVE_OK
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_write_route(af_json_writer *w, af_cfg_route *r) -> af_status
; ---------------------------------------------------------------------------
af_ctl_write_route:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi

        mov     rdi, rbx
        call    af_jw_begin_object
        mov     rdi, rbx
        lea     rsi, [k_id]
        mov     rdx, [r12 + RTE_ID]
        call    af_jw_member_string
        mov     rdi, rbx
        lea     rsi, [k_model_alias]
        mov     rdx, [r12 + RTE_MODEL_ALIAS]
        call    af_jw_member_string
        mov     rdi, rbx
        lea     rsi, [k_enabled]
        mov     rdx, [r12 + RTE_ENABLED]
        call    af_jw_member_bool
        mov     rdi, [r12 + RTE_POLICY]
        call    af_repo_policy_name
        mov     rdx, rax
        mov     rdi, rbx
        lea     rsi, [k_policy]
        call    af_jw_member_string

        mov     rdi, rbx
        lea     rsi, [k_endpoint_families]
        call    af_jw_key
        mov     rdi, rbx
        call    af_jw_begin_array
        mov     rax, [r12 + RTE_ENDPOINT_FAMILIES]
        test    rax, AF_EPF_RESPONSES
        jz      .no_responses
        mov     rdi, rbx
        lea     rsi, [v_responses]
        call    af_jw_string
.no_responses:
        mov     rax, [r12 + RTE_ENDPOINT_FAMILIES]
        test    rax, AF_EPF_CHAT_COMPLETIONS
        jz      .no_chat
        mov     rdi, rbx
        lea     rsi, [v_chat_completions]
        call    af_jw_string
.no_chat:
        mov     rdi, rbx
        call    af_jw_end_array

        mov     rdi, rbx
        lea     rsi, [k_fallback]
        call    af_jw_key
        mov     rdi, rbx
        call    af_jw_begin_object
        mov     rdi, rbx
        lea     rsi, [k_enabled]
        mov     rdx, [r12 + RTE_FB_ENABLED]
        call    af_jw_member_bool
        mov     rdi, rbx
        lea     rsi, [k_max_attempts]
        mov     rdx, [r12 + RTE_FB_MAX_ATTEMPTS]
        call    af_jw_member_uint
        mov     rdi, rbx
        call    af_jw_end_object

        mov     rdi, rbx
        lea     rsi, [k_targets]
        call    af_jw_key
        mov     rdi, rbx
        call    af_jw_begin_array
        xor     r13, r13
.targets:
        cmp     r13, [r12 + RTE_TARGET_COUNT]
        jae     .targets_done
        mov     rax, r13
        imul    rax, rax, RTG_SIZE
        add     rax, [r12 + RTE_TARGETS]
        mov     r14, rax
        mov     rdi, rbx
        call    af_jw_begin_object
        mov     rdi, rbx
        lea     rsi, [k_provider_id]
        mov     rdx, [r14 + RTG_PROVIDER_ID]
        call    af_jw_member_string
        mov     rdi, rbx
        lea     rsi, [k_upstream_model]
        mov     rdx, [r14 + RTG_UPSTREAM_MODEL]
        call    af_jw_member_string
        mov     rdi, rbx
        lea     rsi, [k_priority]
        mov     rdx, [r14 + RTG_PRIORITY]
        call    af_jw_member_int
        mov     rdi, rbx
        lea     rsi, [k_weight]
        mov     rdx, [r14 + RTG_WEIGHT]
        call    af_jw_member_uint
        mov     rdi, rbx
        call    af_jw_end_object
        inc     r13
        jmp     .targets
.targets_done:
        mov     rdi, rbx
        call    af_jw_end_array
        mov     rdi, rbx
        call    af_jw_end_object
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; routes.list
; ---------------------------------------------------------------------------
        global af_ctl_m_routes_list
af_ctl_m_routes_list:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        call    af_ctl_runtime_of
        mov     r13, rax
        mov     rdi, r12
        call    af_jw_begin_array
        test    r13, r13
        jz      .close
        mov     r14, [r13 + RT_CONFIG]
        test    r14, r14
        jz      .close
        xor     r15, r15
.loop:
        cmp     r15, [r14 + CFG_ROUTE_COUNT]
        jae     .close
        mov     rax, r15
        imul    rax, rax, RTE_SIZE
        add     rax, [r14 + CFG_ROUTES]
        mov     rdi, r12
        mov     rsi, rax
        call    af_ctl_write_route
        inc     r15
        jmp     .loop
.close:
        mov     rdi, r12
        call    af_jw_end_array
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; routes.get
; ---------------------------------------------------------------------------
        global af_ctl_m_routes_get
af_ctl_m_routes_get:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        test    r13, r13
        jz      .bad_params

        mov     rdi, rbx
        call    af_ctl_runtime_of
        mov     r14, rax
        test    r14, r14
        jz      .not_found
        mov     r14, [r14 + RT_CONFIG]
        test    r14, r14
        jz      .not_found

        mov     rdi, r13
        lea     rsi, [k_id]
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_json_get_string
        test    rax, rax
        js      .bad_params

        xor     r15, r15
.loop:
        cmp     r15, [r14 + CFG_ROUTE_COUNT]
        jae     .not_found
        mov     rax, r15
        imul    rax, rax, RTE_SIZE
        add     rax, [r14 + CFG_ROUTES]
        mov     [rsp + 16], rax
        mov     rdi, [rax + RTE_ID]
        call    af_cstr_len
        cmp     rax, [rsp + 8]
        jne     .next
        mov     rcx, [rsp + 16]
        mov     rdi, [rcx + RTE_ID]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_mem_eq
        test    rax, rax
        jnz     .found
.next:
        inc     r15
        jmp     .loop
.found:
        mov     rdi, r12
        mov     rsi, [rsp + 16]
        call    af_ctl_write_route
        AF_LEAVE_OK
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.bad_params:
        AF_LEAVE_ERR AF_E_CTL_PARAMS

; ---------------------------------------------------------------------------
; mcp.list
;
; Configuration and enablement only. Live state, era, and inventory arrive with
; the supervisor in M8 and M9.
; ---------------------------------------------------------------------------
        global af_ctl_m_mcp_list
af_ctl_m_mcp_list:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        call    af_ctl_runtime_of
        mov     r13, rax
        mov     rdi, r12
        call    af_jw_begin_array
        test    r13, r13
        jz      .close
        mov     r14, [r13 + RT_CONFIG]
        test    r14, r14
        jz      .close
        xor     r15, r15
.loop:
        cmp     r15, [r14 + CFG_MCP_COUNT]
        jae     .close
        mov     rax, r15
        imul    rax, rax, MCP_SIZE
        add     rax, [r14 + CFG_MCP_SERVERS]
        mov     [rsp], rax
        mov     rdi, r12
        call    af_jw_begin_object
        mov     rcx, [rsp]
        mov     rdi, r12
        lea     rsi, [k_id]
        mov     rdx, [rcx + MCP_ID]
        call    af_jw_member_string
        mov     rcx, [rsp]
        mov     rdi, r12
        lea     rsi, [k_display_name]
        mov     rdx, [rcx + MCP_DISPLAY_NAME]
        call    af_jw_member_string
        mov     rcx, [rsp]
        mov     rdi, [rcx + MCP_TRANSPORT]
        call    af_repo_transport_name
        mov     rdx, rax
        mov     rdi, r12
        lea     rsi, [k_transport]
        call    af_jw_member_string
        mov     rcx, [rsp]
        mov     rdi, r12
        lea     rsi, [k_enabled]
        mov     rdx, [rcx + MCP_ENABLED]
        call    af_jw_member_bool
        mov     rcx, [rsp]
        mov     rdi, r12
        lea     rsi, [k_required]
        mov     rdx, [rcx + MCP_REQUIRED]
        call    af_jw_member_bool
        mov     rdi, r12
        call    af_jw_end_object
        inc     r15
        jmp     .loop
.close:
        mov     rdi, r12
        call    af_jw_end_array
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; config.current
;
; A redacted view of the published snapshot: shape, limits, and policy names.
; No secret value, and no environment variable name — an export that named the
; variables would hand a reader the deployment's secret layout, which is a
; smaller leak than the values but still a leak.
; ---------------------------------------------------------------------------
        global af_ctl_m_config_current
af_ctl_m_config_current:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        call    af_ctl_runtime_of
        mov     r13, rax

        mov     rdi, r12
        call    af_jw_begin_object
        test    r13, r13
        jz      .close
        mov     r14, [r13 + RT_CONFIG]
        test    r14, r14
        jz      .close

        mov     rdi, r12
        lea     rsi, [k_schema_version]
        mov     rdx, [r14 + CFG_SCHEMA_VERSION]
        call    af_jw_member_uint

        ; The hash identifies a configuration revision without disclosing it.
        mov     rdi, r12
        lea     rsi, [k_config_hash]
        mov     rdx, [r14 + CFG_HASH]
        call    af_jw_member_uint

        mov     rdi, r12
        lea     rsi, [k_config_path]
        mov     rdx, [r13 + RT_CONFIG_PATH]
        call    af_jw_member_string

        mov     rdi, r12
        lea     rsi, [k_listener]
        call    af_jw_key
        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_host]
        mov     rdx, [r14 + CFG_LST_HOST]
        call    af_jw_member_string
        mov     rdi, r12
        lea     rsi, [k_port]
        mov     rdx, [r14 + CFG_LST_PORT]
        call    af_jw_member_uint
        mov     rdi, r12
        lea     rsi, [k_loopback]
        mov     rdx, [r14 + CFG_LST_IS_LOOPBACK]
        call    af_jw_member_bool
        mov     rdi, r12
        lea     rsi, [k_auth]
        call    af_jw_key
        mov     rdi, r12
        lea     rsi, [r14 + CFG_LST_AUTH]
        call    af_ctl_write_auth
        mov     rdi, r12
        call    af_jw_end_object

        mov     rdi, r12
        lea     rsi, [k_control]
        call    af_jw_key
        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_socket_path]
        mov     rdx, [r14 + CFG_CTL_SOCKET_PATH]
        call    af_jw_member_string
        mov     rdi, r12
        call    af_jw_end_object

        mov     rdi, r12
        lea     rsi, [k_store_payloads]
        mov     rdx, [r14 + CFG_STO_STORE_PAYLOADS]
        call    af_jw_member_bool

.close:
        mov     rdi, r12
        call    af_jw_end_object
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; provider.enable / provider.disable
;
; The operator's own decision, persisted so a configuration reload cannot
; silently undo it.
; ---------------------------------------------------------------------------
        global af_ctl_m_provider_enable
af_ctl_m_provider_enable:
        AF_ENTER 0
        xor     ecx, ecx
        call    af_ctl_set_provider_state
        AF_LEAVE

        global af_ctl_m_provider_disable
af_ctl_m_provider_disable:
        AF_ENTER 0
        mov     rcx, 1
        call    af_ctl_set_provider_state
        AF_LEAVE

; af_ctl_set_provider_state(conn, writer, params, i64 disabled) -> af_status
af_ctl_set_provider_state:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     [rsp + 16], rcx

        mov     rdi, rbx
        call    af_ctl_runtime_of
        mov     r14, rax
        test    r14, r14
        jz      .not_found
        mov     rdi, [r14 + RT_CONFIG]
        mov     rsi, r13
        lea     rdx, [rsp]
        call    af_ctl_find_provider
        test    rax, rax
        js      .done
        mov     r15, [rsp]

        mov     rdi, [r14 + RT_DB]
        mov     rsi, [r15 + PRV_ID]
        mov     rdx, [rsp + 16]
        call    af_repo_set_operator_disabled
        test    rax, rax
        js      .db_failed

        mov     rdi, rbx
        call    af_ctl_conn_server
        mov     rdi, rax
        call    af_ctl_server_bump_revision_local

        mov     rdi, r12
        mov     rsi, [rsp]
        mov     rdx, [r14 + RT_DB]
        call    af_ctl_write_provider
        AF_LEAVE_OK
.db_failed:
        AF_LEAVE_ERR AF_E_INTERNAL
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.done:
        AF_LEAVE

        extern af_ctl_server_bump_revision
af_ctl_server_bump_revision_local:
        AF_ENTER 0
        call    af_ctl_server_bump_revision
        AF_LEAVE
