; AsmFlow — schema migrations.
;
; ARCHITECTURE.md 9: migrations are monotonic and transactional. Each one runs
; inside a single BEGIN IMMEDIATE / COMMIT, and its `schema_migrations` row is
; written in the same transaction as the statements it describes. That pairing
; is what makes a crash mid-migration recoverable: either the version row and
; the schema change are both present, or neither is. There is no window in
; which the database claims a version it does not have.
;
; A database whose recorded version is NEWER than this build understands is
; refused rather than opened. Running an older binary against a newer schema
; would not fail loudly; it would read columns that had moved.
;
; Secrets never appear here. `providers` and `mcp_servers` carry identity,
; capability, and state, and no credential of any kind — the configuration keeps
; only an environment-variable name, and even that is not persisted
; (SECURITY_MODEL.md 6).

        bits 64
        default rel

%include "asmflow.inc"
%include "db.inc"

        extern af_db_exec
        extern af_db_prepare
        extern af_db_finalize
        extern af_db_step
        extern af_db_bind_int
        extern af_db_column_int
        extern af_db_begin
        extern af_db_commit
        extern af_db_rollback
        extern af_realtime_ms

%define AF_SCHEMA_VERSION 2

        section .rodata

; Migration 1 is deliberately one string per statement rather than one blob.
; sqlite3_exec would run a semicolon-separated blob, but a failure in the middle
; of one would give no indication of which statement failed, and the
; failure-injection test in tests/asm/test_db.asm needs statement granularity.
m1_schema_migrations:
        db "CREATE TABLE schema_migrations ("
        db "  version INTEGER PRIMARY KEY,"
        db "  applied_at_ms INTEGER NOT NULL)", 0

m1_providers:
        db "CREATE TABLE providers ("
        db "  id TEXT PRIMARY KEY,"
        db "  display_name TEXT NOT NULL,"
        db "  adapter TEXT NOT NULL,"
        db "  base_url TEXT NOT NULL,"
        db "  enabled INTEGER NOT NULL,"
        db "  required INTEGER NOT NULL,"
        db "  max_concurrency INTEGER NOT NULL,"
        db "  capabilities INTEGER NOT NULL,"
        db "  updated_at_ms INTEGER NOT NULL)", 0

m1_routes:
        db "CREATE TABLE routes ("
        db "  id TEXT PRIMARY KEY,"
        db "  model_alias TEXT NOT NULL UNIQUE,"
        db "  enabled INTEGER NOT NULL,"
        db "  endpoint_families INTEGER NOT NULL,"
        db "  policy TEXT NOT NULL,"
        db "  fallback_enabled INTEGER NOT NULL,"
        db "  fallback_max_attempts INTEGER NOT NULL,"
        db "  fallback_retryable INTEGER NOT NULL,"
        db "  updated_at_ms INTEGER NOT NULL)", 0

; `position` preserves the configured target order, which routing treats as
; semantically significant (docs/CONFIGURATION.md 10) and uses as a tie-break.
m1_route_targets:
        db "CREATE TABLE route_targets ("
        db "  route_id TEXT NOT NULL REFERENCES routes(id) ON DELETE CASCADE,"
        db "  position INTEGER NOT NULL,"
        db "  provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,"
        db "  upstream_model TEXT NOT NULL,"
        db "  priority INTEGER NOT NULL,"
        db "  weight INTEGER NOT NULL,"
        db "  PRIMARY KEY (route_id, position))", 0

m1_provider_health:
        db "CREATE TABLE provider_health ("
        db "  provider_id TEXT PRIMARY KEY REFERENCES providers(id) ON DELETE CASCADE,"
        db "  state TEXT NOT NULL,"
        db "  consecutive_failures INTEGER NOT NULL DEFAULT 0,"
        db "  consecutive_successes INTEGER NOT NULL DEFAULT 0,"
        db "  ewma_latency_us INTEGER,"
        db "  opened_at_ms INTEGER,"
        db "  last_change_ms INTEGER NOT NULL,"
        db "  operator_disabled INTEGER NOT NULL DEFAULT 0)", 0

