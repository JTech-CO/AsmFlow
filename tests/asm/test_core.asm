; AsmFlow — core primitives: strings, views, clock, identifiers.

        bits 64
        default rel

%include "asmflow.inc"
%include "test.inc"

%define AF_TEST_TAG core

        extern af_cstr_len
        extern af_cstr_eq
        extern af_cstr_starts_with
        extern af_mem_eq
        extern af_mem_eq_ci
        extern af_mem_eq_ct
        extern af_mem_copy
        extern af_mem_zero
        extern af_u64_to_dec
        extern af_dec_to_u64

        extern af_sv_set
        extern af_sv_from_cstr
        extern af_sv_eq
        extern af_sv_eq_ci
        extern af_sv_eq_cstr
        extern af_sv_starts_with_cstr
        extern af_sv_trim_ascii_ws
        extern af_sv_find_byte
        extern af_sv_split_byte
        extern af_sv_to_u64
        extern af_sv_len
        extern af_sv_ptr

        extern af_monotonic_ns
        extern af_monotonic_ms
        extern af_realtime_ms
        extern af_elapsed_ns
        extern af_clock_set_override_ns
        extern af_clock_advance_ns

        extern af_id_generate
        extern af_id_len
        extern af_id_is_valid_ulid
        extern af_id_is_valid_client_ref

        section .rodata
s_hello:      db "hello", 0
s_hello_up:   db "HELLO", 0
s_hellox:     db "hellox", 0
s_empty:      db 0
s_auth:       db "Authorization", 0
s_auth_lower: db "authorization", 0
s_padded:     db "  spaced  ", 0
s_kv:         db "name=value", 0
s_crlf_pad:   db 13, 10, " x ", 13, 10, 0
s_ref_ok:     db "req-01.abc_XYZ", 0
s_ref_space:  db "req 01", 0
s_ref_crlf:   db "req", 13, 10, "Set-Cookie: x", 0

        section .text

; --- byte and C-string primitives ------------------------------------------

AF_TEST "core/cstr_len_handles_null_and_empty"
        xor     edi, edi
        call    af_cstr_len
        AF_CHECK_EQ rax, 0, "a NULL string should measure zero"
        lea     rdi, [s_empty]
        call    af_cstr_len
        AF_CHECK_EQ rax, 0, "an empty string should measure zero"
        lea     rdi, [s_hello]
        call    af_cstr_len
        AF_CHECK_EQ rax, 5, "'hello' should measure five"
AF_TEST_END

AF_TEST "core/cstr_eq_and_starts_with"
        lea     rdi, [s_hello]
        lea     rsi, [s_hello]
        call    af_cstr_eq
        AF_CHECK_EQ rax, 1, "identical strings should compare equal"

        lea     rdi, [s_hello]
        lea     rsi, [s_hellox]
        call    af_cstr_eq
        AF_CHECK_EQ rax, 0, "a prefix must not compare equal to a longer string"

        lea     rdi, [s_hellox]
        lea     rsi, [s_hello]
        call    af_cstr_starts_with
        AF_CHECK_EQ rax, 1, "'hellox' starts with 'hello'"

        lea     rdi, [s_hello]
        lea     rsi, [s_hellox]
        call    af_cstr_starts_with
        AF_CHECK_EQ rax, 0, "'hello' does not start with 'hellox'"

        lea     rdi, [s_hello]
        lea     rsi, [s_empty]
        call    af_cstr_starts_with
        AF_CHECK_EQ rax, 1, "every string starts with the empty prefix"
AF_TEST_END

AF_TEST "core/case_insensitive_compare_folds_only_ascii_letters"
        lea     rdi, [s_auth]
        lea     rsi, [s_auth_lower]
        mov     rdx, 13
        call    af_mem_eq_ci
        AF_CHECK_EQ rax, 1, "header names should compare case-insensitively"

        lea     rdi, [s_hello]
        lea     rsi, [s_hello_up]
        mov     rdx, 5
        call    af_mem_eq
        AF_CHECK_EQ rax, 0, "the case-sensitive compare must still distinguish case"
