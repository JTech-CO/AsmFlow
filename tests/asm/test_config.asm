; AsmFlow — configuration validation primitives and snapshot lifetime
; (HARNESS.md M3).
;
; The end-to-end accept/reject behaviour is covered by the corpus parity test in
; tests/test_config_parity.py, which runs the same files through the schema and
; through this binary. What is tested here is everything a corpus cannot show:
; the pattern validators at their boundaries, the URL policy, path expansion,
; snapshot reference counting, and the reload atomicity invariant.

        bits 64
        default rel

%include "asmflow.inc"
%include "json.inc"
%include "config.inc"
%include "test.inc"

%define AF_TEST_TAG config

        extern af_cfg_id_valid
        extern af_cfg_env_name_valid
        extern af_cfg_model_alias_valid
        extern af_cfg_header_name_valid
        extern af_cfg_is_loopback_host
        extern af_cfg_url_check
        extern af_cfg_expand_path
        extern af_cfg_path_has_dotdot
        extern af_cfg_intern
        extern af_cfg_key_is_credential
        extern af_cfg_enum_lookup

        extern af_cfg_err_init
        extern af_cfg_err_free
        extern af_cfg_err_reset
        extern af_cfg_err_push_key
        extern af_cfg_err_push_index
        extern af_cfg_err_truncate
        extern af_cfg_err_depth
        extern af_cfg_err_fail
        extern af_cfg_err_code
        extern af_cfg_err_pointer
        extern af_cfg_err_pointer_len

        extern af_config_parse
        extern af_config_release
        extern af_config_retain
        extern af_config_refcount
        extern af_config_hash_bytes
        extern af_config_resolve_secrets
        extern af_cfg_resolve_provider

        extern af_arena_init
        extern af_arena_finalize
        extern af_alloc_live_count
        extern af_mem_eq
        extern af_cstr_len

        section .rodata
; --- identifier patterns ---
id_ok:        db "local-ollama"
id_ok_len     equ 12
id_upper:     db "Local"
id_upper_len  equ 5
id_lead_dot:  db ".x"
id_lead_dot_len equ 2
id_lead_dash: db "-x"
id_lead_dash_len equ 2
id_space:     db "a b"
id_space_len  equ 3
id_64:        db "a123456789012345678901234567890123456789012345678901234567890123"
id_64_len     equ 64
id_65:        db "a1234567890123456789012345678901234567890123456789012345678901234"
id_65_len     equ 65

env_ok:       db "OPENAI_API_KEY"
env_ok_len    equ 14
env_under:    db "_X"
env_under_len equ 2
env_lower:    db "openai"
env_lower_len equ 6
env_digit1st: db "1ABC"
env_digit1st_len equ 4

alias_ok:     db "gpt-4o:mini/v1.2"
alias_ok_len  equ 16
alias_bad:    db "has space"
alias_bad_len equ 9

hdr_ok:       db "X-Api-Key"
hdr_ok_len    equ 9
hdr_colon:    db "X:Key"
hdr_colon_len equ 5
hdr_crlf:     db "X", 13, 10, "Y"
hdr_crlf_len  equ 4

host_lo1:     db "127.0.0.1"
host_lo1_len  equ 9
host_lo2:     db "localhost"
host_lo2_len  equ 9
host_lo3:     db "::1"
host_lo3_len  equ 3
host_any:     db "0.0.0.0"
host_any_len  equ 7

url_https:    db "https://api.example.com/v1"
url_https_len equ 26
url_http_lo:  db "http://127.0.0.1:11434/v1"
url_http_lo_len equ 25
url_http_rem: db "http://api.example.com/v1"
url_http_rem_len equ 25
url_http_lo6: db "http://[::1]:11434/v1"
url_http_lo6_len equ $ - url_http_lo6
url_http_priv10: db "http://10.1.2.3/v1"
url_http_priv10_len equ $ - url_http_priv10
url_http_priv172: db "http://172.31.255.254/v1"
url_http_priv172_len equ $ - url_http_priv172
url_http_priv192: db "http://192.168.1.2/v1"
url_http_priv192_len equ $ - url_http_priv192
url_http_link4: db "http://169.254.169.254/v1"
url_http_link4_len equ $ - url_http_link4
url_http_public4: db "http://8.8.8.8/v1"
url_http_public4_len equ $ - url_http_public4
url_http_ula6: db "http://[fd12:3456::1]/mcp"
url_http_ula6_len equ $ - url_http_ula6
url_http_link6: db "http://[fe80::1]/mcp"
url_http_link6_len equ $ - url_http_link6
url_http_public6: db "http://[2001:4860:4860::8888]/mcp"
url_http_public6_len equ $ - url_http_public6
url_creds:    db "https://user:pass@api.example.com/v1"
url_creds_len equ 35
url_frag:     db "https://api.example.com/v1#x"
url_frag_len  equ 28
url_space:    db "https://api.example.com/a b"
url_space_len equ 27
url_ftp:      db "ftp://api.example.com/v1"
url_ftp_len   equ 24
url_crlf:     db "https://api.example.com/", 13, 10, "x"
url_crlf_len  equ 26