; `committed` records whether any byte reached the client. It is the persisted
; form of the commit barrier in ARCHITECTURE.md 7, and it is what makes a
; fallback-after-commit defect visible in the record afterwards rather than only
; in a live trace.
m1_requests:
        db "CREATE TABLE requests ("
        db "  id TEXT PRIMARY KEY,"
        db "  received_at_ms INTEGER NOT NULL,"
        db "  endpoint TEXT NOT NULL,"
        db "  model_alias TEXT,"
        db "  route_id TEXT,"
        db "  streaming INTEGER NOT NULL DEFAULT 0,"
        db "  committed INTEGER NOT NULL DEFAULT 0,"
        db "  status_code INTEGER,"
        db "  error_class TEXT,"
        db "  attempts INTEGER NOT NULL DEFAULT 0,"
        db "  duration_ms INTEGER,"
        db "  client_ref TEXT)", 0

m1_requests_index:
        db "CREATE INDEX requests_received_idx ON requests(received_at_ms DESC)", 0

m1_request_attempts:
        db "CREATE TABLE request_attempts ("
        db "  request_id TEXT NOT NULL REFERENCES requests(id) ON DELETE CASCADE,"
        db "  attempt_no INTEGER NOT NULL,"
        db "  provider_id TEXT,"
        db "  upstream_model TEXT,"
        db "  started_at_ms INTEGER NOT NULL,"
        db "  finished_at_ms INTEGER,"
        db "  status_code INTEGER,"
        db "  error_class TEXT,"
        db "  retryable INTEGER NOT NULL DEFAULT 0,"
        db "  PRIMARY KEY (request_id, attempt_no))", 0

m1_mcp_servers:
        db "CREATE TABLE mcp_servers ("
        db "  id TEXT PRIMARY KEY,"
        db "  display_name TEXT NOT NULL,"
        db "  transport TEXT NOT NULL,"
        db "  enabled INTEGER NOT NULL,"
        db "  required INTEGER NOT NULL,"
        db "  state TEXT NOT NULL,"
        db "  era TEXT,"
        db "  last_error TEXT,"
        db "  restart_count INTEGER NOT NULL DEFAULT 0,"
        db "  crash_loop INTEGER NOT NULL DEFAULT 0,"
        db "  updated_at_ms INTEGER NOT NULL)", 0

; Cached inventory is display metadata only. `cache_scope` carries the modern
; protocol's own hint so a private entry is never shared across credentials
; (docs/MCP_COMPATIBILITY.md 8).
m1_mcp_capability_cache:
        db "CREATE TABLE mcp_capability_cache ("
        db "  server_id TEXT NOT NULL REFERENCES mcp_servers(id) ON DELETE CASCADE,"
        db "  kind TEXT NOT NULL,"
        db "  name TEXT NOT NULL,"
        db "  description TEXT,"
        db "  position INTEGER NOT NULL,"
        db "  fetched_at_ms INTEGER NOT NULL,"
        db "  expires_at_ms INTEGER,"
        db "  cache_scope TEXT,"
        db "  source_protocol_version TEXT,"
        db "  PRIMARY KEY (server_id, kind, name))", 0

m1_settings:
        db "CREATE TABLE settings ("
        db "  key TEXT PRIMARY KEY,"
        db "  value TEXT NOT NULL,"
        db "  updated_at_ms INTEGER NOT NULL)", 0

; Migration 2 adds the operator mutation audit trail.  It intentionally stores
; only static action/outcome names, numeric peer identity, normalized status,
; and time.  Params, target payloads, credentials, and environment names have
; no column in which they could accidentally be persisted.
m2_audit_events:
        db "CREATE TABLE audit_events ("
        db "  id INTEGER PRIMARY KEY,"
        db "  occurred_at_ms INTEGER NOT NULL,"
        db "  peer_uid INTEGER NOT NULL,"
        db "  peer_pid INTEGER NOT NULL,"
        db "  action TEXT NOT NULL,"
        db "  outcome TEXT NOT NULL,"
        db "  status INTEGER NOT NULL)", 0