AF_TEST_END

AF_TEST "core/constant_time_compare_agrees_with_the_plain_one"
        lea     rdi, [s_hello]
        lea     rsi, [s_hello]
        mov     rdx, 5
        call    af_mem_eq_ct
        AF_CHECK_EQ rax, 1, "equal buffers should compare equal"

        lea     rdi, [s_hello]
        lea     rsi, [s_hellox]
        mov     rdx, 5
        call    af_mem_eq_ct
        AF_CHECK_EQ rax, 1, "the first five bytes are equal"

        lea     rdi, [s_hello]
        lea     rsi, [s_hello_up]
        mov     rdx, 5
        call    af_mem_eq_ct
        AF_CHECK_EQ rax, 0, "differing buffers should compare unequal"

        ; A difference in the last byte must be detected: an early-exit
        ; implementation that stopped at the first match would pass the cases
        ; above and fail this one.
        lea     rdi, [s_hello]
        lea     rsi, [s_hellox]
        mov     rdx, 6
        call    af_mem_eq_ct
        AF_CHECK_EQ rax, 0, "a difference in the final byte must be detected"
AF_TEST_END

AF_TEST "core/mem_copy_and_zero", 128
        lea     rbx, [rsp]
        mov     rdi, rbx
        mov     rsi, 64
        call    af_mem_zero

        mov     rdi, rbx
        lea     rsi, [s_hello]
        mov     rdx, 5
        call    af_mem_copy
        AF_CHECK_EQ rax, rbx, "af_mem_copy should return its destination"

        mov     rdi, rbx
        lea     rsi, [s_hello]
        mov     rdx, 5
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the copy does not match the source"

        ; Copies larger than the qword fast path.
        mov     rdi, rbx
        mov     rsi, rbx
        add     rsi, 32
        mov     rdx, 0
        call    af_mem_copy
        AF_CHECK_EQ rax, rbx, "a zero-length copy should still return the destination"

        mov     rdi, rbx
        mov     rsi, 64
        call    af_mem_zero
        movzx   r12, byte [rbx]
        AF_CHECK_EQ r12, 0, "af_mem_zero left a non-zero byte"
        movzx   r12, byte [rbx + 63]
        AF_CHECK_EQ r12, 0, "af_mem_zero left a non-zero trailing byte"
AF_TEST_END

AF_TEST "core/decimal_round_trip", 128
        ; zero
        mov     rdi, 0
        lea     rsi, [rsp]
        mov     rdx, 32
        lea     rcx, [rsp + 32]
        call    af_u64_to_dec
        AF_CHECK_OK rax, "rendering zero failed"
        mov     rbx, [rsp + 32]
        AF_CHECK_EQ rbx, 1, "zero should render as one character"

        lea     rdi, [rsp]
        mov     rsi, [rsp + 32]
        lea     rdx, [rsp + 40]
        call    af_dec_to_u64
        AF_CHECK_OK rax, "parsing zero failed"
        mov     rbx, [rsp + 40]
        AF_CHECK_EQ rbx, 0, "zero did not survive the round trip"

        ; maximum
        mov     rdi, 18446744073709551615
        lea     rsi, [rsp]
        mov     rdx, 32
        lea     rcx, [rsp + 32]
        call    af_u64_to_dec
        AF_CHECK_OK rax, "rendering the maximum failed"
        mov     rbx, [rsp + 32]
        AF_CHECK_EQ rbx, 20, "2^64-1 should render as twenty characters"

        lea     rdi, [rsp]
        mov     rsi, [rsp + 32]
        lea     rdx, [rsp + 40]
        call    af_dec_to_u64
        AF_CHECK_OK rax, "parsing the maximum failed"
        mov     rbx, [rsp + 40]
        mov     r12, 18446744073709551615
        AF_CHECK_EQ rbx, r12, "the maximum did not survive the round trip"

        ; a buffer that is too small is refused rather than truncated
        mov     rdi, 12345
        lea     rsi, [rsp]
        mov     rdx, 19
        lea     rcx, [rsp + 32]
        call    af_u64_to_dec
        AF_CHECK_ERR rax, AF_E_LIMIT, "a short buffer must be refused"
