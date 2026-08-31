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
%include "routing.inc"
%include "mcp.inc"

        extern af_cstr_len
        extern af_u64_to_dec
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
        extern af_jw_raw
        extern af_jw_init
        extern af_jw_finish

        extern af_buf_init
        extern af_buf_free
        extern af_buf_data
        extern af_buf_len
        extern af_buf_append

        extern af_json_member
        extern af_json_type
        extern af_json_get_bool
        extern af_json_get_object
        extern af_json_get_array
        extern af_json_array_at
        extern af_json_array_count
        extern af_json_string_of
        extern af_json_parse
        extern af_json_doc_root
        extern af_json_doc_free
        extern af_jsonc_dump
        extern af_jsonc_dump_free

        extern af_routing_provider
        extern af_health_refresh
        extern af_health_state_name
        extern af_routing_now_ns

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
        extern af_curl_version
        extern af_sqlitec_libversion
        extern jansson_version_str

        extern af_repo_provider_count
        extern af_repo_route_count
        extern af_repo_mcp_count
        extern af_repo_request_count
        extern af_repo_get_operator_disabled
        extern af_repo_set_operator_disabled
        extern af_repo_record_audit
        extern af_repo_adapter_name
        extern af_repo_policy_name
        extern af_repo_transport_name
        extern af_db_is_open

        extern af_cfg_getenv

        extern af_mcp_child_for
        extern af_mcp_state_name
        extern af_mcp_required_ready
        extern af_mcp_manual_start
        extern af_mcp_manual_restart
        extern af_mcp_stop
        extern af_mcp_reset
        extern af_mcp_refresh_inventory
        extern af_mcp_request
        extern af_mcp_call_release

        section .rodata

; --- method names ----------------------------------------------------------
n_system_version:  db "system.version", 0
n_system_snapshot: db "system.snapshot", 0
k_health:          db "health", 0
k_active:          db "active_requests", 0
k_latency_us:      db "observed_latency_us", 0
k_failures:        db "consecutive_failures", 0
k_opened:          db "circuit_opened_count", 0
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
k_status:         db "status", 0
k_era:            db "era", 0
k_pid:            db "pid", 0
k_starts:         db "starts", 0
k_exits:          db "exits", 0
k_restarts:       db "restarts", 0
k_last_exit:      db "last_exit", 0
k_last_signal:    db "last_signal", 0
k_frames_in:      db "frames_in", 0
k_frames_out:     db "frames_out", 0
k_contaminated:   db "contaminated", 0
k_oversized:      db "oversized", 0
k_stderr_bytes:   db "stderr_bytes", 0
k_stderr_truncated: db "stderr_truncated", 0
k_notifications:  db "notifications", 0
k_unmatched:      db "unmatched", 0
k_server_id:      db "server_id", 0
k_tools:          db "tools", 0
k_resources:      db "resources", 0
k_prompts:        db "prompts", 0
k_tool_count:     db "tool_count", 0
k_resource_count: db "resource_count", 0
k_prompt_count:   db "prompt_count", 0
k_fetched_ns:     db "fetched_at_monotonic_ns", 0
k_expires_ns:     db "expires_at_monotonic_ns", 0
k_cache_scope:    db "cache_scope", 0
k_queued:         db "queued", 0
k_request_id:     db "request_id", 0
k_confirmed:      db "confirmed", 0
k_tool:           db "tool", 0
k_arguments:      db "arguments", 0
k_result:         db "result", 0
k_error_code:     db "error_code", 0
k_tool_test:      db "tool_test", 0
k_name:           db "name", 0
k_meta:           db "_meta", 0
k_format_version: db "format_version", 0
k_generated_at_ms: db "generated_at_ms", 0
k_shutting_down:  db "shutting_down", 0
k_last_error:     db "last_error", 0
k_at_ms:          db "at_ms", 0
k_dependencies:   db "dependencies", 0
k_curl:           db "curl", 0
k_sqlite:         db "sqlite", 0
k_jansson:        db "jansson", 0
k_redacted:       db "redacted", 0
k_payloads_included: db "payloads_included", 0
k_secrets_included: db "secrets_included", 0
k_config_current: db "config", 0

v_unknown:        db "unknown", 0
v_modern_2026:    db "modern_2026", 0
v_legacy_2025:    db "legacy_2025", 0
v_pending:        db "pending", 0
v_done:           db "done", 0
v_failed:         db "failed", 0
v_public:         db "public", 0
v_private:        db "private", 0

m_tools_call:     db "tools/call", 0
p_modern_meta:
        db '{"io.modelcontextprotocol/protocolVersion":"2026-07-28",'
        db '"io.modelcontextprotocol/clientInfo":{"name":"AsmFlow","version":"'
        db AF_VERSION_STRING
        db '"},"io.modelcontextprotocol/clientCapabilities":{}}', 0

v_responses:        db "responses", 0
v_chat_completions: db "chat_completions", 0
v_open:             db "open", 0
v_closed:           db "closed", 0
v_none:             db "none", 0
v_bearer_env:       db "bearer_env", 0
v_header_env:       db "header_env", 0
v_audit_success:    db "success", 0
v_audit_failure:    db "failure", 0

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
        align 8
tbl_mutating_methods:
        dq n_provider_enable, n_provider_disable
        dq n_mcp_start, n_mcp_stop, n_mcp_restart, n_mcp_reset_loop
        dq n_mcp_discover, n_mcp_tool_test
        dq 0

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
        dq n_mcp_get,         af_ctl_m_mcp_get
        dq n_mcp_inventory,   af_ctl_m_mcp_inventory
        dq n_logs_tail,       0
        dq n_config_validate, 0
        dq n_config_reload,   0
        dq n_provider_probe,  0
        dq n_mcp_start,       af_ctl_m_mcp_start
        dq n_mcp_stop,        af_ctl_m_mcp_stop
        dq n_mcp_restart,     af_ctl_m_mcp_restart
        dq n_mcp_reset_loop,  af_ctl_m_mcp_reset_loop
        dq n_mcp_discover,    af_ctl_m_mcp_discover
        dq n_mcp_tool_test,   af_ctl_m_mcp_tool_test
        dq n_diagnostics,     af_ctl_m_diagnostics_export
        dq 0, 0

        section .text

