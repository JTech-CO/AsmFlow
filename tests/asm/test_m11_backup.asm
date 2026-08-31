; AsmFlow — M11 SQLite online-backup regression tests.
;
; These tests exercise the storage API directly.  Python never opens the
; database as a writer, and the product path remains the sole owner of SQLite
; policy.  Every path names synthetic data under /tmp and is removed before
; and after a test.

        bits 64
        default rel

%include "asmflow.inc"
%include "config.inc"
%include "db.inc"
%include "test.inc"

%define AF_TEST_TAG m11backup

%define BKT_O_RDONLY   0
%define BKT_O_WRONLY   1
%define BKT_O_CREAT    0x40
%define BKT_O_EXCL     0x80
%define BKT_O_NOFOLLOW 0x20000
%define BKT_O_CLOEXEC  0x80000
%define BKT_STAT_SIZE  144
%define BKT_STAT_MODE  24

        extern af_db_open
        extern af_db_close
        extern af_migrations_apply
        extern af_repo_setting_set
        extern af_repo_setting_get
        extern af_db_backup_to_path
        extern af_db_backup_open_verified
        extern af_db_restore_to_path

        extern af_repo_sync_config
        extern af_repo_provider_count
        extern af_repo_route_count
        extern af_repo_route_target_count
        extern af_repo_mcp_count
        extern af_repo_set_operator_disabled
        extern af_repo_get_operator_disabled

        extern af_config_parse
        extern af_config_release
        extern af_cfg_err_init
        extern af_cfg_err_free

        extern af_buf_init
        extern af_buf_free
        extern af_buf_data
        extern af_buf_len
        extern af_mem_eq
        extern af_mem_zero

        extern af_sys_open
        extern af_sys_close
        extern af_sys_fstat
        extern af_sys_unlink
        extern af_write_all

        section .rodata

source_path: db "/tmp/asmflow-m11-backup-source.db", 0
source_wal:  db "/tmp/asmflow-m11-backup-source.db-wal", 0
source_shm:  db "/tmp/asmflow-m11-backup-source.db-shm", 0
backup_path: db "/tmp/asmflow-m11-backup-copy.db", 0
backup_wal:  db "/tmp/asmflow-m11-backup-copy.db-wal", 0
backup_shm:  db "/tmp/asmflow-m11-backup-copy.db-shm", 0
restore_path: db "/tmp/asmflow-m11-backup-restored.db", 0
restore_wal:  db "/tmp/asmflow-m11-backup-restored.db-wal", 0
restore_shm:  db "/tmp/asmflow-m11-backup-restored.db-shm", 0
corrupt_path: db "/tmp/asmflow-m11-backup-corrupt.db", 0
corrupt_wal:  db "/tmp/asmflow-m11-backup-corrupt.db-wal", 0
corrupt_shm:  db "/tmp/asmflow-m11-backup-corrupt.db-shm", 0

setting_key: db "m11_semantic_marker", 0
source_value: db "source-state", 0
source_value_len equ $ - source_value - 1
existing_value: db "existing-destination", 0
existing_value_len equ $ - existing_value - 1
provider_id: db "local-ollama", 0
route_id: db "general-route", 0

; A complete canonical metadata snapshot: provider, route/target, and MCP
; server.  Secrets remain absent; restore tests persistence semantics only.
restore_cfg:
        db `{"schema_version":1,`
        db `"listener":{"host":"127.0.0.1","port":8080,"auth":{"type":"none"},`
        db `"request_header_max_bytes":65536,"request_body_max_bytes":8388608,`
        db `"idle_timeout_ms":30000},`
        db `"control":{"socket_path":"/tmp/asmflow-restore/control.sock","mode":"0600","frame_max_bytes":1048576},`
        db `"storage":{"database_path":"/tmp/asmflow-restore/asmflow.db","journal_mode":"wal",`
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
        db `"mcp_servers":[{"id":"filesystem","display_name":"FS","transport":"stdio",`
        db `"enabled":false,"required":false,"command":"/usr/bin/node","args":["/opt/s.js","-v"],`
        db `"cwd":"/opt","env_allow":["PATH","HOME"],"env":{},`
        db `"protocol":{"preferred":"2026-07-28","legacy":["2025-11-25"]},`
        db `"restart":{"mode":"on_failure","max_restarts":3,"window_ms":60000,`
        db `"backoff_ms":1000,"max_backoff_ms":30000},`
        db `"startup_timeout_ms":10000,"shutdown_grace_ms":3000}]}`