AF_TEST_END

AF_TEST "core/decimal_parse_is_strict", 128
        ; empty
        lea     rdi, [s_hello]
        mov     rsi, 0
        lea     rdx, [rsp]
        call    af_dec_to_u64
        AF_CHECK_ERR rax, AF_E_INVALID, "an empty span must be rejected"

        ; non-digit
        lea     rdi, [s_hello]
        mov     rsi, 5
        lea     rdx, [rsp]
        call    af_dec_to_u64
        AF_CHECK_ERR rax, AF_E_INVALID, "letters must be rejected"

        ; one past the maximum
        lea     rdi, [s_overflow_digits]
        mov     rsi, 20
        lea     rdx, [rsp]
        call    af_dec_to_u64
        AF_CHECK_ERR rax, AF_E_OVERFLOW, "2^64 must be reported as overflow"
AF_TEST_END

; --- string views -----------------------------------------------------------

AF_TEST "core/strview_construction_and_equality", 128
        lea     rbx, [rsp]              ; view a
        lea     r12, [rsp + 16]         ; view b

        mov     rdi, rbx
        lea     rsi, [s_hello]
        call    af_sv_from_cstr
        mov     rdi, rbx
        call    af_sv_len
        AF_CHECK_EQ rax, 5, "af_sv_from_cstr recorded the wrong length"

        mov     rdi, r12
        lea     rsi, [s_hello]
        mov     rdx, 5
        call    af_sv_set

        mov     rdi, rbx
        mov     rsi, r12
        call    af_sv_eq
        AF_CHECK_EQ rax, 1, "identical views should compare equal"

        ; Differing lengths must not compare equal even when the prefix matches.
        mov     rdi, r12
        lea     rsi, [s_hello]
        mov     rdx, 4
        call    af_sv_set
        mov     rdi, rbx
        mov     rsi, r12
        call    af_sv_eq
        AF_CHECK_EQ rax, 0, "a shorter view must not compare equal"

        mov     rdi, rbx
        lea     rsi, [s_hello]
        call    af_sv_eq_cstr
        AF_CHECK_EQ rax, 1, "af_sv_eq_cstr should match"
        mov     rdi, rbx
        lea     rsi, [s_hellox]
        call    af_sv_eq_cstr
        AF_CHECK_EQ rax, 0, "af_sv_eq_cstr should reject a longer string"

        mov     rdi, rbx
        lea     rsi, [s_hello]
        call    af_sv_starts_with_cstr
        AF_CHECK_EQ rax, 1, "a view starts with its own contents"
        mov     rdi, rbx
        lea     rsi, [s_hellox]
        call    af_sv_starts_with_cstr
        AF_CHECK_EQ rax, 0, "a view does not start with a longer prefix"

        ; case-insensitive view comparison
        mov     rdi, rbx
        lea     rsi, [s_hello]
        mov     rdx, 5
        call    af_sv_set
        mov     rdi, r12
        lea     rsi, [s_hello_up]
        mov     rdx, 5
        call    af_sv_set
        mov     rdi, rbx
        mov     rsi, r12
        call    af_sv_eq_ci
        AF_CHECK_EQ rax, 1, "case-insensitive view comparison failed"
AF_TEST_END

AF_TEST "core/strview_trim_keeps_structural_bytes", 128
        lea     rbx, [rsp]
        mov     rdi, rbx
        lea     rsi, [s_padded]
        call    af_sv_from_cstr
        mov     rdi, rbx
        call    af_sv_trim_ascii_ws
        mov     rdi, rbx
        call    af_sv_len
        AF_CHECK_EQ rax, 6, "trimming should leave 'spaced'"

        ; CR and LF are framing, not whitespace: trimming them would hide a
        ; malformed HTTP message rather than reject it.
        mov     rdi, rbx
        lea     rsi, [s_crlf_pad]
        call    af_sv_from_cstr
        mov     rdi, rbx
        call    af_sv_trim_ascii_ws
        mov     rdi, rbx
        call    af_sv_len
        AF_CHECK_EQ rax, 7, "CR and LF must survive trimming"
