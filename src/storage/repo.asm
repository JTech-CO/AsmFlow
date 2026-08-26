; AsmFlow — the repository layer.
;
; ARCHITECTURE.md 4: `storage/` is the only runtime module that issues SQL.
; Everything above it works in terms of these functions, so a change to the
; schema has exactly one place to propagate from.
;
; Every statement is prepared with placeholders and every value is bound. No SQL
; is built by concatenation anywhere in this file, which is what
; SECURITY_MODEL.md 14 means by "no SQL built from provider IDs or user
; strings" — those ids come from a validated configuration, but the rule does
; not depend on that validation being right.
;
; What is NOT stored here is as deliberate as what is. Providers carry identity,
; capability, and operator state; they do not carry `auth`, not even the name of
; the environment variable, because a database is a file that gets copied,
; backed up, and attached to bug reports (SECURITY_MODEL.md 6).

        bits 64
        default rel

%include "asmflow.inc"
%include "config.inc"
%include "db.inc"

        extern af_db_prepare
        extern af_db_finalize
        extern af_db_step
        extern af_db_reset
        extern af_db_bind_int
        extern af_db_bind_cstr
        extern af_db_bind_text
        extern af_db_bind_null
        extern af_db_column_int
        extern af_db_column_text
        extern af_db_column_is_null
        extern af_db_begin
        extern af_db_commit
        extern af_db_rollback
        extern af_db_exec
        extern af_db_writes_blocked
        extern af_realtime_ms
        extern af_cstr_len

        section .rodata

sql_upsert_provider:
        db "INSERT INTO providers"
        db " (id, display_name, adapter, base_url, enabled, required,"
        db "  max_concurrency, capabilities, updated_at_ms)"
        db " VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)"
        db " ON CONFLICT(id) DO UPDATE SET"
        db "  display_name=excluded.display_name,"
        db "  adapter=excluded.adapter,"
        db "  base_url=excluded.base_url,"
        db "  enabled=excluded.enabled,"
        db "  required=excluded.required,"
        db "  max_concurrency=excluded.max_concurrency,"
        db "  capabilities=excluded.capabilities,"
        db "  updated_at_ms=excluded.updated_at_ms", 0

; A provider that vanished from the configuration is removed, and the cascade
; takes its health row and any route target that referenced it. Leaving it would
; make `providers.list` describe a provider the daemon can no longer reach.
sql_delete_stale_providers:
        db "DELETE FROM providers WHERE updated_at_ms < ?1", 0

sql_select_provider_count:
        db "SELECT COUNT(*) FROM providers", 0

sql_select_provider:
        db "SELECT id, display_name, adapter, base_url, enabled, required,"
        db " max_concurrency, capabilities FROM providers WHERE id = ?1", 0

sql_select_providers:
        db "SELECT id, display_name, adapter, base_url, enabled, required,"
        db " max_concurrency, capabilities FROM providers ORDER BY id", 0

sql_upsert_route:
        db "INSERT INTO routes"
        db " (id, model_alias, enabled, endpoint_families, policy,"
        db "  fallback_enabled, fallback_max_attempts, fallback_retryable,"
        db "  updated_at_ms)"
        db " VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)"
        db " ON CONFLICT(id) DO UPDATE SET"
        db "  model_alias=excluded.model_alias,"
        db "  enabled=excluded.enabled,"
        db "  endpoint_families=excluded.endpoint_families,"
        db "  policy=excluded.policy,"
        db "  fallback_enabled=excluded.fallback_enabled,"
        db "  fallback_max_attempts=excluded.fallback_max_attempts,"
        db "  fallback_retryable=excluded.fallback_retryable,"
        db "  updated_at_ms=excluded.updated_at_ms", 0

sql_delete_stale_routes:
        db "DELETE FROM routes WHERE updated_at_ms < ?1", 0

sql_delete_route_targets:
        db "DELETE FROM route_targets WHERE route_id = ?1", 0

sql_insert_route_target:
        db "INSERT INTO route_targets"
        db " (route_id, position, provider_id, upstream_model, priority, weight)"
        db " VALUES (?1,?2,?3,?4,?5,?6)", 0

sql_select_route_count:
        db "SELECT COUNT(*) FROM routes", 0

