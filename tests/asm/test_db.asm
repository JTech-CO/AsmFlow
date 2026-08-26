; AsmFlow — storage layer (HARNESS.md M4 DoD 1-3, 8).
;
; The rollback test is the important one. A migration that fails part-way and
; leaves the version row written would produce a database that claims a schema
; it does not have, and every later run would trust that claim.

        bits 64
        default rel

%include "asmflow.inc"
%include "config.inc"
%include "db.inc"
%include "test.inc"

%define AF_TEST_TAG db

        extern af_db_open
        extern af_db_close
        extern af_db_exec
        extern af_db_enable_wal
        extern af_db_prepare
        extern af_db_finalize
        extern af_db_step
        extern af_db_reset
        extern af_db_bind_int
        extern af_db_bind_cstr
        extern af_db_column_int
        extern af_db_column_text
        extern af_db_begin
        extern af_db_commit
        extern af_db_rollback
        extern af_db_in_transaction
        extern af_db_is_open
        extern af_db_integrity_check
        extern af_db_block_writes
        extern af_db_status_from_code
        extern af_db_struct_size

        extern af_migrations_apply
        extern af_migrations_current_version
        extern af_migrations_target_version
        extern af_migrations_inject_failure_at
        extern af_migrations_statement_count

        extern af_repo_sync_config
        extern af_repo_provider_count
        extern af_repo_route_count
        extern af_repo_mcp_count
        extern af_repo_request_count
        extern af_repo_route_target_count
        extern af_repo_set_operator_disabled
        extern af_repo_get_operator_disabled
        extern af_repo_setting_set
        extern af_repo_setting_get
        extern af_repo_record_request
        extern af_repo_record_attempt
        extern af_repo_attempt_count
        extern af_repo_prune_requests
        extern af_repo_adapter_name

        extern af_config_parse
        extern af_config_release
        extern af_cfg_err_init
        extern af_cfg_err_free

        extern af_buf_init
        extern af_buf_free
        extern af_buf_data
        extern af_buf_len
        extern af_sys_unlink
        extern af_mem_eq
        extern af_cstr_len

        extern af_sqlitec_result_codes
        extern af_sqlitec_open_flags
        extern af_sqlitec_column_types

        section .rodata
db_path:  db "/tmp/asmflow-test-storage.db", 0
db_wal:   db "/tmp/asmflow-test-storage.db-wal", 0
db_shm:   db "/tmp/asmflow-test-storage.db-shm", 0

sql_count_tables:
        db "SELECT COUNT(*) FROM sqlite_schema WHERE type='table'", 0
sql_probe_providers:
        db "SELECT COUNT(*) FROM providers", 0
sql_select_provider_row:
        db "SELECT display_name, adapter, base_url, enabled, max_concurrency,"
        db " capabilities FROM providers WHERE id = ?1", 0
sql_select_target_row:
        db "SELECT provider_id, upstream_model, priority, weight"
        db " FROM route_targets WHERE route_id = ?1 AND position = 0", 0
sql_bad:
        db "SELECT * FROM a_table_that_does_not_exist", 0

id_ollama:   db "local-ollama", 0
id_route:    db "general-route", 0
exp_display: db "Local"
exp_display_len equ 5
exp_adapter: db "openai_chat"
exp_adapter_len equ 11
exp_url:     db "http://127.0.0.1:11434/v1"
exp_url_len  equ 25
exp_model:   db "qwen"
exp_model_len equ 4

setting_key: db "config_hash", 0
setting_val: db "abc123", 0

req_id:      db "01JTESTREQUEST0000000000AA", 0
req_endpoint: db "/v1/chat/completions", 0
req_alias:   db "general", 0

; A minimal valid configuration, embedded so the storage tests do not depend on
; the filesystem for their input either.
cfg_min:
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
        db `"targets":[{"provider_id":"local-ollama","upstream_model":"qwen","priority":10,"weight":1}]}],`
        db `"mcp_servers":[]}`
cfg_min_len equ $ - cfg_min

        section .text

; Private: remove the test database and its WAL companions so every test starts
; from an empty file rather than inheriting the previous one's schema.
af_test_db_unlink:
        AF_ENTER 0
        lea     rdi, [db_path]
        call    af_sys_unlink
        lea     rdi, [db_wal]
        call    af_sys_unlink
        lea     rdi, [db_shm]
        call    af_sys_unlink
        AF_LEAVE

