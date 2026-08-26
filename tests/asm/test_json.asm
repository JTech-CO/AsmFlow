; AsmFlow — bounded JSON parsing (HARNESS.md M3, and the fuzz surface in
; TEST_STRATEGY.md I).
;
; The depth pre-scan runs on raw untrusted bytes before any allocation, so its
; string and escape handling is the first thing an attacker reaches. Most of
; these cases exist to pin that: a `{` inside a string is not nesting, and a
; `\"` inside a string does not end it.

        bits 64
        default rel

%include "asmflow.inc"
%include "json.inc"
%include "test.inc"

%define AF_TEST_TAG json

        extern af_json_scan_depth
        extern af_json_parse
        extern af_json_doc_free
        extern af_json_doc_root
        extern af_json_type
        extern af_json_member
        extern af_json_get_string
        extern af_json_get_integer
        extern af_json_get_bool
        extern af_json_get_array
        extern af_json_get_object
        extern af_json_array_at
        extern af_json_array_count
        extern af_json_string_of
        extern af_json_iter_begin
        extern af_json_iter_key
        extern af_json_iter_value
        extern af_json_iter_next
        extern af_cstr_len
        extern af_mem_eq
        extern af_jsonc_type_ordinals

        section .rodata
j_flat:      db `{"a":1,"b":"two","c":true,"d":null,"e":[1,2,3]}`
j_flat_len   equ $ - j_flat
j_deep3:     db `[[[1]]]`
j_deep3_len  equ $ - j_deep3
j_brace_str: db `{"a":"{{{{{{{{"}`
j_brace_str_len equ $ - j_brace_str
j_escaped:   db `{"a":"he said \\"hi\\" and left"}`
j_escaped_len equ $ - j_escaped
j_unbalanced: db `{"a":1`
j_unbalanced_len equ $ - j_unbalanced
j_unterminated: db `{"a":"oops}`
j_unterminated_len equ $ - j_unterminated
j_extra_close: db `{"a":1}}`
j_extra_close_len equ $ - j_extra_close
j_dup_key:   db `{"a":1,"a":2}`
j_dup_key_len equ $ - j_dup_key
j_long_str:  db `{"a":"0123456789"}`
j_long_str_len equ $ - j_long_str
j_wide:      db `[1,2,3,4,5,6,7,8,9,10]`
j_wide_len   equ $ - j_wide
j_trailing:  db `{"a":1,}`
j_trailing_len equ $ - j_trailing

key_a: db "a", 0
key_b: db "b", 0
key_c: db "c", 0
key_d: db "d", 0
key_e: db "e", 0
key_missing: db "zzz", 0
val_two: db "two"

        section .text

AF_TEST "json/depth_scan_counts_only_structural_brackets", 64
        lea     rdi, [j_deep3]
        mov     rsi, j_deep3_len
        mov     rdx, 3
        call    af_json_scan_depth
        AF_CHECK_OK rax, "three levels should fit a limit of three"

        lea     rdi, [j_deep3]
        mov     rsi, j_deep3_len
        mov     rdx, 2
        call    af_json_scan_depth
        AF_CHECK_ERR rax, AF_E_JSON_DEPTH, "three levels must exceed a limit of two"

        ; Braces inside a string are data, not nesting.
        lea     rdi, [j_brace_str]
        mov     rsi, j_brace_str_len
        mov     rdx, 2
        call    af_json_scan_depth
        AF_CHECK_OK rax, "braces inside a string must not count as nesting"
AF_TEST_END

AF_TEST "json/depth_scan_honours_backslash_escapes", 64
        ; The escaped quotes must not end the string, so the closing brace is
        ; still seen as structural and the document balances.
        lea     rdi, [j_escaped]
        mov     rsi, j_escaped_len
        mov     rdx, 4
        call    af_json_scan_depth
        AF_CHECK_OK rax, "an escaped quote must not terminate the string"
AF_TEST_END

AF_TEST "json/depth_scan_rejects_unbalanced_input", 64
        lea     rdi, [j_unbalanced]
        mov     rsi, j_unbalanced_len
        mov     rdx, 8
        call    af_json_scan_depth
        AF_CHECK_ERR rax, AF_E_JSON_PARSE, "an unclosed object must be rejected"

        lea     rdi, [j_unterminated]
        mov     rsi, j_unterminated_len
        mov     rdx, 8
        call    af_json_scan_depth
        AF_CHECK_ERR rax, AF_E_JSON_PARSE, "an unterminated string must be rejected"

        lea     rdi, [j_extra_close]
        mov     rsi, j_extra_close_len
        mov     rdx, 8
        call    af_json_scan_depth
        AF_CHECK_ERR rax, AF_E_JSON_PARSE, "an extra closing brace must be rejected"
