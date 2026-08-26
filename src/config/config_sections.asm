; AsmFlow — per-section configuration parsing.
;
; One function per schema object. Each one follows the same shape:
;
;   1. sweep for unknown keys (`additionalProperties: false`)
;   2. read every required field through the typed accessors, which apply the
;      range and enum rules and aim the JSON Pointer at any failure
;   3. apply the cross-field rules that no single field can express
;
; Nothing here writes into the snapshot until the whole section has validated,
; so a rejection cannot leave a half-populated record behind.

        bits 64
        default rel

%include "asmflow.inc"
%include "json.inc"
%include "config.inc"

        extern af_arena_alloc
        extern af_arena_calloc
        extern af_mem_zero
        extern af_cstr_len
        extern af_mem_eq

        extern af_json_type
        extern af_json_member
        extern af_json_array_at
        extern af_json_array_count
        extern af_json_string_of
        extern af_json_iter_begin
        extern af_json_iter_key
        extern af_json_iter_value
        extern af_json_iter_next

        extern af_cfg_check_keys
        extern af_cfg_err_fail
        extern af_cfg_err_push_key
        extern af_cfg_err_push_index
        extern af_cfg_err_truncate
        extern af_cfg_err_depth

        extern af_cfg_req_str
        extern af_cfg_req_int
        extern af_cfg_req_bool
        extern af_cfg_opt_bool
        extern af_cfg_req_enum
        extern af_cfg_req_obj
        extern af_cfg_req_arr
        extern af_cfg_opt_present
        extern af_cfg_fail_here

        extern af_cfg_intern
        extern af_cfg_id_valid
        extern af_cfg_env_name_valid
        extern af_cfg_model_alias_valid
        extern af_cfg_header_name_valid
        extern af_cfg_enum_lookup
        extern af_cfg_is_loopback_host
        extern af_cfg_url_check
        extern af_cfg_expand_path

        ; vocabulary
        extern k_schema_version, k_listener, k_control, k_storage, k_logging
        extern k_limits, k_providers, k_routes, k_mcp_servers
        extern k_type, k_header, k_value, k_source, k_name, k_env
        extern k_host, k_port, k_auth, k_request_header_max_bytes
        extern k_request_body_max_bytes, k_idle_timeout_ms, k_expose_unavailable
        extern k_socket_path, k_mode, k_frame_max_bytes
        extern k_database_path, k_journal_mode, k_busy_timeout_ms
        extern k_retention_days, k_store_payloads
        extern k_level, k_format, k_destination, k_file_path
        extern k_include_req_meta, k_include_payloads, k_redact_headers
        extern k_max_active_requests, k_max_queued_requests, k_json_max_depth
        extern k_json_string_max, k_sse_event_max, k_mcp_frame_max
        extern k_stderr_line_max
        extern k_id, k_display_name, k_adapter, k_base_url, k_enabled
        extern k_required, k_max_concurrency, k_timeouts, k_capabilities
        extern k_health, k_allow_insecure
        extern k_connect_ms, k_request_ms, k_idle_stream_ms
        extern k_responses, k_chat_completions, k_streaming, k_tools
        extern k_vision, k_json_schema
        extern k_path, k_interval_ms, k_failure_threshold
        extern k_success_threshold, k_open_cooldown_ms
        extern k_model_alias, k_endpoint_families, k_policy, k_fallback
        extern k_targets, k_max_attempts, k_retryable, k_provider_id
        extern k_upstream_model, k_priority, k_weight
        extern k_transport, k_command, k_args, k_cwd, k_env_allow
        extern k_protocol, k_restart, k_startup_timeout_ms, k_shutdown_grace_ms
        extern k_url, k_preferred, k_legacy
        extern k_window_ms, k_backoff_ms, k_max_backoff_ms, k_max_restarts

        extern tbl_auth_type, tbl_adapter, tbl_journal, tbl_log_level
        extern tbl_log_format, tbl_log_dest, tbl_policy, tbl_endpoint_family
        extern tbl_retryable, tbl_transport, tbl_restart, tbl_mcp_preferred
        extern tbl_mcp_legacy, tbl_control_mode, tbl_secret_source

        extern keys_listener, keys_control, keys_storage, keys_logging
        extern keys_limits, keys_provider, keys_timeouts, keys_capabilities
        extern keys_health, keys_route, keys_fallback, keys_route_target
        extern keys_mcp_stdio, keys_mcp_http, keys_protocol, keys_restart
        extern keys_secret_ref, keys_auth_none, keys_auth_bearer
        extern keys_auth_header

        extern af_cfg_find_duplicate

        extern m_bad_id, m_bad_alias, m_bad_env, m_bad_header, m_bad_url
        extern m_bad_path, m_auth_required, m_file_path, m_backoff
        extern m_cmd_absolute, m_health_path, m_transport_field
        extern m_bad_enum_value, m_dup_entry

        section .text