path_home:    db "${XDG_STATE_HOME}/asmflow/asmflow.db"
path_home_len equ 35
path_bare:    db "$HOME/x"
path_bare_len equ 7
path_cmd:     db "$(whoami)/x"
path_cmd_len  equ 11
path_tick:    db "/tmp/`id`"
path_tick_len equ 9
path_unknown: db "${PATH}/x"
path_unknown_len equ 9
path_rel:     db "relative/x"
path_rel_len  equ 10
path_climb:   db "${XDG_STATE_HOME}/../../etc/passwd"
path_climb_len equ 33
path_abs:     db "/var/lib/asmflow.db"
path_abs_len  equ 19

dd_mid:   db "/a/../b"
dd_mid_len equ 7
dd_tail:  db "/a/.."
dd_tail_len equ 5
dd_lead:  db "../a"
dd_lead_len equ 4
dd_none:  db "/a/..b/c"
dd_none_len equ 8

cred_api_key:  db "api_key", 0
cred_upper:    db "API_KEY", 0
cred_token:    db "Token", 0
cred_type:     db "type", 0
cred_env:      db "env", 0
cred_name:     db "name", 0

ptr_a: db "providers", 0
ptr_b: db "base~url", 0
ptr_c: db "a/b", 0

; A minimal valid configuration, embedded so the snapshot tests do not depend on
; the filesystem.
cfg_min:
        db `{"schema_version":1,`
        db `"listener":{"host":"127.0.0.1","port":8080,"auth":{"type":"none"},`
        db `"request_header_max_bytes":65536,"request_body_max_bytes":8388608,`
        db `"idle_timeout_ms":30000},`
        db `"control":{"socket_path":"/tmp/asmflow-test/control.sock","mode":"0600","frame_max_bytes":1048576},`
        db `"storage":{"database_path":"/tmp/asmflow-test/asmflow.db","journal_mode":"wal",`
        db `"busy_timeout_ms":3000,"request_metadata_retention_days":30,"store_payloads":false},`
        db `"logging":{"level":"info","format":"jsonl","destination":"stderr",`
        db `"include_request_metadata":true,"include_payloads":false,`
        db `"redact_headers":["authorization","cookie"]},`
        db `"limits":{"max_active_requests":128,"max_queued_requests":256,"json_max_depth":64,`
        db `"json_string_max_bytes":4194304,"sse_event_max_bytes":1048576,`
        db `"mcp_frame_max_bytes":4194304,"stderr_line_max_bytes":65536},`
        db `"providers":[{"id":"local-ollama","display_name":"Local","adapter":"openai_chat",`
        db `"base_url":"http://127.0.0.1:11434/v1","auth":{"type":"none"},"enabled":true,`
        db `"required":false,"max_concurrency":4,`
        db `"timeouts":{"connect_ms":2000,"request_ms":120000,"idle_stream_ms":30000},`
        db `"capabilities":{"responses":false,"chat_completions":true,"streaming":true,`
        db `"tools":true,"vision":false,"json_schema":false},`
        db `"health":{"path":"/models","interval_ms":10000,"failure_threshold":3,`
        db `"success_threshold":2,"open_cooldown_ms":30000}}],`
        db `"routes":[{"id":"general-route","model_alias":"general","enabled":true,`
        db `"endpoint_families":["chat_completions"],"policy":"priority",`
        db `"fallback":{"enabled":false,"max_attempts":1,"retryable":[]},`
        db `"targets":[{"provider_id":"local-ollama","upstream_model":"qwen","priority":10,"weight":1}]}],`
        db `"mcp_servers":[]}`
cfg_min_len equ $ - cfg_min