restore_cfg_len equ $ - restore_cfg

corrupt_bytes: times 512 db 0x5a
corrupt_bytes_len equ $ - corrupt_bytes

        section .text

; Remove every file SQLite can leave for the two fixed test paths.
af_test_backup_cleanup:
        AF_ENTER 0
        lea     rdi, [source_path]
        call    af_sys_unlink
        lea     rdi, [source_wal]
        call    af_sys_unlink
        lea     rdi, [source_shm]
        call    af_sys_unlink
        lea     rdi, [backup_path]
        call    af_sys_unlink
        lea     rdi, [backup_wal]
        call    af_sys_unlink
        lea     rdi, [backup_shm]
        call    af_sys_unlink
        lea     rdi, [restore_path]
        call    af_sys_unlink
        lea     rdi, [restore_wal]
        call    af_sys_unlink
        lea     rdi, [restore_shm]
        call    af_sys_unlink
        lea     rdi, [corrupt_path]
        call    af_sys_unlink
        lea     rdi, [corrupt_wal]
        call    af_sys_unlink
        lea     rdi, [corrupt_shm]
        call    af_sys_unlink
        AF_LEAVE

; Open and migrate one caller-owned af_db at `path`.
; Ownership of the resulting handle remains with the caller.
af_test_backup_open_source:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, 3000
        call    af_db_open
        test    rax, rax
        js      .done
        mov     rdi, rbx
        call    af_migrations_apply
.done:
        AF_LEAVE

; Assert the repository-level meaning that M11 promises to preserve.  Counts
; cover the canonical provider, route, ordered target, and MCP projections;
; operator state and settings prove runtime metadata survives too.
af_test_restore_assert_semantics:
        AF_ENTER 96
        mov     rbx, rdi

        mov     rdi, rbx
        lea     rsi, [rsp]
        call    af_repo_provider_count
        AF_CHECK_OK rax, "restored provider count failed"
        AF_CHECK_EQ qword [rsp], 1, "restored provider metadata changed"

        mov     rdi, rbx
        lea     rsi, [rsp]
        call    af_repo_route_count
        AF_CHECK_OK rax, "restored route count failed"
        AF_CHECK_EQ qword [rsp], 1, "restored route metadata changed"

        mov     rdi, rbx
        lea     rsi, [route_id]
        lea     rdx, [rsp]
        call    af_repo_route_target_count
        AF_CHECK_OK rax, "restored route-target count failed"
        AF_CHECK_EQ qword [rsp], 1, "restored ordered route target changed"

        mov     rdi, rbx
        lea     rsi, [rsp]
        call    af_repo_mcp_count
        AF_CHECK_OK rax, "restored MCP count failed"
        AF_CHECK_EQ qword [rsp], 1, "restored MCP metadata changed"

        mov     rdi, rbx
        lea     rsi, [provider_id]
        lea     rdx, [rsp + 8]
        call    af_repo_get_operator_disabled
        AF_CHECK_OK rax, "restored operator state lookup failed"
        AF_CHECK_EQ qword [rsp + 8], 1, "operator-disabled state was not restored"

        lea     r12, [rsp + 32]
        mov     rdi, r12
        mov     rsi, 128
        call    af_buf_init
        AF_CHECK_OK rax, "restored setting buffer init failed"
        mov     rdi, rbx
        lea     rsi, [setting_key]
        mov     rdx, r12
        call    af_repo_setting_get
        AF_CHECK_OK rax, "restored setting is absent"
        mov     rdi, r12
        call    af_buf_len
        AF_CHECK_EQ rax, source_value_len, "restored setting length changed"
        mov     rdi, r12
        call    af_buf_data
        mov     rdi, rax
        lea     rsi, [source_value]
        mov     rdx, source_value_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "restored setting value changed"
        mov     rdi, r12
        call    af_buf_free
        AF_LEAVE

