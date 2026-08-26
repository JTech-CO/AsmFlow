/* AsmFlow — Jansson ABI adapter.
 *
 * ADR 0007. Jansson exposes several of its accessors as preprocessor macros
 * (`json_typeof`, `json_is_object`, and friends) that dereference the `json_t`
 * struct directly. Assembly cannot call a macro, so the alternatives were to
 * hard-code the struct layout in NASM or to re-export the macros as real
 * functions. The layout is not part of Jansson's compatibility promise, and a
 * silent change to it would corrupt every parse; this file therefore exists.
 *
 * AGENTS.md invariant 2 still applies in full: nothing here makes a decision.
 * There is no validation, no limit, no policy, and no allocation. Every
 * function is a one-line forwarding of a macro or a struct field, and depth,
 * size, count, and schema rules all live in the assembly above it.
 *
 * Ownership: every `json_t *` argument is BORROWED. Reference counting stays
 * with the caller, because the caller is the only side that knows the lifetime.
 */

#include <jansson.h>
#include <stddef.h>
#include <stdint.h>

/* --- type discrimination -------------------------------------------------
 * The returned values are the JSON_* enumerators. include/json.inc mirrors
 * them, and af_jsonc_type_ordinals() below lets a test assert the two agree
 * rather than trusting a comment.
 */
int af_jsonc_type(const json_t *value)
{
    if (value == NULL) {
        return -1;
    }
    return (int)json_typeof(value);
}

/* Writes the eight enumerator values in a fixed order so assembly can check
 * them against its own constants: object, array, string, integer, real, true,
 * false, null. */
void af_jsonc_type_ordinals(int *out8)
{
    out8[0] = JSON_OBJECT;
    out8[1] = JSON_ARRAY;
    out8[2] = JSON_STRING;
    out8[3] = JSON_INTEGER;
    out8[4] = JSON_REAL;
    out8[5] = JSON_TRUE;
    out8[6] = JSON_FALSE;
    out8[7] = JSON_NULL;
}

/* --- error object --------------------------------------------------------
 * json_error_t has a fixed-size layout that assembly would otherwise have to
 * reproduce. Allocating it here keeps that knowledge on this side of the
 * boundary. The caller supplies the storage.
 */
size_t af_jsonc_error_size(void)
{
    return sizeof(json_error_t);
}

int af_jsonc_error_line(const json_error_t *error)
{
    return error->line;
}

int af_jsonc_error_column(const json_error_t *error)
{
    return error->column;
}

int af_jsonc_error_position(const json_error_t *error)
{
    return error->position;
}

const char *af_jsonc_error_text(const json_error_t *error)
{
    return error->text;
}

/* --- parse flags ---------------------------------------------------------
 * Returned rather than duplicated in assembly so a Jansson upgrade that
 * renumbers a flag cannot silently change what the parser rejects.
 *
 * JSON_REJECT_DUPLICATES matters for the configuration contract: a duplicate
 * key would otherwise let a later value silently override an earlier one,
 * which is a way to smuggle a setting past a reviewer who read the first
 * occurrence.
 */
size_t af_jsonc_parse_flags(void)
{
    return JSON_REJECT_DUPLICATES | JSON_DECODE_ANY;
}

/* --- object iteration ----------------------------------------------------
 * These are real functions in Jansson, but they are re-exported here so the
 * whole boundary is visible in one file and so the assembly links against a
 * single, auditable surface.
 */
void *af_jsonc_object_iter(json_t *object)
{
    return json_object_iter(object);
}

void *af_jsonc_object_iter_next(json_t *object, void *iter)
{
    return json_object_iter_next(object, iter);
}

const char *af_jsonc_object_iter_key(void *iter)
{
    return json_object_iter_key(iter);
}

json_t *af_jsonc_object_iter_value(void *iter)
{
    return json_object_iter_value(iter);
}

/* --- scalar accessors ---------------------------------------------------- */
const char *af_jsonc_string_value(const json_t *value)
{
    return json_string_value(value);
}

size_t af_jsonc_string_length(const json_t *value)
{
    return json_string_length(value);
}

int64_t af_jsonc_integer_value(const json_t *value)
{
    return (int64_t)json_integer_value(value);
}

double af_jsonc_real_value(const json_t *value)
{
    return json_real_value(value);
}

/* --- container accessors ------------------------------------------------- */
json_t *af_jsonc_object_get(json_t *object, const char *key)
{
    return json_object_get(object, key);
}

size_t af_jsonc_object_size(const json_t *object)
{
    return json_object_size(object);
}

json_t *af_jsonc_array_get(json_t *array, size_t index)
{
    return json_array_get(array, index);
}

size_t af_jsonc_array_size(const json_t *array)
{
    return json_array_size(array);
}

/* --- lifetime ------------------------------------------------------------ */
json_t *af_jsonc_loadb(const char *buffer, size_t buflen, size_t flags,
                       json_error_t *error)
{
    return json_loadb(buffer, buflen, flags, error);
}

void af_jsonc_decref(json_t *value)
{
    json_decref(value);
}