AF_TEST "db/constants_match_the_linked_sqlite", 256
        lea     rdi, [rsp]
        call    af_sqlitec_result_codes wrt ..plt
        AF_CHECK_EQ qword [rsp +  0], SQLITE_OK,         "SQLITE_OK drifted"
        AF_CHECK_EQ qword [rsp +  8], SQLITE_ERROR,      "SQLITE_ERROR drifted"
        AF_CHECK_EQ qword [rsp + 16], SQLITE_BUSY,       "SQLITE_BUSY drifted"
        AF_CHECK_EQ qword [rsp + 24], SQLITE_LOCKED,     "SQLITE_LOCKED drifted"
        AF_CHECK_EQ qword [rsp + 32], SQLITE_READONLY,   "SQLITE_READONLY drifted"
        AF_CHECK_EQ qword [rsp + 40], SQLITE_IOERR,      "SQLITE_IOERR drifted"
        AF_CHECK_EQ qword [rsp + 48], SQLITE_CORRUPT,    "SQLITE_CORRUPT drifted"
        AF_CHECK_EQ qword [rsp + 56], SQLITE_FULL,       "SQLITE_FULL drifted"
        AF_CHECK_EQ qword [rsp + 64], SQLITE_CANTOPEN,   "SQLITE_CANTOPEN drifted"
        AF_CHECK_EQ qword [rsp + 72], SQLITE_CONSTRAINT, "SQLITE_CONSTRAINT drifted"
        AF_CHECK_EQ qword [rsp + 80], SQLITE_MISUSE,     "SQLITE_MISUSE drifted"
        AF_CHECK_EQ qword [rsp + 88], SQLITE_NOTADB,     "SQLITE_NOTADB drifted"
        AF_CHECK_EQ qword [rsp + 96], SQLITE_ROW,        "SQLITE_ROW drifted"
        AF_CHECK_EQ qword [rsp + 104], SQLITE_DONE,      "SQLITE_DONE drifted"

        lea     rdi, [rsp]
        call    af_sqlitec_open_flags wrt ..plt
        AF_CHECK_EQ qword [rsp +  0], SQLITE_OPEN_READONLY,  "READONLY flag drifted"
        AF_CHECK_EQ qword [rsp +  8], SQLITE_OPEN_READWRITE, "READWRITE flag drifted"
        AF_CHECK_EQ qword [rsp + 16], SQLITE_OPEN_CREATE,    "CREATE flag drifted"
        AF_CHECK_EQ qword [rsp + 24], SQLITE_OPEN_NOMUTEX,   "NOMUTEX flag drifted"

        lea     rdi, [rsp]
        call    af_sqlitec_column_types wrt ..plt
        AF_CHECK_EQ qword [rsp +  0], SQLITE_INTEGER, "INTEGER type drifted"
        AF_CHECK_EQ qword [rsp + 16], SQLITE_TEXT,    "TEXT type drifted"
        AF_CHECK_EQ qword [rsp + 32], SQLITE_NULL,    "NULL type drifted"
AF_TEST_END

AF_TEST "db/result_code_classification"
        mov     rdi, SQLITE_OK
        call    af_db_status_from_code
        AF_CHECK_OK rax, "OK should map to success"
        mov     rdi, SQLITE_ROW
        call    af_db_status_from_code
        AF_CHECK_OK rax, "ROW should map to success"
        mov     rdi, SQLITE_BUSY
        call    af_db_status_from_code
        AF_CHECK_ERR rax, AF_E_DB_BUSY, "BUSY must be distinguishable"
        mov     rdi, SQLITE_LOCKED
        call    af_db_status_from_code
        AF_CHECK_ERR rax, AF_E_DB_BUSY, "LOCKED is also a retry condition"
        mov     rdi, SQLITE_READONLY
        call    af_db_status_from_code
        AF_CHECK_ERR rax, AF_E_DB_READONLY, "READONLY must be distinguishable"
        mov     rdi, SQLITE_CORRUPT
        call    af_db_status_from_code
        AF_CHECK_ERR rax, AF_E_DB_SCHEMA, "CORRUPT must not look retryable"
        mov     rdi, SQLITE_CONSTRAINT
        call    af_db_status_from_code
        AF_CHECK_ERR rax, AF_E_DB, "a constraint violation is a generic failure"
AF_TEST_END

