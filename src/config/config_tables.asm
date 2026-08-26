; AsmFlow — configuration vocabulary.
;
; Every key name, enum spelling, allowed-key list, and rejection message that
; the validator uses lives here, in one file, exported. Two reasons:
;
;   * the schema in config/asmflow.schema.json and this file are the two halves
;     of the same contract, and having the runtime half in one place makes the
;     diff against the schema a mechanical read rather than a hunt;
;   * the allowed-key lists implement `additionalProperties: false`, so the set
;     of keys the runtime accepts is literally the set written here.
;
; Pointer tables live in .data.rel.ro: a table of addresses in a
; position-independent executable needs a load-time relocation, and RELRO makes
; the pages read-only again before the daemon serves anything.

        bits 64
        default rel

%include "asmflow.inc"
%include "config.inc"

; AF_KEY name, "text" — an exported NUL-terminated constant.
%macro AF_KEY 2
        global %1
%1:     db %2, 0
%endmacro

; AF_TABLE name — an exported pointer table.
%macro AF_TABLE 1
        align 8
        global %1
%1:
%endmacro

        section .rodata

; --- top level -------------------------------------------------------------
AF_KEY k_schema_version, "schema_version"
AF_KEY k_listener,       "listener"
AF_KEY k_control,        "control"
AF_KEY k_storage,        "storage"
AF_KEY k_logging,        "logging"
AF_KEY k_limits,         "limits"
AF_KEY k_providers,      "providers"
AF_KEY k_routes,         "routes"
AF_KEY k_mcp_servers,    "mcp_servers"

; --- listener --------------------------------------------------------------
AF_KEY k_host,                     "host"
AF_KEY k_port,                     "port"
AF_KEY k_auth,                     "auth"
AF_KEY k_request_header_max_bytes, "request_header_max_bytes"
AF_KEY k_request_body_max_bytes,   "request_body_max_bytes"
AF_KEY k_idle_timeout_ms,          "idle_timeout_ms"
AF_KEY k_expose_unavailable,       "expose_unavailable_models"

; --- control ---------------------------------------------------------------
AF_KEY k_socket_path,     "socket_path"
AF_KEY k_mode,            "mode"
AF_KEY k_frame_max_bytes, "frame_max_bytes"

; --- storage ---------------------------------------------------------------
AF_KEY k_database_path,   "database_path"
AF_KEY k_journal_mode,    "journal_mode"
AF_KEY k_busy_timeout_ms, "busy_timeout_ms"
AF_KEY k_retention_days,  "request_metadata_retention_days"
AF_KEY k_store_payloads,  "store_payloads"

; --- logging ---------------------------------------------------------------
AF_KEY k_level,            "level"
AF_KEY k_format,           "format"
AF_KEY k_destination,      "destination"
AF_KEY k_file_path,        "file_path"
AF_KEY k_include_req_meta, "include_request_metadata"
AF_KEY k_include_payloads, "include_payloads"
AF_KEY k_redact_headers,   "redact_headers"

; --- limits ----------------------------------------------------------------
AF_KEY k_max_active_requests, "max_active_requests"
AF_KEY k_max_queued_requests, "max_queued_requests"
AF_KEY k_json_max_depth,      "json_max_depth"
AF_KEY k_json_string_max,     "json_string_max_bytes"
AF_KEY k_sse_event_max,       "sse_event_max_bytes"
AF_KEY k_mcp_frame_max,       "mcp_frame_max_bytes"
AF_KEY k_stderr_line_max,     "stderr_line_max_bytes"

; --- provider --------------------------------------------------------------
AF_KEY k_id,              "id"
AF_KEY k_display_name,    "display_name"
AF_KEY k_adapter,         "adapter"
AF_KEY k_base_url,        "base_url"
AF_KEY k_enabled,         "enabled"
AF_KEY k_required,        "required"
AF_KEY k_max_concurrency, "max_concurrency"
AF_KEY k_timeouts,        "timeouts"
AF_KEY k_capabilities,    "capabilities"
AF_KEY k_health,          "health"
AF_KEY k_allow_insecure,  "allow_insecure_private_http"

AF_KEY k_connect_ms,     "connect_ms"
AF_KEY k_request_ms,     "request_ms"
AF_KEY k_idle_stream_ms, "idle_stream_ms"

AF_KEY k_responses,        "responses"
AF_KEY k_chat_completions, "chat_completions"
AF_KEY k_streaming,        "streaming"
AF_KEY k_tools,            "tools"
AF_KEY k_vision,           "vision"
AF_KEY k_json_schema,      "json_schema"