; ---------------------------------------------------------------------------
; af_cfg_load_secret_ref(json_t *obj, af_arena *arena, af_cfg_error *err,
;                        char **out_env_name) -> af_status
;
; Parses {"source": "env", "name": "VAR"}. `source` is an enum with exactly one
; member, which is the point: a future file source would be a schema change and
; a decision, not something the runtime accepts because it happened to parse.
; ---------------------------------------------------------------------------
        global af_cfg_load_secret_ref
af_cfg_load_secret_ref:
        AF_ENTER 48
        mov     rbx, rdi                ; object
        mov     r12, rsi                ; arena
        mov     r13, rdx                ; error
        mov     r14, rcx                ; out

        mov     rdi, rbx
        lea     rsi, [keys_secret_ref]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_source]
        lea     rdx, [tbl_secret_source]
        mov     rcx, r13
        lea     r8, [rsp + 32]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_name]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done

        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_env_name_valid
        test    rax, rax
        jz      .bad_env

        mov     rdi, r12
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        mov     rcx, r14
        call    af_cfg_intern
.done:
        AF_LEAVE
.bad_env:
        mov     rdi, r13
        lea     rsi, [k_name]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_env]
        call    af_cfg_fail_here
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_auth(json_t *obj, af_arena *arena, af_cfg_error *err,
;                  void *auth_out) -> af_status
;
; The three shapes are a schema `oneOf`, so the permitted key set depends on
; `type`. Reading `type` first and then sweeping against that variant's list is
; what makes `{"type":"none","env":"X"}` a rejection instead of a silently
; ignored field.
; ---------------------------------------------------------------------------
        global af_cfg_load_auth
af_cfg_load_auth:
        AF_ENTER 48
        mov     rbx, rdi                ; object
        mov     r12, rsi                ; arena
        mov     r13, rdx                ; error
        mov     r14, rcx                ; auth out

        mov     qword [r14 + AUTH_TYPE], AF_AUTH_NONE
        mov     qword [r14 + AUTH_HEADER], 0
        mov     qword [r14 + AUTH_ENV], 0

        mov     rdi, rbx
        lea     rsi, [k_type]
        lea     rdx, [tbl_auth_type]
        mov     rcx, r13
        lea     r8, [rsp + 32]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done
        mov     r15, [rsp + 32]
        mov     [r14 + AUTH_TYPE], r15

        cmp     r15, AF_AUTH_NONE
        je      .none
        cmp     r15, AF_AUTH_BEARER_ENV
        je      .bearer
        jmp     .header

.none:
        mov     rdi, rbx
        lea     rsi, [keys_auth_none]
        mov     rdx, r13
        call    af_cfg_check_keys
        AF_LEAVE

.bearer:
        mov     rdi, rbx
        lea     rsi, [keys_auth_bearer]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [k_env]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_env_name_valid
        test    rax, rax
        jz      .bad_env
        mov     rdi, r12
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r14 + AUTH_ENV]
        call    af_cfg_intern
        AF_LEAVE