AF_TEST "db/open_migrate_and_report_the_version", 128
        call    af_test_db_unlink
        lea     rbx, [rsp]              ; af_db
        mov     rdi, rbx
        lea     rsi, [db_path]
        mov     rdx, 3000
        call    af_db_open
        AF_CHECK_OK rax, "opening a fresh database failed"
        mov     rdi, rbx
        call    af_db_is_open
        AF_CHECK_EQ rax, 1, "the handle should report open"

        mov     rdi, rbx
        lea     rsi, [rsp + 64]
        call    af_migrations_current_version
        AF_CHECK_OK rax, "reading the version of an empty database failed"
        AF_CHECK_EQ qword [rsp + 64], 0, "an empty database is at version zero"

        mov     rdi, rbx
        call    af_migrations_apply
        AF_CHECK_OK rax, "applying migrations failed"

        mov     rdi, rbx
        lea     rsi, [rsp + 64]
        call    af_migrations_current_version
        AF_CHECK_OK rax, "reading the version after migration failed"
        call    af_migrations_target_version
        mov     r12, rax
        AF_CHECK_EQ qword [rsp + 64], r12, "the version should match the target"

        ; Ten tables plus one index; sqlite_schema counts only the tables here.
        mov     rdi, rbx
        lea     rsi, [sql_count_tables]
        lea     rdx, [rsp + 72]
        call    af_db_prepare
        AF_CHECK_OK rax, "counting tables failed"
        mov     r13, [rsp + 72]
        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        AF_CHECK_OK rax, "stepping the count failed"
        mov     rdi, r13
        xor     esi, esi
        call    af_db_column_int
        AF_CHECK_EQ rax, 10, "the schema should define ten tables"
        mov     rdi, r13
        call    af_db_finalize

        ; Re-applying is a no-op, not an error.
        mov     rdi, rbx
        call    af_migrations_apply
        AF_CHECK_OK rax, "re-applying migrations should be a no-op"

        mov     rdi, rbx
        call    af_db_enable_wal
        AF_CHECK_OK rax, "enabling WAL failed"

        mov     rdi, rbx
        call    af_db_integrity_check
        AF_CHECK_OK rax, "the integrity check should pass"

        mov     rdi, rbx
        call    af_db_close
        call    af_test_db_unlink
AF_TEST_END

AF_TEST "db/migration_failure_rolls_back_completely", 128
        ; HARNESS.md M4 DoD 2. Inject a failure at every statement of the
        ; migration in turn; each time, the database must end at version zero
        ; with none of the tables present.
        call    af_migrations_statement_count_probe
        mov     r15, rax                ; statement count

        xor     r14, r14
.next_injection:
        cmp     r14, r15
        jae     .all_injections_done

        call    af_test_db_unlink
        lea     rbx, [rsp]
        mov     rdi, rbx
        lea     rsi, [db_path]
        mov     rdx, 3000
        call    af_db_open
        AF_CHECK_OK rax, "opening for the injection round failed"

        mov     rdi, r14
        call    af_migrations_inject_failure_at
        mov     rdi, rbx
        call    af_migrations_apply
        AF_CHECK_TRUE rax, "an injected failure must be reported"
        mov     rdi, -1
        call    af_migrations_inject_failure_at

        ; The version must be unchanged.
        mov     rdi, rbx
        lea     rsi, [rsp + 64]
        call    af_migrations_current_version
        AF_CHECK_EQ qword [rsp + 64], 0, "a rolled-back migration must leave version zero"

        ; And no transaction may be left open, or the next writer would block.
        mov     rdi, rbx
        call    af_db_in_transaction
        AF_CHECK_EQ rax, 0, "the transaction must have been rolled back"

        ; The `providers` table must not exist, whichever statement failed.
        mov     rdi, rbx
        lea     rsi, [sql_probe_providers]
        lea     rdx, [rsp + 72]
        call    af_db_prepare
        AF_CHECK_TRUE rax, "no table should have survived the rollback"

        mov     rdi, rbx
        call    af_db_close
        inc     r14
        jmp     .next_injection

.all_injections_done:
        AF_CHECK_TRUE r15, "the migration should have statements to inject into"
        call    af_test_db_unlink
AF_TEST_END

; Private: the statement count of migration 1.
af_migrations_statement_count_probe:
        AF_ENTER 0
        mov     rdi, 1
        call    af_migrations_statement_count
        AF_LEAVE