AF_TEST_END

AF_TEST "json/type_ordinals_match_the_linked_jansson", 128
        lea     rdi, [rsp]
        call    af_jsonc_type_ordinals wrt ..plt
        mov     ebx, [rsp]
        AF_CHECK_EQ rbx, AF_JSON_OBJECT, "JSON_OBJECT ordinal drifted"
        mov     ebx, [rsp + 4]
        AF_CHECK_EQ rbx, AF_JSON_ARRAY, "JSON_ARRAY ordinal drifted"
        mov     ebx, [rsp + 8]
        AF_CHECK_EQ rbx, AF_JSON_STRING, "JSON_STRING ordinal drifted"
        mov     ebx, [rsp + 12]
        AF_CHECK_EQ rbx, AF_JSON_INTEGER, "JSON_INTEGER ordinal drifted"
        mov     ebx, [rsp + 16]
        AF_CHECK_EQ rbx, AF_JSON_REAL, "JSON_REAL ordinal drifted"
        mov     ebx, [rsp + 20]
        AF_CHECK_EQ rbx, AF_JSON_TRUE, "JSON_TRUE ordinal drifted"
        mov     ebx, [rsp + 24]
        AF_CHECK_EQ rbx, AF_JSON_FALSE, "JSON_FALSE ordinal drifted"
        mov     ebx, [rsp + 28]
        AF_CHECK_EQ rbx, AF_JSON_NULL, "JSON_NULL ordinal drifted"
AF_TEST_END

; A shared limits block for the parse tests: generous depth, tight enough
; string and element ceilings that the boundary cases below can reach them.
%macro JSON_LIMITS 4
        mov     qword [rsp + 0],  %1     ; max bytes
        mov     qword [rsp + 8],  %2     ; max depth
        mov     qword [rsp + 16], %3     ; max string bytes
        mov     qword [rsp + 24], %4     ; max elements
%endmacro

AF_TEST "json/parse_and_read_every_scalar_type", 192
        JSON_LIMITS 4096, 32, 4096, 256
        lea     rdi, [j_flat]
        mov     rsi, j_flat_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        AF_CHECK_OK rax, "parsing a flat object failed"

        lea     rdi, [rsp + 32]
        call    af_json_doc_root
        mov     rbx, rax
        mov     rdi, rbx
        call    af_json_type
        AF_CHECK_EQ rax, AF_JSON_OBJECT, "the root should be an object"

        mov     rdi, rbx
        lea     rsi, [key_a]
        lea     rdx, [rsp + 64]
        call    af_json_get_integer
        AF_CHECK_OK rax, "reading an integer failed"
        mov     r12, [rsp + 64]
        AF_CHECK_EQ r12, 1, "the integer value is wrong"

        mov     rdi, rbx
        lea     rsi, [key_b]
        lea     rdx, [rsp + 72]
        lea     rcx, [rsp + 80]
        call    af_json_get_string
        AF_CHECK_OK rax, "reading a string failed"
        mov     r12, [rsp + 80]
        AF_CHECK_EQ r12, 3, "the string length is wrong"
        mov     rdi, [rsp + 72]
        lea     rsi, [val_two]
        mov     rdx, 3
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the string contents are wrong"

        mov     rdi, rbx
        lea     rsi, [key_c]
        lea     rdx, [rsp + 88]
        call    af_json_get_bool
        AF_CHECK_OK rax, "reading a boolean failed"
        mov     r12, [rsp + 88]
        AF_CHECK_EQ r12, 1, "true should read as 1"

        ; A type mismatch is an error, never a coercion.
        mov     rdi, rbx
        lea     rsi, [key_a]
        lea     rdx, [rsp + 88]
        call    af_json_get_bool
        AF_CHECK_ERR rax, AF_E_JSON_TYPE, "an integer must not read as a boolean"

        mov     rdi, rbx
        lea     rsi, [key_b]
        lea     rdx, [rsp + 64]
        call    af_json_get_integer
        AF_CHECK_ERR rax, AF_E_JSON_TYPE, "a string must not read as an integer"

        ; A null is a value of its own type, not an absent key.
        mov     rdi, rbx
        lea     rsi, [key_d]
        lea     rdx, [rsp + 96]
        call    af_json_member
        AF_CHECK_OK rax, "a null member should be present"
        mov     rdi, [rsp + 96]
        call    af_json_type
        AF_CHECK_EQ rax, AF_JSON_NULL, "a null member should have the null type"

        mov     rdi, rbx
        lea     rsi, [key_missing]
        xor     edx, edx
        call    af_json_member
        AF_CHECK_ERR rax, AF_E_NOTFOUND, "an absent key must report not-found"

        mov     rdi, rbx
        lea     rsi, [key_e]
        lea     rdx, [rsp + 104]
        lea     rcx, [rsp + 112]
        call    af_json_get_array
        AF_CHECK_OK rax, "reading an array failed"
        mov     r12, [rsp + 112]
        AF_CHECK_EQ r12, 3, "the array count is wrong"

        lea     rdi, [rsp + 32]
        call    af_json_doc_free
