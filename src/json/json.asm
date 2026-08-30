; AsmFlow — bounded JSON parsing and normalised accessors.
;
; Everything untrusted that reaches the runtime as JSON — the configuration
; file, an inbound request envelope, an upstream response, an MCP frame — is
; parsed through here, under explicit byte, depth, string, and element limits
; (AGENTS.md invariant 8).
;
; Jansson does the syntax. This module owns the limits, because Jansson's own
; depth ceiling is a compile-time constant and its string handling has no
; per-value ceiling at all. The depth check runs BEFORE the parse: a document
; nested a million levels deep must be refused without first building a million
; levels of nodes.
;
; No policy lives here. Which keys are required, which values are legal, and
; what a violation means are all decided in src/config.

        bits 64
        default rel

%include "asmflow.inc"
%include "json.inc"

        extern af_alloc
        extern af_free
        extern af_mem_zero
        extern af_jsonc_loadb
        extern af_jsonc_decref
        extern af_jsonc_type
        extern af_jsonc_error_size
        extern af_jsonc_error_line
        extern af_jsonc_error_column
        extern af_jsonc_error_position
        extern af_jsonc_parse_flags
        extern af_jsonc_object_get
        extern af_jsonc_object_size
        extern af_jsonc_array_get
        extern af_jsonc_array_size
        extern af_jsonc_string_value
        extern af_jsonc_string_length
        extern af_jsonc_integer_value
        extern af_jsonc_object_iter
        extern af_jsonc_object_iter_next
        extern af_jsonc_object_iter_key
        extern af_jsonc_object_iter_key_len
        extern af_jsonc_object_iter_value

        section .text

; ---------------------------------------------------------------------------
; af_json_scan_depth(const char *buf, u64 len, u64 max_depth) -> af_status
;
; String-aware bracket scan. Counts nesting outside string literals, honours
; backslash escapes inside them, and rejects a document whose nesting exceeds
; `max_depth` or whose brackets do not balance.
;
; This runs on raw untrusted bytes before any allocation, so it is also the
; first fuzz target of the JSON boundary (TEST_STRATEGY.md I).
;
; Returns AF_OK, AF_E_JSON_DEPTH, or AF_E_JSON_PARSE for unbalanced input.
; ---------------------------------------------------------------------------
        global af_json_scan_depth
af_json_scan_depth:
        AF_ENTER 0
        mov     rbx, rdi                ; buffer
        mov     r12, rsi                ; length
        mov     r13, rdx                ; max depth
        xor     r14, r14                ; cursor
        xor     r15, r15                ; current depth
        xor     r8d, r8d                ; 1 = inside a string
        xor     r9d, r9d                ; 1 = previous byte was a backslash

.loop:
        cmp     r14, r12
        jae     .end
        movzx   eax, byte [rbx + r14]
        inc     r14

        test    r8d, r8d
        jnz     .in_string

        cmp     al, '"'
        je      .enter_string
        cmp     al, '{'
        je      .open
        cmp     al, '['
        je      .open
        cmp     al, '}'
        je      .close
        cmp     al, ']'
        je      .close
        jmp     .loop

.enter_string:
        mov     r8d, 1
        xor     r9d, r9d
        jmp     .loop

.in_string:
        test    r9d, r9d
        jnz     .escaped
        cmp     al, '\'
        je      .set_escape
        cmp     al, '"'
        je      .leave_string
        jmp     .loop
.set_escape:
        mov     r9d, 1
        jmp     .loop
.escaped:
        xor     r9d, r9d
        jmp     .loop
.leave_string:
        xor     r8d, r8d
        jmp     .loop

.open:
        inc     r15
        cmp     r15, r13
        ja      .too_deep
        jmp     .loop

.close:
        test    r15, r15
        jz      .unbalanced
        dec     r15
        jmp     .loop