AF_TEST "db/config_round_trips_through_the_repository", 256
        ; HARNESS.md M4 DoD 3: what comes back matches the domain model.
        call    af_test_db_unlink
        lea     rbx, [rsp]              ; af_db
        lea     r12, [rsp + 64]         ; af_cfg_error
        mov     rdi, rbx
        lea     rsi, [db_path]
        mov     rdx, 3000
        call    af_db_open
        AF_CHECK_OK rax, "open failed"
        mov     rdi, rbx
        call    af_migrations_apply
        AF_CHECK_OK rax, "migrations failed"

        mov     rdi, r12
        call    af_cfg_err_init
        lea     rdi, [cfg_min]
        mov     rsi, cfg_min_len
        mov     rdx, r12
        lea     rcx, [rsp + 152]
        call    af_config_parse
        AF_CHECK_OK rax, "the embedded configuration should parse"
        mov     r13, [rsp + 152]

        mov     rdi, rbx
        mov     rsi, r13
        call    af_repo_sync_config
        AF_CHECK_OK rax, "syncing the configuration failed"

        mov     rdi, rbx
        lea     rsi, [rsp + 160]
        call    af_repo_provider_count
        AF_CHECK_OK rax, "counting providers failed"
        AF_CHECK_EQ qword [rsp + 160], 1, "one provider should have been written"

        mov     rdi, rbx
        lea     rsi, [rsp + 160]
        call    af_repo_route_count
        AF_CHECK_OK rax, "counting routes failed"
        AF_CHECK_EQ qword [rsp + 160], 1, "one route should have been written"

        mov     rdi, rbx
        lea     rsi, [id_route]
        lea     rdx, [rsp + 160]
        call    af_repo_route_target_count
        AF_CHECK_OK rax, "counting route targets failed"
        AF_CHECK_EQ qword [rsp + 160], 1, "one target should have been written"

        ; Read the provider row back field by field.
        mov     rdi, rbx
        lea     rsi, [sql_select_provider_row]
        lea     rdx, [rsp + 168]
        call    af_db_prepare
        AF_CHECK_OK rax, "preparing the provider read failed"
        mov     r14, [rsp + 168]
        mov     rdi, r14
        mov     rsi, 1
        lea     rdx, [id_ollama]
        call    af_db_bind_cstr
        AF_CHECK_OK rax, "binding the provider id failed"
        mov     rdi, rbx
        mov     rsi, r14
        call    af_db_step
        AF_CHECK_OK rax, "the provider row should exist"

        mov     rdi, r14
        xor     esi, esi
        lea     rdx, [rsp + 176]
        call    af_db_column_text
        mov     r15, rax
        AF_CHECK_EQ qword [rsp + 176], exp_display_len, "display_name length is wrong"
        mov     rdi, r15
        lea     rsi, [exp_display]
        mov     rdx, exp_display_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "display_name did not round-trip"

        mov     rdi, r14
        mov     rsi, 1
        lea     rdx, [rsp + 176]
        call    af_db_column_text
        mov     r15, rax
        mov     rdi, r15
        lea     rsi, [exp_adapter]
        mov     rdx, exp_adapter_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "adapter did not round-trip"

        mov     rdi, r14
        mov     rsi, 2
        lea     rdx, [rsp + 176]
        call    af_db_column_text
        mov     r15, rax
        AF_CHECK_EQ qword [rsp + 176], exp_url_len, "base_url length is wrong"
        mov     rdi, r15
        lea     rsi, [exp_url]
        mov     rdx, exp_url_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "base_url did not round-trip"

        mov     rdi, r14
        mov     rsi, 3
        call    af_db_column_int
        AF_CHECK_EQ rax, 1, "enabled did not round-trip"
        mov     rdi, r14
        mov     rsi, 4
        call    af_db_column_int
        AF_CHECK_EQ rax, 4, "max_concurrency did not round-trip"
        mov     rdi, r14
        mov     rsi, 5
        call    af_db_column_int
        mov     r15, AF_CAP_CHAT_COMPLETIONS | AF_CAP_STREAMING | AF_CAP_TOOLS
        AF_CHECK_EQ rax, r15, "the capability bitmask did not round-trip"
        mov     rdi, r14
        call    af_db_finalize

        ; And the route target, whose position carries the configured order.
        mov     rdi, rbx
        lea     rsi, [sql_select_target_row]
        lea     rdx, [rsp + 168]
        call    af_db_prepare
        AF_CHECK_OK rax, "preparing the target read failed"
        mov     r14, [rsp + 168]
        mov     rdi, r14
        mov     rsi, 1
        lea     rdx, [id_route]
        call    af_db_bind_cstr
        mov     rdi, rbx
        mov     rsi, r14
        call    af_db_step
        AF_CHECK_OK rax, "the target row should exist"
        mov     rdi, r14
        mov     rsi, 1
        lea     rdx, [rsp + 176]
        call    af_db_column_text
        mov     r15, rax
        mov     rdi, r15
        lea     rsi, [exp_model]
        mov     rdx, exp_model_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "upstream_model did not round-trip"
        mov     rdi, r14
        mov     rsi, 2
        call    af_db_column_int
        AF_CHECK_EQ rax, 10, "priority did not round-trip"
        mov     rdi, r14
        call    af_db_finalize

        ; Syncing the same snapshot twice must be idempotent.
        mov     rdi, rbx
        mov     rsi, r13
        call    af_repo_sync_config
        AF_CHECK_OK rax, "a second sync failed"
        mov     rdi, rbx
        lea     rsi, [rsp + 160]
        call    af_repo_provider_count
        AF_CHECK_EQ qword [rsp + 160], 1, "a second sync must not duplicate rows"

        mov     rdi, r13
        call    af_config_release
        mov     rdi, r12
        call    af_cfg_err_free
        mov     rdi, rbx
        call    af_db_close
        call    af_test_db_unlink