AF_TEST_END

AF_TEST "json/limits_are_enforced_after_the_parse", 192
        ; A string one byte over its ceiling.
        JSON_LIMITS 4096, 32, 9, 256
        lea     rdi, [j_long_str]
        mov     rsi, j_long_str_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        AF_CHECK_ERR rax, AF_E_JSON_SIZE, "a ten-byte string must exceed a limit of nine"

        ; Exactly at the ceiling.
        JSON_LIMITS 4096, 32, 10, 256
        lea     rdi, [j_long_str]
        mov     rsi, j_long_str_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        AF_CHECK_OK rax, "a ten-byte string should fit a limit of ten"
        lea     rdi, [rsp + 32]
        call    af_json_doc_free

        ; Element count.
        JSON_LIMITS 4096, 32, 4096, 9
        lea     rdi, [j_wide]
        mov     rsi, j_wide_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        AF_CHECK_ERR rax, AF_E_LIMIT, "ten elements must exceed a limit of nine"

        JSON_LIMITS 4096, 32, 4096, 10
        lea     rdi, [j_wide]
        mov     rsi, j_wide_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        AF_CHECK_OK rax, "ten elements should fit a limit of ten"
        lea     rdi, [rsp + 32]
        call    af_json_doc_free

        ; Document size.
        JSON_LIMITS 4, 32, 4096, 256
        lea     rdi, [j_flat]
        mov     rsi, j_flat_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        AF_CHECK_ERR rax, AF_E_JSON_SIZE, "an oversized document must be refused"
AF_TEST_END

AF_TEST "json/duplicate_keys_are_rejected", 192
        ; A duplicate would otherwise let a later value silently override an
        ; earlier one, which is a way to slip a setting past a reviewer who read
        ; the first occurrence.
        JSON_LIMITS 4096, 32, 4096, 256
        lea     rdi, [j_dup_key]
        mov     rsi, j_dup_key_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        AF_CHECK_ERR rax, AF_E_JSON_PARSE, "a duplicate key must be rejected"
AF_TEST_END

AF_TEST "json/trailing_comma_is_rejected", 192
        JSON_LIMITS 4096, 32, 4096, 256
        lea     rdi, [j_trailing]
        mov     rsi, j_trailing_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        AF_CHECK_ERR rax, AF_E_JSON_PARSE, "a trailing comma must be rejected"
AF_TEST_END

AF_TEST "json/object_iteration_visits_every_member", 192
        JSON_LIMITS 4096, 32, 4096, 256
        lea     rdi, [j_flat]
        mov     rsi, j_flat_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        AF_CHECK_OK rax, "parsing failed"
        lea     rdi, [rsp + 32]
        call    af_json_doc_root
        mov     rbx, rax

        xor     r12, r12                ; visited count
        mov     rdi, rbx
        call    af_json_iter_begin
        mov     r13, rax
.loop:
        test    r13, r13
        jz      .done
        mov     rdi, r13
        call    af_json_iter_key
        AF_CHECK_NE rax, 0, "an iterator key should never be NULL"
        mov     rdi, r13
        call    af_json_iter_value
        AF_CHECK_NE rax, 0, "an iterator value should never be NULL"
        inc     r12
        mov     rdi, rbx
        mov     rsi, r13
        call    af_json_iter_next
        mov     r13, rax
        jmp     .loop
.done:
        AF_CHECK_EQ r12, 5, "iteration should visit all five members"
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
AF_TEST_END

AF_TEST "json/doc_free_is_idempotent", 192
        JSON_LIMITS 4096, 32, 4096, 256
        lea     rdi, [j_flat]
        mov     rsi, j_flat_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        AF_CHECK_OK rax, "parsing failed"
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        lea     rdi, [rsp + 32]
        call    af_json_doc_root
        AF_CHECK_EQ rax, 0, "the root should be cleared after a free"
AF_TEST_END