.end:
        ; An unterminated string or an unclosed bracket is a syntax error that
        ; Jansson would also reject; catching it here keeps the two answers
        ; consistent and avoids parsing a document already known to be bad.
        test    r8d, r8d
        jnz     .unbalanced
        test    r15, r15
        jnz     .unbalanced
        AF_LEAVE_OK
.too_deep:
        AF_LEAVE_ERR AF_E_JSON_DEPTH
.unbalanced:
        AF_LEAVE_ERR AF_E_JSON_PARSE

; ---------------------------------------------------------------------------
; af_json_parse(const char *buf, u64 len, const af_json_limits *limits,
;               af_json_doc *out) -> af_status
;
; Ownership: `buf` and `limits` are BORROWED. `out` is caller-supplied storage;
; on success it owns a document that must be released with af_json_doc_free.
; On failure `out` carries the parse position and holds no reference.
; ---------------------------------------------------------------------------
        global af_json_parse
af_json_parse:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        test    rcx, rcx
        jz      .invalid
        mov     rbx, rdi                ; buffer
        mov     r12, rsi                ; length
        mov     r13, rdx                ; limits
        mov     r14, rcx                ; out doc

        mov     qword [r14 + AF_JSONDOC_ROOT], 0
        mov     qword [r14 + AF_JSONDOC_LINE], 0
        mov     qword [r14 + AF_JSONDOC_COLUMN], 0
        mov     qword [r14 + AF_JSONDOC_POSITION], 0

        mov     rax, [r13 + AF_JSONLIM_MAX_BYTES]
        cmp     r12, rax
        ja      .too_large

        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, [r13 + AF_JSONLIM_MAX_DEPTH]
        call    af_json_scan_depth
        test    rax, rax
        js      .done

        ; The error object's size is whatever the linked Jansson says it is.
        call    af_jsonc_error_size
        mov     r15, rax
        mov     rdi, r15
        call    af_alloc
        test    rax, rax
        jz      .nomem
        mov     [rsp], rax              ; error object
        mov     rdi, rax
        mov     rsi, r15
        call    af_mem_zero

        call    af_jsonc_parse_flags
        mov     rdx, rax
        mov     rdi, rbx
        mov     rsi, r12
        mov     rcx, [rsp]
        call    af_jsonc_loadb
        test    rax, rax
        jz      .parse_failed
        mov     [r14 + AF_JSONDOC_ROOT], rax

        mov     rdi, [rsp]
        call    af_free

        ; Walk the parsed tree for the per-value limits Jansson does not apply.
        mov     rdi, [r14 + AF_JSONDOC_ROOT]
        mov     rsi, r13
        call    af_json_enforce_limits
        test    rax, rax
        js      .limit_failed
        AF_LEAVE_OK

.limit_failed:
        mov     [rsp + 8], rax
        mov     rdi, r14
        call    af_json_doc_free
        mov     rax, [rsp + 8]
        AF_LEAVE

.parse_failed:
        mov     rdi, [rsp]
        call    af_jsonc_error_line
        mov     [r14 + AF_JSONDOC_LINE], rax
        mov     rdi, [rsp]
        call    af_jsonc_error_column
        mov     [r14 + AF_JSONDOC_COLUMN], rax
        mov     rdi, [rsp]
        call    af_jsonc_error_position
        mov     [r14 + AF_JSONDOC_POSITION], rax
        mov     rdi, [rsp]
        call    af_free
        AF_LEAVE_ERR AF_E_JSON_PARSE

.too_large:
        AF_LEAVE_ERR AF_E_JSON_SIZE
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_json_enforce_limits(json_t *value, const af_json_limits *limits)
;   -> af_status
;
; Recursive post-parse walk applying the string-length and element-count
; ceilings. Recursion is safe because af_json_scan_depth has already bounded
; the nesting to max_depth, and max_depth is itself bounded by AF_MAX_JSON_DEPTH.
; ---------------------------------------------------------------------------
        global af_json_enforce_limits
