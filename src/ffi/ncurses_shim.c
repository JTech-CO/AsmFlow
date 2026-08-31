/* AsmFlow -- ncurses macro and opaque-WINDOW ABI adapter.
 *
 * ncurses exposes getmaxyx(), COLOR_PAIR(), and several key values as C
 * macros.  Assembly must not duplicate WINDOW layout or macro encodings, so
 * this file turns only those ABI facts into fixed-signature functions.  It
 * contains no layout, key-dispatch, colour, confirmation, or cleanup policy.
 *
 * Ownership: WINDOW pointers and output pointers are BORROWED.  No reference
 * is retained and this adapter performs no allocation.
 */

#include <ncurses.h>
#include <stdint.h>

int af_ncc_getmaxyx(WINDOW *window, int64_t *out_rows, int64_t *out_columns)
{
    int rows;
    int columns;

    if (window == NULL || out_rows == NULL || out_columns == NULL) {
        return ERR;
    }
    getmaxyx(window, rows, columns);
    *out_rows = (int64_t)rows;
    *out_columns = (int64_t)columns;
    return OK;
}

int64_t af_ncc_color_pair(int64_t pair)
{
    return (int64_t)COLOR_PAIR((int)pair);
}

int64_t af_ncc_key_resize(void)
{
    return (int64_t)KEY_RESIZE;
}

int64_t af_ncc_key_backspace(void)
{
    return (int64_t)KEY_BACKSPACE;
}

int64_t af_ncc_err(void)
{
    return (int64_t)ERR;
}