.header:
        mov     rdi, rbx
        lea     rsi, [keys_auth_header]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_header]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_header_name_valid
        test    rax, rax
        jz      .bad_header
        mov     rdi, r12
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r14 + AUTH_HEADER]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 16], rax
        mov     rdi, rbx
        lea     rsi, [k_value]
        mov     rdx, r13
        lea     rcx, [rsp + 24]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 24]
        mov     rsi, r12
        mov     rdx, r13
        lea     rcx, [r14 + AUTH_ENV]
        call    af_cfg_load_secret_ref
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 16]
        call    af_cfg_err_truncate
        AF_LEAVE_OK

.bad_env:
        mov     rdi, r13
        lea     rsi, [k_env]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_env]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_header:
        mov     rdi, r13
        lea     rsi, [k_header]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_header]
        call    af_cfg_fail_here
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_timeouts(json_t *obj, af_cfg_error *err, void *out) -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_load_timeouts
af_cfg_load_timeouts:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi                ; error
        mov     r13, rdx                ; out

        mov     rdi, rbx
        lea     rsi, [keys_timeouts]
        mov     rdx, r12
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_connect_ms]
        mov     rdx, 100
        mov     rcx, 600000
        mov     r8, r12
        lea     r9, [r13 + TMO_CONNECT_MS]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_request_ms]
        mov     rdx, 1000
        mov     rcx, 86400000
        mov     r8, r12
        lea     r9, [r13 + TMO_REQUEST_MS]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_idle_stream_ms]
        mov     rdx, 1000
        mov     rcx, 3600000
        mov     r8, r12
        lea     r9, [r13 + TMO_IDLE_MS]
        call    af_cfg_req_int
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_capabilities(json_t *obj, af_cfg_error *err, u64 *out_bits)
;   -> af_status
;
; Six required booleans collapsed into a bitmask, because routing tests
; capability sets rather than individual flags.
; ---------------------------------------------------------------------------
        global af_cfg_load_capabilities
af_cfg_load_capabilities:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        xor     r14, r14                ; accumulated bits

        mov     rdi, rbx
        lea     rsi, [keys_capabilities]
        mov     rdx, r12
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_responses]
        mov     rdx, r12
        mov     rcx, AF_CAP_RESPONSES
        lea     r8, [rsp]
        call    af_cfg_capability_bit
        test    rax, rax
        js      .done
        or      r14, [rsp]

        mov     rdi, rbx
        lea     rsi, [k_chat_completions]
        mov     rdx, r12
        mov     rcx, AF_CAP_CHAT_COMPLETIONS
        lea     r8, [rsp]
        call    af_cfg_capability_bit
        test    rax, rax
        js      .done
        or      r14, [rsp]

        mov     rdi, rbx
        lea     rsi, [k_streaming]
        mov     rdx, r12
        mov     rcx, AF_CAP_STREAMING
        lea     r8, [rsp]
        call    af_cfg_capability_bit
        test    rax, rax
        js      .done
        or      r14, [rsp]

        mov     rdi, rbx
        lea     rsi, [k_tools]
        mov     rdx, r12
        mov     rcx, AF_CAP_TOOLS
        lea     r8, [rsp]
        call    af_cfg_capability_bit
        test    rax, rax
        js      .done
        or      r14, [rsp]

        mov     rdi, rbx
        lea     rsi, [k_vision]
        mov     rdx, r12
        mov     rcx, AF_CAP_VISION
        lea     r8, [rsp]
        call    af_cfg_capability_bit
        test    rax, rax
        js      .done
        or      r14, [rsp]

        mov     rdi, rbx
        lea     rsi, [k_json_schema]
        mov     rdx, r12
        mov     rcx, AF_CAP_JSON_SCHEMA
        lea     r8, [rsp]
        call    af_cfg_capability_bit
        test    rax, rax
        js      .done
        or      r14, [rsp]

        mov     [r13], r14
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_capability_bit(json_t *obj, const char *key, af_cfg_error *err,
;                       u64 bit, u64 *out) -> af_status
;
; Reads one required boolean and writes `bit` or 0. A real function with its own
; frame rather than a local `call` target: a local one would run with rsp eight
; bytes lower than the enclosing frame expects, so every `[rsp + n]` inside it
; would name the wrong slot — including, in the version this replaces, the
; return address.
; ---------------------------------------------------------------------------
        global af_cfg_capability_bit