sql_select_target_count:
        db "SELECT COUNT(*) FROM route_targets WHERE route_id = ?1", 0

sql_select_route:
        db "SELECT id, model_alias, enabled, endpoint_families, policy,"
        db " fallback_enabled, fallback_max_attempts, fallback_retryable"
        db " FROM routes WHERE id = ?1", 0

sql_upsert_health:
        db "INSERT INTO provider_health"
        db " (provider_id, state, consecutive_failures, consecutive_successes,"
        db "  ewma_latency_us, opened_at_ms, last_change_ms, operator_disabled)"
        db " VALUES (?1,?2,0,0,NULL,NULL,?3,0)"
        db " ON CONFLICT(provider_id) DO NOTHING", 0

sql_set_operator_disabled:
        db "UPDATE provider_health SET operator_disabled = ?2,"
        db " last_change_ms = ?3 WHERE provider_id = ?1", 0

sql_select_operator_disabled:
        db "SELECT operator_disabled FROM provider_health WHERE provider_id = ?1", 0

sql_insert_request:
        db "INSERT INTO requests"
        db " (id, received_at_ms, endpoint, model_alias, route_id, streaming,"
        db "  committed, status_code, error_class, attempts, duration_ms,"
        db "  client_ref)"
        db " VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)", 0

sql_select_request_count:
        db "SELECT COUNT(*) FROM requests", 0

sql_select_request:
        db "SELECT id, received_at_ms, endpoint, model_alias, route_id,"
        db " streaming, committed, status_code, error_class, attempts,"
        db " duration_ms, client_ref FROM requests WHERE id = ?1", 0

sql_select_requests_page:
        db "SELECT id, received_at_ms, endpoint, model_alias, route_id,"
        db " streaming, committed, status_code, error_class, attempts,"
        db " duration_ms, client_ref FROM requests"
        db " ORDER BY received_at_ms DESC, id DESC LIMIT ?1", 0

sql_insert_attempt:
        db "INSERT INTO request_attempts"
        db " (request_id, attempt_no, provider_id, upstream_model,"
        db "  started_at_ms, finished_at_ms, status_code, error_class, retryable)"
        db " VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)", 0

sql_select_attempt_count:
        db "SELECT COUNT(*) FROM request_attempts WHERE request_id = ?1", 0

sql_prune_requests:
        db "DELETE FROM requests WHERE received_at_ms < ?1", 0

sql_upsert_mcp:
        db "INSERT INTO mcp_servers"
        db " (id, display_name, transport, enabled, required, state, era,"
        db "  last_error, restart_count, crash_loop, updated_at_ms)"
        db " VALUES (?1,?2,?3,?4,?5,'stopped',NULL,NULL,0,0,?6)"
        db " ON CONFLICT(id) DO UPDATE SET"
        db "  display_name=excluded.display_name,"
        db "  transport=excluded.transport,"
        db "  enabled=excluded.enabled,"
        db "  required=excluded.required,"
        db "  updated_at_ms=excluded.updated_at_ms", 0

sql_delete_stale_mcp:
        db "DELETE FROM mcp_servers WHERE updated_at_ms < ?1", 0

sql_select_mcp_count:
        db "SELECT COUNT(*) FROM mcp_servers", 0

sql_set_setting:
        db "INSERT INTO settings (key, value, updated_at_ms) VALUES (?1,?2,?3)"
        db " ON CONFLICT(key) DO UPDATE SET value=excluded.value,"
        db " updated_at_ms=excluded.updated_at_ms", 0

sql_get_setting:
        db "SELECT value FROM settings WHERE key = ?1", 0

; Adapter and policy are stored as text so the database is readable with a
; command-line client during an incident. The enum ordinals stay internal.
adapter_names:
a_responses: db "openai_responses", 0
a_chat:      db "openai_chat", 0
a_dual:      db "openai_dual", 0
policy_priority:      db "priority", 0
policy_round_robin:   db "round_robin", 0
policy_least_latency: db "least_latency", 0
transport_stdio: db "stdio", 0
transport_http:  db "streamable_http", 0
state_unknown:   db "unknown", 0

        section .data.rel.ro progbits align=8 write
        align 8