af_json_enforce_limits:
        AF_ENTER 32
        test    rdi, rdi
        jz      .ok
        mov     rbx, rdi                ; value
        mov     r12, rsi                ; limits

        mov     rdi, rbx
        call    af_jsonc_type
        mov     r13, rax

        cmp     r13, AF_JSON_STRING
        je      .string
        cmp     r13, AF_JSON_ARRAY
        je      .array
        cmp     r13, AF_JSON_OBJECT
        je      .object
.ok:
        AF_LEAVE_OK

.string:
        mov     rdi, rbx
        call    af_jsonc_string_length
        cmp     rax, [r12 + AF_JSONLIM_MAX_STRING]
        ja      .too_long
        AF_LEAVE_OK

.array:
        mov     rdi, rbx
        call    af_jsonc_array_size
        cmp     rax, [r12 + AF_JSONLIM_MAX_ELEMS]
        ja      .too_many
        mov     r14, rax                ; count
        xor     r15, r15                ; index
.array_loop:
        cmp     r15, r14
        jae     .ok
        mov     rdi, rbx
        mov     rsi, r15
        call    af_jsonc_array_get
        mov     rdi, rax
        mov     rsi, r12
        call    af_json_enforce_limits
        test    rax, rax
        js      .done
        inc     r15
        jmp     .array_loop

.object:
        mov     rdi, rbx
        call    af_jsonc_object_size
        cmp     rax, [r12 + AF_JSONLIM_MAX_ELEMS]
        ja      .too_many
        mov     rdi, rbx
        call    af_jsonc_object_iter
        mov     r14, rax                ; iterator
.object_loop:
        test    r14, r14
        jz      .ok
        ; Object names are JSON strings too. Use Jansson's explicit length so
        ; embedded NUL cannot truncate the measurement and so max_string
        ; bounds keys as well as values.
        mov     rdi, r14
        call    af_jsonc_object_iter_key_len
        cmp     rax, [r12 + AF_JSONLIM_MAX_STRING]
        ja      .too_long
        mov     rdi, r14
        call    af_jsonc_object_iter_value
        mov     rdi, rax
        mov     rsi, r12
        call    af_json_enforce_limits
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r14
        call    af_jsonc_object_iter_next
        mov     r14, rax
        jmp     .object_loop

.too_long:
        AF_LEAVE_ERR AF_E_JSON_SIZE
.too_many:
        AF_LEAVE_ERR AF_E_LIMIT
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_json_doc_free(af_json_doc *doc) -> void
;
; Idempotent. Releases the single reference the parse acquired.
; ---------------------------------------------------------------------------
        global af_json_doc_free
af_json_doc_free:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rdi, [rbx + AF_JSONDOC_ROOT]
        test    rdi, rdi
        jz      .done
        call    af_jsonc_decref
        mov     qword [rbx + AF_JSONDOC_ROOT], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_json_doc_root(const af_json_doc *doc) -> json_t * (BORROWED)
; ---------------------------------------------------------------------------
        global af_json_doc_root
af_json_doc_root:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + AF_JSONDOC_ROOT]
.done:
        ret

; ---------------------------------------------------------------------------
; Normalised accessors.
;
; Each one answers a single question with a single status, so a caller never
; has to combine "is it present", "is it the right type", and "what is the
; value" from three separate results. Every returned pointer is BORROWED from
; the document and is invalid after af_json_doc_free.
; ---------------------------------------------------------------------------

; af_json_type(json_t *value) -> i64 (AF_JSON_*, or AF_JSON_INVALID for NULL)
        global af_json_type
af_json_type:
        AF_ENTER 0
        call    af_jsonc_type
        AF_LEAVE

; af_json_member(json_t *object, const char *key, json_t **out) -> af_status
;   AF_E_JSON_TYPE when the container is not an object.
;   AF_E_NOTFOUND when the key is absent; `out` is left untouched.
        global af_json_member
af_json_member:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, rbx
        call    af_jsonc_type
        cmp     rax, AF_JSON_OBJECT
        jne     .not_object
        mov     rdi, rbx
        mov     rsi, r12
        call    af_jsonc_object_get
        test    rax, rax
        jz      .absent
        test    r13, r13
        jz      .ok
        mov     [r13], rax