af_cfg_capability_bit:
        AF_ENTER 16
        mov     r12, rcx                ; bit
        mov     r13, r8                 ; out
        mov     qword [r13], 0
        lea     rcx, [rsp]
        call    af_cfg_req_bool
        test    rax, rax
        js      .done
        cmp     qword [rsp], 0
        je      .done
        mov     [r13], r12
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_health(json_t *obj, af_arena *arena, af_cfg_error *err, void *out)
;   -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_load_health
af_cfg_load_health:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi                ; arena
        mov     r13, rdx                ; error
        mov     r14, rcx                ; out

        mov     rdi, rbx
        lea     rsi, [keys_health]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_path]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .bad_path
        cmp     rax, 512
        ja      .bad_path
        mov     rcx, [rsp]
        cmp     byte [rcx], '/'
        jne     .bad_path
        mov     rdi, r12
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r14 + HLT_PATH]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_interval_ms]
        mov     rdx, 1000
        mov     rcx, 3600000
        mov     r8, r13
        lea     r9, [r14 + HLT_INTERVAL_MS]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_failure_threshold]
        mov     rdx, 1
        mov     rcx, 100
        mov     r8, r13
        lea     r9, [r14 + HLT_FAIL_THR]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_success_threshold]
        mov     rdx, 1
        mov     rcx, 100
        mov     r8, r13
        lea     r9, [r14 + HLT_SUCC_THR]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_open_cooldown_ms]
        mov     rdx, 1000
        mov     rcx, 3600000
        mov     r8, r13
        lea     r9, [r14 + HLT_COOLDOWN_MS]
        call    af_cfg_req_int
.done:
        AF_LEAVE
.bad_path:
        mov     rdi, r13
        lea     rsi, [k_path]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_health_path]
        call    af_cfg_fail_here
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_listener(json_t *root, af_config *cfg, af_cfg_error *err)
;   -> af_status
;
; The one cross-field rule that matters here: a non-loopback host with
; `auth.type == "none"` is refused at load time, not at bind time
; (SECURITY_MODEL.md 5, M5 DoD 8). Discovering it at bind time would mean the
; listener had already been created.
; ---------------------------------------------------------------------------
        global af_cfg_load_listener