AF_TEST_END

AF_TEST "db/operator_disable_survives_a_config_sync", 256
        ; A provider an operator turned off during an incident must not come
        ; back on because the configuration was reloaded.
        call    af_test_db_unlink
        lea     rbx, [rsp]
        lea     r12, [rsp + 64]
        mov     rdi, rbx
        lea     rsi, [db_path]
        mov     rdx, 3000
        call    af_db_open
        mov     rdi, rbx
        call    af_migrations_apply
        mov     rdi, r12
        call    af_cfg_err_init
        lea     rdi, [cfg_min]
        mov     rsi, cfg_min_len
        mov     rdx, r12
        lea     rcx, [rsp + 152]
        call    af_config_parse
        AF_CHECK_OK rax, "parse failed"
        mov     r13, [rsp + 152]
        mov     rdi, rbx
        mov     rsi, r13
        call    af_repo_sync_config
        AF_CHECK_OK rax, "the first sync failed"

        mov     rdi, rbx
        lea     rsi, [id_ollama]
        mov     rdx, 1
        call    af_repo_set_operator_disabled
        AF_CHECK_OK rax, "disabling the provider failed"

        mov     rdi, rbx
        mov     rsi, r13
        call    af_repo_sync_config
        AF_CHECK_OK rax, "the second sync failed"

        mov     rdi, rbx
        lea     rsi, [id_ollama]
        lea     rdx, [rsp + 160]
        call    af_repo_get_operator_disabled
        AF_CHECK_OK rax, "reading the operator state failed"
        AF_CHECK_EQ qword [rsp + 160], 1, "a reload must not re-enable the provider"

        mov     rdi, r13
        call    af_config_release
        mov     rdi, r12
        call    af_cfg_err_free
        mov     rdi, rbx
        call    af_db_close
        call    af_test_db_unlink
AF_TEST_END

