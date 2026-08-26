; AsmFlow — long-running soak scenarios.
;
; HARNESS.md M3 DoD 7 asks for a 10,000-iteration configuration reload with zero
; leaks. That does not belong in the ordinary unit-test run — it takes long
; enough to make the fast feedback loop worse — so it lives behind a runner flag
; and is invoked by the milestone gate.
;
; The assertion is the allocator's own live-block counter: after N build-and-
; discard cycles the count must be exactly what it was before the first one.
; That catches a leak of one block per reload, which is precisely the shape a
; missing release on a rarely-taken error path produces.

        bits 64
        default rel

%include "asmflow.inc"
%include "config.inc"

        extern af_cfg_err_init
        extern af_cfg_err_free
        extern af_cfg_err_reset
        extern af_config_parse
        extern af_config_release
        extern af_alloc_live_count
        extern af_out_bytes
        extern af_out_u64
        extern af_sys_exit_group

%define AF_FD_STDOUT 1
%define AF_FD_STDERR 2

        section .rodata
; Deliberately the same documents the unit tests use, so the soak exercises the
; identical accept and reject paths rather than a simplified stand-in.
soak_cfg_ok:
        db `{"schema_version":1,`
        db `"listener":{"host":"127.0.0.1","port":8080,"auth":{"type":"none"},`
        db `"request_header_max_bytes":65536,"request_body_max_bytes":8388608,`
        db `"idle_timeout_ms":30000},`
        db `"control":{"socket_path":"/tmp/asmflow-soak/control.sock","mode":"0600","frame_max_bytes":1048576},`
        db `"storage":{"database_path":"/tmp/asmflow-soak/asmflow.db","journal_mode":"wal",`
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
        db `"mcp_servers":[{"id":"filesystem","display_name":"FS","transport":"stdio",`
        db `"enabled":false,"required":false,"command":"/usr/bin/node","args":["/opt/s.js","-v"],`
        db `"cwd":"/opt","env_allow":["PATH","HOME"],"env":{},`
        db `"protocol":{"preferred":"2026-07-28","legacy":["2025-11-25"]},`
        db `"restart":{"mode":"on_failure","max_restarts":3,"window_ms":60000,`
        db `"backoff_ms":1000,"max_backoff_ms":30000},`
        db `"startup_timeout_ms":10000,"shutdown_grace_ms":3000}]}`
soak_cfg_ok_len equ $ - soak_cfg_ok

; A document that fails late, after providers and routes have already been
; built: the interesting unwind is the one that has the most to release.
soak_cfg_bad:
        db `{"schema_version":1,`
        db `"listener":{"host":"127.0.0.1","port":8080,"auth":{"type":"none"},`
        db `"request_header_max_bytes":65536,"request_body_max_bytes":8388608,`
        db `"idle_timeout_ms":30000},`
        db `"control":{"socket_path":"/tmp/asmflow-soak/control.sock","mode":"0600","frame_max_bytes":1048576},`
        db `"storage":{"database_path":"/tmp/asmflow-soak/asmflow.db","journal_mode":"wal",`
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
soak_cfg_bad_len equ $ - soak_cfg_bad

m_soak_ok:      db "reload soak: live allocations returned to baseline after "
m_soak_ok_len   equ $ - m_soak_ok
m_soak_iter:    db " iterations", 10
m_soak_iter_len equ $ - m_soak_iter
m_soak_leak:    db "reload soak: leaked blocks: "
m_soak_leak_len equ $ - m_soak_leak
m_soak_fail:    db "reload soak: an iteration behaved unexpectedly at iteration "
m_soak_fail_len equ $ - m_soak_fail
m_nl:           db 10

        section .text

; ---------------------------------------------------------------------------
; af_test_run_reload_soak(u64 iterations) -> does not return
;
; Exit 0 when the live-block count is unchanged, 30 on a leak, 31 when an
; iteration produced an unexpected verdict.
; ---------------------------------------------------------------------------
        global af_test_run_reload_soak