tbl_adapter_names:
        dq a_responses, a_chat, a_dual
        align 8
tbl_policy_names:
        dq policy_priority, policy_round_robin, policy_least_latency
        align 8
tbl_transport_names:
        dq transport_stdio, transport_http

        section .text

; ---------------------------------------------------------------------------
; af_repo_adapter_name(i64 adapter) -> const char * (STATIC)
; ---------------------------------------------------------------------------
        global af_repo_adapter_name
af_repo_adapter_name:
        lea     rax, [state_unknown]
        cmp     rdi, 0
        jl      .done
        cmp     rdi, 2
        ja      .done
        lea     rax, [tbl_adapter_names]
        mov     rax, [rax + rdi * 8]
.done:
        ret

        global af_repo_policy_name
af_repo_policy_name:
        lea     rax, [state_unknown]
        cmp     rdi, 0
        jl      .done
        cmp     rdi, 2
        ja      .done
        lea     rax, [tbl_policy_names]
        mov     rax, [rax + rdi * 8]
.done:
        ret

        global af_repo_transport_name
af_repo_transport_name:
        lea     rax, [state_unknown]
        cmp     rdi, 0
        jl      .done
        cmp     rdi, 1
        ja      .done
        lea     rax, [tbl_transport_names]
        mov     rax, [rax + rdi * 8]
.done:
        ret

; ---------------------------------------------------------------------------
; af_repo_guard_write(af_db *db) -> af_status
;
; Private. Honours the test-only write block from af_db_block_writes so that
; ARCHITECTURE.md 11 — a write failure degrades observability without stopping
; the daemon — can actually be tested.
; ---------------------------------------------------------------------------
af_repo_guard_write:
        AF_ENTER 0
        call    af_db_writes_blocked
        test    rax, rax
        jnz     .blocked
        AF_LEAVE_OK
.blocked:
        AF_LEAVE_ERR AF_E_DB
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_repo_sync_config(af_db *db, af_config *cfg) -> af_status
;
; Projects a published configuration snapshot into the database, in one
; transaction. Entries whose `updated_at_ms` did not advance are removed, which
; is how a provider deleted from the file stops being reported.
;
; The snapshot remains the authority for routing decisions; these rows exist so
; the control plane and the console can describe state without parsing the
; configuration file themselves.
; ---------------------------------------------------------------------------
        global af_repo_sync_config
af_repo_sync_config:
        AF_ENTER 64
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi                ; db
        mov     r12, rsi                ; config

        mov     rdi, rbx
        call    af_repo_guard_write
        test    rax, rax
        js      .done

        lea     rdi, [rsp]
        call    af_realtime_ms
        test    rax, rax
        js      .done
        mov     r13, [rsp]              ; the stamp for this sync

        mov     rdi, rbx
        call    af_db_begin
        test    rax, rax
        js      .done

        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        call    af_repo_write_providers
        test    rax, rax
        js      .rollback

        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        call    af_repo_write_routes
        test    rax, rax
        js      .rollback

        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        call    af_repo_write_mcp_servers
        test    rax, rax
        js      .rollback

        ; Order matters: route targets reference providers, so stale providers
        ; are removed only after every route has been rewritten.
        mov     rdi, rbx
        lea     rsi, [sql_delete_stale_routes]
        mov     rdx, r13
        call    af_repo_exec_one_int
        test    rax, rax
        js      .rollback
        mov     rdi, rbx
        lea     rsi, [sql_delete_stale_providers]
        mov     rdx, r13
        call    af_repo_exec_one_int
        test    rax, rax
        js      .rollback
        mov     rdi, rbx
        lea     rsi, [sql_delete_stale_mcp]
        mov     rdx, r13
        call    af_repo_exec_one_int
        test    rax, rax
        js      .rollback

        mov     rdi, rbx
        call    af_db_commit
        AF_LEAVE

.rollback:
        mov     [rsp + 8], rax
        mov     rdi, rbx
        call    af_db_rollback
        mov     rax, [rsp + 8]
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_exec_one_int(af_db *db, const char *sql, i64 value) -> af_status
;
; Private. Runs a single-parameter statement to completion.
; ---------------------------------------------------------------------------
af_repo_exec_one_int:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rdx
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]
        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, r12
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .ok
        test    rax, rax
        js      .finalize