; The same document with the route pointing at a provider that does not exist.
cfg_badref:
        db `{"schema_version":1,`
        db `"listener":{"host":"127.0.0.1","port":8080,"auth":{"type":"none"},`
        db `"request_header_max_bytes":65536,"request_body_max_bytes":8388608,`
        db `"idle_timeout_ms":30000},`
        db `"control":{"socket_path":"/tmp/asmflow-test/control.sock","mode":"0600","frame_max_bytes":1048576},`
        db `"storage":{"database_path":"/tmp/asmflow-test/asmflow.db","journal_mode":"wal",`
        db `"busy_timeout_ms":3000,"request_metadata_retention_days":30,"store_payloads":false},`
        db `"logging":{"level":"info","format":"jsonl","destination":"stderr",`
        db `"include_request_metadata":true,"include_payloads":false,"redact_headers":[]},`
        db `"limits":{"max_active_requests":128,"max_queued_requests":256,"json_max_depth":64,`
        db `"json_string_max_bytes":4194304,"sse_event_max_bytes":1048576,`
        db `"mcp_frame_max_bytes":4194304,"stderr_line_max_bytes":65536},`
        db `"providers":[{"id":"local-ollama","display_name":"Local","adapter":"openai_chat",`
        db `"base_url":"http://127.0.0.1:11434/v1","auth":{"type":"none"},"enabled":true,`
        db `"required":false,"max_concurrency":4,`
        db `"timeouts":{"connect_ms":2000,"request_ms":120000,"idle_stream_ms":30000},`
        db `"capabilities":{"responses":false,"chat_completions":true,"streaming":true,`
        db `"tools":true,"vision":false,"json_schema":false},`
        db `"health":{"path":"/models","interval_ms":10000,"failure_threshold":3,`
        db `"success_threshold":2,"open_cooldown_ms":30000}}],`
        db `"routes":[{"id":"general-route","model_alias":"general","enabled":true,`
        db `"endpoint_families":["chat_completions"],"policy":"priority",`
        db `"fallback":{"enabled":false,"max_attempts":1,"retryable":[]},`
        db `"targets":[{"provider_id":"absent","upstream_model":"qwen","priority":10,"weight":1}]}],`
        db `"mcp_servers":[]}`
cfg_badref_len equ $ - cfg_badref

expect_ptr_badref: db "/routes/0/targets/0/provider_id"
expect_ptr_badref_len equ 31

provider_id_str: db "local-ollama", 0

        section .text

; --- pattern validators -----------------------------------------------------

AF_TEST "config/identifier_pattern_boundaries"
        lea     rdi, [id_ok]
        mov     rsi, id_ok_len
        call    af_cfg_id_valid
        AF_CHECK_EQ rax, 1, "a normal identifier should be accepted"

        lea     rdi, [id_upper]
        mov     rsi, id_upper_len
        call    af_cfg_id_valid
        AF_CHECK_EQ rax, 0, "uppercase must be rejected"

        lea     rdi, [id_lead_dot]
        mov     rsi, id_lead_dot_len
        call    af_cfg_id_valid
        AF_CHECK_EQ rax, 0, "a leading dot must be rejected"

        lea     rdi, [id_lead_dash]
        mov     rsi, id_lead_dash_len
        call    af_cfg_id_valid
        AF_CHECK_EQ rax, 0, "a leading dash must be rejected"

        lea     rdi, [id_space]
        mov     rsi, id_space_len
        call    af_cfg_id_valid
        AF_CHECK_EQ rax, 0, "a space must be rejected"

        lea     rdi, [id_ok]
        xor     esi, esi
        call    af_cfg_id_valid
        AF_CHECK_EQ rax, 0, "an empty identifier must be rejected"

        ; length boundary: 64 accepted, 65 refused
        lea     rdi, [id_64]
        mov     rsi, id_64_len
        call    af_cfg_id_valid
        AF_CHECK_EQ rax, 1, "sixty-four characters should be accepted"
        lea     rdi, [id_65]
        mov     rsi, id_65_len
        call    af_cfg_id_valid
        AF_CHECK_EQ rax, 0, "sixty-five characters must be rejected"
AF_TEST_END

AF_TEST "config/environment_name_pattern"
        lea     rdi, [env_ok]
        mov     rsi, env_ok_len
        call    af_cfg_env_name_valid
        AF_CHECK_EQ rax, 1, "a normal variable name should be accepted"

        lea     rdi, [env_under]
        mov     rsi, env_under_len
        call    af_cfg_env_name_valid
        AF_CHECK_EQ rax, 1, "a leading underscore is permitted"

        lea     rdi, [env_lower]
        mov     rsi, env_lower_len
        call    af_cfg_env_name_valid
        AF_CHECK_EQ rax, 0, "lowercase must be rejected"

        lea     rdi, [env_digit1st]
        mov     rsi, env_digit1st_len
        call    af_cfg_env_name_valid
        AF_CHECK_EQ rax, 0, "a leading digit must be rejected"
