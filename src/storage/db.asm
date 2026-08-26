; AsmFlow — SQLite handle and statement layer.
;
; ARCHITECTURE.md 9: `asmflowd` opens the database as the single writer. Nothing
; else in the system holds a handle, and the console reaches state only through
; the control socket (AGENTS.md invariant 14).
;
; Two rules shape this file.
;
; Every statement is prepared and bound. No SQL is ever built by concatenating a
; provider id, a model alias, or anything else that came from outside
; (SECURITY_MODEL.md 14). The `af_db_exec` helper takes only static SQL from
; .rodata; everything with a value goes through prepare and bind.
;
; A write failure degrades observability, it does not stop the daemon
; (ARCHITECTURE.md 11). Callers get an af_status and decide; nothing here
; panics, and `af_db_block_writes` exists so a test can hold a database in the
; failing state and prove read-only control commands still answer.

        bits 64
        default rel

%include "asmflow.inc"
%include "db.inc"

        extern af_mem_zero
        extern af_cstr_len
        extern af_monotonic_ms

        extern sqlite3_open_v2
        extern sqlite3_close_v2
        extern sqlite3_exec
        extern sqlite3_prepare_v2
        extern sqlite3_finalize
        extern sqlite3_step
        extern sqlite3_reset
        extern sqlite3_clear_bindings
        extern sqlite3_bind_int64
        extern sqlite3_bind_text
        extern sqlite3_bind_null
        extern sqlite3_column_int64
        extern sqlite3_column_text
        extern sqlite3_column_bytes
        extern sqlite3_column_type
        extern sqlite3_column_count
        extern sqlite3_errmsg
        extern sqlite3_extended_errcode
        extern sqlite3_busy_timeout
        extern sqlite3_changes64
        extern sqlite3_last_insert_rowid
        extern af_sqlitec_transient

        section .rodata
sql_begin_immediate: db "BEGIN IMMEDIATE", 0
sql_commit:          db "COMMIT", 0
sql_rollback:        db "ROLLBACK", 0
sql_wal:             db "PRAGMA journal_mode=WAL", 0
sql_foreign_keys:    db "PRAGMA foreign_keys=ON", 0
sql_synchronous:     db "PRAGMA synchronous=NORMAL", 0
sql_integrity:       db "PRAGMA integrity_check", 0

        section .text

; ---------------------------------------------------------------------------
; af_db_status_from_code(i64 sqlite_code) -> af_status
;
; Maps a raw SQLite result onto the af_status contract. BUSY is distinguished
; from a generic failure because the caller may retry it; a corrupt or
; not-a-database result is not retryable and must reach the operator as itself.
; ---------------------------------------------------------------------------
        global af_db_status_from_code
af_db_status_from_code:
        cmp     rdi, SQLITE_OK
        je      .ok
        cmp     rdi, SQLITE_ROW
        je      .ok
        cmp     rdi, SQLITE_DONE
        je      .ok
        cmp     rdi, SQLITE_BUSY
        je      .busy
        cmp     rdi, SQLITE_LOCKED
        je      .busy
        cmp     rdi, SQLITE_READONLY
        je      .readonly
        cmp     rdi, SQLITE_CORRUPT
        je      .schema
        cmp     rdi, SQLITE_NOTADB
        je      .schema
        mov     rax, AF_E_DB
        ret
.ok:
        xor     eax, eax
        ret
.busy:
        mov     rax, AF_E_DB_BUSY
        ret
.readonly:
        mov     rax, AF_E_DB_READONLY
        ret
.schema:
        mov     rax, AF_E_DB_SCHEMA
        ret

; ---------------------------------------------------------------------------
; af_db_open(af_db *db, const char *path, i64 busy_timeout_ms) -> af_status
;
; Ownership: `db` is caller-supplied storage; `path` is BORROWED from the
; configuration snapshot and must outlive the handle.
;
; NOMUTEX is chosen deliberately: the daemon is single-threaded by design
; (ADR 0002), so SQLite's own locking would be pure overhead. If threads are
; ever introduced, this flag is one of the things that has to change with them.
; ---------------------------------------------------------------------------
        global af_db_open