AF_TEST_END

AF_TEST "core/strview_find_and_split", 128
        lea     rbx, [rsp]              ; source view
        lea     r12, [rsp + 16]         ; head
        lea     r13, [rsp + 32]         ; tail

        mov     rdi, rbx
        lea     rsi, [s_kv]
        call    af_sv_from_cstr

        mov     rdi, rbx
        mov     rsi, '='
        lea     rdx, [rsp + 48]
        call    af_sv_find_byte
        AF_CHECK_OK rax, "the delimiter should be found"
        mov     r14, [rsp + 48]
        AF_CHECK_EQ r14, 4, "the delimiter is at index four"

        mov     rdi, rbx
        mov     rsi, '?'
        lea     rdx, [rsp + 48]
        call    af_sv_find_byte
        AF_CHECK_ERR rax, AF_E_NOTFOUND, "a missing byte must report not-found"

        mov     rdi, rbx
        mov     rsi, '='
        mov     rdx, r12
        mov     rcx, r13
        call    af_sv_split_byte
        AF_CHECK_OK rax, "the split should succeed"
        mov     rdi, r12
        call    af_sv_len
        AF_CHECK_EQ rax, 4, "the head should be 'name'"
        mov     rdi, r13
        call    af_sv_len
        AF_CHECK_EQ rax, 5, "the tail should be 'value'"
AF_TEST_END

AF_TEST "core/strview_to_u64", 128
        lea     rbx, [rsp]
        mov     rdi, rbx
        lea     rsi, [s_digits_42]
        mov     rdx, 2
        call    af_sv_set
        mov     rdi, rbx
        lea     rsi, [rsp + 16]
        call    af_sv_to_u64
        AF_CHECK_OK rax, "parsing a numeric view failed"
        mov     r12, [rsp + 16]
        AF_CHECK_EQ r12, 42, "the parsed value is wrong"
AF_TEST_END

; --- clock ------------------------------------------------------------------

AF_TEST "core/monotonic_clock_moves_forward_only", 128
        lea     rdi, [rsp]
        call    af_monotonic_ns
        AF_CHECK_OK rax, "reading the monotonic clock failed"
        mov     rbx, [rsp]
        AF_CHECK_TRUE rbx, "the monotonic clock returned zero"

        mov     r13, 0
.spin:
        lea     rdi, [rsp + 8]
        call    af_monotonic_ns
        AF_CHECK_OK rax, "re-reading the monotonic clock failed"
        mov     r12, [rsp + 8]
        cmp     r12, rbx
        jae     .ok
        AF_CHECK_TRUE r13, "the monotonic clock went backwards"
.ok:
        mov     rbx, r12
        inc     r13
        cmp     r13, 100
        jb      .spin
AF_TEST_END

AF_TEST "core/clock_override_makes_timelines_deterministic", 128
        mov     rdi, 1000000
        call    af_clock_set_override_ns
        lea     rdi, [rsp]
        call    af_monotonic_ns
        AF_CHECK_OK rax, "reading the overridden clock failed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 1000000, "the override was not honoured"

        mov     rdi, 500
        call    af_clock_advance_ns
        AF_CHECK_OK rax, "advancing the overridden clock failed"
        lea     rdi, [rsp]
        call    af_monotonic_ns
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 1000500, "the clock did not advance by the requested amount"

        ; milliseconds derive from the same source
        lea     rdi, [rsp]
        call    af_monotonic_ms
        AF_CHECK_OK rax, "reading overridden milliseconds failed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 1, "1000500 ns should be 1 ms"

        ; restore the kernel source, then prove advancing is refused
        mov     rdi, -1
        call    af_clock_set_override_ns
        mov     rdi, 1
        call    af_clock_advance_ns
        AF_CHECK_ERR rax, AF_E_INVALID, "advancing a real clock must be refused"