sql_select_version:
        db "SELECT COALESCE(MAX(version), 0) FROM schema_migrations", 0
sql_table_exists:
        db "SELECT COUNT(*) FROM sqlite_schema "
        db "WHERE type='table' AND name='schema_migrations'", 0
sql_insert_version:
        db "INSERT INTO schema_migrations (version, applied_at_ms) VALUES (?1, ?2)", 0

        section .data.rel.ro progbits align=8 write
; Migration 1: the whole schema. The list is NULL-terminated.
        align 8
migration_1_statements:
        dq m1_schema_migrations
        dq m1_providers
        dq m1_routes
        dq m1_route_targets
        dq m1_provider_health
        dq m1_requests
        dq m1_requests_index
        dq m1_request_attempts
        dq m1_mcp_servers
        dq m1_mcp_capability_cache
        dq m1_settings
        dq 0

        align 8
migration_2_statements:
        dq m2_audit_events
        dq 0

; The migration table: {version, statements}. Append only; never renumber.
        align 8
        global af_migration_table
af_migration_table:
        dq 1, migration_1_statements
        dq 2, migration_2_statements
        dq 0, 0

        section .data
; Failure injection for HARNESS.md M4 DoD 2. -1 disables. When set to N, the
; Nth statement of the migration currently running reports a failure, which the
; runner must turn into a full rollback with the version unchanged.
af_migration_fail_at: dq -1

        section .text

; ---------------------------------------------------------------------------
; af_migrations_target_version() -> u64
; ---------------------------------------------------------------------------
        global af_migrations_target_version
af_migrations_target_version:
        mov     eax, AF_SCHEMA_VERSION
        ret

; ---------------------------------------------------------------------------
; af_migrations_current_version(af_db *db, i64 *out) -> af_status
;
; Zero for a database that has never been migrated. Checking for the table
; first avoids relying on an error code to mean "empty database", which would
; also swallow a genuine failure.
; ---------------------------------------------------------------------------
        global af_migrations_current_version
af_migrations_current_version:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     qword [r12], 0

        mov     rdi, rbx
        lea     rsi, [sql_table_exists]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]
        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        test    rax, rax
        js      .finalize_probe
        mov     rdi, r13
        xor     esi, esi
        call    af_db_column_int
        mov     r14, rax
        mov     rdi, r13
        call    af_db_finalize
        test    r14, r14
        jz      .no_table               ; version stays 0

        mov     rdi, rbx
        lea     rsi, [sql_select_version]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r13, [rsp]
        mov     rdi, rbx
        mov     rsi, r13
        call    af_db_step
        test    rax, rax
        js      .finalize_probe
        mov     rdi, r13
        xor     esi, esi
        call    af_db_column_int
        mov     [r12], rax
        mov     rdi, r13
        call    af_db_finalize
        AF_LEAVE_OK

.no_table:
        AF_LEAVE_OK
.finalize_probe:
        mov     [rsp + 8], rax
        mov     rdi, r13
        call    af_db_finalize
        mov     rax, [rsp + 8]
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_migrations_apply(af_db *db) -> af_status
;
; Brings an empty or older database up to AF_SCHEMA_VERSION. A database that
; already matches is left alone; one that is newer is refused.
;
; Each migration is one transaction. Its version row is written inside that same
; transaction, so a crash can never leave a database claiming a version whose
; statements did not all run.
; ---------------------------------------------------------------------------
        global af_migrations_apply
af_migrations_apply:
        AF_ENTER 48
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi

        mov     rdi, rbx
        lea     rsi, [rsp]
        call    af_migrations_current_version
        test    rax, rax
        js      .done
        mov     r12, [rsp]              ; current version

        cmp     r12, AF_SCHEMA_VERSION
        ja      .too_new
        je      .up_to_date

        lea     r13, [af_migration_table]
.loop:
        mov     r14, [r13]              ; version
        test    r14, r14
        jz      .up_to_date
        cmp     r14, r12
        jbe     .next                   ; already applied
        mov     r15, [r13 + 8]          ; statement list
        mov     rdi, rbx
        mov     rsi, r14
        mov     rdx, r15
        call    af_migration_run_one
        test    rax, rax
        js      .done