AF_TEST_END

AF_TEST "config/model_alias_pattern"
        lea     rdi, [alias_ok]
        mov     rsi, alias_ok_len
        call    af_cfg_model_alias_valid
        AF_CHECK_EQ rax, 1, "a dotted, colonned, slashed alias should be accepted"

        lea     rdi, [alias_bad]
        mov     rsi, alias_bad_len
        call    af_cfg_model_alias_valid
        AF_CHECK_EQ rax, 0, "a space must be rejected"
AF_TEST_END

AF_TEST "config/header_name_pattern_blocks_injection"
        lea     rdi, [hdr_ok]
        mov     rsi, hdr_ok_len
        call    af_cfg_header_name_valid
        AF_CHECK_EQ rax, 1, "a normal header name should be accepted"

        ; A colon or a CRLF in a configured header name would end up in an
        ; outbound request line.
        lea     rdi, [hdr_colon]
        mov     rsi, hdr_colon_len
        call    af_cfg_header_name_valid
        AF_CHECK_EQ rax, 0, "a colon must be rejected"

        lea     rdi, [hdr_crlf]
        mov     rsi, hdr_crlf_len
        call    af_cfg_header_name_valid
        AF_CHECK_EQ rax, 0, "CRLF must be rejected"
AF_TEST_END

AF_TEST "config/loopback_host_recognition"
        lea     rdi, [host_lo1]
        mov     rsi, host_lo1_len
        call    af_cfg_is_loopback_host
        AF_CHECK_EQ rax, 1, "127.0.0.1 is loopback"
        lea     rdi, [host_lo2]
        mov     rsi, host_lo2_len
        call    af_cfg_is_loopback_host
        AF_CHECK_EQ rax, 1, "localhost is loopback"
        lea     rdi, [host_lo3]
        mov     rsi, host_lo3_len
        call    af_cfg_is_loopback_host
        AF_CHECK_EQ rax, 1, "::1 is loopback"
        lea     rdi, [host_any]
        mov     rsi, host_any_len
        call    af_cfg_is_loopback_host
        AF_CHECK_EQ rax, 0, "0.0.0.0 is not loopback"
AF_TEST_END

; --- outbound URL policy ----------------------------------------------------