AF_KEY k_path,              "path"
AF_KEY k_interval_ms,       "interval_ms"
AF_KEY k_failure_threshold, "failure_threshold"
AF_KEY k_success_threshold, "success_threshold"
AF_KEY k_open_cooldown_ms,  "open_cooldown_ms"

; --- route -----------------------------------------------------------------
AF_KEY k_model_alias,       "model_alias"
AF_KEY k_endpoint_families, "endpoint_families"
AF_KEY k_policy,            "policy"
AF_KEY k_fallback,          "fallback"
AF_KEY k_targets,           "targets"
AF_KEY k_max_attempts,      "max_attempts"
AF_KEY k_retryable,         "retryable"
AF_KEY k_provider_id,       "provider_id"
AF_KEY k_upstream_model,    "upstream_model"
AF_KEY k_priority,          "priority"
AF_KEY k_weight,            "weight"

; --- MCP -------------------------------------------------------------------
AF_KEY k_transport,          "transport"
AF_KEY k_command,            "command"
AF_KEY k_args,               "args"
AF_KEY k_cwd,                "cwd"
AF_KEY k_env_allow,          "env_allow"
AF_KEY k_env,                "env"
AF_KEY k_protocol,           "protocol"
AF_KEY k_restart,            "restart"
AF_KEY k_startup_timeout_ms, "startup_timeout_ms"
AF_KEY k_shutdown_grace_ms,  "shutdown_grace_ms"
AF_KEY k_url,                "url"
AF_KEY k_preferred,          "preferred"
AF_KEY k_legacy,             "legacy"
AF_KEY k_window_ms,          "window_ms"
AF_KEY k_backoff_ms,         "backoff_ms"
AF_KEY k_max_backoff_ms,     "max_backoff_ms"
AF_KEY k_max_restarts,       "max_restarts"

; --- auth and secret references --------------------------------------------
AF_KEY k_type,   "type"
AF_KEY k_header, "header"
AF_KEY k_value,  "value"
AF_KEY k_source, "source"
AF_KEY k_name,   "name"

; --- enum spellings --------------------------------------------------------
e_auth_none:   db "none", 0
e_auth_bearer: db "bearer_env", 0
e_auth_header: db "header_env", 0

e_adapter_resp: db "openai_responses", 0
e_adapter_chat: db "openai_chat", 0
e_adapter_dual: db "openai_dual", 0

e_wal: db "wal", 0

e_trace: db "trace", 0
e_debug: db "debug", 0
e_info:  db "info", 0
e_warn:  db "warn", 0
e_error: db "error", 0
e_fatal: db "fatal", 0

e_jsonl: db "jsonl", 0
e_text:  db "text", 0

e_stderr: db "stderr", 0
e_file:   db "file", 0

e_priority:      db "priority", 0
e_round_robin:   db "round_robin", 0
e_least_latency: db "least_latency", 0

e_retry_connect_failed:  db "connect_failed", 0
e_retry_dns_failed:      db "dns_failed", 0
e_retry_connect_timeout: db "connect_timeout", 0
e_retry_502:             db "http_502", 0
e_retry_503:             db "http_503", 0
e_retry_504:             db "http_504", 0

e_stdio: db "stdio", 0
e_shttp: db "streamable_http", 0

e_never:      db "never", 0
e_on_failure: db "on_failure", 0
e_always:     db "always", 0

e_modern_version: db AF_MCP_MODERN_VERSION, 0
e_legacy_version: db AF_MCP_LEGACY_VERSION, 0

e_mode_0600:  db "0600", 0
e_source_env: db "env", 0

; --- credential-shaped key names -------------------------------------------
; The sweep matches on the KEY, not the value: a configuration containing
; `api_key` is rejected even when the value is a placeholder, because accepting
; the shape at all invites somebody to fill it in later.
p_api_key:       db "api_key", 0
p_apikey:        db "apikey", 0
p_secret:        db "secret", 0
p_password:      db "password", 0
p_token:         db "token", 0
p_authorization: db "authorization", 0
p_private_key:   db "private_key", 0
p_credential:    db "credential", 0
p_credentials:   db "credentials", 0
p_passphrase:    db "passphrase", 0
p_bearer:        db "bearer", 0

; --- rejection messages ----------------------------------------------------
; A message names the rule, never the value. A rejection is logged before the
; redaction policy from the file itself is even available.
        global m_not_object
m_not_object:       db "value must be a JSON object", 0
        global m_bad_id