; ---------------------------------------------------------------------------
; af_ctl_write_config_hash(af_json_writer *writer, u64 hash) -> af_status
;
; A configuration hash spans the complete unsigned 64-bit domain. Jansson,
; which validates every console response before presentation, accepts JSON
; integers only through signed 64-bit. The wire representation is therefore
; the canonical base-10 string: exact and parseable for every hash. `writer`
; is BORROWED and the temporary decimal span is stack-owned.
; ---------------------------------------------------------------------------
af_ctl_write_config_hash:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, r12
        lea     rsi, [rsp]
        mov     rdx, 20
        lea     rcx, [rsp + 24]
        call    af_u64_to_dec
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [k_config_hash]
        call    af_jw_key
        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, [rsp + 24]
        call    af_jw_string_n
.done:
        AF_LEAVE

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

        ; Audit is deliberately best-effort: a storage observability failure
        ; cannot turn a completed operator action into a reported failure.  The
        ; repository stores only the static method/outcome names, peer numbers,
        ; normalized status, and time — never params or payloads.
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, [rsp + 104]
        call    af_ctl_record_audit

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
        ; Preserve only the normalized status and its time.  Request params,
        ; payload bytes, provider text, and submitted credentials are never
        ; copied into runtime diagnostics.
        mov     rdi, rbx
        call    af_ctl_runtime_of
        test    rax, rax
        jz      .error_recorded
        mov     rcx, [rsp + 104]
        mov     [rax + RT_LAST_ERROR], rcx
        mov     [rsp + 120], rax
        lea     rdi, [rsp + 112]
        call    af_realtime_ms
        test    rax, rax
        js      .error_recorded
        mov     rax, [rsp + 120]
        mov     rcx, [rsp + 112]
        mov     [rax + RT_LAST_ERROR_AT_MS], rcx
.error_recorded:
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
        mov     rcx, AF_CTLERR_UNCONFIRMED
        cmp     qword [rsp + 104], AF_E_MCP_UNCONFIRMED
        je      .emit
        mov     rcx, AF_CTLERR_STATE
        cmp     qword [rsp + 104], AF_E_MCP_NOT_READY
        je      .emit
        cmp     qword [rsp + 104], AF_E_MCP_CRASH_LOOP
        je      .emit
        cmp     qword [rsp + 104], AF_E_CLOSED
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

; af_ctl_record_audit(af_ctl_conn *c, const void *entry, af_status status)
;   -> void
af_ctl_record_audit:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        test    rsi, rsi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, [r12]              ; STATIC action name
        lea     r15, [tbl_mutating_methods]
.scan:
        mov     rax, [r15]
        test    rax, rax
        jz      .done
        cmp     rax, r14
        je      .record
        add     r15, 8
        jmp     .scan
.record:
        mov     rdi, rbx
        call    af_ctl_runtime_of
        test    rax, rax
        jz      .done
        mov     rdi, [rax + RT_DB]
        test    rdi, rdi
        jz      .done
        lea     r8, [v_audit_success]
        test    r13, r13
        jns     .have_outcome
        lea     r8, [v_audit_failure]
.have_outcome:
        mov     rsi, r14
        mov     rdx, [rbx + CONN_PEER_UID]
        mov     rcx, [rbx + CONN_PEER_PID]
        mov     r9, r13
        call    af_repo_record_audit
.done:
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
        mov     rdx, AF_CTL_PROTOCOL_VERSION
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

        ; The snapshot and /readyz use the same dependency predicate.  RT_READY
        ; says startup completed; required MCP children still have to finish a
        ; successful tools inventory, and shutdown/database state remain hard
        ; readiness barriers.
        xor     rax, rax
        cmp     qword [r13 + RT_READY], 0
        je      .ready_known
        cmp     qword [r13 + RT_SHUTTING_DOWN], 0
        jne     .ready_known
        mov     rdi, [r13 + RT_DB]
        test    rdi, rdi
        jz      .ready_known
        call    af_db_is_open
        test    rax, rax
        jz      .ready_known
        mov     rdi, [r13 + RT_MCP]
        call    af_mcp_required_ready
.ready_known:
        mov     [rsp + 32], rax
        mov     rdi, r12
        lea     rsi, [k_ready]
        mov     rdx, [rsp + 32]
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
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     [rsp + 8], rcx                  ; af_routing *, may be NULL

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

        ; The live view. Absent from a snapshot that predates any traffic,
        ; which is why every field has a defined value for a provider nothing
        ; has yet tried: healthy, nothing in flight, nothing measured.
        mov     r14, [rsp + 8]
        xor     r15, r15
        test    r14, r14
        jz      .no_state
        mov     rdi, r14
        mov     rsi, [r12 + PRV_ID]
        call    af_routing_provider
        mov     r15, rax
        test    r15, r15
        jz      .no_state
        ; Reported after the cooldown has been applied, so an operator reading
        ; this sees `half_open` at the moment a probe would be admitted rather
        ; than `open` until the next request happens to look.
        mov     rdi, r14
        call    af_routing_now_ns
        mov     rdi, r15
        mov     rsi, rax
        call    af_health_refresh
.no_state:

        xor     edi, edi
        test    r15, r15
        jz      .health_name
        mov     rdi, [r15 + PS_HEALTH]
.health_name:
        call    af_health_state_name
        mov     rdx, rax
        mov     rdi, rbx
        lea     rsi, [k_health]
        call    af_jw_member_string

        xor     edx, edx
        test    r15, r15
        jz      .write_active
        mov     rdx, [r15 + PS_ACTIVE]
.write_active:
        mov     rdi, rbx
        lea     rsi, [k_active]
        call    af_jw_member_uint

        xor     edx, edx
        test    r15, r15
        jz      .write_latency
        mov     rdx, [r15 + PS_EWMA]
.write_latency:
        mov     rdi, rbx
        lea     rsi, [k_latency_us]
        call    af_jw_member_uint

        xor     edx, edx
        test    r15, r15
        jz      .write_failures
        mov     rdx, [r15 + PS_FAILURES]
