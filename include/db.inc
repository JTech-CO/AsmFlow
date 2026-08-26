; AsmFlow — SQLite result codes, flags, and handle layout.
;
; These constants are asserted against the linked library by
; tests/asm/test_db.asm rather than trusted: reading a "busy" as a "done" would
; turn a contended write into a silent success.

%ifndef ASMFLOW_DB_INC
%define ASMFLOW_DB_INC

%define SQLITE_OK          0
%define SQLITE_ERROR       1
%define SQLITE_BUSY        5
%define SQLITE_LOCKED      6
%define SQLITE_READONLY    8
%define SQLITE_IOERR       10
%define SQLITE_CORRUPT     11
%define SQLITE_FULL        13
%define SQLITE_CANTOPEN    14
%define SQLITE_CONSTRAINT  19
%define SQLITE_MISUSE      21
%define SQLITE_NOTADB      26
%define SQLITE_ROW         100
%define SQLITE_DONE        101

%define SQLITE_OPEN_READONLY   0x00000001
%define SQLITE_OPEN_READWRITE  0x00000002
%define SQLITE_OPEN_CREATE     0x00000004
%define SQLITE_OPEN_NOMUTEX    0x00008000
%define SQLITE_OPEN_FULLMUTEX  0x00010000
%define SQLITE_OPEN_URI        0x00000040

%define SQLITE_INTEGER 1
%define SQLITE_FLOAT   2
%define SQLITE_TEXT    3
%define SQLITE_BLOB    4
%define SQLITE_NULL    5

; af_db — the daemon's single database handle (ARCHITECTURE.md 9: asmflowd is
; the only writer).
;
;   +0   handle          sqlite3 * (owned)
;   +8   last_code       the most recent raw SQLite result code
;   +16  in_transaction  1 between BEGIN and COMMIT/ROLLBACK
;   +24  writes_blocked  test hook: forces every write to report AF_E_DB
;   +32  path            char * (BORROWED from the configuration snapshot)
%define DB_HANDLE         0
%define DB_LAST_CODE      8
%define DB_IN_TRANSACTION 16
%define DB_WRITES_BLOCKED 24
%define DB_PATH           32
%define DB_SIZE           40

%endif ; ASMFLOW_DB_INC