AF_TEST_END

AF_TEST "core/elapsed_rejects_a_backwards_interval", 128
        mov     rdi, 100
        mov     rsi, 250
        lea     rdx, [rsp]
        call    af_elapsed_ns
        AF_CHECK_OK rax, "a forward interval should succeed"
        mov     rbx, [rsp]
        AF_CHECK_EQ rbx, 150, "the elapsed value is wrong"

        mov     rdi, 250
        mov     rsi, 100
        lea     rdx, [rsp]
        call    af_elapsed_ns
        AF_CHECK_ERR rax, AF_E_RANGE, "a backwards interval must be rejected"
AF_TEST_END

AF_TEST "core/realtime_clock_is_populated", 128
        lea     rdi, [rsp]
        call    af_realtime_ms
        AF_CHECK_OK rax, "reading the realtime clock failed"
        mov     rbx, [rsp]
        ; Later than 2020-01-01 in milliseconds; a zero or tiny value would mean
        ; the seconds and nanoseconds fields were mixed up.
        mov     r12, 1577836800000
        cmp     rbx, r12
        ja      .ok
        AF_CHECK_EQ rbx, r12, "the realtime clock looks implausible"
.ok:
AF_TEST_END

; --- identifiers ------------------------------------------------------------

AF_TEST "core/generated_ids_are_valid_and_unique", 256
        call    af_id_len
        AF_CHECK_EQ rax, 26, "a ULID is 26 characters"

        lea     rbx, [rsp]
        lea     r12, [rsp + 32]

        mov     rdi, rbx
        call    af_id_generate
        AF_CHECK_OK rax, "generating an identifier failed"
        mov     rdi, rbx
        mov     rsi, 26
        call    af_id_is_valid_ulid
        AF_CHECK_EQ rax, 1, "the generated identifier is not a valid ULID"

        mov     rdi, r12
        call    af_id_generate
        AF_CHECK_OK rax, "generating a second identifier failed"
        mov     rdi, r12
        mov     rsi, 26
        call    af_id_is_valid_ulid
        AF_CHECK_EQ rax, 1, "the second identifier is not a valid ULID"

        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, 26
        call    af_mem_eq
        AF_CHECK_EQ rax, 0, "two generated identifiers collided"

        ; The timestamp prefix is shared within the same millisecond and sorts
        ; lexicographically, so the first characters should agree.
        movzx   r13, byte [rbx]
        movzx   r14, byte [r12]
        AF_CHECK_EQ r13, r14, "the timestamp prefix should be stable"
AF_TEST_END

AF_TEST "core/client_request_id_validation_rejects_injection"
        lea     rdi, [s_ref_ok]
        mov     rsi, 14
        call    af_id_is_valid_client_ref
        AF_CHECK_EQ rax, 1, "a well-formed client reference should be accepted"

        lea     rdi, [s_ref_space]
        mov     rsi, 6
        call    af_id_is_valid_client_ref
        AF_CHECK_EQ rax, 0, "a space must be rejected"

        ; A CRLF in an echoed header value is response splitting.
        lea     rdi, [s_ref_crlf]
        mov     rsi, 18
        call    af_id_is_valid_client_ref
        AF_CHECK_EQ rax, 0, "CRLF must be rejected"

        lea     rdi, [s_ref_ok]
        mov     rsi, 0
        call    af_id_is_valid_client_ref
        AF_CHECK_EQ rax, 0, "an empty reference must be rejected"

        lea     rdi, [s_ref_ok]
        mov     rsi, 65
        call    af_id_is_valid_client_ref
        AF_CHECK_EQ rax, 0, "an over-long reference must be rejected"
AF_TEST_END

        section .rodata
s_overflow_digits: db "18446744073709551616"
s_digits_42:       db "42"