.write_failures:
        mov     rdi, rbx
        lea     rsi, [k_failures]
        call    af_jw_member_uint

        xor     edx, edx
        test    r15, r15
        jz      .write_opened
        mov     rdx, [r15 + PS_OPENED]
.write_opened:
        mov     rdi, rbx
        lea     rsi, [k_opened]
        call    af_jw_member_uint

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
        mov     rcx, [r13 + RT_ROUTING]
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
        mov     rcx, [r14 + RT_ROUTING]
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
; mcp.list / mcp.get / mcp.inventory
;
; Configuration and live state are joined by the stable configured identifier.
; Both stdio and Streamable HTTP servers have transport-neutral supervisor
; children; the transport-specific adapter remains private to that child.
; ---------------------------------------------------------------------------
        global af_ctl_m_mcp_list
af_ctl_m_mcp_list:
        AF_ENTER 48
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
        mov     rax, [r13 + RT_MCP]
        mov     [rsp], rax
        xor     r15, r15
.loop:
        cmp     r15, [r14 + CFG_MCP_COUNT]
        jae     .close
        mov     rax, r15
        imul    rax, rax, MCP_SIZE
        add     rax, [r14 + CFG_MCP_SERVERS]
        mov     [rsp + 8], rax
        xor     r13d, r13d
        mov     rdi, [rsp]
        test    rdi, rdi
        jz      .write
        mov     rsi, [rax + MCP_ID]
        call    af_mcp_child_for
        mov     r13, rax
.write:
        mov     rdi, r12
        mov     rsi, [rsp + 8]
        mov     rdx, r13
        xor     ecx, ecx
        call    af_ctl_write_mcp
        inc     r15
        jmp     .loop
.close:
        mov     rdi, r12
        call    af_jw_end_array
        AF_LEAVE_OK

; af_ctl_find_mcp(af_runtime *rt, json_t *params, af_cfg_mcp **out_cfg,
;                 af_mcp_child **out_child) -> af_status
;
; The JSON length is authoritative.  Requiring the borrowed Jansson string's
; C length to match rejects an embedded NUL before any C-string lookup can turn
; `real\u0000suffix` into `real`.
af_ctl_find_mcp:
        AF_ENTER 64
        test    rdi, rdi
        jz      .not_found
        test    rsi, rsi
        jz      .bad_params
        test    rdx, rdx
        jz      .bad_params
        test    rcx, rcx
        jz      .bad_params
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     qword [r13], 0
        mov     qword [r14], 0

        mov     rdi, r12
        lea     rsi, [k_server_id]
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_json_get_string
        test    rax, rax
        js      .bad_params
        cmp     qword [rsp + 8], 0
        je      .bad_params
        mov     rdi, [rsp]
        call    af_cstr_len
        cmp     rax, [rsp + 8]
        jne     .bad_params

        mov     r15, [rbx + RT_CONFIG]
        test    r15, r15
        jz      .not_found
        mov     qword [rsp + 16], 0
.scan:
        mov     rax, [rsp + 16]
        cmp     rax, [r15 + CFG_MCP_COUNT]
        jae     .not_found
        imul    rax, rax, MCP_SIZE
        add     rax, [r15 + CFG_MCP_SERVERS]
        mov     [rsp + 24], rax
        mov     rdi, [rax + MCP_ID]
        call    af_cstr_len
        cmp     rax, [rsp + 8]
        jne     .next
        mov     rax, [rsp + 24]
        mov     rdi, [rax + MCP_ID]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_mem_eq
        test    rax, rax
        jnz     .found
.next:
        inc     qword [rsp + 16]
        jmp     .scan
.found:
        mov     rax, [rsp + 24]
        mov     [r13], rax
        mov     rdi, [rbx + RT_MCP]
        test    rdi, rdi
        jz      .not_found
        mov     rsi, [rsp]
        call    af_mcp_child_for
        test    rax, rax
        jz      .not_found
        mov     [r14], rax
        AF_LEAVE_OK
.bad_params:
        AF_LEAVE_ERR AF_E_CTL_PARAMS
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND

; af_ctl_mcp_era_name(i64 era) -> const char * (STATIC)
af_ctl_mcp_era_name:
        cmp     rdi, AF_ERA_MODERN
        je      .modern
        cmp     rdi, AF_ERA_LEGACY
        je      .legacy
        lea     rax, [v_unknown]
        ret
.modern:
        lea     rax, [v_modern_2026]
        ret
.legacy:
        lea     rax, [v_legacy_2025]
        ret

; af_ctl_mcp_cache_scope_name(i64 scope) -> const char * (STATIC)
af_ctl_mcp_cache_scope_name:
        cmp     rdi, AF_MCP_CACHE_PUBLIC
        je      .public
        cmp     rdi, AF_MCP_CACHE_PRIVATE
        je      .private
        lea     rax, [v_none]
        ret
.public:
        lea     rax, [v_public]
        ret
.private:
        lea     rax, [v_private]
        ret

; af_ctl_find_tool_call(af_mcp_child *child) -> af_mcp_call * (BORROWED)
af_ctl_find_tool_call:
        test    rdi, rdi
        jz      .none
        xor     ecx, ecx
.scan:
        cmp     rcx, AF_MCP_MAX_CALLS
        jae     .none
        mov     rax, rcx
        imul    rax, rax, CL_SIZE
        add     rax, rdi
        add     rax, MC_CALLS
        cmp     qword [rax + CL_STATE], AF_MCP_CALL_FREE
        je      .next
        cmp     qword [rax + CL_KIND], AF_MCP_CALL_TOOL_TEST
        je      .done
.next:
        inc     rcx
        jmp     .scan
.none:
        xor     eax, eax
.done:
        ret