.ok:
        xor     eax, eax
.finalize:
        mov     [rsp + 8], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 8]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_write_providers(af_db *db, af_config *cfg, i64 stamp) -> af_status
; ---------------------------------------------------------------------------
        global af_repo_write_providers
af_repo_write_providers:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi
        mov     [rsp + 16], rdx         ; stamp

        mov     rdi, rbx
        lea     rsi, [sql_upsert_provider]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]              ; provider upsert

        mov     rdi, rbx
        lea     rsi, [sql_upsert_health]
        lea     rdx, [rsp + 8]
        call    af_db_prepare
        test    rax, rax
        js      .finalize_provider
        mov     r14, [rsp + 8]          ; health upsert

        xor     r15, r15
.loop:
        cmp     r15, [r12 + CFG_PROVIDER_COUNT]
        jae     .finished
        mov     rax, r15
        imul    rax, rax, PRV_SIZE
        add     rax, [r12 + CFG_PROVIDERS]
        mov     [rsp + 24], rax         ; provider record

        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_reset
        test    rax, rax
        js      .finalize_both

        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, [rcx + PRV_ID]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize_both
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 2
        mov     rdx, [rcx + PRV_DISPLAY_NAME]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize_both
        mov     rcx, [rsp + 24]
        mov     rdi, [rcx + PRV_ADAPTER]
        call    af_repo_adapter_name
        mov     rdx, rax
        mov     rdi, r13
        mov     rsi, 3
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize_both
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 4
        mov     rdx, [rcx + PRV_BASE_URL]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize_both
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 5
        mov     rdx, [rcx + PRV_ENABLED]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize_both
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 6
        mov     rdx, [rcx + PRV_REQUIRED]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize_both
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 7
        mov     rdx, [rcx + PRV_MAX_CONCURRENCY]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize_both
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 8
        mov     rdx, [rcx + PRV_CAPABILITIES]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize_both
        mov     rdi, r13
        mov     rsi, 9
        mov     rdx, [rsp + 16]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize_both

        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .provider_written
        test    rax, rax
        js      .finalize_both
.provider_written:

        ; A health row is created once and then left alone: it carries live
        ; state that a configuration reload has no business resetting.
        mov     rdi, rbx
        mov     rsi, r14
        call    af_db_reset
        test    rax, rax
        js      .finalize_both
        mov     rcx, [rsp + 24]
        mov     rdi, r14
        mov     rsi, 1
        mov     rdx, [rcx + PRV_ID]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize_both
        mov     rdi, r14
        mov     rsi, 2
        lea     rdx, [state_unknown]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize_both
        mov     rdi, r14
        mov     rsi, 3
        mov     rdx, [rsp + 16]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize_both
        mov     rdi, rbx
        mov     rsi, r14
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .health_written
        test    rax, rax
        js      .finalize_both
.health_written:
        inc     r15
        jmp     .loop

.finished:
        xor     eax, eax
.finalize_both:
        mov     [rsp + 32], rax
        mov     rdi, r14
        call    af_db_finalize
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 32]
        AF_LEAVE
.finalize_provider:
        mov     [rsp + 32], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 32]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_write_routes(af_db *db, af_config *cfg, i64 stamp) -> af_status
;
; Targets are deleted and reinserted rather than merged: their `position` is the
; configured order, and a merge would have to reason about which of two orderings
; was intended.
; ---------------------------------------------------------------------------
        global af_repo_write_routes
af_repo_write_routes:
        AF_ENTER 96
        mov     rbx, rdi
        mov     r12, rsi
        mov     [rsp + 16], rdx

        mov     rdi, rbx
        lea     rsi, [sql_upsert_route]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]

        xor     r15, r15
