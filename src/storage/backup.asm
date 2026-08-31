; AsmFlow — bounded SQLite online backup.
;
; Policy remains in NASM: the SQLite Online Backup API is called directly and
; no C shim decides paths, limits, overwrite behavior, or cleanup.  The source
; `af_db` and every path argument are BORROWED.  A successfully opened verified
; `af_db` is TRANSFERRED to the caller and must be released with af_db_close.
;
; Limits:
;   * paths must terminate within AF_BACKUP_PATH_MAX bytes;
;   * callers must provide a non-zero ceiling no larger than 64 GiB;
;   * page_count * page_size is overflow-checked before a file is created and
;     after every backup step;
;   * the number of 256-page steps is hard-bounded, preventing a source that is
;     continually modified from keeping this synchronous operation alive.

        bits 64
        default rel

%include "asmflow.inc"
%include "db.inc"

%define AF_BACKUP_PATH_MAX        4096
%define AF_BACKUP_HARD_MAX_BYTES  (64 * 1024 * 1024 * 1024)
%define AF_BACKUP_STEP_PAGES      256
; 64 GiB / (SQLite's minimum 512-byte page * 256 pages per step), plus
; bounded slack for a source-generation restart.
%define AF_BACKUP_MAX_STEPS       525312

; Module-private Linux open(2) values.  They are not shared because this file
; is their only consumer and include/fileio.inc is outside the M11 change set.
%define AF_BK_O_RDWR              2
%define AF_BK_O_CREAT             0x40
%define AF_BK_O_EXCL              0x80
%define AF_BK_O_NOFOLLOW          0x20000
%define AF_BK_O_CLOEXEC           0x80000
%define AF_BK_MODE_PRIVATE        0o600
%define AF_BK_SQLITE_OPEN_NOFOLLOW 0x01000000

        extern af_mem_zero
        extern af_mul_size

        extern af_db_prepare
        extern af_db_finalize
        extern af_db_step
        extern af_db_column_int
        extern af_db_integrity_check
        extern af_db_status_from_code
        extern af_db_close

        extern af_sys_open
        extern af_sys_close
        extern af_sys_fchmod
        extern af_sys_fsync
        extern af_sys_unlink
        extern af_status_from_errno

        extern sqlite3_open_v2
        extern sqlite3_extended_errcode
        extern sqlite3_backup_init
        extern sqlite3_backup_step
        extern sqlite3_backup_finish
        extern sqlite3_backup_pagecount

        section .rodata

af_backup_main:           db "main", 0
af_backup_page_count_sql: db "PRAGMA page_count", 0
af_backup_page_size_sql:  db "PRAGMA page_size", 0

        section .text

; af_db_backup_validate_path(const char *path) -> af_status
;
; `path` is BORROWED.  Scanning stops at AF_BACKUP_PATH_MAX, so an unterminated
; untrusted path never turns into an unbounded libc/SQLite read.
af_db_backup_validate_path:
        test    rdi, rdi
        jz      .invalid
        xor     eax, eax
.scan:
        cmp     rax, AF_BACKUP_PATH_MAX
        jae     .limit
        cmp     byte [rdi + rax], 0
        je      .found
        inc     rax
        jmp     .scan
.found:
        test    rax, rax
        jz      .invalid
        xor     eax, eax
        ret
.invalid:
        mov     rax, AF_E_INVALID
        ret
.limit:
        mov     rax, AF_E_LIMIT
        ret

; af_db_backup_sqlite_status(i64 sqlite_code) -> af_status
;
; sqlite3_extended_errcode may include an extended value in the high bits;
; af_db_status_from_code consumes the stable primary code.
af_db_backup_sqlite_status:
        and     edi, 0xff
        jmp     af_db_status_from_code

; af_db_backup_query_i64(af_db *db, const char *static_sql, i64 *out)
;   -> af_status
;
; The statement is OWNED only by this helper and finalized on every path after
; successful prepare.  `out` is written only after a non-negative row value.
af_db_backup_query_i64:
        AF_ENTER 32
        test    rdx, rdx
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     qword [rsp], 0

        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        call    af_db_prepare
        test    rax, rax
        js      .done
        mov     r14, [rsp]

        mov     rdi, rbx
        mov     rsi, r14
        call    af_db_step
        test    rax, rax
        js      .finalize

        mov     rdi, r14
        xor     esi, esi
        call    af_db_column_int
        test    rax, rax
        js      .bad_value
        mov     [r13], rax
        xor     eax, eax
.finalize:
        mov     [rsp + 8], rax
        mov     rdi, r14
        call    af_db_finalize
        mov     rax, [rsp + 8]
.done:
        AF_LEAVE
.bad_value:
        mov     rax, AF_E_DB_SCHEMA
        jmp     .finalize
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_db_backup_measure(af_db *db, u64 *out_bytes, u64 *out_page_size)
;   -> af_status
;
; Both outputs are caller-owned.  SQLite page sizes are validated before the
; checked multiplication, and neither output is published on failure.
af_db_backup_measure:
        AF_ENTER 48
        test    rdi, rdi
        jz      .invalid
        cmp     qword [rdi + DB_HANDLE], 0
        je      .closed
        test    rsi, rsi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, rbx
        lea     rsi, [af_backup_page_count_sql]
        lea     rdx, [rsp]
        call    af_db_backup_query_i64
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [af_backup_page_size_sql]
        lea     rdx, [rsp + 8]
        call    af_db_backup_query_i64
        test    rax, rax
        js      .done

        ; SQLite accepts power-of-two page sizes from 512 through 65536.
        mov     rax, [rsp + 8]
        cmp     rax, 512
        jb      .bad_page_size
        cmp     rax, 65536
        ja      .bad_page_size
        lea     rcx, [rax - 1]
        test    rax, rcx
        jnz     .bad_page_size

        mov     rdi, [rsp]
        mov     rsi, rax
        lea     rdx, [rsp + 16]
        call    af_mul_size
        test    rax, rax
        js      .done
        mov     rax, [rsp + 16]
        mov     [r12], rax
        mov     rax, [rsp + 8]
        mov     [r13], rax
        xor     eax, eax
.done:
        AF_LEAVE
.bad_page_size:
        AF_LEAVE_ERR AF_E_DB_SCHEMA
.closed:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_db_backup_to_path(af_db *source, const char *destination_path,
;                      u64 max_bytes) -> af_status
;
; The final path itself is reserved with O_CREAT|O_EXCL|O_NOFOLLOW.  Therefore
; an existing file, directory, or symlink is never opened by this operation.
; On failure this function unlinks only the inode name it created; it never
; removes a pre-existing destination.  The reservation fd and destination
; SQLite handle are OWNED here and closed on all paths.
;
; sqlite3_backup_finish rule: after a non-NULL sqlite3_backup_init result,
; every branch reaches `.finish_backup`, which invokes finish exactly once and
; clears the pointer before any later cleanup can run.
        global af_db_backup_to_path
af_db_backup_to_path:
        AF_ENTER 128
        mov     rbx, rdi                ; BORROWED source af_db
        mov     r12, rsi                ; BORROWED destination path
        mov     r13, rdx                ; caller byte ceiling
        mov     qword [rsp + 40], -1    ; reservation fd
        mov     qword [rsp + 48], 0     ; created destination flag
        mov     qword [rsp + 56], 0     ; sqlite3_backup *
        mov     qword [rsp + 64], 0     ; saved af_status
        mov     qword [rsp + 88], 0     ; step count
        mov     qword [rsp + 96], 0     ; current step result
        lea     rdi, [rsp]              ; local destination af_db
        mov     rsi, DB_SIZE
        call    af_mem_zero

        test    rbx, rbx
        jz      .invalid
        cmp     qword [rbx + DB_HANDLE], 0
        je      .closed
        mov     rdi, r12
        call    af_db_backup_validate_path
        test    rax, rax
        js      .return
        test    r13, r13
        jz      .invalid
        mov     rax, AF_BACKUP_HARD_MAX_BYTES
        cmp     r13, rax
        ja      .limit

        ; Preflight happens before O_CREAT, so a size rejection leaves no file.
        mov     rdi, rbx
        lea     rsi, [rsp + 72]
        lea     rdx, [rsp + 80]
        call    af_db_backup_measure
        test    rax, rax
        js      .return
        cmp     qword [rsp + 72], r13
        ja      .limit

        mov     rdi, r12
        mov     esi, AF_BK_O_RDWR | AF_BK_O_CREAT | AF_BK_O_EXCL | AF_BK_O_NOFOLLOW | AF_BK_O_CLOEXEC
        mov     edx, AF_BK_MODE_PRIVATE
        call    af_sys_open
        test    rax, rax
        js      .open_errno
        mov     [rsp + 40], rax
        mov     qword [rsp + 48], 1

        mov     rdi, rax
        mov     esi, AF_BK_MODE_PRIVATE
        call    af_sys_fchmod
        test    rax, rax
        js      .syscall_failed

        mov     [rsp + DB_PATH], r12
        mov     rdi, r12
        lea     rsi, [rsp + DB_HANDLE]
        mov     edx, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | AF_BK_SQLITE_OPEN_NOFOLLOW
        xor     ecx, ecx
        call    sqlite3_open_v2 wrt ..plt
        mov     [rsp + DB_LAST_CODE], rax
        cmp     eax, SQLITE_OK
        jne     .sqlite_open_failed

        mov     rdi, [rsp + DB_HANDLE]
        lea     rsi, [af_backup_main]
        mov     rdx, [rbx + DB_HANDLE]
        lea     rcx, [af_backup_main]
        call    sqlite3_backup_init wrt ..plt
        test    rax, rax
        jz      .backup_init_failed
        mov     [rsp + 56], rax

.step:
        inc     qword [rsp + 88]
        cmp     qword [rsp + 88], AF_BACKUP_MAX_STEPS
        ja      .step_limit
        mov     rdi, [rsp + 56]
        mov     esi, AF_BACKUP_STEP_PAGES
        call    sqlite3_backup_step wrt ..plt
        mov     [rsp + 96], rax
        cmp     eax, SQLITE_OK
        je      .check_step_size
        cmp     eax, SQLITE_DONE
        je      .check_step_size
        mov     rdi, rax
        call    af_db_backup_sqlite_status
        mov     [rsp + 64], rax
        jmp     .finish_backup

.check_step_size:
        mov     rdi, [rsp + 56]
        call    sqlite3_backup_pagecount wrt ..plt
        test    eax, eax
        js      .step_db_error
        movsxd  rdi, eax
        mov     rsi, [rsp + 80]
        lea     rdx, [rsp + 104]
        call    af_mul_size
        test    rax, rax
        js      .save_step_status
        mov     rax, [rsp + 104]
        cmp     rax, r13
        ja      .step_limit
        cmp     dword [rsp + 96], SQLITE_DONE
        jne     .step
        mov     qword [rsp + 64], AF_OK
        jmp     .finish_backup

.step_db_error:
        mov     rax, AF_E_DB
        jmp     .save_step_status
.step_limit:
        mov     rax, AF_E_LIMIT
.save_step_status:
        mov     [rsp + 64], rax

.finish_backup:
        ; This is the sole finish call for every successful backup_init.
        mov     rdi, [rsp + 56]
        call    sqlite3_backup_finish wrt ..plt
        mov     qword [rsp + 56], 0
        mov     [rsp + 104], rax
        cmp     qword [rsp + 64], 0
        jl      .cleanup
        mov     rdi, [rsp + 104]
        call    af_db_backup_sqlite_status
        test    rax, rax
        js      .save_and_cleanup

        lea     rdi, [rsp]
        call    af_db_integrity_check
        test    rax, rax
        js      .save_and_cleanup

        ; SQLite has closed over the completed image before the inode is synced.
        lea     rdi, [rsp]
        call    af_db_close
        mov     rdi, [rsp + 40]
        mov     esi, AF_BK_MODE_PRIVATE
        call    af_sys_fchmod
        test    rax, rax
        js      .syscall_failed
        mov     rdi, [rsp + 40]
        call    af_sys_fsync
        test    rax, rax
        js      .syscall_failed
        mov     rdi, [rsp + 40]
        call    af_sys_close
        mov     qword [rsp + 40], -1
        test    rax, rax
        js      .close_failed
        mov     qword [rsp + 48], 0     ; success owns no live resource
        xor     eax, eax
        jmp     .return

.backup_init_failed:
        mov     rdi, [rsp + DB_HANDLE]
        call    sqlite3_extended_errcode wrt ..plt
        mov     rdi, rax
        call    af_db_backup_sqlite_status
        jmp     .save_and_cleanup
.sqlite_open_failed:
        mov     rdi, rax
        call    af_db_backup_sqlite_status
        jmp     .save_and_cleanup
.syscall_failed:
        mov     rdi, rax
        call    af_status_from_errno
        jmp     .save_and_cleanup
.close_failed:
        mov     rdi, rax
        call    af_status_from_errno
        jmp     .save_and_cleanup
.open_errno:
        mov     rdi, rax
        call    af_status_from_errno
        jmp     .return
.save_and_cleanup:
        mov     [rsp + 64], rax
.cleanup:
        ; backup pointer must be NULL here: all post-init paths finished once.
        lea     rdi, [rsp]
        call    af_db_close
        mov     rdi, [rsp + 40]
        test    rdi, rdi
        js      .maybe_unlink
        call    af_sys_close
        mov     qword [rsp + 40], -1
.maybe_unlink:
        cmp     qword [rsp + 48], 0
        je      .cleanup_done
        mov     rdi, r12
        call    af_sys_unlink
.cleanup_done:
        mov     rax, [rsp + 64]
        jmp     .return
.limit:
        mov     rax, AF_E_LIMIT
        jmp     .return
.closed:
        mov     rax, AF_E_CLOSED
        jmp     .return
.invalid:
        mov     rax, AF_E_INVALID
.return:
        AF_LEAVE

; af_db_backup_open_verified(const char *path, u64 max_bytes, af_db *out)
;   -> af_status
;
; Opens an existing backup on a separate READONLY SQLite connection, enforces
; the same bounded size calculation, then runs PRAGMA integrity_check.  On
; success the handle is TRANSFERRED to the caller; `path` remains BORROWED and
; must outlive that handle.  `out` must be uninitialized/closed caller storage;
; on every failure it is left closed and zeroed.
        global af_db_backup_open_verified
af_db_backup_open_verified:
        AF_ENTER 48
        mov     rbx, rdi                ; BORROWED path
        mov     r12, rsi                ; caller byte ceiling
        mov     r13, rdx                ; caller-owned output af_db
        test    r13, r13
        jz      .invalid
        mov     rdi, r13
        mov     rsi, DB_SIZE
        call    af_mem_zero
        mov     rdi, rbx
        call    af_db_backup_validate_path
        test    rax, rax
        js      .return
        test    r12, r12
        jz      .invalid
        mov     rax, AF_BACKUP_HARD_MAX_BYTES
        cmp     r12, rax
        ja      .limit

        mov     [r13 + DB_PATH], rbx
        mov     rdi, rbx
        lea     rsi, [r13 + DB_HANDLE]
        mov     edx, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | AF_BK_SQLITE_OPEN_NOFOLLOW
        xor     ecx, ecx
        call    sqlite3_open_v2 wrt ..plt
        mov     [r13 + DB_LAST_CODE], rax
        cmp     eax, SQLITE_OK
        jne     .sqlite_failed

        mov     rdi, r13
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_db_backup_measure
        test    rax, rax
        js      .fail
        cmp     qword [rsp], r12
        ja      .limit_open
        mov     rdi, r13
        call    af_db_integrity_check
        test    rax, rax
        js      .fail
        xor     eax, eax
        jmp     .return

.sqlite_failed:
        mov     rdi, rax
        call    af_db_backup_sqlite_status
        jmp     .fail
.limit_open:
        mov     rax, AF_E_LIMIT
.fail:
        mov     [rsp + 16], rax
        mov     rdi, r13
        call    af_db_close
        mov     rdi, r13
        mov     rsi, DB_SIZE
        call    af_mem_zero
        mov     rax, [rsp + 16]
        jmp     .return
.limit:
        mov     rax, AF_E_LIMIT
        jmp     .return
.invalid:
        mov     rax, AF_E_INVALID
.return:
        AF_LEAVE

; af_db_backup_verify_path(const char *path, u64 max_bytes) -> af_status
;
; Convenience verifier for callers that do not need to retain the separate
; read-only handle.  The local af_db is owned and closed entirely here.
        global af_db_backup_verify_path
af_db_backup_verify_path:
        AF_ENTER 48
        lea     rdx, [rsp]
        call    af_db_backup_open_verified
        test    rax, rax
        js      .done
        lea     rdi, [rsp]
        call    af_db_close
        xor     eax, eax
.done:
        AF_LEAVE

; af_db_restore_to_path(const char *verified_backup_path,
;                       const char *new_destination_path,
;                       u64 max_bytes) -> af_status
;
; Both paths are BORROWED for the duration of this synchronous call.  The
; source is opened by af_db_backup_open_verified as a separate
; READONLY|NOFOLLOW connection and must pass the byte ceiling plus
; integrity_check before any destination is created.  The verified handle is
; OWNED only by this frame and closed on every post-open path.
;
; Restoration deliberately reuses af_db_backup_to_path instead of copying file
; bytes: SQLite takes a coherent snapshot, the destination is reserved with
; O_EXCL, mode 0600 and fsync are enforced, and no existing destination can be
; replaced.  On failure no handle is transferred to the caller.
        global af_db_restore_to_path
af_db_restore_to_path:
        AF_ENTER 48
        mov     rbx, rdi                ; BORROWED verified backup path
        mov     r12, rsi                ; BORROWED new destination path
        mov     r13, rdx                ; caller byte ceiling
        test    rbx, rbx
        jz      .invalid
        mov     rdi, r12
        call    af_db_backup_validate_path
        test    rax, rax
        js      .done

        mov     rdi, rbx
        mov     rsi, r13
        lea     rdx, [rsp]
        call    af_db_backup_open_verified
        test    rax, rax
        js      .done

        lea     rdi, [rsp]
        mov     rsi, r12
        mov     rdx, r13
        call    af_db_backup_to_path
        mov     [rsp + 40], rax
        lea     rdi, [rsp]
        call    af_db_close
        mov     rax, [rsp + 40]
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