; af_ctl_write_tool_call(af_json_writer *w, af_mcp_call *call) -> af_status
af_ctl_write_tool_call:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        call    af_jw_begin_object
        mov     rdi, rbx
        lea     rsi, [k_request_id]
        mov     rdx, [r12 + CL_ID]
        call    af_jw_member_uint
        mov     rdi, rbx
        lea     rsi, [k_state]
        cmp     qword [r12 + CL_STATE], AF_MCP_CALL_DONE
        je      .done_name
        lea     rdx, [v_pending]
        jmp     .state_name
.done_name:
        lea     rdx, [v_done]
.state_name:
        call    af_jw_member_string
        mov     rdi, rbx
        lea     rsi, [k_status]
        mov     rdx, [r12 + CL_STATUS]
        call    af_jw_member_int
        mov     rdi, rbx
        lea     rsi, [k_error_code]
        mov     rdx, [r12 + CL_ERROR_CODE]
        call    af_jw_member_int
        mov     rdi, rbx
        lea     rsi, [k_result]
        call    af_jw_key
        cmp     qword [r12 + CL_STATE], AF_MCP_CALL_DONE
        jne     .null
        lea     rdi, [r12 + CL_RESULT]
        call    af_buf_len
        mov     r13, rax
        test    r13, r13
        jz      .null
        lea     rdi, [r12 + CL_RESULT]
        call    af_buf_data
        test    rax, rax
        jz      .null
        mov     rdi, rbx
        mov     rsi, rax
        mov     rdx, r13
        call    af_jw_raw
        jmp     .close
.null:
        mov     rdi, rbx
        call    af_jw_null
.close:
        mov     rdi, rbx
        call    af_jw_end_object
        AF_LEAVE_OK

; af_ctl_write_mcp(af_json_writer *w, af_cfg_mcp *cfg, af_mcp_child *child,
;                  i64 include_tool_test) -> af_status
af_ctl_write_mcp:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r13, rsi
        mov     r14, rdx
        mov     r15, rcx
        mov     rdi, rbx
        call    af_jw_begin_object
        mov     rdi, rbx
        lea     rsi, [k_id]
        mov     rdx, [r13 + MCP_ID]
        call    af_jw_member_string
        mov     rdi, rbx
        lea     rsi, [k_display_name]
        mov     rdx, [r13 + MCP_DISPLAY_NAME]
        call    af_jw_member_string
        mov     rdi, [r13 + MCP_TRANSPORT]
        call    af_repo_transport_name
        mov     rdx, rax
        mov     rdi, rbx
        lea     rsi, [k_transport]
        call    af_jw_member_string
        mov     rdi, rbx
        lea     rsi, [k_enabled]
        mov     rdx, [r13 + MCP_ENABLED]
        call    af_jw_member_bool
        mov     rdi, rbx
        lea     rsi, [k_required]
        mov     rdx, [r13 + MCP_REQUIRED]
        call    af_jw_member_bool

        mov     rdi, rbx
        lea     rsi, [k_state]
        test    r14, r14
        jz      .configured_state
        mov     rdi, [r14 + MC_STATE]
        call    af_mcp_state_name
        mov     rdx, rax
        jmp     .emit_state
.configured_state:
        cmp     qword [r13 + MCP_ENABLED], 0
        jne     .configured_failed
        mov     rdi, AF_MCP_S_DISABLED
        call    af_mcp_state_name
        mov     rdx, rax
        jmp     .emit_state
.configured_failed:
        lea     rdx, [v_failed]
.emit_state:
        mov     rdi, rbx
        lea     rsi, [k_state]
        call    af_jw_member_string

        xor     edi, edi
        test    r14, r14
        jz      .era_name
        mov     rdi, [r14 + MC_ERA]
.era_name:
        call    af_ctl_mcp_era_name
        mov     rdx, rax
        mov     rdi, rbx
        lea     rsi, [k_era]
        call    af_jw_member_string

        ; Negotiated version is owned by this process view and is NULL until
        ; era validation commits. Emit null after stop/failure/restart rather
        ; than inferring a version from the era label or configuration.
        mov     rdi, rbx
        lea     rsi, [k_protocol_ver]
        call    af_jw_key
        test    r14, r14
        jz      .protocol_version_null
        mov     rdx, [r14 + MC_VERSION]
        test    rdx, rdx
        jz      .protocol_version_null
        mov     rdi, rbx
        mov     rsi, rdx
        call    af_jw_string
        jmp     .protocol_version_done
.protocol_version_null:
        mov     rdi, rbx
        call    af_jw_null
.protocol_version_done:

%macro MCP_LIVE_UINT 2
        xor     edx, edx
        test    r14, r14
        jz      %%emit
        mov     rdx, [r14 + %2]
%%emit:
        mov     rdi, rbx
        lea     rsi, [%1]
        call    af_jw_member_uint
%endmacro
        MCP_LIVE_UINT k_pid, MC_PID
        MCP_LIVE_UINT k_starts, MC_STARTS
        MCP_LIVE_UINT k_exits, MC_EXITS
        MCP_LIVE_UINT k_restarts, MC_RESTARTS
        MCP_LIVE_UINT k_last_exit, MC_LAST_EXIT
        MCP_LIVE_UINT k_last_signal, MC_LAST_SIGNAL
        MCP_LIVE_UINT k_frames_in, MC_FRAMES_IN
        MCP_LIVE_UINT k_frames_out, MC_FRAMES_OUT
        MCP_LIVE_UINT k_contaminated, MC_CONTAMINATED
        MCP_LIVE_UINT k_oversized, MC_OVERSIZED
        MCP_LIVE_UINT k_stderr_bytes, MC_STDERR_BYTES
        MCP_LIVE_UINT k_stderr_truncated, MC_STDERR_TRUNC
        MCP_LIVE_UINT k_notifications, MC_NOTIFICATIONS
        MCP_LIVE_UINT k_unmatched, MC_UNMATCHED
        MCP_LIVE_UINT k_tool_count, MC_TOOL_COUNT
        MCP_LIVE_UINT k_resource_count, MC_RES_COUNT
        MCP_LIVE_UINT k_prompt_count, MC_PROMPT_COUNT
        MCP_LIVE_UINT k_fetched_ns, MC_FETCHED_NS
        MCP_LIVE_UINT k_expires_ns, MC_EXPIRES_NS