af_test_run_reload_soak:
        AF_ENTER 128
        mov     rbx, rdi                ; iterations

        lea     r15, [rsp]              ; af_cfg_error
        mov     rdi, r15
        call    af_cfg_err_init
        test    rax, rax
        js      .internal

        ; One warm-up cycle before sampling. The error object's pointer and
        ; message buffers allocate lazily on first use, so a baseline taken
        ; before any cycle would count that one-time growth as a leak. What the
        ; soak actually asserts is that the STEADY STATE does not grow.
        mov     rdi, r15
        call    af_test_soak_cycle
        test    rax, rax
        jnz     .unexpected

        call    af_alloc_live_count
        mov     r12, rax

        xor     r13, r13
.loop:
        cmp     r13, rbx
        jae     .finished
        mov     rdi, r15
        call    af_test_soak_cycle
        test    rax, rax
        jnz     .unexpected
        inc     r13
        jmp     .loop

.finished:
        call    af_alloc_live_count
        mov     r14, rax
        cmp     r14, r12
        jne     .leaked

        mov     edi, AF_FD_STDOUT
        lea     rsi, [m_soak_ok]
        mov     rdx, m_soak_ok_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, rbx
        call    af_out_u64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [m_soak_iter]
        mov     rdx, m_soak_iter_len
        call    af_out_bytes

        mov     rdi, r15
        call    af_cfg_err_free
        xor     edi, edi
        call    af_sys_exit_group
        ud2

.leaked:
        mov     edi, AF_FD_STDERR
        lea     rsi, [m_soak_leak]
        mov     rdx, m_soak_leak_len
        call    af_out_bytes
        sub     r14, r12
        mov     edi, AF_FD_STDERR
        mov     rsi, r14
        call    af_out_u64
        mov     edi, AF_FD_STDERR
        lea     rsi, [m_nl]
        mov     rdx, 1
        call    af_out_bytes
        mov     edi, 30
        call    af_sys_exit_group
        ud2

.unexpected:
        mov     edi, AF_FD_STDERR
        lea     rsi, [m_soak_fail]
        mov     rdx, m_soak_fail_len
        call    af_out_bytes
        mov     edi, AF_FD_STDERR
        mov     rsi, r13
        call    af_out_u64
        mov     edi, AF_FD_STDERR
        lea     rsi, [m_nl]
        mov     rdx, 1
        call    af_out_bytes
        mov     edi, 31
        call    af_sys_exit_group
        ud2

.internal:
        mov     edi, 32
        call    af_sys_exit_group
        ud2

; ---------------------------------------------------------------------------
; af_test_soak_cycle(af_cfg_error *err) -> af_status
;
; One accept and one reject through the real loader. The rejecting document
; fails after providers and routes have already been built, so it exercises the
; unwind path with the most to release — which is the one a leak would hide in.
;
; Returns AF_OK when both halves behaved as expected, AF_E_INTERNAL otherwise.
; ---------------------------------------------------------------------------
        global af_test_soak_cycle
af_test_soak_cycle:
        AF_ENTER 32
        mov     rbx, rdi                ; error object

        mov     rdi, rbx
        call    af_cfg_err_reset
        mov     qword [rsp], 0
        lea     rdi, [soak_cfg_ok]
        mov     rsi, soak_cfg_ok_len
        mov     rdx, rbx
        lea     rcx, [rsp]
        call    af_config_parse
        test    rax, rax
        js      .unexpected
        cmp     qword [rsp], 0
        je      .unexpected
        mov     rdi, [rsp]
        call    af_config_release

        mov     rdi, rbx
        call    af_cfg_err_reset
        mov     qword [rsp], 0
        lea     rdi, [soak_cfg_bad]
        mov     rsi, soak_cfg_bad_len
        mov     rdx, rbx
        lea     rcx, [rsp]
        call    af_config_parse
        test    rax, rax
        jns     .unexpected
        ; A rejection must leave no snapshot at all.
        cmp     qword [rsp], 0
        jne     .unexpected
        AF_LEAVE_OK
.unexpected:
        AF_LEAVE_ERR AF_E_INTERNAL
