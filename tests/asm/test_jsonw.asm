; AsmFlow — JSON serialisation (HARNESS.md M4; the writer is what the control
; protocol emits).
;
; The escaping and UTF-8 cases matter most: the control plane carries
; third-party text — an MCP server's advertised name, a tool description, an
; upstream error message — straight to an operator's terminal.

        bits 64
        default rel

%include "asmflow.inc"
%include "jsonw.inc"
%include "test.inc"

%define AF_TEST_TAG jsonw

        extern af_jw_init
        extern af_jw_status
        extern af_jw_finish
        extern af_jw_begin_object
        extern af_jw_end_object
        extern af_jw_begin_array
        extern af_jw_end_array
        extern af_jw_key
        extern af_jw_key_n
        extern af_jw_string
        extern af_jw_string_n
        extern af_jw_uint
        extern af_jw_int
        extern af_jw_bool
        extern af_jw_null
        extern af_jw_member_string
        extern af_jw_member_uint
        extern af_jw_member_int
        extern af_jw_member_bool
        extern af_jw_struct_size
        extern af_utf8_validate
        extern af_utf8_sequence_length

        extern af_buf_init
        extern af_buf_free
        extern af_buf_data
        extern af_buf_len
        extern af_mem_eq

        section .rodata
k_a:      db "a", 0
k_b:      db "b", 0
k_list:   db "list", 0
v_hello:  db "hello", 0

exp_flat: db `{"a":1,"b":"hello"}`
exp_flat_len equ $ - exp_flat

exp_nested: db `{"list":[1,2,{"a":true}],"b":null}`
exp_nested_len equ $ - exp_nested

; Every mandatory escape plus the five short forms.
raw_escapes: db `he said "hi"`, 92, 8, 12, 10, 13, 9, 1, 0x7F
raw_escapes_len equ $ - raw_escapes
exp_escapes: db `"he said \\"hi\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u007f"`
exp_escapes_len equ $ - exp_escapes

; Well-formed UTF-8 passes through unchanged: Korean, an emoji, and a
; two-byte sequence.
raw_utf8: db 0xED, 0x95, 0x9C, 0xEA, 0xB5, 0xAD, 0xF0, 0x9F, 0x94, 0xA5, 0xC3, 0xA9
raw_utf8_len equ $ - raw_utf8
exp_utf8: db '"', 0xED, 0x95, 0x9C, 0xEA, 0xB5, 0xAD, 0xF0, 0x9F, 0x94, 0xA5, 0xC3, 0xA9, '"'
exp_utf8_len equ $ - exp_utf8

; An unpaired surrogate, an overlong encoding, and a truncated sequence: each
; bad byte becomes exactly one U+FFFD.
raw_bad_utf8: db 0xED, 0xA0, 0x80, 0xC0, 0xAF, 0xE2, 0x82
raw_bad_utf8_len equ $ - raw_bad_utf8

s_ok:   db "ok", 0

        section .text