%unmacro MCP_LIVE_UINT 2

        xor     edi, edi
        test    r14, r14
        jz      .scope_name_ready
        mov     rdi, [r14 + MC_CACHE_SCOPE]
.scope_name_ready:
        call    af_ctl_mcp_cache_scope_name
        mov     rdx, rax
        mov     rdi, rbx
        lea     rsi, [k_cache_scope]
        call    af_jw_member_string

        test    r15, r15
        jz      .close
        test    r14, r14
        jz      .close
        mov     rdi, r14
        call    af_ctl_find_tool_call
        test    rax, rax
        jz      .close
        mov     [rsp], rax
        mov     rdi, rbx
        lea     rsi, [k_tool_test]
        call    af_jw_key
        mov     rdi, rbx
        mov     rsi, [rsp]
        call    af_ctl_write_tool_call
.close:
        mov     rdi, rbx
        call    af_jw_end_object
        AF_LEAVE_OK

        global af_ctl_m_mcp_get
af_ctl_m_mcp_get:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, rbx
        call    af_ctl_runtime_of
        test    rax, rax
        jz      .not_found
        mov     rdi, rax
        mov     rsi, r13
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_find_mcp
        test    rax, rax
        js      .done
        mov     rdi, r12
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        mov     rcx, 1
        call    af_ctl_write_mcp
        AF_LEAVE_OK
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.done:
        AF_LEAVE

; af_ctl_write_inventory_value(writer, key, af_buffer *value) -> void
af_ctl_write_inventory_value:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rdx
        mov     rdi, rbx
        call    af_jw_key
        mov     rdi, r12
        call    af_buf_len
        mov     r13, rax
        test    r13, r13
        jz      .null
        mov     rdi, r12
        call    af_buf_data
        test    rax, rax
        jz      .null
        mov     rdi, rbx
        mov     rsi, rax
        mov     rdx, r13
        call    af_jw_raw
        AF_LEAVE
.null:
        mov     rdi, rbx
        call    af_jw_null
        AF_LEAVE

        global af_ctl_m_mcp_inventory
af_ctl_m_mcp_inventory:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, rbx
        call    af_ctl_runtime_of
        test    rax, rax
        jz      .not_found
        mov     rdi, rax
        mov     rsi, r13
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_find_mcp
        test    rax, rax
        js      .done
        mov     r14, [rsp + 8]
        test    r14, r14
        jz      .not_ready
        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_server_id]
        mov     rdx, [r14 + MC_ID]
        call    af_jw_member_string
        mov     rdi, [r14 + MC_ERA]
        call    af_ctl_mcp_era_name
        mov     rdx, rax
        mov     rdi, r12
        lea     rsi, [k_era]
        call    af_jw_member_string
        mov     rdi, r12
        lea     rsi, [k_tools]
        lea     rdx, [r14 + MC_TOOLS]
        call    af_ctl_write_inventory_value
        mov     rdi, r12
        lea     rsi, [k_resources]
        lea     rdx, [r14 + MC_RESOURCES]
        call    af_ctl_write_inventory_value
        mov     rdi, r12
        lea     rsi, [k_prompts]
        lea     rdx, [r14 + MC_PROMPTS]
        call    af_ctl_write_inventory_value
        mov     rdi, r12
        lea     rsi, [k_tool_count]
        mov     rdx, [r14 + MC_TOOL_COUNT]
        call    af_jw_member_uint
        mov     rdi, r12
        lea     rsi, [k_resource_count]
        mov     rdx, [r14 + MC_RES_COUNT]
        call    af_jw_member_uint
        mov     rdi, r12
        lea     rsi, [k_prompt_count]
        mov     rdx, [r14 + MC_PROMPT_COUNT]
        call    af_jw_member_uint
        mov     rdi, r12
        lea     rsi, [k_fetched_ns]
        mov     rdx, [r14 + MC_FETCHED_NS]
        call    af_jw_member_uint
        mov     rdi, r12
        lea     rsi, [k_expires_ns]
        mov     rdx, [r14 + MC_EXPIRES_NS]
        call    af_jw_member_uint
        mov     rdi, [r14 + MC_CACHE_SCOPE]
        call    af_ctl_mcp_cache_scope_name
        mov     rdx, rax
        mov     rdi, r12
        lea     rsi, [k_cache_scope]
        call    af_jw_member_string
        mov     rdi, r12
        call    af_jw_end_object
        AF_LEAVE_OK
.not_ready:
        AF_LEAVE_ERR AF_E_MCP_NOT_READY
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; MCP lifecycle and discovery mutations.
; ---------------------------------------------------------------------------
%define CTL_MCP_ACT_START    0
%define CTL_MCP_ACT_STOP     1
%define CTL_MCP_ACT_RESTART  2
%define CTL_MCP_ACT_RESET    3
%define CTL_MCP_ACT_DISCOVER 4

        global af_ctl_m_mcp_start
af_ctl_m_mcp_start:
        AF_ENTER 0
        mov     rcx, CTL_MCP_ACT_START
        call    af_ctl_mcp_action
        AF_LEAVE

        global af_ctl_m_mcp_stop
af_ctl_m_mcp_stop:
        AF_ENTER 0
        mov     rcx, CTL_MCP_ACT_STOP
        call    af_ctl_mcp_action
        AF_LEAVE

        global af_ctl_m_mcp_restart
af_ctl_m_mcp_restart:
        AF_ENTER 0
        mov     rcx, CTL_MCP_ACT_RESTART
        call    af_ctl_mcp_action
        AF_LEAVE

        global af_ctl_m_mcp_reset_loop
af_ctl_m_mcp_reset_loop:
        AF_ENTER 0
        mov     rcx, CTL_MCP_ACT_RESET
        call    af_ctl_mcp_action
        AF_LEAVE

        global af_ctl_m_mcp_discover
af_ctl_m_mcp_discover:
        AF_ENTER 0
        mov     rcx, CTL_MCP_ACT_DISCOVER
        call    af_ctl_mcp_action
        AF_LEAVE