m_bad_id:           db "identifier does not match the permitted pattern", 0
        global m_bad_alias
m_bad_alias:        db "model alias does not match the permitted pattern", 0
        global m_bad_env
m_bad_env:          db "environment variable name is not permitted", 0
        global m_bad_header
m_bad_header:       db "header name is not permitted", 0
        global m_bad_url
m_bad_url:          db "URL violates the outbound policy", 0
        global m_bad_path
m_bad_path:         db "path is not absolute, climbs, or uses a forbidden expansion", 0
        global m_plaintext
m_plaintext:        db "plaintext credentials are not accepted in configuration", 0
        global m_dup_id
m_dup_id:           db "identifier is already used by another entry", 0
        global m_dup_alias
m_dup_alias:        db "model alias is already used by another route", 0
        global m_unknown_provider
m_unknown_provider: db "route target names a provider that does not exist", 0
        global m_attempts
m_attempts:         db "max_attempts exceeds the number of targets", 0
        global m_schema_version
m_schema_version:   db "schema_version must be 1", 0
        global m_auth_required
m_auth_required:    db "a non-loopback listener requires an authentication policy", 0
        global m_file_path
m_file_path:        db "a file log destination requires file_path", 0
        global m_backoff
m_backoff:          db "max_backoff_ms must be at least backoff_ms", 0
        global m_cmd_absolute
m_cmd_absolute:     db "command must be an absolute path", 0
        global m_health_path
m_health_path:      db "health path must start with /", 0
        global m_transport_field
m_transport_field:  db "field is not valid for this transport", 0
        global m_missing_secret
m_missing_secret:   db "referenced environment variable is not set", 0
        global m_responses_target
m_responses_target: db "a responses route needs a target that advertises responses", 0
        global m_dup_entry
m_dup_entry:        db "duplicate entry", 0
        global m_bad_enum_value
m_bad_enum_value:   db "value is not one of the permitted choices", 0
        global m_unknown_key
m_unknown_key:      db "unknown key is not permitted here", 0

        section .data.rel.ro progbits align=8 write

; --- enum tables: {const char *name, i64 value}, NULL-terminated ------------
AF_TABLE tbl_auth_type
        dq e_auth_none,   AF_AUTH_NONE
        dq e_auth_bearer, AF_AUTH_BEARER_ENV
        dq e_auth_header, AF_AUTH_HEADER_ENV
        dq 0, 0

AF_TABLE tbl_adapter
        dq e_adapter_resp, AF_ADAPTER_OPENAI_RESPONSES
        dq e_adapter_chat, AF_ADAPTER_OPENAI_CHAT
        dq e_adapter_dual, AF_ADAPTER_OPENAI_DUAL
        dq 0, 0

AF_TABLE tbl_journal
        dq e_wal, AF_JOURNAL_WAL
        dq 0, 0

AF_TABLE tbl_log_level
        dq e_trace, AF_LOG_TRACE
        dq e_debug, AF_LOG_DEBUG
        dq e_info,  AF_LOG_INFO
        dq e_warn,  AF_LOG_WARN
        dq e_error, AF_LOG_ERROR
        dq e_fatal, AF_LOG_FATAL
        dq 0, 0

AF_TABLE tbl_log_format
        dq e_jsonl, AF_LOG_FORMAT_JSONL
        dq e_text,  AF_LOG_FORMAT_TEXT
        dq 0, 0

AF_TABLE tbl_log_dest
        dq e_stderr, AF_LOG_DEST_STDERR
        dq e_file,   AF_LOG_DEST_FILE
        dq 0, 0

AF_TABLE tbl_policy
        dq e_priority,      AF_POLICY_PRIORITY
        dq e_round_robin,   AF_POLICY_ROUND_ROBIN
        dq e_least_latency, AF_POLICY_LEAST_LATENCY
        dq 0, 0

AF_TABLE tbl_endpoint_family
        dq k_responses,        AF_EPF_RESPONSES
        dq k_chat_completions, AF_EPF_CHAT_COMPLETIONS
        dq 0, 0

AF_TABLE tbl_retryable
        dq e_retry_connect_failed,  AF_RETRY_CONNECT_FAILED
        dq e_retry_dns_failed,      AF_RETRY_DNS_FAILED
        dq e_retry_connect_timeout, AF_RETRY_CONNECT_TIMEOUT
        dq e_retry_502,             AF_RETRY_HTTP_502
        dq e_retry_503,             AF_RETRY_HTTP_503
        dq e_retry_504,             AF_RETRY_HTTP_504
        dq 0, 0

