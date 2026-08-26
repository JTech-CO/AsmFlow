/* AsmFlow — SQLite constant manifest.
 *
 * SQLite's API is entirely real functions, so unlike Jansson it needs no
 * forwarding layer. What it does have is a large set of preprocessor constants
 * that the assembly must agree with exactly: a result code the assembly reads
 * as "done" when the library means "busy" would turn a contended write into a
 * silent success.
 *
 * This file therefore exports the constants rather than the functions. The
 * assembly keeps its own copies in include/db.inc, and tests/asm/test_db.asm
 * asserts the two agree, so a SQLite upgrade that renumbered anything fails a
 * test instead of misreading a result.
 *
 * AGENTS.md invariant 2 holds: there is no decision here, only values.
 */

#include <sqlite3.h>
#include <stddef.h>
#include <stdint.h>

/* Written in a fixed order that include/db.inc mirrors. */
void af_sqlitec_result_codes(int64_t *out)
{
    out[0] = SQLITE_OK;
    out[1] = SQLITE_ERROR;
    out[2] = SQLITE_BUSY;
    out[3] = SQLITE_LOCKED;
    out[4] = SQLITE_READONLY;
    out[5] = SQLITE_IOERR;
    out[6] = SQLITE_CORRUPT;
    out[7] = SQLITE_FULL;
    out[8] = SQLITE_CANTOPEN;
    out[9] = SQLITE_CONSTRAINT;
    out[10] = SQLITE_MISUSE;
    out[11] = SQLITE_NOTADB;
    out[12] = SQLITE_ROW;
    out[13] = SQLITE_DONE;
}

void af_sqlitec_open_flags(int64_t *out)
{
    out[0] = SQLITE_OPEN_READONLY;
    out[1] = SQLITE_OPEN_READWRITE;
    out[2] = SQLITE_OPEN_CREATE;
    out[3] = SQLITE_OPEN_NOMUTEX;
    out[4] = SQLITE_OPEN_FULLMUTEX;
    out[5] = SQLITE_OPEN_URI;
}

void af_sqlitec_column_types(int64_t *out)
{
    out[0] = SQLITE_INTEGER;
    out[1] = SQLITE_FLOAT;
    out[2] = SQLITE_TEXT;
    out[3] = SQLITE_BLOB;
    out[4] = SQLITE_NULL;
}

/* SQLITE_TRANSIENT is a cast of -1 to a function-pointer type, which assembly
 * cannot spell portably. Telling SQLite the text is transient makes it copy the
 * bytes, which is what every bind site here wants: the source is usually an
 * arena string whose lifetime ends with the request. */
void *af_sqlitec_transient(void)
{
    return (void *)SQLITE_TRANSIENT;
}

void *af_sqlitec_static(void)
{
    return (void *)SQLITE_STATIC;
}

const char *af_sqlitec_libversion(void)
{
    return sqlite3_libversion();
}