AF_TEST "db/request_and_attempt_records", 256
        call    af_test_db_unlink
        lea     rbx, [rsp]
        mov     rdi, rbx
        lea     rsi, [db_path]
        mov     rdx, 3000
        call    af_db_open
        mov     rdi, rbx
        call    af_migrations_apply
        AF_CHECK_OK rax, "migrations failed"

        ; outcome: streaming, committed, status, error_class, attempts,
        ; duration_ms, client_ref
        mov     qword [rsp + 64], 1     ; streaming
        mov     qword [rsp + 72], 1     ; committed
        mov     qword [rsp + 80], 200   ; status code
        mov     qword [rsp + 88], 0     ; error class: NULL
        mov     qword [rsp + 96], 1     ; attempts
        mov     qword [rsp + 104], 42   ; duration
        mov     qword [rsp + 112], 0    ; client reference: NULL

        sub     rsp, 16
        lea     rax, [rsp + 16 + 64]
        mov     [rsp], rax
        mov     rdi, rbx
        lea     rsi, [req_id]
        mov     rdx, 1000
        lea     rcx, [req_endpoint]
        lea     r8, [req_alias]
        lea     r9, [id_route]
        call    af_repo_record_request
        add     rsp, 16
        AF_CHECK_OK rax, "recording the request failed"

        mov     rdi, rbx
        lea     rsi, [rsp + 120]
        call    af_repo_request_count
        AF_CHECK_EQ qword [rsp + 120], 1, "one request should have been recorded"

        ; timing: started, finished, status, error_class, retryable
        mov     qword [rsp + 128], 1000
        mov     qword [rsp + 136], 1042
        mov     qword [rsp + 144], 200
        mov     qword [rsp + 152], 0
        mov     qword [rsp + 160], 0
        mov     rdi, rbx
        lea     rsi, [req_id]
        mov     rdx, 1
        lea     rcx, [id_ollama]
        lea     r8, [exp_model]
        lea     r9, [rsp + 128]
        call    af_repo_record_attempt
        AF_CHECK_OK rax, "recording the attempt failed"

        mov     rdi, rbx
        lea     rsi, [req_id]
        lea     rdx, [rsp + 120]
        call    af_repo_attempt_count
        AF_CHECK_OK rax, "counting attempts failed"
        AF_CHECK_EQ qword [rsp + 120], 1, "exactly one attempt should be recorded"

        ; Retention: pruning before the record leaves it, after removes it and
        ; cascades to the attempt.
        mov     rdi, rbx
        mov     rsi, 500
        call    af_repo_prune_requests
        AF_CHECK_OK rax, "pruning failed"
        mov     rdi, rbx
        lea     rsi, [rsp + 120]
        call    af_repo_request_count
        AF_CHECK_EQ qword [rsp + 120], 1, "pruning before the record must keep it"

        mov     rdi, rbx
        mov     rsi, 2000
        call    af_repo_prune_requests
        AF_CHECK_OK rax, "pruning failed"
        mov     rdi, rbx
        lea     rsi, [rsp + 120]
        call    af_repo_request_count
        AF_CHECK_EQ qword [rsp + 120], 0, "pruning after the record must remove it"
        mov     rdi, rbx
        lea     rsi, [req_id]
        lea     rdx, [rsp + 120]
        call    af_repo_attempt_count
        AF_CHECK_EQ qword [rsp + 120], 0, "the attempt should cascade away"

        mov     rdi, rbx
        call    af_db_close
        call    af_test_db_unlink
AF_TEST_END

AF_TEST "db/settings_round_trip", 256
        call    af_test_db_unlink
        lea     rbx, [rsp]
        lea     r12, [rsp + 64]         ; af_buffer
        mov     rdi, rbx
        lea     rsi, [db_path]
        mov     rdx, 3000
        call    af_db_open
        mov     rdi, rbx
        call    af_migrations_apply

        mov     rdi, r12
        mov     rsi, 4096
        call    af_buf_init

        mov     rdi, rbx
        lea     rsi, [setting_key]
        mov     rdx, r12
        call    af_repo_setting_get
        AF_CHECK_ERR rax, AF_E_NOTFOUND, "an absent setting must report not-found"

        mov     rdi, rbx
        lea     rsi, [setting_key]
        lea     rdx, [setting_val]
        call    af_repo_setting_set
        AF_CHECK_OK rax, "setting a value failed"

        mov     rdi, rbx
        lea     rsi, [setting_key]
        mov     rdx, r12
        call    af_repo_setting_get
        AF_CHECK_OK rax, "reading the setting failed"
        mov     rdi, r12
        call    af_buf_len
        AF_CHECK_EQ rax, 6, "the stored value has the wrong length"
        mov     rdi, r12
        call    af_buf_data
        mov     rdi, rax
        lea     rsi, [setting_val]
        mov     rdx, 6
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the setting did not round-trip"

        mov     rdi, r12
        call    af_buf_free
        mov     rdi, rbx
        call    af_db_close
        call    af_test_db_unlink
AF_TEST_END