; af_ctl_mcp_action(conn, writer, params, action) -> af_status
af_ctl_mcp_action:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     [rsp + 24], rcx
        mov     rdi, rbx
        call    af_ctl_runtime_of
        test    rax, rax
        jz      .not_found
        mov     r14, rax
        mov     r15, [r14 + RT_MCP]
        test    r15, r15
        jz      .not_ready
        mov     rdi, r14
        mov     rsi, r13
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_find_mcp
        test    rax, rax
        js      .done
        mov     r13, [rsp + 8]
        test    r13, r13
        jz      .not_ready

        mov     rax, [rsp + 24]
        cmp     rax, CTL_MCP_ACT_START
        je      .start
        cmp     rax, CTL_MCP_ACT_STOP
        je      .stop
        cmp     rax, CTL_MCP_ACT_RESTART
        je      .restart
        cmp     rax, CTL_MCP_ACT_RESET
        je      .reset
        cmp     rax, CTL_MCP_ACT_DISCOVER
        jne     .bad_params
        mov     rdi, r13
        call    af_mcp_refresh_inventory
        jmp     .acted
.start:
        mov     rdi, r13
        mov     rsi, r15
        call    af_mcp_manual_start
        jmp     .acted
.stop:
        mov     rdi, r13
        mov     rsi, r15
        mov     rdx, 1
        call    af_mcp_stop
        jmp     .acted
.restart:
        mov     rdi, r13
        mov     rsi, r15
        call    af_mcp_manual_restart
        jmp     .acted
.reset:
        mov     rdi, r13
        call    af_mcp_reset
.acted:
        test    rax, rax
        js      .done
        mov     rdi, rbx
        call    af_ctl_conn_server
        mov     rdi, rax
        call    af_ctl_server_bump_revision_local

        cmp     qword [rsp + 24], CTL_MCP_ACT_DISCOVER
        je      .queued
        mov     rdi, r12
        mov     rsi, [rsp]
        mov     rdx, r13
        xor     ecx, ecx
        call    af_ctl_write_mcp
        AF_LEAVE_OK
.queued:
        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_server_id]
        mov     rdx, [r13 + MC_ID]
        call    af_jw_member_string
        mov     rdi, r12
        lea     rsi, [k_queued]
        mov     rdx, 1
        call    af_jw_member_bool
        mov     rdi, r12
        call    af_jw_end_object
        AF_LEAVE_OK
.bad_params:
        AF_LEAVE_ERR AF_E_CTL_PARAMS
.not_ready:
        AF_LEAVE_ERR AF_E_MCP_NOT_READY
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.done:
        AF_LEAVE

; af_ctl_mcp_tool_known(child, name, name_len) -> i64
;
; Inventory is parsed as bounded JSON and names are compared by explicit byte
; length.  A description containing the requested bytes is not a match, and a
; server-reported name with an embedded NUL cannot truncate the comparison.
af_ctl_mcp_tool_known:
        AF_ENTER 160
        test    rdi, rdi
        jz      .false_direct
        test    rsi, rsi
        jz      .false_direct
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        lea     rdi, [rbx + MC_TOOLS]
        call    af_buf_len
        mov     [rsp], rax
        test    rax, rax
        jz      .false_direct
        lea     rdi, [rbx + MC_TOOLS]
        call    af_buf_data
        mov     [rsp + 8], rax
        test    rax, rax
        jz      .false_direct

        mov     rax, [rsp]
        mov     [rsp + 64 + AF_JSONLIM_MAX_BYTES], rax
        mov     qword [rsp + 64 + AF_JSONLIM_MAX_DEPTH], 64
        mov     qword [rsp + 64 + AF_JSONLIM_MAX_STRING], AF_MCP_INVENTORY_MAX
        mov     qword [rsp + 64 + AF_JSONLIM_MAX_ELEMS], 100000
        mov     rdi, [rsp + 8]
        mov     rsi, [rsp]
        lea     rdx, [rsp + 64]
        lea     rcx, [rsp + 96]
        call    af_json_parse
        test    rax, rax
        js      .false_direct
        xor     r14d, r14d

        lea     rdi, [rsp + 96]
        call    af_json_doc_root
        mov     [rsp + 16], rax
        mov     rdi, rax
        call    af_json_type
        cmp     rax, AF_JSON_ARRAY
        jne     .free
        mov     rdi, [rsp + 16]
        call    af_json_array_count
        mov     [rsp + 24], rax
        xor     r15d, r15d
.scan:
        cmp     r15, [rsp + 24]
        jae     .free
        mov     rdi, [rsp + 16]
        mov     rsi, r15
        lea     rdx, [rsp + 32]
        call    af_json_array_at
        test    rax, rax
        js      .next
        mov     rdi, [rsp + 32]
        lea     rsi, [k_name]
        lea     rdx, [rsp + 40]
        lea     rcx, [rsp + 48]
        call    af_json_get_string
        test    rax, rax
        js      .next
        cmp     qword [rsp + 48], r13
        jne     .next
        mov     rdi, [rsp + 40]
        mov     rsi, r12
        mov     rdx, r13
        call    af_mem_eq
        test    rax, rax
        jz      .next
        mov     r14, 1
        jmp     .free
.next:
        inc     r15
        jmp     .scan
.free:
        lea     rdi, [rsp + 96]
        call    af_json_doc_free
        mov     rax, r14
        AF_LEAVE
.false_direct:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; mcp.tool_test
;
; One operator test call per child is retained.  A second request while it is
; pending is refused; after completion, the next confirmed test releases the
; previous result before allocating its slot.  This gives mcp.get a clear
; latest-result view without allowing DONE calls to exhaust the fixed table.
; ---------------------------------------------------------------------------
        global af_ctl_m_mcp_tool_test