af_cfg_load_listener:
        AF_ENTER 64
        mov     rbx, rdi                ; root
        mov     r12, rsi                ; config
        mov     r13, rdx                ; error

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 32], rax
        mov     rdi, rbx
        lea     rsi, [k_listener]
        mov     rdx, r13
        lea     rcx, [rsp + 40]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     r14, [rsp + 40]         ; listener object

        mov     rdi, r14
        lea     rsi, [keys_listener]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_host]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .bad_host
        cmp     rax, 255
        ja      .bad_host
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r12 + CFG_LST_HOST]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_is_loopback_host
        mov     [r12 + CFG_LST_IS_LOOPBACK], rax

        mov     rdi, r14
        lea     rsi, [k_port]
        mov     rdx, 1
        mov     rcx, 65535
        mov     r8, r13
        lea     r9, [r12 + CFG_LST_PORT]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_request_header_max_bytes]
        mov     rdx, 4096
        mov     rcx, 1048576
        mov     r8, r13
        lea     r9, [r12 + CFG_LST_HDR_MAX]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_request_body_max_bytes]
        mov     rdx, 1024
        mov     rcx, 67108864
        mov     r8, r13
        lea     r9, [r12 + CFG_LST_BODY_MAX]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_idle_timeout_ms]
        mov     rdx, 1000
        mov     rcx, 3600000
        mov     r8, r13
        lea     r9, [r12 + CFG_LST_IDLE_MS]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_expose_unavailable]
        mov     rdx, r13
        lea     rcx, [r12 + CFG_LST_EXPOSE_UNAVAIL]
        xor     r8d, r8d                ; schema default: false
        call    af_cfg_opt_bool
        test    rax, rax
        js      .done

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 16], rax
        mov     rdi, r14
        lea     rsi, [k_auth]
        mov     rdx, r13
        lea     rcx, [rsp + 24]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 24]
        lea     rsi, [r12 + CFG_ARENA]
        mov     rdx, r13
        lea     rcx, [r12 + CFG_LST_AUTH]
        call    af_cfg_load_auth
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 16]
        call    af_cfg_err_truncate

        ; Cross-field rule: exposure requires authentication.
        cmp     qword [r12 + CFG_LST_IS_LOOPBACK], 0
        jne     .accept
        cmp     qword [r12 + CFG_LST_AUTH + AUTH_TYPE], AF_AUTH_NONE
        je      .needs_auth
.accept:
        mov     rdi, r13
        mov     rsi, [rsp + 32]
        call    af_cfg_err_truncate
        AF_LEAVE_OK

.needs_auth:
        mov     rdi, r13
        lea     rsi, [k_auth]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_auth_required]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_host:
        mov     rdi, r13
        lea     rsi, [k_host]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_enum_value]
        call    af_cfg_fail_here
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_control(json_t *root, af_config *cfg, af_cfg_error *err)
;   -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_load_control
af_cfg_load_control:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 32], rax
        mov     rdi, rbx
        lea     rsi, [k_control]
        mov     rdx, r13
        lea     rcx, [rsp + 40]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     r14, [rsp + 40]

        mov     rdi, r14
        lea     rsi, [keys_control]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_socket_path]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r12 + CFG_CTL_SOCKET_PATH]
        call    af_cfg_expand_path
        test    rax, rax
        js      .bad_path

        mov     rdi, r14
        lea     rsi, [k_mode]
        lea     rdx, [tbl_control_mode]
        mov     rcx, r13
        lea     r8, [r12 + CFG_CTL_MODE]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_frame_max_bytes]
        mov     rdx, 4096
        mov     rcx, AF_MAX_CONTROL_FRAME
        mov     r8, r13
        lea     r9, [r12 + CFG_CTL_FRAME_MAX]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r13
        mov     rsi, [rsp + 32]
        call    af_cfg_err_truncate
        AF_LEAVE_OK
.bad_path:
        mov     rdi, r13
        lea     rsi, [k_socket_path]
        mov     rdx, AF_E_CFG_PATH
        lea     rcx, [m_bad_path]
        call    af_cfg_fail_here
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_storage(json_t *root, af_config *cfg, af_cfg_error *err)
;   -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_load_storage
af_cfg_load_storage:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 32], rax
        mov     rdi, rbx
        lea     rsi, [k_storage]
        mov     rdx, r13
        lea     rcx, [rsp + 40]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     r14, [rsp + 40]

        mov     rdi, r14
        lea     rsi, [keys_storage]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_database_path]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r12 + CFG_STO_DB_PATH]
        call    af_cfg_expand_path
        test    rax, rax
        js      .bad_path

        mov     rdi, r14
        lea     rsi, [k_journal_mode]
        lea     rdx, [tbl_journal]
        mov     rcx, r13
        lea     r8, [r12 + CFG_STO_JOURNAL_MODE]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_busy_timeout_ms]
        xor     edx, edx
        mov     rcx, 60000
        mov     r8, r13
        lea     r9, [r12 + CFG_STO_BUSY_MS]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_retention_days]
        xor     edx, edx
        mov     rcx, 3650
        mov     r8, r13
        lea     r9, [r12 + CFG_STO_RETENTION_DAYS]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_store_payloads]
        mov     rdx, r13
        lea     rcx, [r12 + CFG_STO_STORE_PAYLOADS]
        call    af_cfg_req_bool
        test    rax, rax
        js      .done

        mov     rdi, r13
        mov     rsi, [rsp + 32]
        call    af_cfg_err_truncate
        AF_LEAVE_OK