AF_TEST "config/url_policy", 64
        lea     rdi, [url_https]
        mov     rsi, url_https_len
        xor     edx, edx
        lea     rcx, [rsp]
        call    af_cfg_url_check
        AF_CHECK_OK rax, "https should be accepted"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 0, "a remote https host is not loopback"

        lea     rdi, [url_http_lo]
        mov     rsi, url_http_lo_len
        xor     edx, edx
        lea     rcx, [rsp]
        call    af_cfg_url_check
        AF_CHECK_OK rax, "plain http on loopback should be accepted"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 1, "127.0.0.1 should be reported as loopback"

        lea     rdi, [url_http_rem]
        mov     rsi, url_http_rem_len
        xor     edx, edx
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_ERR rax, AF_E_CFG_URL, "plain http to a remote host must be refused"

        ; A hostname cannot be authorized by the exception: its DNS answer can
        ; change after validation.
        lea     rdi, [url_http_rem]
        mov     rsi, url_http_rem_len
        mov     rdx, 1
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_ERR rax, AF_E_CFG_URL, "the exception must not authorize a hostname"

        lea     rdi, [url_http_lo6]
        mov     rsi, url_http_lo6_len
        xor     edx, edx
        lea     rcx, [rsp]
        call    af_cfg_url_check
        AF_CHECK_OK rax, "bracketed IPv6 loopback should be accepted"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 1, "IPv6 loopback should be reported as loopback"

        ; RFC1918 and link-local IPv4 literals require the explicit exception.
        lea     rdi, [url_http_priv10]
        mov     rsi, url_http_priv10_len
        xor     edx, edx
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_ERR rax, AF_E_CFG_URL, "RFC1918 plaintext must require the exception"

        lea     rdi, [url_http_priv10]
        mov     rsi, url_http_priv10_len
        mov     rdx, 1
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_OK rax, "the exception should permit 10/8"

        lea     rdi, [url_http_priv172]
        mov     rsi, url_http_priv172_len
        mov     rdx, 1
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_OK rax, "the exception should permit 172.16/12"

        lea     rdi, [url_http_priv192]
        mov     rsi, url_http_priv192_len
        mov     rdx, 1
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_OK rax, "the exception should permit 192.168/16"

        lea     rdi, [url_http_link4]
        mov     rsi, url_http_link4_len
        mov     rdx, 1
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_OK rax, "the exception should permit IPv4 link-local"

        lea     rdi, [url_http_public4]
        mov     rsi, url_http_public4_len
        mov     rdx, 1
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_ERR rax, AF_E_CFG_URL, "the exception must not authorize public IPv4"

        ; IPv6 ULA and link-local literals follow the same explicit policy.
        lea     rdi, [url_http_ula6]
        mov     rsi, url_http_ula6_len
        xor     edx, edx
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_ERR rax, AF_E_CFG_URL, "IPv6 ULA plaintext must require the exception"

        lea     rdi, [url_http_ula6]
        mov     rsi, url_http_ula6_len
        mov     rdx, 1
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_OK rax, "the exception should permit IPv6 ULA"

        lea     rdi, [url_http_link6]
        mov     rsi, url_http_link6_len
        mov     rdx, 1
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_OK rax, "the exception should permit IPv6 link-local"

        lea     rdi, [url_http_public6]
        mov     rsi, url_http_public6_len
        mov     rdx, 1
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_ERR rax, AF_E_CFG_URL, "the exception must not authorize public IPv6"

        lea     rdi, [url_creds]
        mov     rsi, url_creds_len
        xor     edx, edx
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_ERR rax, AF_E_CFG_URL, "embedded credentials must be refused"

        lea     rdi, [url_frag]
        mov     rsi, url_frag_len
        xor     edx, edx
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_ERR rax, AF_E_CFG_URL, "a fragment must be refused"

        lea     rdi, [url_space]
        mov     rsi, url_space_len
        xor     edx, edx
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_ERR rax, AF_E_CFG_URL, "a space must be refused"

        lea     rdi, [url_crlf]
        mov     rsi, url_crlf_len
        xor     edx, edx
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_ERR rax, AF_E_CFG_URL, "CRLF must be refused"

        lea     rdi, [url_ftp]
        mov     rsi, url_ftp_len
        xor     edx, edx
        xor     ecx, ecx
        call    af_cfg_url_check
        AF_CHECK_ERR rax, AF_E_CFG_URL, "a non-HTTP scheme must be refused"
AF_TEST_END

; --- path expansion ---------------------------------------------------------

AF_TEST "config/path_dotdot_detection"
        lea     rdi, [dd_mid]
        mov     rsi, dd_mid_len
        call    af_cfg_path_has_dotdot
        AF_CHECK_EQ rax, 1, "an interior /../ must be detected"
        lea     rdi, [dd_tail]
        mov     rsi, dd_tail_len
        call    af_cfg_path_has_dotdot
        AF_CHECK_EQ rax, 1, "a trailing /.. must be detected"
        lea     rdi, [dd_lead]
        mov     rsi, dd_lead_len
        call    af_cfg_path_has_dotdot
        AF_CHECK_EQ rax, 1, "a leading ../ must be detected"
        lea     rdi, [dd_none]
        mov     rsi, dd_none_len
        call    af_cfg_path_has_dotdot
        AF_CHECK_EQ rax, 0, "a filename beginning with .. is not a climb"
AF_TEST_END