.loop:
        cmp     r15, [r12 + CFG_ROUTE_COUNT]
        jae     .finished
        mov     rax, r15
        imul    rax, rax, RTE_SIZE
        add     rax, [r12 + CFG_ROUTES]
        mov     [rsp + 24], rax

        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_reset
        test    rax, rax
        js      .finalize

        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, [rcx + RTE_ID]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 2
        mov     rdx, [rcx + RTE_MODEL_ALIAS]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 3
        mov     rdx, [rcx + RTE_ENABLED]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 4
        mov     rdx, [rcx + RTE_ENDPOINT_FAMILIES]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rcx, [rsp + 24]
        mov     rdi, [rcx + RTE_POLICY]
        call    af_repo_policy_name
        mov     rdx, rax
        mov     rdi, r13
        mov     rsi, 5
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 6
        mov     rdx, [rcx + RTE_FB_ENABLED]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 7
        mov     rdx, [rcx + RTE_FB_MAX_ATTEMPTS]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 8
        mov     rdx, [rcx + RTE_FB_RETRYABLE]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 9
        mov     rdx, [rsp + 16]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize

        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .route_written
        test    rax, rax
        js      .finalize
.route_written:

        mov     rdi, rbx
        mov     rsi, [rsp + 24]
        call    af_repo_write_route_targets
        test    rax, rax
        js      .finalize

        inc     r15
        jmp     .loop
.finished:
        xor     eax, eax
.finalize:
        mov     [rsp + 32], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 32]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_write_route_targets(af_db *db, af_cfg_route *route) -> af_status
; ---------------------------------------------------------------------------
        global af_repo_write_route_targets
af_repo_write_route_targets:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi

        mov     rdi, rbx
        lea     rsi, [sql_delete_route_targets]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]
        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, [r12 + RTE_ID]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize_delete
        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .deleted
        test    rax, rax
        js      .finalize_delete
.deleted:
        mov     rdi, r13
        call    af_db_finalize

        mov     rdi, rbx
        lea     rsi, [sql_insert_route_target]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]

        xor     r14, r14
.loop:
        cmp     r14, [r12 + RTE_TARGET_COUNT]
        jae     .finished
        mov     rax, r14
        imul    rax, rax, RT_SIZE
        add     rax, [r12 + RTE_TARGETS]
        mov     [rsp + 8], rax

        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_reset
        test    rax, rax
        js      .finalize_insert

        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, [r12 + RTE_ID]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize_insert
        mov     rdi, r13
        mov     rsi, 2
        mov     rdx, r14
        call    af_db_bind_int
        test    rax, rax
        js      .finalize_insert
        mov     rcx, [rsp + 8]
        mov     rdi, r13
        mov     rsi, 3
        mov     rdx, [rcx + RT_PROVIDER_ID]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize_insert
        mov     rcx, [rsp + 8]
        mov     rdi, r13
        mov     rsi, 4
        mov     rdx, [rcx + RT_UPSTREAM_MODEL]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize_insert
        mov     rcx, [rsp + 8]
        mov     rdi, r13
        mov     rsi, 5
        mov     rdx, [rcx + RT_PRIORITY]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize_insert
        mov     rcx, [rsp + 8]
        mov     rdi, r13
        mov     rsi, 6
        mov     rdx, [rcx + RT_WEIGHT]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize_insert

        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .target_written
        test    rax, rax
        js      .finalize_insert
.target_written:
        inc     r14
        jmp     .loop
.finished:
        xor     eax, eax
.finalize_insert:
        mov     [rsp + 16], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 16]
        AF_LEAVE
.finalize_delete:
        mov     [rsp + 16], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 16]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_write_mcp_servers(af_db *db, af_config *cfg, i64 stamp) -> af_status
; ---------------------------------------------------------------------------
        global af_repo_write_mcp_servers
af_repo_write_mcp_servers:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi
        mov     [rsp + 16], rdx

        mov     rdi, rbx
        lea     rsi, [sql_upsert_mcp]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]

        xor     r15, r15
.loop:
        cmp     r15, [r12 + CFG_MCP_COUNT]
        jae     .finished
        mov     rax, r15
        imul    rax, rax, MCP_SIZE
        add     rax, [r12 + CFG_MCP_SERVERS]
        mov     [rsp + 24], rax

        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_reset
        test    rax, rax
        js      .finalize

        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, [rcx + MCP_ID]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 2
        mov     rdx, [rcx + MCP_DISPLAY_NAME]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rcx, [rsp + 24]
        mov     rdi, [rcx + MCP_TRANSPORT]
        call    af_repo_transport_name
        mov     rdx, rax
        mov     rdi, r13
        mov     rsi, 3
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 4
        mov     rdx, [rcx + MCP_ENABLED]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rcx, [rsp + 24]
        mov     rdi, r13
        mov     rsi, 5
        mov     rdx, [rcx + MCP_REQUIRED]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 6
        mov     rdx, [rsp + 16]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize

        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .written
        test    rax, rax
        js      .finalize