.ok:
        AF_LEAVE_OK
.absent:
        AF_LEAVE_ERR AF_E_NOTFOUND
.not_object:
        AF_LEAVE_ERR AF_E_JSON_TYPE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_json_get_string(json_t *object, const char *key, const char **out_ptr,
;                    u64 *out_len) -> af_status
        global af_json_get_string
af_json_get_string:
        AF_ENTER 32
        mov     [rsp + 8], rdx          ; out_ptr
        mov     [rsp + 16], rcx         ; out_len
        lea     rdx, [rsp]
        call    af_json_member
        test    rax, rax
        js      .done
        mov     rbx, [rsp]
        mov     rdi, rbx
        call    af_jsonc_type
        cmp     rax, AF_JSON_STRING
        jne     .not_string
        mov     rdi, rbx
        call    af_jsonc_string_value
        mov     r12, rax
        mov     rdi, rbx
        call    af_jsonc_string_length
        mov     rcx, [rsp + 8]
        test    rcx, rcx
        jz      .no_ptr
        mov     [rcx], r12
.no_ptr:
        mov     rcx, [rsp + 16]
        test    rcx, rcx
        jz      .ok
        mov     [rcx], rax
.ok:
        AF_LEAVE_OK
.not_string:
        AF_LEAVE_ERR AF_E_JSON_TYPE
.done:
        AF_LEAVE

; af_json_get_integer(json_t *object, const char *key, i64 *out) -> af_status
        global af_json_get_integer
af_json_get_integer:
        AF_ENTER 32
        mov     [rsp + 8], rdx          ; out
        lea     rdx, [rsp]
        call    af_json_member
        test    rax, rax
        js      .done
        mov     rbx, [rsp]
        mov     rdi, rbx
        call    af_jsonc_type
        cmp     rax, AF_JSON_INTEGER
        jne     .not_integer
        mov     rdi, rbx
        call    af_jsonc_integer_value
        mov     rcx, [rsp + 8]
        test    rcx, rcx
        jz      .ok
        mov     [rcx], rax
.ok:
        AF_LEAVE_OK
.not_integer:
        AF_LEAVE_ERR AF_E_JSON_TYPE
.done:
        AF_LEAVE

; af_json_get_bool(json_t *object, const char *key, i64 *out) -> af_status
;   `out` receives 1 or 0. JSON has two boolean types, so the caller should not
;   have to know that.
        global af_json_get_bool
af_json_get_bool:
        AF_ENTER 32
        mov     [rsp + 8], rdx
        lea     rdx, [rsp]
        call    af_json_member
        test    rax, rax
        js      .done
        mov     rdi, [rsp]
        call    af_jsonc_type
        cmp     rax, AF_JSON_TRUE
        je      .true
        cmp     rax, AF_JSON_FALSE
        je      .false
        AF_LEAVE_ERR AF_E_JSON_TYPE
.true:
        mov     rcx, [rsp + 8]
        test    rcx, rcx
        jz      .ok
        mov     qword [rcx], 1
        AF_LEAVE_OK
.false:
        mov     rcx, [rsp + 8]
        test    rcx, rcx
        jz      .ok
        mov     qword [rcx], 0
.ok:
        AF_LEAVE_OK
.done:
        AF_LEAVE

; af_json_get_array(json_t *object, const char *key, json_t **out,
;                   u64 *out_count) -> af_status
        global af_json_get_array
af_json_get_array:
        AF_ENTER 32
        mov     [rsp + 8], rdx          ; out
        mov     [rsp + 16], rcx         ; out_count
        lea     rdx, [rsp]
        call    af_json_member
        test    rax, rax
        js      .done
        mov     rbx, [rsp]
        mov     rdi, rbx
        call    af_jsonc_type
        cmp     rax, AF_JSON_ARRAY
        jne     .not_array
        mov     rcx, [rsp + 8]
        test    rcx, rcx
        jz      .no_ptr
        mov     [rcx], rbx