AF_TEST "backup/copies_semantic_state_and_passes_integrity", 384
        call    af_test_backup_cleanup
        lea     rbx, [rsp]               ; source af_db
        lea     r12, [rsp + 48]          ; verified backup af_db
        lea     r13, [rsp + 96]          ; result af_buffer

        mov     rdi, rbx
        lea     rsi, [source_path]
        call    af_test_backup_open_source
        AF_CHECK_OK rax, "source open/migration failed"

        mov     rdi, rbx
        lea     rsi, [setting_key]
        lea     rdx, [source_value]
        call    af_repo_setting_set
        AF_CHECK_OK rax, "source semantic marker write failed"

        mov     rdi, rbx
        lea     rsi, [backup_path]
        mov     rdx, 64 * 1024 * 1024
        call    af_db_backup_to_path
        AF_CHECK_OK rax, "online backup failed"

        lea     rdi, [backup_path]
        mov     rsi, 64 * 1024 * 1024
        mov     rdx, r12
        call    af_db_backup_open_verified
        AF_CHECK_OK rax, "backup did not reopen read-only with integrity ok"

        mov     rdi, r13
        mov     rsi, 128
        call    af_buf_init
        AF_CHECK_OK rax, "result buffer init failed"
        mov     rdi, r12
        lea     rsi, [setting_key]
        mov     rdx, r13
        call    af_repo_setting_get
        AF_CHECK_OK rax, "semantic marker is absent from the backup"
        mov     rdi, r13
        call    af_buf_len
        AF_CHECK_EQ rax, source_value_len, "semantic marker length changed"
        mov     rdi, r13
        call    af_buf_data
        mov     r14, rax
        mov     rdi, r14
        lea     rsi, [source_value]
        mov     rdx, source_value_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "semantic marker changed during backup"

        ; The destination is explicitly mode 0600, independent of ambient umask.
        lea     rdi, [backup_path]
        mov     rsi, BKT_O_RDONLY | BKT_O_NOFOLLOW | BKT_O_CLOEXEC
        xor     edx, edx
        call    af_sys_open
        mov     r15, rax
        test    r15, r15
        setns   al
        movzx   r14, al
        AF_CHECK_TRUE r14, "backup file should be openable"
        mov     rdi, r15
        lea     rsi, [rsp + 160]
        call    af_sys_fstat
        AF_CHECK_OK rax, "backup fstat failed"
        mov     eax, [rsp + 160 + BKT_STAT_MODE]
        and     eax, 0o777
        AF_CHECK_EQ rax, 0o600, "backup file mode must be exactly 0600"
        mov     rdi, r15
        call    af_sys_close

        mov     rdi, r13
        call    af_buf_free
        mov     rdi, r12
        call    af_db_close
        mov     rdi, rbx
        call    af_db_close
        call    af_test_backup_cleanup
AF_TEST_END