af_db_open:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi                ; path
        mov     r13, rdx                ; busy timeout

        mov     rdi, rbx
        mov     rsi, DB_SIZE
        call    af_mem_zero
        mov     [rbx + DB_PATH], r12

        mov     rdi, r12
        lea     rsi, [rbx + DB_HANDLE]
        mov     rdx, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        xor     ecx, ecx                ; default VFS
        call    sqlite3_open_v2 wrt ..plt
        mov     [rbx + DB_LAST_CODE], rax
        cmp     rax, SQLITE_OK
        jne     .open_failed

        ; The busy timeout has to be installed before anything else touches the
        ; file, or the first PRAGMA could fail on a lock that would have cleared.
        mov     rdi, [rbx + DB_HANDLE]
        mov     rsi, r13
        call    sqlite3_busy_timeout wrt ..plt

        ; Foreign keys are off by default in SQLite. The schema uses ON DELETE
        ; CASCADE for route targets and capability cache entries, so leaving
        ; them off would silently orphan rows.
        mov     rdi, rbx
        lea     rsi, [sql_foreign_keys]
        call    af_db_exec
        test    rax, rax
        js      .close_and_fail

        mov     rdi, rbx
        lea     rsi, [sql_synchronous]
        call    af_db_exec
        test    rax, rax
        js      .close_and_fail
        AF_LEAVE_OK

.open_failed:
        ; sqlite3_open_v2 allocates a handle even on failure, so it still has to
        ; be closed to recover the error message and release the memory.
        mov     rdi, rax
        call    af_db_status_from_code
        mov     [rsp], rax
        mov     rdi, [rbx + DB_HANDLE]
        test    rdi, rdi
        jz      .no_handle
        call    sqlite3_close_v2 wrt ..plt
.no_handle:
        mov     qword [rbx + DB_HANDLE], 0
        mov     rax, [rsp]
        AF_LEAVE
.close_and_fail:
        mov     [rsp], rax
        mov     rdi, rbx
        call    af_db_close
        mov     rax, [rsp]
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_db_enable_wal(af_db *db) -> af_status
;
; ARCHITECTURE.md 9: WAL is enabled *after* successful startup validation, not
; as part of opening. A journal-mode change writes to the file, and doing it
; before the schema has been checked would modify a database we may be about to
; refuse.
; ---------------------------------------------------------------------------
        global af_db_enable_wal
af_db_enable_wal:
        AF_ENTER 0
        lea     rsi, [sql_wal]
        call    af_db_exec
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_db_close(af_db *db) -> void
;
; Idempotent.
; ---------------------------------------------------------------------------
        global af_db_close
af_db_close:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rdi, [rbx + DB_HANDLE]
        test    rdi, rdi
        jz      .done
        call    sqlite3_close_v2 wrt ..plt
        mov     qword [rbx + DB_HANDLE], 0
        mov     qword [rbx + DB_IN_TRANSACTION], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_db_exec(af_db *db, const char *static_sql) -> af_status
;
; Runs SQL that carries no values. The parameter name says `static_sql` because
; that is the contract: the only acceptable argument is a literal from .rodata.
; Anything with a value goes through af_db_prepare and bind.
; ---------------------------------------------------------------------------
        global af_db_exec
af_db_exec:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + DB_HANDLE], 0
        je      .closed
        mov     rdi, [rbx + DB_HANDLE]  ; rsi already holds the SQL
        xor     edx, edx                ; no callback
        xor     ecx, ecx
        xor     r8d, r8d                ; no error message buffer
        call    sqlite3_exec wrt ..plt
        mov     [rbx + DB_LAST_CODE], rax
        mov     rdi, rax
        call    af_db_status_from_code
        AF_LEAVE
.closed:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; Transactions.
;
; BEGIN IMMEDIATE rather than the default deferred: a deferred transaction takes
; its write lock at the first write, which means a busy failure can surface in
; the middle of a multi-statement change. Taking the lock up front turns that
; into a failure before anything has been written.
; ---------------------------------------------------------------------------
        global af_db_begin
af_db_begin:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + DB_IN_TRANSACTION], 0
        jne     .nested
        lea     rsi, [sql_begin_immediate]
        call    af_db_exec
        test    rax, rax
        js      .done
        mov     qword [rbx + DB_IN_TRANSACTION], 1
.done:
        AF_LEAVE
.nested:
        ; SQLite has savepoints, but nothing here needs them, and a silent
        ; nested BEGIN would make a later ROLLBACK undo more than its caller
        ; intended.
        AF_LEAVE_ERR AF_E_INTERNAL
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

        global af_db_commit
af_db_commit:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + DB_IN_TRANSACTION], 0
        je      .not_in_transaction
        lea     rsi, [sql_commit]
        call    af_db_exec
        mov     qword [rbx + DB_IN_TRANSACTION], 0
        AF_LEAVE
.not_in_transaction:
        AF_LEAVE_ERR AF_E_INTERNAL
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_db_rollback(af_db *db) -> af_status
;   Safe to call when no transaction is open, because it runs on the failure
;   path where the caller may not know how far it got.
        global af_db_rollback
af_db_rollback:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + DB_IN_TRANSACTION], 0
        je      .nothing
        lea     rsi, [sql_rollback]
        call    af_db_exec
        mov     qword [rbx + DB_IN_TRANSACTION], 0
        AF_LEAVE