.bad_path:
        mov     rdi, r13
        lea     rsi, [k_database_path]
        mov     rdx, AF_E_CFG_PATH
        lea     rcx, [m_bad_path]
        call    af_cfg_fail_here
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_logging(json_t *root, af_config *cfg, af_cfg_error *err)
;   -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_load_logging
af_cfg_load_logging:
        AF_ENTER 96
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 32], rax
        mov     rdi, rbx
        lea     rsi, [k_logging]
        mov     rdx, r13
        lea     rcx, [rsp + 40]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     r14, [rsp + 40]

        mov     rdi, r14
        lea     rsi, [keys_logging]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_level]
        lea     rdx, [tbl_log_level]
        mov     rcx, r13
        lea     r8, [r12 + CFG_LOG_LEVEL]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_format]
        lea     rdx, [tbl_log_format]
        mov     rcx, r13
        lea     r8, [r12 + CFG_LOG_FORMAT]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_destination]
        lea     rdx, [tbl_log_dest]
        mov     rcx, r13
        lea     r8, [r12 + CFG_LOG_DESTINATION]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_include_req_meta]
        mov     rdx, r13
        lea     rcx, [r12 + CFG_LOG_INC_REQ_META]
        call    af_cfg_req_bool
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_include_payloads]
        mov     rdx, r13
        lea     rcx, [r12 + CFG_LOG_INC_PAYLOADS]
        call    af_cfg_req_bool
        test    rax, rax
        js      .done

        ; The schema's conditional: destination "file" requires file_path.
        cmp     qword [r12 + CFG_LOG_DESTINATION], AF_LOG_DEST_FILE
        jne     .no_file_path
        mov     rdi, r14
        lea     rsi, [k_file_path]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        cmp     rax, AF_E_CFG_MISSING_KEY
        je      .file_path_required
        test    rax, rax
        js      .done
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r12 + CFG_LOG_FILE_PATH]
        call    af_cfg_expand_path
        test    rax, rax
        js      .bad_path
.no_file_path:

        ; redact_headers: an array of header names, interned as a NULL-free
        ; vector so the redaction registry can walk it without re-parsing.
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 48], rax
        mov     rdi, r14
        lea     rsi, [k_redact_headers]
        xor     edx, edx                ; minItems 0
        mov     rcx, 128
        mov     r8, r13
        lea     r9, [rsp + 56]          ; {array, count}
        call    af_cfg_req_arr
        test    rax, rax
        js      .done

        mov     rax, [rsp + 64]
        mov     [r12 + CFG_LOG_REDACT_COUNT], rax
        test    rax, rax
        jz      .redact_done
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, rax
        mov     rdx, 8
        call    af_arena_calloc
        test    rax, rax
        jz      .nomem
        mov     [r12 + CFG_LOG_REDACT], rax
        mov     r15, rax                ; char**

        xor     rax, rax
        mov     [rsp + 72], rax         ; index