AF_TEST "backup/refuses_to_overwrite_an_existing_destination", 384
        call    af_test_backup_cleanup
        lea     rbx, [rsp]               ; source af_db
        lea     r12, [rsp + 48]          ; existing destination / verified db
        lea     r13, [rsp + 96]          ; result af_buffer

        mov     rdi, rbx
        lea     rsi, [source_path]
        call    af_test_backup_open_source
        AF_CHECK_OK rax, "source open/migration failed"
        mov     rdi, rbx
        lea     rsi, [setting_key]
        lea     rdx, [source_value]
        call    af_repo_setting_set
        AF_CHECK_OK rax, "source marker write failed"

        mov     rdi, r12
        lea     rsi, [backup_path]
        call    af_test_backup_open_source
        AF_CHECK_OK rax, "existing destination open/migration failed"
        mov     rdi, r12
        lea     rsi, [setting_key]
        lea     rdx, [existing_value]
        call    af_repo_setting_set
        AF_CHECK_OK rax, "existing marker write failed"
        mov     rdi, r12
        call    af_db_close

        mov     rdi, rbx
        lea     rsi, [backup_path]
        mov     rdx, 64 * 1024 * 1024
        call    af_db_backup_to_path
        AF_CHECK_ERR rax, AF_E_EXISTS, "an existing destination must never be replaced"

        lea     rdi, [backup_path]
        mov     rsi, 64 * 1024 * 1024
        mov     rdx, r12
        call    af_db_backup_open_verified
        AF_CHECK_OK rax, "the original destination was damaged"
        mov     rdi, r13
        mov     rsi, 128
        call    af_buf_init
        AF_CHECK_OK rax, "result buffer init failed"
        mov     rdi, r12
        lea     rsi, [setting_key]
        mov     rdx, r13
        call    af_repo_setting_get
        AF_CHECK_OK rax, "existing marker disappeared"
        mov     rdi, r13
        call    af_buf_len
        AF_CHECK_EQ rax, existing_value_len, "existing marker length changed"
        mov     rdi, r13
        call    af_buf_data
        mov     r14, rax
        mov     rdi, r14
        lea     rsi, [existing_value]
        mov     rdx, existing_value_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "existing destination content was overwritten"

        mov     rdi, r13
        call    af_buf_free
        mov     rdi, r12
        call    af_db_close
        mov     rdi, rbx
        call    af_db_close
        call    af_test_backup_cleanup
AF_TEST_END

AF_TEST "backup/size_limit_fails_before_destination_creation", 256
        call    af_test_backup_cleanup
        lea     rbx, [rsp]
        mov     rdi, rbx
        lea     rsi, [source_path]
        call    af_test_backup_open_source
        AF_CHECK_OK rax, "source open/migration failed"

        mov     rdi, rbx
        lea     rsi, [backup_path]
        mov     rdx, 1
        call    af_db_backup_to_path
        AF_CHECK_ERR rax, AF_E_LIMIT, "backup must enforce the caller's byte ceiling"

        lea     rdi, [backup_path]
        mov     rsi, BKT_O_RDONLY | BKT_O_NOFOLLOW | BKT_O_CLOEXEC
        xor     edx, edx
        call    af_sys_open
        test    rax, rax
        setl    al
        movzx   r14, al
        AF_CHECK_EQ r14, 1, "a rejected backup must leave no destination file"

        mov     rdi, rbx
        call    af_db_close
        call    af_test_backup_cleanup
AF_TEST_END