.written:
        inc     r15
        jmp     .loop
.finished:
        xor     eax, eax
.finalize:
        mov     [rsp + 32], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 32]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_count(af_db *db, const char *sql, i64 *out) -> af_status
;
; Private helper for the several COUNT(*) statements above.
; ---------------------------------------------------------------------------
        global af_repo_count
af_repo_count:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r14, rdx
        mov     qword [r14], 0
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]
        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        xor     esi, esi
        call    af_db_column_int
        mov     [r14], rax
        xor     eax, eax
.finalize:
        mov     [rsp + 8], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 8]
        AF_LEAVE
.done:
        AF_LEAVE

        global af_repo_provider_count
af_repo_provider_count:
        AF_ENTER 0
        mov     rdx, rsi
        lea     rsi, [sql_select_provider_count]
        call    af_repo_count
        AF_LEAVE

        global af_repo_route_count
af_repo_route_count:
        AF_ENTER 0
        mov     rdx, rsi
        lea     rsi, [sql_select_route_count]
        call    af_repo_count
        AF_LEAVE

        global af_repo_mcp_count
af_repo_mcp_count:
        AF_ENTER 0
        mov     rdx, rsi
        lea     rsi, [sql_select_mcp_count]
        call    af_repo_count
        AF_LEAVE

        global af_repo_request_count
af_repo_request_count:
        AF_ENTER 0
        mov     rdx, rsi
        lea     rsi, [sql_select_request_count]
        call    af_repo_count
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_route_target_count(af_db *db, const char *route_id, i64 *out)
;   -> af_status
; ---------------------------------------------------------------------------
        global af_repo_route_target_count
af_repo_route_target_count:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r14, rdx
        mov     qword [r14], 0
        mov     rdi, rbx
        lea     rsi, [sql_select_target_count]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]
        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, r12
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        xor     esi, esi
        call    af_db_column_int
        mov     [r14], rax
        xor     eax, eax
.finalize:
        mov     [rsp + 8], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 8]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_set_operator_disabled(af_db *db, const char *provider_id,
;                               i64 disabled) -> af_status
;
; The operator's own enable/disable decision. It lives in provider_health rather
; than in the configuration because it is state the operator sets at runtime,
; and a configuration reload must not silently re-enable a provider somebody
; turned off during an incident.
; ---------------------------------------------------------------------------
        global af_repo_set_operator_disabled
af_repo_set_operator_disabled:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, rbx
        call    af_repo_guard_write
        test    rax, rax
        js      .done

        lea     rdi, [rsp + 16]
        call    af_realtime_ms
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [sql_set_operator_disabled]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r14, [rsp]
        mov     rdi, r14
        mov     rsi, 1
        mov     rdx, r12
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, r14
        mov     rsi, 2
        mov     rdx, r13
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r14
        mov     rsi, 3
        mov     rdx, [rsp + 16]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, rbx
        mov     rsi, r14
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .ok
        test    rax, rax
        js      .finalize
.ok:
        xor     eax, eax
.finalize:
        mov     [rsp + 24], rax
        mov     rdi, r14
        call    af_db_finalize
        mov     rax, [rsp + 24]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_get_operator_disabled(af_db *db, const char *provider_id, i64 *out)
;   -> af_status
;
; AF_E_NOTFOUND when the provider has no health row.
; ---------------------------------------------------------------------------
        global af_repo_get_operator_disabled
af_repo_get_operator_disabled:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r14, rdx
        mov     qword [r14], 0
        mov     rdi, rbx
        lea     rsi, [sql_select_operator_disabled]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]
        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, r12
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .absent
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        xor     esi, esi
        call    af_db_column_int
        mov     [r14], rax
        xor     eax, eax
        jmp     .finalize