AF_TEST "config/path_expansion_allowlist", 128
        lea     rbx, [rsp + 64]         ; af_arena
        mov     rdi, rbx
        mov     rsi, 4096
        mov     rdx, 65536
        call    af_arena_init
        AF_CHECK_OK rax, "arena init failed"

        ; An allowlisted variable expands.
        mov     rdi, rbx
        lea     rsi, [path_home]
        mov     rdx, path_home_len
        lea     rcx, [rsp]
        call    af_cfg_expand_path
        AF_CHECK_OK rax, "an allowlisted expansion should succeed"
        mov     r12, [rsp]
        AF_CHECK_NE r12, 0, "the expanded path should not be NULL"
        movzx   r13, byte [r12]
        AF_CHECK_EQ r13, '/', "the expanded path should be absolute"

        ; An absolute literal needs no expansion at all.
        mov     rdi, rbx
        lea     rsi, [path_abs]
        mov     rdx, path_abs_len
        lea     rcx, [rsp]
        call    af_cfg_expand_path
        AF_CHECK_OK rax, "a literal absolute path should be accepted"

        ; Everything else is refused rather than passed through.
        mov     rdi, rbx
        lea     rsi, [path_bare]
        mov     rdx, path_bare_len
        lea     rcx, [rsp]
        call    af_cfg_expand_path
        AF_CHECK_ERR rax, AF_E_CFG_PATH, "$VAR must be refused"

        mov     rdi, rbx
        lea     rsi, [path_cmd]
        mov     rdx, path_cmd_len
        lea     rcx, [rsp]
        call    af_cfg_expand_path
        AF_CHECK_ERR rax, AF_E_CFG_PATH, "command substitution must be refused"

        mov     rdi, rbx
        lea     rsi, [path_tick]
        mov     rdx, path_tick_len
        lea     rcx, [rsp]
        call    af_cfg_expand_path
        AF_CHECK_ERR rax, AF_E_CFG_PATH, "backticks must be refused"

        mov     rdi, rbx
        lea     rsi, [path_unknown]
        mov     rdx, path_unknown_len
        lea     rcx, [rsp]
        call    af_cfg_expand_path
        AF_CHECK_ERR rax, AF_E_CFG_PATH, "a variable outside the allowlist must be refused"

        mov     rdi, rbx
        lea     rsi, [path_rel]
        mov     rdx, path_rel_len
        lea     rcx, [rsp]
        call    af_cfg_expand_path
        AF_CHECK_ERR rax, AF_E_CFG_PATH, "a relative path must be refused"

        mov     rdi, rbx
        lea     rsi, [path_climb]
        mov     rdx, path_climb_len
        lea     rcx, [rsp]
        call    af_cfg_expand_path
        AF_CHECK_ERR rax, AF_E_CFG_PATH, "a climbing path must be refused"

        mov     rdi, rbx
        call    af_arena_finalize
AF_TEST_END

; --- credential-shaped keys -------------------------------------------------

AF_TEST "config/credential_key_detection"
        lea     rdi, [cred_api_key]
        call    af_cfg_key_is_credential
        AF_CHECK_EQ rax, 1, "api_key is credential-shaped"
        lea     rdi, [cred_upper]
        call    af_cfg_key_is_credential
        AF_CHECK_EQ rax, 1, "the match is case-insensitive"
        lea     rdi, [cred_token]
        call    af_cfg_key_is_credential
        AF_CHECK_EQ rax, 1, "Token is credential-shaped"

        ; A legitimate SecretRef must pass cleanly.
        lea     rdi, [cred_type]
        call    af_cfg_key_is_credential
        AF_CHECK_EQ rax, 0, "type is not credential-shaped"
        lea     rdi, [cred_env]
        call    af_cfg_key_is_credential
        AF_CHECK_EQ rax, 0, "env is not credential-shaped"
        lea     rdi, [cred_name]
        call    af_cfg_key_is_credential
        AF_CHECK_EQ rax, 0, "name is not credential-shaped"
AF_TEST_END

; --- JSON Pointer construction ---------------------------------------------

AF_TEST "config/json_pointer_escaping_and_truncation", 128
        lea     rbx, [rsp]              ; af_cfg_error
        mov     rdi, rbx
        call    af_cfg_err_init
        AF_CHECK_OK rax, "error init failed"

        mov     rdi, rbx
        lea     rsi, [ptr_a]
        call    af_cfg_err_push_key
        mov     rdi, rbx
        mov     rsi, 3
        call    af_cfg_err_push_index
        mov     rdi, rbx
        call    af_cfg_err_depth
        mov     r12, rax
        AF_CHECK_EQ r12, 12, "'/providers/3' is twelve characters"

        ; RFC 6901: '~' becomes ~0 and '/' becomes ~1.
        mov     rdi, rbx
        lea     rsi, [ptr_b]
        call    af_cfg_err_push_key
        mov     rdi, rbx
        call    af_cfg_err_depth
        AF_CHECK_EQ rax, 22, "'~' must expand to two characters"

        mov     rdi, rbx
        mov     rsi, r12
        call    af_cfg_err_truncate
        AF_CHECK_OK rax, "truncation failed"
        mov     rdi, rbx
        lea     rsi, [ptr_c]
        call    af_cfg_err_push_key
        mov     rdi, rbx
        call    af_cfg_err_depth
        AF_CHECK_EQ rax, 17, "'/' must expand to two characters"

        ; Truncating past the current length is a range error, not a clamp.
        mov     rdi, rbx
        mov     rsi, 999
        call    af_cfg_err_truncate
        AF_CHECK_ERR rax, AF_E_RANGE, "over-truncation must be refused"

        mov     rdi, rbx
        call    af_cfg_err_free