.redact_loop:
        mov     rax, [rsp + 72]
        cmp     rax, [r12 + CFG_LOG_REDACT_COUNT]
        jae     .redact_done
        mov     rdi, r13
        mov     rsi, rax
        call    af_cfg_err_push_index
        mov     rdi, [rsp + 56]
        mov     rsi, [rsp + 72]
        lea     rdx, [rsp + 80]
        call    af_json_array_at
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 80]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_json_string_of
        test    rax, rax
        js      .bad_header_type
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_header_name_valid
        test    rax, rax
        jz      .bad_header_value
        mov     rax, [rsp + 72]
        lea     rcx, [r15 + rax * 8]
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        ; `uniqueItems: true`. A repeated header would be redacted twice, which
        ; is harmless, but accepting it means the runtime and the schema
        ; disagree about what a valid document is.
        mov     rax, [rsp + 72]
        mov     rdi, r15
        mov     rsi, rax
        mov     rdx, 8
        xor     ecx, ecx
        mov     r8, [r15 + rax * 8]
        call    af_cfg_find_duplicate
        test    rax, rax
        jnz     .duplicate_header

        mov     rdi, r13
        mov     rsi, [rsp + 48]
        call    af_cfg_err_truncate
        inc     qword [rsp + 72]
        jmp     .redact_loop

.redact_done:
        mov     rdi, r13
        mov     rsi, [rsp + 32]
        call    af_cfg_err_truncate
        AF_LEAVE_OK

.file_path_required:
        mov     rdi, r13
        lea     rsi, [k_file_path]
        mov     rdx, AF_E_CFG_MISSING_KEY
        lea     rcx, [m_file_path]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_path:
        mov     rdi, r13
        lea     rsi, [k_file_path]
        mov     rdx, AF_E_CFG_PATH
        lea     rcx, [m_bad_path]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_header_type:
        mov     rdi, r13
        xor     esi, esi
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_header]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_header_value:
        mov     rdi, r13
        xor     esi, esi
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_header]
        call    af_cfg_fail_here
        AF_LEAVE
.duplicate_header:
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
; af_cfg_load_limits(json_t *root, af_config *cfg, af_cfg_error *err)
;   -> af_status
;
; docs/CONFIGURATION.md 8: "No limit may be zero to mean unlimited." The schema
; minimums enforce that, and the ceilings here are the hard maxima from
; include/asmflow.inc that no configuration may raise.
; ---------------------------------------------------------------------------
        global af_cfg_load_limits
af_cfg_load_limits:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 32], rax
        mov     rdi, rbx
        lea     rsi, [k_limits]
        mov     rdx, r13
        lea     rcx, [rsp + 40]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     r14, [rsp + 40]

        mov     rdi, r14
        lea     rsi, [keys_limits]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_max_active_requests]
        mov     rdx, 1
        mov     rcx, 65535
        mov     r8, r13
        lea     r9, [r12 + CFG_LIM_MAX_ACTIVE]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_max_queued_requests]
        xor     edx, edx
        mov     rcx, 65535
        mov     r8, r13
        lea     r9, [r12 + CFG_LIM_MAX_QUEUED]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_json_max_depth]
        mov     rdx, 4
        mov     rcx, AF_MAX_JSON_DEPTH
        mov     r8, r13
        lea     r9, [r12 + CFG_LIM_JSON_DEPTH]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_json_string_max]
        mov     rdx, 1024
        mov     rcx, 67108864
        mov     r8, r13
        lea     r9, [r12 + CFG_LIM_JSON_STR_MAX]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_sse_event_max]
        mov     rdx, 1024
        mov     rcx, 16777216
        mov     r8, r13
        lea     r9, [r12 + CFG_LIM_SSE_EVENT_MAX]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_mcp_frame_max]
        mov     rdx, 1024
        mov     rcx, 67108864
        mov     r8, r13
        lea     r9, [r12 + CFG_LIM_MCP_FRAME_MAX]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_stderr_line_max]
        mov     rdx, 256
        mov     rcx, 1048576
        mov     r8, r13
        lea     r9, [r12 + CFG_LIM_STDERR_LINE_MAX]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r13
        mov     rsi, [rsp + 32]
        call    af_cfg_err_truncate
        AF_LEAVE_OK
.done:
        AF_LEAVE