.absent:
        mov     rax, AF_E_NOTFOUND
.finalize:
        mov     [rsp + 8], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 8]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_setting_set(af_db *db, const char *key, const char *value)
;   -> af_status
; ---------------------------------------------------------------------------
        global af_repo_setting_set
af_repo_setting_set:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, rbx
        call    af_repo_guard_write
        test    rax, rax
        js      .done

        lea     rdi, [rsp + 16]
        call    af_realtime_ms
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [sql_set_setting]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r14, [rsp]
        mov     rdi, r14
        mov     rsi, 1
        mov     rdx, r12
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, r14
        mov     rsi, 2
        mov     rdx, r13
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, r14
        mov     rsi, 3
        mov     rdx, [rsp + 16]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, rbx
        mov     rsi, r14
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .ok
        test    rax, rax
        js      .finalize
.ok:
        xor     eax, eax
.finalize:
        mov     [rsp + 24], rax
        mov     rdi, r14
        call    af_db_finalize
        mov     rax, [rsp + 24]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_setting_get(af_db *db, const char *key, af_buffer *out)
;   -> af_status
;
; AF_E_NOTFOUND when the key is absent. The value is appended to `out` because
; the column text is only valid until the next step.
; ---------------------------------------------------------------------------
        global af_repo_setting_get
af_repo_setting_get:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     r15, rdx
        mov     rdi, rbx
        lea     rsi, [sql_get_setting]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]
        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, r12
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .absent
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        xor     esi, esi
        lea     rdx, [rsp + 8]
        call    af_db_column_text
        mov     r14, rax
        test    r14, r14
        jz      .absent
        mov     rdi, r15
        mov     rsi, r14
        mov     rdx, [rsp + 8]
        call    af_repo_append
        jmp     .finalize
.absent:
        mov     rax, AF_E_NOTFOUND
.finalize:
        mov     [rsp + 16], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 16]
        AF_LEAVE
.done:
        AF_LEAVE

; A thin forward so this file does not need to import the buffer module's whole
; surface just to copy one column out.
        extern af_buf_append
af_repo_append:
        AF_ENTER 0
        call    af_buf_append
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_record_request(af_db *db, const char *id, i64 received_at_ms,
;                        const char *endpoint, const char *model_alias,
;                        const char *route_id, const void *outcome)
;   -> af_status
;
; `outcome` points at six consecutive words: streaming, committed, status_code,
; attempts, duration_ms, and a client reference pointer. Passing them as a block
; keeps the function inside the six-register argument convention rather than
; spilling half of them to the stack at every call site.
;
; No prompt and no response body is written. docs/CONFIGURATION.md 6 makes
; payload persistence opt-in, and even then Authorization and secret headers stay
; out; this path never has them to begin with.
; ---------------------------------------------------------------------------
        global af_repo_record_request
af_repo_record_request:
        AF_ENTER 64
        mov     rbx, rdi                ; db
        mov     [rsp + 16], rsi         ; id
        mov     [rsp + 24], rdx         ; received_at_ms
        mov     [rsp + 32], rcx         ; endpoint
        mov     [rsp + 40], r8          ; model_alias
        mov     [rsp + 48], r9          ; route_id
        mov     r15, [rbp + 16]         ; outcome block (first stack argument)

        mov     rdi, rbx
        call    af_repo_guard_write
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [sql_insert_request]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]

        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, [rsp + 16]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 2
        mov     rdx, [rsp + 24]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 3
        mov     rdx, [rsp + 32]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 4
        mov     rdx, [rsp + 40]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 5
        mov     rdx, [rsp + 48]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize

        ; outcome[0..5]
        mov     rdi, r13
        mov     rsi, 6
        mov     rdx, [r15]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 7
        mov     rdx, [r15 + 8]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 8
        mov     rdx, [r15 + 16]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 9
        mov     rdx, [r15 + 24]         ; error class, or NULL
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 10
        mov     rdx, [r15 + 32]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 11
        mov     rdx, [r15 + 40]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 12
        mov     rdx, [r15 + 48]         ; client reference, or NULL
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize

        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .ok
        test    rax, rax
        js      .finalize
.ok:
        xor     eax, eax