.no_ptr:
        mov     rdi, rbx
        call    af_jsonc_array_size
        mov     rcx, [rsp + 16]
        test    rcx, rcx
        jz      .ok
        mov     [rcx], rax
.ok:
        AF_LEAVE_OK
.not_array:
        AF_LEAVE_ERR AF_E_JSON_TYPE
.done:
        AF_LEAVE

; af_json_get_object(json_t *object, const char *key, json_t **out)
;   -> af_status
        global af_json_get_object
af_json_get_object:
        AF_ENTER 32
        mov     [rsp + 8], rdx
        lea     rdx, [rsp]
        call    af_json_member
        test    rax, rax
        js      .done
        mov     rbx, [rsp]
        mov     rdi, rbx
        call    af_jsonc_type
        cmp     rax, AF_JSON_OBJECT
        jne     .not_object
        mov     rcx, [rsp + 8]
        test    rcx, rcx
        jz      .ok
        mov     [rcx], rbx
.ok:
        AF_LEAVE_OK
.not_object:
        AF_LEAVE_ERR AF_E_JSON_TYPE
.done:
        AF_LEAVE

; af_json_array_at(json_t *array, u64 index, json_t **out) -> af_status
        global af_json_array_at
af_json_array_at:
        AF_ENTER 0
        mov     r12, rdx
        call    af_jsonc_array_get
        test    rax, rax
        jz      .absent
        test    r12, r12
        jz      .ok
        mov     [r12], rax
.ok:
        AF_LEAVE_OK
.absent:
        AF_LEAVE_ERR AF_E_NOTFOUND

; af_json_array_count(json_t *array) -> u64
        global af_json_array_count
af_json_array_count:
        AF_ENTER 0
        call    af_jsonc_array_size
        AF_LEAVE

; af_json_string_of(json_t *value, const char **out_ptr, u64 *out_len)
;   -> af_status
;
;   The unkeyed form, for array elements and iterator values.
        global af_json_string_of
af_json_string_of:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     [rsp + 8], rdx
        mov     rdi, rbx
        call    af_jsonc_type
        cmp     rax, AF_JSON_STRING
        jne     .not_string
        mov     rdi, rbx
        call    af_jsonc_string_value
        mov     r12, rax
        mov     rdi, rbx
        call    af_jsonc_string_length
        mov     rcx, [rsp]
        test    rcx, rcx
        jz      .no_ptr
        mov     [rcx], r12
.no_ptr:
        mov     rcx, [rsp + 8]
        test    rcx, rcx
        jz      .ok
        mov     [rcx], rax
.ok:
        AF_LEAVE_OK
.not_string:
        AF_LEAVE_ERR AF_E_JSON_TYPE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; Object iteration, used by the unknown-key check.
;
; af_json_iter_begin(json_t *object) -> void * (NULL when empty)
; af_json_iter_key(void *iter) -> const char * (BORROWED)
; af_json_iter_key_len(void *iter) -> u64
; af_json_iter_value(void *iter) -> json_t * (BORROWED)
; af_json_iter_next(json_t *object, void *iter) -> void * (NULL at the end)
; ---------------------------------------------------------------------------
        global af_json_iter_begin
af_json_iter_begin:
        AF_ENTER 0
        call    af_jsonc_object_iter
        AF_LEAVE

        global af_json_iter_key
af_json_iter_key:
        AF_ENTER 0
        call    af_jsonc_object_iter_key
        AF_LEAVE

        global af_json_iter_key_len
af_json_iter_key_len:
        AF_ENTER 0
        call    af_jsonc_object_iter_key_len
        AF_LEAVE

        global af_json_iter_value
af_json_iter_value:
        AF_ENTER 0
        call    af_jsonc_object_iter_value
        AF_LEAVE

        global af_json_iter_next
af_json_iter_next:
        AF_ENTER 0
        call    af_jsonc_object_iter_next
        AF_LEAVE