AF_TEST "jsonw/flat_object_grammar", 256
        lea     rbx, [rsp + 64]         ; af_buffer
        lea     r12, [rsp + 128]        ; af_json_writer
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "buffer init failed"
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init
        AF_CHECK_OK rax, "writer init failed"

        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_a]
        mov     rdx, 1
        call    af_jw_member_uint
        mov     rdi, r12
        lea     rsi, [k_b]
        lea     rdx, [v_hello]
        call    af_jw_member_string
        mov     rdi, r12
        call    af_jw_end_object

        mov     rdi, r12
        call    af_jw_finish
        AF_CHECK_OK rax, "the document should be complete"

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, exp_flat_len, "the rendered length is wrong"
        mov     rdi, rbx
        call    af_buf_data
        mov     rdi, rax
        lea     rsi, [exp_flat]
        mov     rdx, exp_flat_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the rendered document does not match"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/nested_containers_and_separators", 256
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_list]
        call    af_jw_key
        mov     rdi, r12
        call    af_jw_begin_array
        mov     rdi, r12
        mov     rsi, 1
        call    af_jw_uint
        mov     rdi, r12
        mov     rsi, 2
        call    af_jw_uint
        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_a]
        mov     rdx, 1
        call    af_jw_member_bool
        mov     rdi, r12
        call    af_jw_end_object
        mov     rdi, r12
        call    af_jw_end_array
        mov     rdi, r12
        lea     rsi, [k_b]
        call    af_jw_key
        mov     rdi, r12
        call    af_jw_null
        mov     rdi, r12
        call    af_jw_end_object

        mov     rdi, r12
        call    af_jw_finish
        AF_CHECK_OK rax, "the nested document should be complete"

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, exp_nested_len, "the nested length is wrong"
        mov     rdi, rbx
        call    af_buf_data
        mov     rdi, rax
        lea     rsi, [exp_nested]
        mov     rdx, exp_nested_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the nested document does not match"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/escapes_every_required_character", 256
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        mov     rdi, r12
        lea     rsi, [raw_escapes]
        mov     rdx, raw_escapes_len
        call    af_jw_string_n
        AF_CHECK_OK rax, "writing an escaped string failed"

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, exp_escapes_len, "the escaped length is wrong"
        mov     rdi, rbx
        call    af_buf_data
        mov     rdi, rax
        lea     rsi, [exp_escapes]
        mov     rdx, exp_escapes_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the escaping does not match"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/valid_utf8_passes_through", 256
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        mov     rdi, r12
        lea     rsi, [raw_utf8]
        mov     rdx, raw_utf8_len
        call    af_jw_string_n
        AF_CHECK_OK rax, "writing UTF-8 failed"

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, exp_utf8_len, "UTF-8 should not be re-encoded"
        mov     rdi, rbx
        call    af_buf_data
        mov     rdi, rax
        lea     rsi, [exp_utf8]
        mov     rdx, exp_utf8_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the UTF-8 bytes were altered"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/invalid_utf8_becomes_replacement_characters", 256
        ; Seven bad bytes in, seven U+FFFD out, wrapped in quotes: 7*3 + 2.
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        mov     rdi, r12
        lea     rsi, [raw_bad_utf8]
        mov     rdx, raw_bad_utf8_len
        call    af_jw_string_n
        AF_CHECK_OK rax, "writing invalid UTF-8 should still succeed"

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 23, "each bad byte should become one U+FFFD"

        ; The result must itself be valid UTF-8, or the frame is undecodable.
        mov     rdi, rbx
        call    af_buf_data
        mov     r13, rax
        mov     rdi, rbx
        call    af_buf_len
        mov     rdi, r13
        mov     rsi, rax
        call    af_utf8_validate
        AF_CHECK_EQ rax, 1, "the sanitised output must be valid UTF-8"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/grammar_violations_are_sticky_errors", 256
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        ; A key inside an array is not a member.
        mov     rdi, r12
        call    af_jw_begin_array
        AF_CHECK_OK rax, "begin_array failed"
        mov     rdi, r12
        lea     rsi, [k_a]
        call    af_jw_key
        AF_CHECK_ERR rax, AF_E_INTERNAL, "a key inside an array must be refused"

        ; Once failed, every later call is a no-op and the status is kept.
        mov     rdi, r12
        mov     rsi, 1
        call    af_jw_uint
        mov     rdi, r12
        call    af_jw_status
        AF_CHECK_ERR rax, AF_E_INTERNAL, "the failure must be sticky"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/mismatched_close_is_refused", 256
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        call    af_jw_end_array
        AF_CHECK_ERR rax, AF_E_INTERNAL, "closing an object as an array must be refused"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/dangling_key_is_refused", 256
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_a]
        call    af_jw_key
        AF_CHECK_OK rax, "the key should be accepted"
        ; Closing now would produce `{"a":}`.
        mov     rdi, r12
        call    af_jw_end_object
        AF_CHECK_ERR rax, AF_E_INTERNAL, "a key without a value must be refused"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/two_keys_in_a_row_are_refused", 256
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_a]
        call    af_jw_key
        mov     rdi, r12
        lea     rsi, [k_b]
        call    af_jw_key
        AF_CHECK_ERR rax, AF_E_INTERNAL, "two keys in a row must be refused"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/unbalanced_document_fails_at_finish", 256
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_a]
        mov     rdx, 1
        call    af_jw_member_uint
        ; Never closed.
        mov     rdi, r12
        call    af_jw_finish
        AF_CHECK_ERR rax, AF_E_INTERNAL, "an unclosed container must fail at finish"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/depth_ceiling", 256
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 65536
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        xor     r13, r13
.open:
        mov     rdi, r12
        call    af_jw_begin_array
        inc     r13
        cmp     r13, AF_JW_MAX_DEPTH
        jb      .open
        mov     rdi, r12
        call    af_jw_status
        AF_CHECK_OK rax, "the maximum depth itself should be reachable"

        mov     rdi, r12
        call    af_jw_begin_array
        AF_CHECK_ERR rax, AF_E_JSON_DEPTH, "one past the ceiling must be refused"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/output_ceiling_is_reported_not_truncated", 256
        ; A buffer far too small for the document: the writer reports the limit
        ; rather than emitting a truncated frame a peer would have to reject.
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 8
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        mov     rdi, r12
        call    af_jw_begin_object
        mov     rdi, r12
        lea     rsi, [k_a]
        lea     rdx, [v_hello]
        call    af_jw_member_string
        mov     rdi, r12
        call    af_jw_status
        AF_CHECK_ERR rax, AF_E_LIMIT, "exceeding the output ceiling must be reported"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "jsonw/negative_integers", 256
        lea     rbx, [rsp + 64]
        lea     r12, [rsp + 128]
        mov     rdi, rbx
        mov     rsi, 4096
        call    af_buf_init
        mov     rdi, r12
        mov     rsi, rbx
        call    af_jw_init

        mov     rdi, r12
        call    af_jw_begin_array
        mov     rdi, r12
        mov     rsi, -1
        call    af_jw_int
        mov     rdi, r12
        mov     rsi, 0
        call    af_jw_int
        mov     rdi, r12
        call    af_jw_end_array
        mov     rdi, r12
        call    af_jw_finish
        AF_CHECK_OK rax, "writing signed integers failed"

        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 6, "[-1,0] is six characters"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