.finalize:
        mov     [rsp + 56], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 56]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_record_attempt(af_db *db, const char *request_id, i64 attempt_no,
;                        const char *provider_id, const char *upstream_model,
;                        const void *timing) -> af_status
;
; `timing` points at five words: started_at_ms, finished_at_ms, status_code,
; error_class pointer, retryable.
;
; SECURITY_MODEL.md 10: each attempt gets its own audit record. That is what
; makes a fallback-after-commit defect provable after the fact rather than only
; observable live.
; ---------------------------------------------------------------------------
        global af_repo_record_attempt
af_repo_record_attempt:
        AF_ENTER 64
        mov     rbx, rdi
        mov     [rsp + 16], rsi         ; request id
        mov     [rsp + 24], rdx         ; attempt number
        mov     [rsp + 32], rcx         ; provider id
        mov     [rsp + 40], r8          ; upstream model
        mov     r15, r9                 ; timing block

        mov     rdi, rbx
        call    af_repo_guard_write
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [sql_insert_attempt]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]

        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, [rsp + 16]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 2
        mov     rdx, [rsp + 24]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 3
        mov     rdx, [rsp + 32]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 4
        mov     rdx, [rsp + 40]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 5
        mov     rdx, [r15]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 6
        mov     rdx, [r15 + 8]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 7
        mov     rdx, [r15 + 16]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 8
        mov     rdx, [r15 + 24]
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        mov     rsi, 9
        mov     rdx, [r15 + 32]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize

        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .ok
        test    rax, rax
        js      .finalize
.ok:
        xor     eax, eax
.finalize:
        mov     [rsp + 56], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 56]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_attempt_count(af_db *db, const char *request_id, i64 *out)
;   -> af_status
;
; The invariant test in TEST_STRATEGY.md 3 reads exactly this: after a provider
; sends one event and then fails, the attempt count must still be one.
; ---------------------------------------------------------------------------
        global af_repo_attempt_count
af_repo_attempt_count:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r14, rdx
        mov     qword [r14], 0
        mov     rdi, rbx
        lea     rsi, [sql_select_attempt_count]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]
        mov     rdi, r13
        mov     rsi, 1
        mov     rdx, r12
        call    af_db_bind_cstr
        test    rax, rax
        js      .finalize
        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        test    rax, rax
        js      .finalize
        mov     rdi, r13
        xor     esi, esi
        call    af_db_column_int
        mov     [r14], rax
        xor     eax, eax
.finalize:
        mov     [rsp + 8], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 8]
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_repo_prune_requests(af_db *db, i64 older_than_ms) -> af_status
;
; The retention policy from docs/CONFIGURATION.md 6. Attempts follow through the
; foreign key cascade.
; ---------------------------------------------------------------------------
        global af_repo_prune_requests
af_repo_prune_requests:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        call    af_repo_guard_write
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [sql_prune_requests]
        mov     rdx, r12
        call    af_repo_exec_one_int
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; Statement accessors for the control plane's list methods. Returning the
; prepared statement lets the caller stream rows straight into a JSON writer
; without materialising them.
; ---------------------------------------------------------------------------
        global af_repo_providers_query
af_repo_providers_query:
        AF_ENTER 0
        mov     rdx, rsi
        lea     rsi, [sql_select_providers]
        call    af_db_prepare
        AF_LEAVE

        global af_repo_provider_query
af_repo_provider_query:
        AF_ENTER 0
        mov     rdx, rsi
        lea     rsi, [sql_select_provider]
        call    af_db_prepare
        AF_LEAVE

        global af_repo_route_query
af_repo_route_query:
        AF_ENTER 0
        mov     rdx, rsi
        lea     rsi, [sql_select_route]
        call    af_db_prepare
        AF_LEAVE

        global af_repo_request_query
af_repo_request_query:
        AF_ENTER 0
        mov     rdx, rsi
        lea     rsi, [sql_select_request]
        call    af_db_prepare
        AF_LEAVE

        global af_repo_requests_page_query
af_repo_requests_page_query:
        AF_ENTER 0
        mov     rdx, rsi
        lea     rsi, [sql_select_requests_page]
        call    af_db_prepare
        AF_LEAVE
