/* AsmFlow — C side of the ABI boundary.
 *
 * AGENTS.md invariant 2: C shims are ABI adapters only. Nothing in this file
 * makes a routing, retry, provider, MCP, security, or persistence decision. It
 * exists so that the assembly can be checked against a real C compiler's idea
 * of the System V AMD64 ABI rather than against our own reading of it.
 *
 * It also pins the structure layouts that assembly and C both depend on. The
 * offsets below are written out by hand; the assembly reports its own with
 * af_*_struct_size, and af_ffi_struct_offsets_match asserts they agree. A
 * layout change in either place fails the M2 gate until both are updated.
 */

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

/* Sizes reported by the assembly side. */
uint64_t af_buf_struct_size(void);
uint64_t af_sv_struct_size(void);
uint64_t af_arena_struct_size(void);

/* C mirrors of the assembly layouts. These are the definitions any future C
 * shim would use, so keeping them in step is not busywork: a mismatch would
 * corrupt memory at the first callback that touched one. */
typedef struct {
    uint8_t *data;
    uint64_t len;
    uint64_t cap;
    uint64_t max;
} af_buffer_c;

typedef struct {
    const uint8_t *ptr;
    uint64_t len;
} af_strview_c;

typedef struct {
    void *head;
    uint64_t chunk_size;
    uint64_t total_bytes;
    uint64_t max_bytes;
    uint64_t finalized;
    uint64_t alloc_count;
} af_arena_c;

/* ---------------------------------------------------------------------------
 * af_ffi_check_args
 *
 * Six register arguments plus two stack arguments. Returns 1 only when every
 * one arrived with the expected value, which catches a call site that forgot
 * that arguments seven and eight go on the stack in order.
 * ------------------------------------------------------------------------- */
int af_ffi_check_args(long a0, long a1, long a2, long a3, long a4, long a5,
                      long s0, long s1)
{
    return (a0 == 1 && a1 == 2 && a2 == 3 && a3 == 4 && a4 == 5 && a5 == 6 &&
            s0 == 7 && s1 == 8)
               ? 1
               : 0;
}

/* ---------------------------------------------------------------------------
 * af_ffi_check_variadic
 *
 * A variadic callee. Reaching it with a stale al would make va_arg read from
 * the register save area for vector registers that were never spilled, which is
 * the failure the "set al before a variadic call" rule exists to prevent.
 * ------------------------------------------------------------------------- */
long af_ffi_check_variadic(int count, ...)
{
    va_list ap;
    long total = 0;

    va_start(ap, count);
    for (int i = 0; i < count; i++) {
        total += va_arg(ap, long);
    }
    va_end(ap);
    return total;
}

/* ---------------------------------------------------------------------------
 * af_ffi_struct_offsets_match
 *
 * Returns 0 when every shared layout agrees, or a bitmask naming the first
 * disagreement per structure so the failure message is actionable.
 * ------------------------------------------------------------------------- */
uint64_t af_ffi_struct_offsets_match(void)
{
    uint64_t bad = 0;

    if (sizeof(af_buffer_c) != af_buf_struct_size()) bad |= 1u << 0;
    if (offsetof(af_buffer_c, data) != 0) bad |= 1u << 1;
    if (offsetof(af_buffer_c, len) != 8) bad |= 1u << 2;
    if (offsetof(af_buffer_c, cap) != 16) bad |= 1u << 3;
    if (offsetof(af_buffer_c, max) != 24) bad |= 1u << 4;

    if (sizeof(af_strview_c) != af_sv_struct_size()) bad |= 1u << 5;
    if (offsetof(af_strview_c, ptr) != 0) bad |= 1u << 6;
    if (offsetof(af_strview_c, len) != 8) bad |= 1u << 7;

    if (sizeof(af_arena_c) != af_arena_struct_size()) bad |= 1u << 8;
    if (offsetof(af_arena_c, head) != 0) bad |= 1u << 9;
    if (offsetof(af_arena_c, chunk_size) != 8) bad |= 1u << 10;
    if (offsetof(af_arena_c, total_bytes) != 16) bad |= 1u << 11;
    if (offsetof(af_arena_c, max_bytes) != 24) bad |= 1u << 12;
    if (offsetof(af_arena_c, finalized) != 32) bad |= 1u << 13;
    if (offsetof(af_arena_c, alloc_count) != 40) bad |= 1u << 14;

    return bad;
}

/* ---------------------------------------------------------------------------
 * af_ffi_stack_alignment_seen
 *
 * Reports the low four bits of the frame base as this compiler established it.
 * With a frame pointer, the base is the caller's aligned rsp minus 16, so a
 * conforming caller yields 0. Built with -fno-omit-frame-pointer for exactly
 * this reason (see the Makefile).
 * ------------------------------------------------------------------------- */
uint64_t af_ffi_stack_alignment_seen(void)
{
    return ((uintptr_t)__builtin_frame_address(0)) & 15u;
}