af_ctl_m_mcp_tool_test:
        AF_ENTER 256
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        test    r13, r13
        jz      .unconfirmed

        mov     qword [rsp + 184], 0
        mov     rdi, r13
        lea     rsi, [k_confirmed]
        lea     rdx, [rsp + 184]
        call    af_json_get_bool
        test    rax, rax
        js      .unconfirmed
        cmp     qword [rsp + 184], 1
        jne     .unconfirmed

        mov     rdi, rbx
        call    af_ctl_runtime_of
        test    rax, rax
        jz      .not_found
        mov     r14, rax
        mov     r15, [r14 + RT_MCP]
        test    r15, r15
        jz      .not_ready
        mov     rdi, r14
        mov     rsi, r13
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_find_mcp
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .not_ready
        cmp     qword [rax + MC_STATE], AF_MCP_S_READY
        jne     .not_ready
        test    qword [rax + MC_FLAGS], AF_MC_F_STOPPING
        jnz     .not_ready
        test    qword [rax + MC_FLAGS], AF_MC_F_TOOLS_CURRENT
        jz      .not_ready

        mov     rdi, r13
        lea     rsi, [k_tool]
        lea     rdx, [rsp + 16]
        lea     rcx, [rsp + 24]
        call    af_json_get_string
        test    rax, rax
        js      .bad_params
        cmp     qword [rsp + 24], 0
        je      .bad_params
        mov     rdi, [rsp + 16]
        call    af_cstr_len
        cmp     rax, [rsp + 24]
        jne     .bad_params
        mov     rdi, r13
        lea     rsi, [k_arguments]
        lea     rdx, [rsp + 32]
        call    af_json_get_object
        test    rax, rax
        js      .bad_params

        mov     rdi, [rsp + 8]
        mov     rsi, [rsp + 16]
        mov     rdx, [rsp + 24]
        call    af_ctl_mcp_tool_known
        test    rax, rax
        jz      .not_found

        mov     rdi, [rsp + 8]
        call    af_ctl_find_tool_call
        test    rax, rax
        jz      .no_previous
        cmp     qword [rax + CL_STATE], AF_MCP_CALL_PENDING
        je      .not_ready
        mov     rdi, rax
        call    af_mcp_call_release
.no_previous:

        mov     rdi, [rsp + 32]
        lea     rsi, [rsp + 168]
        call    af_jsonc_dump
        test    rax, rax
        jz      .internal
        mov     [rsp + 160], rax

        lea     rdi, [rsp + 64]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        test    rax, rax
        js      .free_dump_internal
        lea     rdi, [rsp + 96]
        lea     rsi, [rsp + 64]
        call    af_jw_init
        lea     rdi, [rsp + 96]
        call    af_jw_begin_object
        lea     rdi, [rsp + 96]
        lea     rsi, [k_name]
        call    af_jw_key
        lea     rdi, [rsp + 96]
        mov     rsi, [rsp + 16]
        mov     rdx, [rsp + 24]
        call    af_jw_string_n
        lea     rdi, [rsp + 96]
        lea     rsi, [k_arguments]
        call    af_jw_key
        lea     rdi, [rsp + 96]
        mov     rsi, [rsp + 160]
        mov     rdx, [rsp + 168]
        call    af_jw_raw

        mov     rax, [rsp + 8]
        cmp     qword [rax + MC_ERA], AF_ERA_MODERN
        jne     .finish_params
        lea     rdi, [rsp + 96]
        lea     rsi, [k_meta]
        call    af_jw_key
        lea     rdi, [p_modern_meta]
        call    af_cstr_len
        mov     rdx, rax
        lea     rdi, [rsp + 96]
        lea     rsi, [p_modern_meta]
        call    af_jw_raw
.finish_params:
        lea     rdi, [rsp + 96]
        call    af_jw_end_object
        lea     rdi, [rsp + 96]
        call    af_jw_finish
        test    rax, rax
        js      .free_both_internal
        mov     byte [rsp + 176], 0
        lea     rdi, [rsp + 64]
        lea     rsi, [rsp + 176]
        mov     rdx, 1
        call    af_buf_append
        test    rax, rax
        js      .free_both_internal

        mov     qword [rsp + 56], 10000
        mov     rax, [rsp + 8]
        mov     rax, [rax + MC_CFG]
        test    rax, rax
        jz      .have_timeout
        mov     rcx, [rax + MCP_TIMEOUTS + TMO_REQUEST_MS]
        test    rcx, rcx
        jz      .have_timeout
        mov     [rsp + 56], rcx
.have_timeout:
        lea     rdi, [rsp + 64]
        call    af_buf_data
        mov     rdx, rax
        mov     rdi, [rsp + 8]
        lea     rsi, [m_tools_call]
        mov     rcx, AF_MCP_CALL_TOOL_TEST
        mov     r8, [rsp + 56]
        call    af_mcp_request
        mov     [rsp + 40], rax

        lea     rdi, [rsp + 64]
        call    af_buf_free
        mov     rdi, [rsp + 160]
        call    af_jsonc_dump_free
        cmp     qword [rsp + 40], 0
        je      .internal

        mov     rdi, rbx
        call    af_ctl_conn_server
        mov     rdi, rax
        call    af_ctl_server_bump_revision_local
        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_server_id]
        mov     rax, [rsp + 8]
        mov     rdx, [rax + MC_ID]
        call    af_jw_member_string
        mov     rdi, r12
        lea     rsi, [k_request_id]
        mov     rax, [rsp + 40]
        mov     rdx, [rax + CL_ID]
        call    af_jw_member_uint
        mov     rdi, r12
        lea     rsi, [k_queued]
        mov     rdx, 1
        call    af_jw_member_bool
        mov     rdi, r12
        call    af_jw_end_object
        AF_LEAVE_OK

.free_both_internal:
        lea     rdi, [rsp + 64]
        call    af_buf_free
.free_dump_internal:
        mov     rdi, [rsp + 160]
        call    af_jsonc_dump_free
.internal:
        AF_LEAVE_ERR AF_E_INTERNAL
.unconfirmed:
        AF_LEAVE_ERR AF_E_MCP_UNCONFIRMED
.bad_params:
        AF_LEAVE_ERR AF_E_CTL_PARAMS