.nothing:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

        global af_db_in_transaction
af_db_in_transaction:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + DB_IN_TRANSACTION]
.done:
        ret

; ---------------------------------------------------------------------------
; af_db_prepare(af_db *db, const char *static_sql, void **out_stmt)
;   -> af_status
;
; Ownership: the statement is TRANSFERRED to the caller and must be released
; with af_db_finalize.
; ---------------------------------------------------------------------------
        global af_db_prepare
af_db_prepare:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     qword [r13], 0
        cmp     qword [rbx + DB_HANDLE], 0
        je      .closed

        mov     rdi, r12
        call    af_cstr_len
        mov     rdx, rax
        mov     rdi, [rbx + DB_HANDLE]
        mov     rsi, r12
        mov     rcx, r13
        xor     r8d, r8d                ; no tail pointer: one statement only
        call    sqlite3_prepare_v2 wrt ..plt
        mov     [rbx + DB_LAST_CODE], rax
        mov     rdi, rax
        call    af_db_status_from_code
        AF_LEAVE
.closed:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_db_finalize(void *stmt) -> void
; ---------------------------------------------------------------------------
        global af_db_finalize
af_db_finalize:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        call    sqlite3_finalize wrt ..plt
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_db_step(af_db *db, void *stmt) -> af_status
;
; AF_OK when a row is available, AF_E_EOF when the statement is complete. The
; distinction is deliberate: a caller that ignores it would read column values
; out of a finished statement.
; ---------------------------------------------------------------------------
        global af_db_step
af_db_step:
        AF_ENTER 0
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, rsi
        call    sqlite3_step wrt ..plt
        test    rbx, rbx
        jz      .no_db
        mov     [rbx + DB_LAST_CODE], rax
.no_db:
        cmp     rax, SQLITE_ROW
        je      .row
        cmp     rax, SQLITE_DONE
        je      .done_rows
        mov     rdi, rax
        call    af_db_status_from_code
        AF_LEAVE
.row:
        AF_LEAVE_OK
.done_rows:
        AF_LEAVE_ERR AF_E_EOF
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_db_reset(af_db *db, void *stmt) -> af_status
;
; Resets and clears bindings together: a reused statement that kept a stale
; binding would silently write the previous row's value into a column the
; caller forgot to rebind.
; ---------------------------------------------------------------------------
        global af_db_reset
af_db_reset:
        AF_ENTER 0
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rsi
        mov     rdi, rbx
        call    sqlite3_reset wrt ..plt
        mov     r12, rax
        mov     rdi, rbx
        call    sqlite3_clear_bindings wrt ..plt
        mov     rdi, r12
        call    af_db_status_from_code
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; Binding. Parameter indices are 1-based, as SQLite defines them.
; ---------------------------------------------------------------------------
        global af_db_bind_int
af_db_bind_int:
        AF_ENTER 0
        call    sqlite3_bind_int64 wrt ..plt
        mov     rdi, rax
        call    af_db_status_from_code
        AF_LEAVE

; af_db_bind_text(void *stmt, i64 index, const char *text, i64 len)
;   -> af_status
;
;   A NULL pointer binds SQL NULL, which is what an absent optional field is.
;   `len` may be -1 to mean "up to the terminator". SQLITE_TRANSIENT tells
;   SQLite to copy: most sources here are arena strings whose lifetime ends with
;   the request, and a static binding would leave the statement pointing at
;   released memory.
        global af_db_bind_text
af_db_bind_text:
        AF_ENTER 32
        test    rdx, rdx
        jz      .bind_null
        mov     [rsp], rdi              ; stmt
        mov     [rsp + 8], rsi          ; index
        mov     [rsp + 16], rdx         ; text
        mov     [rsp + 24], rcx         ; length
        call    af_sqlitec_transient wrt ..plt
        mov     r8, rax
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        mov     rdx, [rsp + 16]
        mov     rcx, [rsp + 24]
        call    sqlite3_bind_text wrt ..plt
        mov     rdi, rax
        call    af_db_status_from_code
        AF_LEAVE
.bind_null:
        call    sqlite3_bind_null wrt ..plt
        mov     rdi, rax
        call    af_db_status_from_code
        AF_LEAVE

; af_db_bind_cstr(void *stmt, i64 index, const char *text) -> af_status
        global af_db_bind_cstr
af_db_bind_cstr:
        AF_ENTER 0
        mov     rcx, -1
        call    af_db_bind_text
        AF_LEAVE

        global af_db_bind_null
af_db_bind_null:
        AF_ENTER 0
        call    sqlite3_bind_null wrt ..plt
        mov     rdi, rax
        call    af_db_status_from_code
        AF_LEAVE