AF_TEST "backup/restore_preserves_canonical_metadata", 512
        call    af_test_backup_cleanup
        lea     rbx, [rsp]               ; source af_db
        lea     r12, [rsp + 48]          ; af_cfg_error
        lea     r14, [rsp + 128]         ; restored read-only af_db

        mov     rdi, rbx
        lea     rsi, [source_path]
        call    af_test_backup_open_source
        AF_CHECK_OK rax, "restore source open/migration failed"

        mov     rdi, r12
        call    af_cfg_err_init
        lea     rdi, [restore_cfg]
        mov     rsi, restore_cfg_len
        mov     rdx, r12
        lea     rcx, [rsp + 176]
        call    af_config_parse
        AF_CHECK_OK rax, "restore metadata fixture should parse"
        mov     r13, [rsp + 176]

        mov     rdi, rbx
        mov     rsi, r13
        call    af_repo_sync_config
        AF_CHECK_OK rax, "canonical metadata sync failed"
        mov     rdi, rbx
        lea     rsi, [provider_id]
        mov     rdx, 1
        call    af_repo_set_operator_disabled
        AF_CHECK_OK rax, "operator-disabled seed failed"
        mov     rdi, rbx
        lea     rsi, [setting_key]
        lea     rdx, [source_value]
        call    af_repo_setting_set
        AF_CHECK_OK rax, "settings seed failed"

        mov     rdi, rbx
        call    af_test_restore_assert_semantics

        mov     rdi, rbx
        lea     rsi, [backup_path]
        mov     rdx, 64 * 1024 * 1024
        call    af_db_backup_to_path
        AF_CHECK_OK rax, "canonical backup failed"
        mov     rdi, rbx
        call    af_db_close

        lea     rdi, [backup_path]
        lea     rsi, [restore_path]
        mov     rdx, 64 * 1024 * 1024
        call    af_db_restore_to_path
        AF_CHECK_OK rax, "verified restore failed"

        ; A second restore must not replace the first restored database.
        lea     rdi, [backup_path]
        lea     rsi, [restore_path]
        mov     rdx, 64 * 1024 * 1024
        call    af_db_restore_to_path
        AF_CHECK_ERR rax, AF_E_EXISTS, "restore must never overwrite its destination"

        lea     rdi, [restore_path]
        mov     rsi, 64 * 1024 * 1024
        mov     rdx, r14
        call    af_db_backup_open_verified
        AF_CHECK_OK rax, "restored database failed read-only integrity verification"
        mov     rdi, r14
        call    af_test_restore_assert_semantics

        lea     rdi, [restore_path]
        mov     rsi, BKT_O_RDONLY | BKT_O_NOFOLLOW | BKT_O_CLOEXEC
        xor     edx, edx
        call    af_sys_open
        mov     r15, rax
        test    r15, r15
        setns   al
        movzx   rax, al
        AF_CHECK_TRUE rax, "restored database should be openable"
        mov     rdi, r15
        lea     rsi, [rsp + 208]
        call    af_sys_fstat
        AF_CHECK_OK rax, "restored database fstat failed"
        mov     eax, [rsp + 208 + BKT_STAT_MODE]
        and     eax, 0o777
        AF_CHECK_EQ rax, 0o600, "restored database mode must be exactly 0600"
        mov     rdi, r15
        call    af_sys_close

        mov     rdi, r14
        call    af_db_close
        mov     rdi, r13
        call    af_config_release
        mov     rdi, r12
        call    af_cfg_err_free
        call    af_test_backup_cleanup
AF_TEST_END

AF_TEST "backup/restore_rejects_corrupt_source_without_destination", 256
        call    af_test_backup_cleanup
        lea     rdi, [corrupt_path]
        mov     rsi, BKT_O_WRONLY | BKT_O_CREAT | BKT_O_EXCL | BKT_O_NOFOLLOW | BKT_O_CLOEXEC
        mov     rdx, 0o600
        call    af_sys_open
        mov     rbx, rax
        test    rbx, rbx
        setns   al
        movzx   r12, al
        AF_CHECK_TRUE r12, "corrupt fixture creation failed"
        mov     rdi, rbx
        lea     rsi, [corrupt_bytes]
        mov     rdx, corrupt_bytes_len
        call    af_write_all
        AF_CHECK_OK rax, "corrupt fixture write failed"
        mov     rdi, rbx
        call    af_sys_close

        lea     rdi, [corrupt_path]
        lea     rsi, [restore_path]
        mov     rdx, 64 * 1024 * 1024
        call    af_db_restore_to_path
        AF_CHECK_ERR rax, AF_E_DB_SCHEMA, "corrupt backup must be rejected"

        lea     rdi, [restore_path]
        mov     rsi, BKT_O_RDONLY | BKT_O_NOFOLLOW | BKT_O_CLOEXEC
        xor     edx, edx
        call    af_sys_open
        test    rax, rax
        setl    al
        movzx   r12, al
        AF_CHECK_EQ r12, 1, "corrupt restore must not create a destination"
        call    af_test_backup_cleanup
AF_TEST_END