.not_ready:
        AF_LEAVE_ERR AF_E_MCP_NOT_READY
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.done:
        AF_LEAVE

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
        mov     rsi, [r14 + CFG_HASH]
        call    af_ctl_write_config_hash

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
; diagnostics.export
;
; A bounded inline diagnostic bundle.  The control connection's frame ceiling
; is the export ceiling, so this method cannot create an unbounded side file or
; bypass the 0600 UDS authority boundary.  It deliberately reuses the existing
; redacted config/provider/route/MCP writers: none emit secret values, payloads,
; MCP stderr, tool arguments, or tool results.
; ---------------------------------------------------------------------------
        global af_ctl_m_diagnostics_export
af_ctl_m_diagnostics_export:
        AF_ENTER 64
        mov     rbx, rdi                ; control connection (BORROWED)
        mov     r12, rsi                ; writer (BORROWED)
        mov     rdi, rbx
        call    af_ctl_runtime_of
        mov     r13, rax                ; runtime (BORROWED, nullable)

        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_format_version]
        mov     rdx, 1
        call    af_jw_member_uint

        lea     rdi, [rsp]
        call    af_realtime_ms
        test    rax, rax
        js      .version
        mov     rdi, r12
        lea     rsi, [k_generated_at_ms]
        mov     rdx, [rsp]
        call    af_jw_member_uint

.version:
        lea     rdi, [rsp + 8]
        call    af_version_str
        ; member_string_n is intentionally spelled as key + string_n because
        ; the canonical version spans are static but not NUL-terminated.
        mov     [rsp + 32], rax
        mov     rax, [rsp + 8]
        mov     [rsp + 40], rax
        mov     rdi, r12
        lea     rsi, [k_version]
        call    af_jw_key
        mov     rdi, r12
        mov     rsi, [rsp + 32]
        mov     rdx, [rsp + 40]
        call    af_jw_string_n

        lea     rdi, [rsp + 8]
        call    af_build_target_str
        mov     [rsp + 32], rax
        mov     rax, [rsp + 8]
        mov     [rsp + 40], rax
        mov     rdi, r12
        lea     rsi, [k_target]
        call    af_jw_key
        mov     rdi, r12
        mov     rsi, [rsp + 32]
        mov     rdx, [rsp + 40]
        call    af_jw_string_n

        lea     rdi, [rsp + 8]
        call    af_build_mode_str
        mov     [rsp + 32], rax
        mov     rax, [rsp + 8]
        mov     [rsp + 40], rax
        mov     rdi, r12
        lea     rsi, [k_build]
        call    af_jw_key
        mov     rdi, r12
        mov     rsi, [rsp + 32]
        mov     rdx, [rsp + 40]
        call    af_jw_string_n

        mov     rdi, r12
        lea     rsi, [k_protocol_ver]
        mov     rdx, AF_CTL_PROTOCOL_VERSION
        call    af_jw_member_uint

        test    r13, r13
        jz      .no_runtime_fields
        mov     r14, [r13 + RT_CONFIG]
        test    r14, r14
        jz      .no_config_fields
        mov     rdi, r12
        mov     rsi, [r14 + CFG_HASH]
        call    af_ctl_write_config_hash
        mov     rdi, r12
        lea     rsi, [k_schema_version]
        mov     rdx, [r14 + CFG_SCHEMA_VERSION]
        call    af_jw_member_uint
.no_config_fields:
        mov     rdi, r12
        lea     rsi, [k_ready]
        mov     rdx, [r13 + RT_READY]
        call    af_jw_member_bool
        mov     rdi, r12
        lea     rsi, [k_shutting_down]
        mov     rdx, [r13 + RT_SHUTTING_DOWN]
        call    af_jw_member_bool

        mov     rdi, r12
        lea     rsi, [k_last_error]
        call    af_jw_key
        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_status]
        mov     rdx, [r13 + RT_LAST_ERROR]
        call    af_jw_member_int
        mov     rdi, r12
        lea     rsi, [k_at_ms]
        mov     rdx, [r13 + RT_LAST_ERROR_AT_MS]
        call    af_jw_member_uint
        mov     rdi, r12
        call    af_jw_end_object
.no_runtime_fields:

        mov     rdi, r12
        lea     rsi, [k_dependencies]
        call    af_jw_key
        mov     rdi, r12
        call    af_jw_begin_object
        call    af_curl_version wrt ..plt
        mov     rdx, rax
        mov     rdi, r12
        lea     rsi, [k_curl]
        call    af_jw_member_string
        call    af_sqlitec_libversion wrt ..plt
        mov     rdx, rax
        mov     rdi, r12
        lea     rsi, [k_sqlite]
        call    af_jw_member_string
        call    jansson_version_str wrt ..plt
        mov     rdx, rax
        mov     rdi, r12
        lea     rsi, [k_jansson]
        call    af_jw_member_string
        mov     rdi, r12
        call    af_jw_end_object

        ; A redacted config view plus live metadata.  These handlers ignore a
        ; NULL params pointer and append one complete JSON value each.
        mov     rdi, r12
        lea     rsi, [k_config_current]
        call    af_jw_key
        mov     rdi, rbx
        mov     rsi, r12
        xor     edx, edx
        call    af_ctl_m_config_current
        mov     rdi, r12
        lea     rsi, [k_providers]
        call    af_jw_key
        mov     rdi, rbx
        mov     rsi, r12
        xor     edx, edx
        call    af_ctl_m_providers_list
        mov     rdi, r12
        lea     rsi, [k_routes]
        call    af_jw_key
        mov     rdi, rbx
        mov     rsi, r12
        xor     edx, edx
        call    af_ctl_m_routes_list
        mov     rdi, r12
        lea     rsi, [k_mcp_servers]
        call    af_jw_key
        mov     rdi, rbx
        mov     rsi, r12
        xor     edx, edx
        call    af_ctl_m_mcp_list

        mov     rdi, r12
        lea     rsi, [k_redacted]
        mov     rdx, 1
        call    af_jw_member_bool
        mov     rdi, r12
        lea     rsi, [k_payloads_included]
        xor     edx, edx
        call    af_jw_member_bool
        mov     rdi, r12
        lea     rsi, [k_secrets_included]
        xor     edx, edx
        call    af_jw_member_bool
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
        mov     rcx, [r14 + RT_ROUTING]
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