AF_TABLE tbl_transport
        dq e_stdio, AF_TRANSPORT_STDIO
        dq e_shttp, AF_TRANSPORT_STREAMABLE_HTTP
        dq 0, 0

AF_TABLE tbl_restart
        dq e_never,      AF_RESTART_NEVER
        dq e_on_failure, AF_RESTART_ON_FAILURE
        dq e_always,     AF_RESTART_ALWAYS
        dq 0, 0

AF_TABLE tbl_mcp_preferred
        dq e_modern_version, AF_ERA_MODERN
        dq 0, 0

AF_TABLE tbl_mcp_legacy
        dq e_legacy_version, AF_MCP_LEGACY_2025_11_25
        dq 0, 0

AF_TABLE tbl_control_mode
        dq e_mode_0600, 0o600
        dq 0, 0

AF_TABLE tbl_secret_source
        dq e_source_env, 0
        dq 0, 0

AF_TABLE tbl_plaintext_keys
        dq p_api_key, p_apikey, p_secret, p_password, p_token
        dq p_authorization, p_private_key, p_credential, p_credentials
        dq p_passphrase, p_bearer, 0

; --- allowed-key lists: `additionalProperties: false` ----------------------
AF_TABLE keys_root
        dq k_schema_version, k_listener, k_control, k_storage, k_logging
        dq k_limits, k_providers, k_routes, k_mcp_servers, 0

AF_TABLE keys_listener
        dq k_host, k_port, k_auth, k_request_header_max_bytes
        dq k_request_body_max_bytes, k_idle_timeout_ms, k_expose_unavailable, 0

AF_TABLE keys_control
        dq k_socket_path, k_mode, k_frame_max_bytes, 0

AF_TABLE keys_storage
        dq k_database_path, k_journal_mode, k_busy_timeout_ms
        dq k_retention_days, k_store_payloads, 0

AF_TABLE keys_logging
        dq k_level, k_format, k_destination, k_file_path
        dq k_include_req_meta, k_include_payloads, k_redact_headers, 0

AF_TABLE keys_limits
        dq k_max_active_requests, k_max_queued_requests, k_json_max_depth
        dq k_json_string_max, k_sse_event_max, k_mcp_frame_max
        dq k_stderr_line_max, 0

AF_TABLE keys_provider
        dq k_id, k_display_name, k_adapter, k_base_url, k_auth, k_enabled
        dq k_required, k_max_concurrency, k_timeouts, k_capabilities
        dq k_health, k_allow_insecure, 0

AF_TABLE keys_timeouts
        dq k_connect_ms, k_request_ms, k_idle_stream_ms, 0

AF_TABLE keys_capabilities
        dq k_responses, k_chat_completions, k_streaming, k_tools
        dq k_vision, k_json_schema, 0

AF_TABLE keys_health
        dq k_path, k_interval_ms, k_failure_threshold
        dq k_success_threshold, k_open_cooldown_ms, 0

AF_TABLE keys_route
        dq k_id, k_model_alias, k_enabled, k_endpoint_families, k_policy
        dq k_fallback, k_targets, 0

AF_TABLE keys_fallback
        dq k_enabled, k_max_attempts, k_retryable, 0

AF_TABLE keys_route_target
        dq k_provider_id, k_upstream_model, k_priority, k_weight, 0

AF_TABLE keys_mcp_stdio
        dq k_id, k_display_name, k_transport, k_enabled, k_required
        dq k_command, k_args, k_cwd, k_env_allow, k_env, k_protocol
        dq k_restart, k_startup_timeout_ms, k_shutdown_grace_ms, 0

AF_TABLE keys_mcp_http
        dq k_id, k_display_name, k_transport, k_enabled, k_required
        dq k_url, k_auth, k_protocol, k_timeouts, k_allow_insecure, 0

AF_TABLE keys_protocol
        dq k_preferred, k_legacy, 0

AF_TABLE keys_restart
        dq k_mode, k_max_restarts, k_window_ms, k_backoff_ms, k_max_backoff_ms, 0

AF_TABLE keys_secret_ref
        dq k_source, k_name, 0

; The three `auth` shapes are a schema `oneOf`, so each variant has its own
; permitted key set rather than a union: `{"type":"none","env":"X"}` must be
; rejected, not quietly accepted with an ignored field.
AF_TABLE keys_auth_none
        dq k_type, 0

AF_TABLE keys_auth_bearer
        dq k_type, k_env, 0

AF_TABLE keys_auth_header
        dq k_type, k_header, k_value, 0