.next:
        add     r13, 16
        jmp     .loop

.up_to_date:
        AF_LEAVE_OK
.too_new:
        ; An older binary against a newer schema would not fail loudly; it would
        ; read columns that had moved.
        AF_LEAVE_ERR AF_E_DB_SCHEMA
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_migration_run_one(af_db *db, i64 version, const void *statements)
;   -> af_status
;
; Private. One transaction: every statement, then the version row, then commit.
; Any failure rolls the whole thing back.
; ---------------------------------------------------------------------------
af_migration_run_one:
        AF_ENTER 48
        mov     rbx, rdi                ; db
        mov     r12, rsi                ; version
        mov     r13, rdx                ; statement list

        mov     rdi, rbx
        call    af_db_begin
        test    rax, rax
        js      .done

        xor     r14, r14                ; statement index
.stmt_loop:
        mov     r15, [r13 + r14 * 8]
        test    r15, r15
        jz      .statements_done

        ; Injection point for the rollback test.
        mov     rax, [af_migration_fail_at]
        cmp     rax, r14
        je      .injected_failure

        mov     rdi, rbx
        mov     rsi, r15
        call    af_db_exec
        test    rax, rax
        js      .rollback
        inc     r14
        jmp     .stmt_loop

.statements_done:
        ; The version row belongs to the same transaction as the statements it
        ; describes.
        mov     rdi, rbx
        lea     rsi, [sql_insert_version]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .rollback
        mov     r15, [rsp]

        mov     rdi, r15
        mov     rsi, 1
        mov     rdx, r12
        call    af_db_bind_int
        test    rax, rax
        js      .finalize_and_rollback

        lea     rdi, [rsp + 8]
        call    af_realtime_ms
        test    rax, rax
        js      .finalize_and_rollback
        mov     rdi, r15
        mov     rsi, 2
        mov     rdx, [rsp + 8]
        call    af_db_bind_int
        test    rax, rax
        js      .finalize_and_rollback

        mov     rdi, rbx
        mov     rsi, r15
        call    af_db_step
        cmp     rax, AF_E_EOF
        je      .version_written
        test    rax, rax
        js      .finalize_and_rollback
.version_written:
        mov     rdi, r15
        call    af_db_finalize

        mov     rdi, rbx
        call    af_db_commit
        AF_LEAVE

.injected_failure:
        mov     rax, AF_E_DB
        jmp     .rollback
.finalize_and_rollback:
        mov     [rsp + 16], rax
        mov     rdi, r15
        call    af_db_finalize
        mov     rax, [rsp + 16]
.rollback:
        mov     [rsp + 16], rax
        mov     rdi, rbx
        call    af_db_rollback
        mov     rax, [rsp + 16]
        ; The caller sees the original cause, not the rollback's own status: a
        ; successful rollback of a failed migration is still a failed migration.
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_migrations_inject_failure_at(i64 statement_index) -> void
;
; Test hook for HARNESS.md M4 DoD 2. A negative value disables injection.
; ---------------------------------------------------------------------------
        global af_migrations_inject_failure_at
af_migrations_inject_failure_at:
        mov     [af_migration_fail_at], rdi
        ret

; ---------------------------------------------------------------------------
; af_migrations_statement_count(i64 version) -> u64
;
; How many statements a migration has, so the rollback test can walk every
; injection point rather than guessing.
; ---------------------------------------------------------------------------
        global af_migrations_statement_count
af_migrations_statement_count:
        lea     rcx, [af_migration_table]
.find:
        mov     rax, [rcx]
        test    rax, rax
        jz      .none
        cmp     rax, rdi
        je      .found
        add     rcx, 16
        jmp     .find
.found:
        mov     rcx, [rcx + 8]
        xor     eax, eax
.count:
        cmp     qword [rcx + rax * 8], 0
        je      .done
        inc     rax
        jmp     .count
.none:
        xor     eax, eax
.done:
        ret