; ---------------------------------------------------------------------------
; Column access. Indices are 0-based, as SQLite defines them.
; ---------------------------------------------------------------------------
        global af_db_column_int
af_db_column_int:
        AF_ENTER 0
        call    sqlite3_column_int64 wrt ..plt
        AF_LEAVE

; af_db_column_text(void *stmt, i64 index, u64 *out_len) -> const char *
;   BORROWED from the statement and invalidated by the next step or reset.
;   NULL when the column is SQL NULL.
        global af_db_column_text
af_db_column_text:
        AF_ENTER 32
        mov     [rsp], rdi
        mov     [rsp + 8], rsi
        mov     [rsp + 16], rdx
        call    sqlite3_column_text wrt ..plt
        mov     [rsp + 24], rax
        mov     rcx, [rsp + 16]
        test    rcx, rcx
        jz      .no_len
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    sqlite3_column_bytes wrt ..plt
        mov     rcx, [rsp + 16]
        mov     [rcx], rax
.no_len:
        mov     rax, [rsp + 24]
        AF_LEAVE

        global af_db_column_type
af_db_column_type:
        AF_ENTER 0
        call    sqlite3_column_type wrt ..plt
        AF_LEAVE

        global af_db_column_is_null
af_db_column_is_null:
        AF_ENTER 0
        call    sqlite3_column_type wrt ..plt
        cmp     rax, SQLITE_NULL
        sete    al
        movzx   eax, al
        AF_LEAVE

        global af_db_column_count
af_db_column_count:
        AF_ENTER 0
        call    sqlite3_column_count wrt ..plt
        AF_LEAVE

; ---------------------------------------------------------------------------
; Diagnostics.
;
; af_db_errmsg returns SQLite's message, which describes the SQL, never the
; bound values. Bound values are the ones that could carry a credential, and
; they never appear in it.
; ---------------------------------------------------------------------------
        global af_db_errmsg
af_db_errmsg:
        AF_ENTER 0
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rdi, [rdi + DB_HANDLE]
        test    rdi, rdi
        jz      .done
        call    sqlite3_errmsg wrt ..plt
.done:
        AF_LEAVE

        global af_db_last_code
af_db_last_code:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + DB_LAST_CODE]
.done:
        ret

        global af_db_changes
af_db_changes:
        AF_ENTER 0
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rdi, [rdi + DB_HANDLE]
        test    rdi, rdi
        jz      .done
        call    sqlite3_changes64 wrt ..plt
.done:
        AF_LEAVE

        global af_db_is_open
af_db_is_open:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        cmp     qword [rdi + DB_HANDLE], 0
        setne   al
        movzx   eax, al
.done:
        ret

; ---------------------------------------------------------------------------
; af_db_integrity_check(af_db *db) -> af_status
;
; The maintenance command SECURITY_MODEL.md 14 asks for. Runs the pragma and
; reports whether it answered "ok".
; ---------------------------------------------------------------------------
        global af_db_integrity_check
af_db_integrity_check:
        AF_ENTER 32
        mov     rbx, rdi
        mov     rdi, rbx
        lea     rsi, [sql_integrity]
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r12, [rsp]
        mov     rdi, rbx
        mov     rsi, r12
        call    af_db_step
        test    rax, rax
        js      .finalize
        mov     rdi, r12
        xor     esi, esi
        lea     rdx, [rsp + 8]
        call    af_db_column_text
        mov     r13, rax
        cmp     qword [rsp + 8], 2
        jne     .corrupt
        test    r13, r13
        jz      .corrupt
        cmp     byte [r13], 'o'
        jne     .corrupt
        cmp     byte [r13 + 1], 'k'
        jne     .corrupt
        xor     eax, eax
.finalize:
        mov     [rsp + 16], rax
        mov     rdi, r12
        call    af_db_finalize
        mov     rax, [rsp + 16]
        AF_LEAVE
.corrupt:
        mov     rax, AF_E_DB_SCHEMA
        jmp     .finalize
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_db_block_writes(af_db *db, i64 blocked) -> void
;
; Test hook. ARCHITECTURE.md 11 states that a database write failure degrades
; observability without stopping the daemon or corrupting a committed stream.
; Proving that needs a database that fails writes on demand, which is what this
; provides; nothing on a product path calls it.
; ---------------------------------------------------------------------------
        global af_db_block_writes
af_db_block_writes:
        test    rdi, rdi
        jz      .done
        mov     [rdi + DB_WRITES_BLOCKED], rsi
.done:
        ret

        global af_db_writes_blocked
af_db_writes_blocked:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + DB_WRITES_BLOCKED]
.done:
        ret

        global af_db_struct_size
af_db_struct_size:
        mov     eax, DB_SIZE
        ret