AF_TEST_END

AF_TEST "config/first_failure_wins", 128
        lea     rbx, [rsp]
        mov     rdi, rbx
        call    af_cfg_err_init

        mov     rdi, rbx
        mov     rsi, AF_E_CFG_SCHEMA
        lea     rdx, [ptr_a]
        call    af_cfg_err_fail
        AF_CHECK_EQ rax, AF_E_CFG_SCHEMA, "af_cfg_err_fail should return its code"

        ; A later rule must not overwrite the pointer that named the cause.
        mov     rdi, rbx
        mov     rsi, AF_E_CFG_URL
        lea     rdx, [ptr_b]
        call    af_cfg_err_fail
        mov     rdi, rbx
        call    af_cfg_err_code
        AF_CHECK_EQ rax, AF_E_CFG_SCHEMA, "the first failure must be preserved"

        mov     rdi, rbx
        call    af_cfg_err_reset
        mov     rdi, rbx
        call    af_cfg_err_code
        AF_CHECK_EQ rax, AF_OK, "reset should clear the code"
        mov     rdi, rbx
        call    af_cfg_err_pointer_len
        AF_CHECK_EQ rax, 0, "reset should clear the pointer"

        mov     rdi, rbx
        call    af_cfg_err_free
AF_TEST_END

; --- snapshot lifetime ------------------------------------------------------

AF_TEST "config/parse_produces_a_snapshot_with_one_reference", 128
        call    af_alloc_live_count
        mov     r14, rax                ; baseline

        lea     rbx, [rsp]              ; af_cfg_error
        mov     rdi, rbx
        call    af_cfg_err_init
        AF_CHECK_OK rax, "error init failed"

        lea     rdi, [cfg_min]
        mov     rsi, cfg_min_len
        mov     rdx, rbx
        lea     rcx, [rsp + 96]
        call    af_config_parse
        AF_CHECK_OK rax, "the minimal configuration should be accepted"

        mov     r12, [rsp + 96]
        AF_CHECK_NE r12, 0, "a snapshot should have been produced"

        mov     rdi, r12
        call    af_config_refcount
        AF_CHECK_EQ rax, 1, "a fresh snapshot holds one reference"

        AF_CHECK_EQ qword [r12 + CFG_PROVIDER_COUNT], 1, "one provider expected"
        AF_CHECK_EQ qword [r12 + CFG_ROUTE_COUNT], 1, "one route expected"
        AF_CHECK_EQ qword [r12 + CFG_MCP_COUNT], 0, "no MCP servers expected"
        AF_CHECK_EQ qword [r12 + CFG_LST_PORT], 8080, "the listener port is wrong"
        AF_CHECK_EQ qword [r12 + CFG_LST_IS_LOOPBACK], 1, "the listener should be loopback"
        AF_CHECK_EQ qword [r12 + CFG_LOG_REDACT_COUNT], 2, "two redacted headers expected"

        ; The route target must have been resolved to an index at load time.
        mov     rax, [r12 + CFG_ROUTES]
        mov     rax, [rax + RTE_TARGETS]
        AF_CHECK_EQ qword [rax + RTG_PROVIDER_INDEX], 0, "the target should resolve to provider 0"

        ; A held reference keeps the snapshot alive across a release.
        mov     rdi, r12
        call    af_config_retain
        mov     rdi, r12
        call    af_config_refcount
        AF_CHECK_EQ rax, 2, "retain should raise the count"
        mov     rdi, r12
        call    af_config_release
        mov     rdi, r12
        call    af_config_refcount
        AF_CHECK_EQ rax, 1, "release should lower the count"

        mov     rdi, r12
        call    af_config_release
        mov     rdi, rbx
        call    af_cfg_err_free
        call    af_alloc_live_count
        AF_CHECK_EQ rax, r14, "releasing the snapshot should free everything"
AF_TEST_END