AF_TEST "db/blocked_writes_do_not_break_reads", 256
        ; ARCHITECTURE.md 11: a write failure degrades observability without
        ; stopping the daemon. Reads keep working.
        call    af_test_db_unlink
        lea     rbx, [rsp]
        lea     r12, [rsp + 64]
        mov     rdi, rbx
        lea     rsi, [db_path]
        mov     rdx, 3000
        call    af_db_open
        mov     rdi, rbx
        call    af_migrations_apply
        mov     rdi, r12
        call    af_cfg_err_init
        lea     rdi, [cfg_min]
        mov     rsi, cfg_min_len
        mov     rdx, r12
        lea     rcx, [rsp + 152]
        call    af_config_parse
        mov     r13, [rsp + 152]
        mov     rdi, rbx
        mov     rsi, r13
        call    af_repo_sync_config
        AF_CHECK_OK rax, "the initial sync should succeed"

        mov     rdi, rbx
        mov     rsi, 1
        call    af_db_block_writes

        mov     rdi, rbx
        mov     rsi, r13
        call    af_repo_sync_config
        AF_CHECK_ERR rax, AF_E_DB, "a blocked write must be reported"
        mov     rdi, rbx
        lea     rsi, [id_ollama]
        mov     rdx, 1
        call    af_repo_set_operator_disabled
        AF_CHECK_ERR rax, AF_E_DB, "a blocked mutation must be reported"

        ; Reads still answer, which is the whole point.
        mov     rdi, rbx
        lea     rsi, [rsp + 160]
        call    af_repo_provider_count
        AF_CHECK_OK rax, "reads must keep working while writes fail"
        AF_CHECK_EQ qword [rsp + 160], 1, "the read returned the wrong count"
        mov     rdi, rbx
        call    af_db_is_open
        AF_CHECK_EQ rax, 1, "the handle must stay open"

        mov     rdi, rbx
        xor     esi, esi
        call    af_db_block_writes
        mov     rdi, r13
        call    af_config_release
        mov     rdi, r12
        call    af_cfg_err_free
        mov     rdi, rbx
        call    af_db_close
        call    af_test_db_unlink
AF_TEST_END

AF_TEST "db/transaction_discipline", 128
        call    af_test_db_unlink
        lea     rbx, [rsp]
        mov     rdi, rbx
        lea     rsi, [db_path]
        mov     rdx, 3000
        call    af_db_open
        mov     rdi, rbx
        call    af_migrations_apply

        mov     rdi, rbx
        call    af_db_in_transaction
        AF_CHECK_EQ rax, 0, "no transaction should be open initially"
        mov     rdi, rbx
        call    af_db_begin
        AF_CHECK_OK rax, "begin failed"
        mov     rdi, rbx
        call    af_db_in_transaction
        AF_CHECK_EQ rax, 1, "the transaction should be recorded"

        ; A nested begin is refused rather than silently ignored: a later
        ; rollback would otherwise undo more than its caller intended.
        mov     rdi, rbx
        call    af_db_begin
        AF_CHECK_ERR rax, AF_E_INTERNAL, "a nested begin must be refused"

        mov     rdi, rbx
        call    af_db_rollback
        AF_CHECK_OK rax, "rollback failed"
        mov     rdi, rbx
        call    af_db_in_transaction
        AF_CHECK_EQ rax, 0, "the transaction should be closed"

        ; Rolling back with nothing open is safe: it runs on the failure path
        ; where the caller may not know how far it got.
        mov     rdi, rbx
        call    af_db_rollback
        AF_CHECK_OK rax, "a redundant rollback should be safe"

        mov     rdi, rbx
        call    af_db_commit
        AF_CHECK_ERR rax, AF_E_INTERNAL, "committing nothing must be refused"

        mov     rdi, rbx
        call    af_db_close
        call    af_test_db_unlink
AF_TEST_END

AF_TEST "db/bad_sql_is_reported_not_fatal", 128
        call    af_test_db_unlink
        lea     rbx, [rsp]
        mov     rdi, rbx
        lea     rsi, [db_path]
        mov     rdx, 3000
        call    af_db_open
        mov     rdi, rbx
        lea     rsi, [sql_bad]
        lea     rdx, [rsp + 64]
        call    af_db_prepare
        AF_CHECK_TRUE rax, "preparing invalid SQL must fail"
        AF_CHECK_EQ qword [rsp + 64], 0, "a failed prepare must not hand back a statement"
        mov     rdi, rbx
        call    af_db_is_open
        AF_CHECK_EQ rax, 1, "a failed prepare must not close the handle"
        mov     rdi, rbx
        call    af_db_close
        call    af_test_db_unlink
AF_TEST_END

AF_TEST "db/struct_size_is_stable"
        call    af_db_struct_size
        AF_CHECK_EQ rax, DB_SIZE, "the handle layout changed without the header"
AF_TEST_END