; --- UTF-8 validation, shared with HTTP and MCP -----------------------------

AF_TEST "jsonw/utf8_sequence_rules", 128
        ; A continuation byte cannot lead.
        mov     byte [rsp], 0x80
        lea     rdi, [rsp]
        mov     rsi, 1
        lea     rdx, [rsp + 64]
        call    af_utf8_sequence_length
        AF_CHECK_EQ rax, 0, "a continuation byte must not lead a sequence"

        ; C0 and C1 are always overlong.
        mov     byte [rsp], 0xC0
        mov     byte [rsp + 1], 0xAF
        lea     rdi, [rsp]
        mov     rsi, 2
        lea     rdx, [rsp + 64]
        call    af_utf8_sequence_length
        AF_CHECK_EQ rax, 0, "an overlong two-byte sequence must be rejected"

        ; A truncated three-byte sequence.
        mov     byte [rsp], 0xE2
        mov     byte [rsp + 1], 0x82
        lea     rdi, [rsp]
        mov     rsi, 2
        lea     rdx, [rsp + 64]
        call    af_utf8_sequence_length
        AF_CHECK_EQ rax, 0, "a truncated sequence must be rejected"

        ; A UTF-16 surrogate has no UTF-8 encoding.
        mov     byte [rsp], 0xED
        mov     byte [rsp + 1], 0xA0
        mov     byte [rsp + 2], 0x80
        lea     rdi, [rsp]
        mov     rsi, 3
        lea     rdx, [rsp + 64]
        call    af_utf8_sequence_length
        AF_CHECK_EQ rax, 0, "a surrogate must be rejected"

        ; Above U+10FFFF.
        mov     byte [rsp], 0xF5
        mov     byte [rsp + 1], 0x80
        mov     byte [rsp + 2], 0x80
        mov     byte [rsp + 3], 0x80
        lea     rdi, [rsp]
        mov     rsi, 4
        lea     rdx, [rsp + 64]
        call    af_utf8_sequence_length
        AF_CHECK_EQ rax, 0, "a codepoint above U+10FFFF must be rejected"

        ; A well-formed three-byte sequence decodes to the right codepoint.
        mov     byte [rsp], 0xE2
        mov     byte [rsp + 1], 0x82
        mov     byte [rsp + 2], 0xAC     ; U+20AC EURO SIGN
        lea     rdi, [rsp]
        mov     rsi, 3
        lea     rdx, [rsp + 64]
        call    af_utf8_sequence_length
        AF_CHECK_EQ rax, 3, "a valid three-byte sequence should be accepted"
        mov     ebx, [rsp + 64]
        AF_CHECK_EQ rbx, 0x20AC, "the decoded codepoint is wrong"

        ; ASCII.
        mov     byte [rsp], 'A'
        lea     rdi, [rsp]
        mov     rsi, 1
        lea     rdx, [rsp + 64]
        call    af_utf8_sequence_length
        AF_CHECK_EQ rax, 1, "ASCII should be a one-byte sequence"
AF_TEST_END

AF_TEST "jsonw/struct_size_is_stable"
        call    af_jw_struct_size
        AF_CHECK_EQ rax, JW_SIZE, "the writer layout changed without the header"
AF_TEST_END