AF_TEST "config/a_rejected_document_produces_no_snapshot", 128
        call    af_alloc_live_count
        mov     r14, rax

        lea     rbx, [rsp]
        mov     rdi, rbx
        call    af_cfg_err_init

        mov     qword [rsp + 96], 0
        lea     rdi, [cfg_badref]
        mov     rsi, cfg_badref_len
        mov     rdx, rbx
        lea     rcx, [rsp + 96]
        call    af_config_parse
        AF_CHECK_ERR rax, AF_E_CFG_REF, "an unresolvable target must be rejected"
        AF_CHECK_EQ qword [rsp + 96], 0, "a rejection must leave no snapshot"

        ; The pointer must name the exact target, not merely "routes".
        mov     rdi, rbx
        call    af_cfg_err_pointer_len
        AF_CHECK_EQ rax, expect_ptr_badref_len, "the pointer has the wrong length"
        mov     rdi, rbx
        call    af_cfg_err_pointer
        mov     rdi, rax
        lea     rsi, [expect_ptr_badref]
        mov     rdx, expect_ptr_badref_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the pointer does not name the offending target"

        mov     rdi, rbx
        call    af_cfg_err_free
        call    af_alloc_live_count
        AF_CHECK_EQ rax, r14, "a rejected parse must not leak"
AF_TEST_END

AF_TEST "config/repeated_reloads_are_leak_free", 128
        ; docs/CONFIGURATION.md 13: a failed reload leaves the previous snapshot
        ; untouched. The allocator-level statement of that is simply that
        ; building and discarding snapshots repeatedly returns to the baseline.
        call    af_alloc_live_count
        mov     r14, rax

        lea     rbx, [rsp]
        mov     rdi, rbx
        call    af_cfg_err_init

        xor     r13, r13
.loop:
        mov     rdi, rbx
        call    af_cfg_err_reset
        mov     qword [rsp + 96], 0
        lea     rdi, [cfg_min]
        mov     rsi, cfg_min_len
        mov     rdx, rbx
        lea     rcx, [rsp + 96]
        call    af_config_parse
        AF_CHECK_OK rax, "a reload iteration failed"
        mov     rdi, [rsp + 96]
        call    af_config_release

        ; Alternate with a rejection so both paths are exercised.
        mov     rdi, rbx
        call    af_cfg_err_reset
        mov     qword [rsp + 96], 0
        lea     rdi, [cfg_badref]
        mov     rsi, cfg_badref_len
        mov     rdx, rbx
        lea     rcx, [rsp + 96]
        call    af_config_parse
        AF_CHECK_ERR rax, AF_E_CFG_REF, "the rejection iteration changed behaviour"

        inc     r13
        cmp     r13, 200
        jb      .loop

        mov     rdi, rbx
        call    af_cfg_err_free
        call    af_alloc_live_count
        AF_CHECK_EQ rax, r14, "repeated reloads leaked"
AF_TEST_END

AF_TEST "config/hash_identifies_content", 128
        lea     rdi, [cfg_min]
        mov     rsi, cfg_min_len
        call    af_config_hash_bytes
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "the hash should not be zero"

        lea     rdi, [cfg_min]
        mov     rsi, cfg_min_len
        call    af_config_hash_bytes
        AF_CHECK_EQ rax, rbx, "the hash must be stable for identical input"

        lea     rdi, [cfg_badref]
        mov     rsi, cfg_badref_len
        call    af_config_hash_bytes
        AF_CHECK_NE rax, rbx, "different content should hash differently"
AF_TEST_END

AF_TEST "config/provider_resolution_by_id", 128
        lea     rbx, [rsp]
        mov     rdi, rbx
        call    af_cfg_err_init
        lea     rdi, [cfg_min]
        mov     rsi, cfg_min_len
        mov     rdx, rbx
        lea     rcx, [rsp + 96]
        call    af_config_parse
        AF_CHECK_OK rax, "parse failed"
        mov     r12, [rsp + 96]

        mov     rdi, r12
        lea     rsi, [provider_id_str]
        lea     rdx, [rsp + 104]
        call    af_cfg_resolve_provider
        AF_CHECK_OK rax, "a configured provider should resolve"
        AF_CHECK_EQ qword [rsp + 104], 0, "it should resolve to index zero"

        mov     rdi, r12
        lea     rsi, [cred_name]        ; an id that does not exist
        lea     rdx, [rsp + 104]
        call    af_cfg_resolve_provider
        AF_CHECK_ERR rax, AF_E_NOTFOUND, "an unknown id must not resolve"
        AF_CHECK_EQ qword [rsp + 104], -1, "a failed resolution must write -1"

        mov     rdi, r12
        call    af_config_release
        mov     rdi, rbx
        call    af_cfg_err_free
AF_TEST_END
