; AsmFlow — the HTTP layer's decidable parts (HARNESS.md M5).
;
; The endpoint suites drive a real daemon over TCP, which is the only honest way
; to test a listener. What is left for here is everything that is a pure
; function of its input and everything that is an assumption about the linked
; library: the address parsers, the path table, the Content-Length grammar, and
; llhttp's own enumerators.
;
; That last group matters most. `include/http.inc` mirrors llhttp's method and
; error ordinals so the assembly can compare against a constant, and a release
; that renumbered them would otherwise be discovered as a request being handled
; as the wrong method rather than as a failing test.

        bits 64
        default rel

%include "asmflow.inc"
%include "http.inc"
%include "test.inc"

%define AF_TEST_TAG http

        extern af_http_parse_ipv4
        extern af_http_parse_ipv6
        extern af_http_parse_u64
        extern af_http_resolve_endpoint
        extern af_http_error_def
        extern af_http_error_count
        extern af_http_reason
        extern af_http_error_class_name
        extern af_http_conn_struct_size
        extern af_http_server_struct_size

        extern af_llhttp_parser_size
        extern af_llhttp_request_init
        extern af_llhttp_lenient_flags
        extern af_llhttp_method_ordinals
        extern af_llhttp_errno_ordinals

        extern af_cstr_len
        extern af_mem_eq
        extern af_mem_zero

        section .rodata

p_healthz:    db "/healthz", 0
p_readyz:     db "/readyz", 0
p_models:     db "/v1/models", 0
p_responses:  db "/v1/responses", 0
p_chat:       db "/v1/chat/completions", 0
p_query:      db "/v1/models?limit=2", 0
p_trailing:   db "/healthz/", 0
p_prefix:     db "/healthzz", 0
p_encoded:    db "/v1%2Fmodels", 0
p_dot:        db "/v1/./models", 0
p_double:     db "//v1/models", 0
p_absolute:   db "http://host/healthz", 0
p_empty_q:    db "/healthz?", 0

a_loopback:   db "127.0.0.1", 0
a_zeros:      db "0.0.0.0", 0
a_broadcast:  db "255.255.255.255", 0
a_leading0:   db "010.0.0.1", 0
a_short:      db "127.0.1", 0
a_long:       db "127.0.0.1.5", 0
a_range:      db "127.0.0.256", 0
a_empty_part: db "127..0.1", 0
a_trailing:   db "127.0.0.1.", 0
a_letters:    db "127.0.0.x", 0
a_spaced:     db "127.0.0.1 ", 0

a6_one:       db "::1", 0
a6_any:       db "::", 0
a6_full:      db "2001:0db8:0000:0000:0000:ff00:0042:8329", 0
a6_short:     db "2001:db8::ff00:42:8329", 0
a6_head:      db "fe80::", 0
a6_triple:    db ":::1", 0
a6_two_gaps:  db "1::2::3", 0
a6_too_many:  db "1:2:3:4:5:6:7:8:9", 0
a6_bad_digit: db "1:2:3:4:5:6:7:g", 0
a6_v4mapped:  db "::ffff:127.0.0.1", 0
a6_trailing:  db "1:2:3:4:5:6:7:", 0

n_zero:       db "0"
n_one:        db "1"
n_normal:     db "1024"
n_max:        db "18446744073709551615"
n_plus:       db "+2"
n_space:      db "2 "
n_hex:        db "0x2"
n_list:       db "2, 2"
n_empty:      db ""
n_overflow:   db "18446744073709551616"

        section .text

; ---------------------------------------------------------------------------
        AF_TEST "http/llhttp_method_ordinals_match_the_header", 64
        lea     rdi, [rsp]
        mov     rsi, 64
        call    af_mem_zero
        lea     rdi, [rsp]
        call    af_llhttp_method_ordinals
        mov     eax, dword [rsp + 0]
        AF_CHECK_EQ rax, AF_HTTP_M_DELETE, "DELETE ordinal"
        mov     eax, dword [rsp + 4]
        AF_CHECK_EQ rax, AF_HTTP_M_GET, "GET ordinal"
        mov     eax, dword [rsp + 8]
        AF_CHECK_EQ rax, AF_HTTP_M_HEAD, "HEAD ordinal"
        mov     eax, dword [rsp + 12]
        AF_CHECK_EQ rax, AF_HTTP_M_POST, "POST ordinal"
        mov     eax, dword [rsp + 16]
        AF_CHECK_EQ rax, AF_HTTP_M_PUT, "PUT ordinal"
        mov     eax, dword [rsp + 20]
        AF_CHECK_EQ rax, AF_HTTP_M_CONNECT, "CONNECT ordinal"
        mov     eax, dword [rsp + 24]
        AF_CHECK_EQ rax, AF_HTTP_M_OPTIONS, "OPTIONS ordinal"
        AF_LEAVE

        AF_TEST "http/llhttp_error_ordinals_match_the_header", 64
        lea     rdi, [rsp]
        mov     rsi, 64
        call    af_mem_zero
        lea     rdi, [rsp]
        call    af_llhttp_errno_ordinals
        mov     eax, dword [rsp + 0]
        AF_CHECK_EQ rax, AF_HPE_OK, "HPE_OK"
        mov     eax, dword [rsp + 4]
        AF_CHECK_EQ rax, AF_HPE_PAUSED, "HPE_PAUSED"
        mov     eax, dword [rsp + 8]
        AF_CHECK_EQ rax,  AF_HPE_PAUSED_UPGRADE, "HPE_PAUSED_UPGRADE"
        mov     eax, dword [rsp + 12]
        AF_CHECK_EQ rax, AF_HPE_USER, "HPE_USER"
        AF_LEAVE

        AF_TEST "http/the_parser_fits_the_reserved_field", 16
        ; The daemon asserts this at startup; asserting it here as well means a
        ; library upgrade fails the test suite rather than the first daemon run.
        call    af_llhttp_parser_size
        AF_CHECK_TRUE rax, "llhttp reports a parser size"
        cmp     rax, AF_HTTP_PARSER_MAX
        setbe   al
        movzx   rax, al
        AF_CHECK_TRUE rax, "the reserved parser field is large enough"
        AF_LEAVE

        AF_TEST "http/a_fresh_parser_has_no_leniency", 320
        ; HARNESS.md M5 DoD 5. Leniency being off is what makes the smuggling
        ; corpus mean anything, so it is read back rather than assumed.
        lea     rdi, [rsp]
        mov     rsi, 320
        call    af_mem_zero
        lea     rdi, [rsp]
        xor     esi, esi
        call    af_llhttp_request_init
        lea     rdi, [rsp]
        call    af_llhttp_lenient_flags
        movsxd  rax, eax
        AF_CHECK_EQ rax, 0, "every lenient flag is clear"
        AF_LEAVE

; --- the routing table -----------------------------------------------------

        AF_TEST "http/every_contract_path_resolves", 16
        lea     rdi, [p_healthz]
        mov     rsi, 8
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_HEALTHZ, "/healthz"
        lea     rdi, [p_readyz]
        mov     rsi, 7
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_READYZ, "/readyz"
        lea     rdi, [p_models]
        mov     rsi, 10
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_MODELS, "/v1/models"
        lea     rdi, [p_responses]
        mov     rsi, 13
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_RESPONSES, "/v1/responses"
        lea     rdi, [p_chat]
        mov     rsi, 20
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_CHAT, "/v1/chat/completions"
        AF_LEAVE

        AF_TEST "http/a_query_string_is_not_part_of_the_path", 16
        lea     rdi, [p_query]
        mov     rsi, 18
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_MODELS, "/v1/models?limit=2"
        lea     rdi, [p_empty_q]
        mov     rsi, 9
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_HEALTHZ, "/healthz?"
        AF_LEAVE

        AF_TEST "http/the_path_is_matched_byte_for_byte", 16
        ; No normalisation means no disagreement about what was matched.
        lea     rdi, [p_trailing]
        mov     rsi, 9
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_UNKNOWN, "a trailing slash is a different path"
        lea     rdi, [p_prefix]
        mov     rsi, 9
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_UNKNOWN, "no prefix match"
        lea     rdi, [p_encoded]
        mov     rsi, 12
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_UNKNOWN, "no percent-decoding"
        lea     rdi, [p_dot]
        mov     rsi, 12
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_UNKNOWN, "no dot-segment collapsing"
        lea     rdi, [p_double]
        mov     rsi, 11
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_UNKNOWN, "no empty-segment collapsing"
        AF_LEAVE

        AF_TEST "http/a_non_origin_form_target_resolves_to_nothing", 16
        lea     rdi, [p_absolute]
        mov     rsi, 19
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_UNKNOWN, "absolute form"
        xor     edi, edi
        mov     rsi, 4
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_UNKNOWN, "a null target"
        lea     rdi, [p_healthz]
        xor     esi, esi
        call    af_http_resolve_endpoint
        AF_CHECK_EQ rax, AF_EP_UNKNOWN, "an empty target"
        AF_LEAVE

; --- Content-Length --------------------------------------------------------

        AF_TEST "http/a_length_is_digits_and_nothing_else", 32
        lea     rdi, [n_zero]
        mov     rsi, 1
        lea     rdx, [rsp]
        call    af_http_parse_u64
        AF_CHECK_OK rax, "0 parses"
        AF_CHECK_EQ qword [rsp], 0, "0 is zero"
        lea     rdi, [n_normal]
        mov     rsi, 4
        lea     rdx, [rsp]
        call    af_http_parse_u64
        AF_CHECK_OK rax, "1024 parses"
        AF_CHECK_EQ qword [rsp], 1024, "1024 is 1024"
        lea     rdi, [n_max]
        mov     rsi, 20
        lea     rdx, [rsp]
        call    af_http_parse_u64
        AF_CHECK_OK rax, "the largest u64 parses"
        AF_CHECK_EQ qword [rsp], -1, "and is all ones"
        AF_LEAVE

        AF_TEST "http/a_length_that_two_parsers_could_read_differently_is_refused", 32
        lea     rdi, [n_plus]
        mov     rsi, 2
        lea     rdx, [rsp]
        call    af_http_parse_u64
        AF_CHECK_ERR rax, AF_E_INVALID, "a leading plus"
        lea     rdi, [n_space]
        mov     rsi, 2
        lea     rdx, [rsp]
        call    af_http_parse_u64
        AF_CHECK_ERR rax, AF_E_INVALID, "a trailing space"
        lea     rdi, [n_hex]
        mov     rsi, 3
        lea     rdx, [rsp]
        call    af_http_parse_u64
        AF_CHECK_ERR rax, AF_E_INVALID, "a hex prefix"
        lea     rdi, [n_list]
        mov     rsi, 4
        lea     rdx, [rsp]
        call    af_http_parse_u64
        AF_CHECK_ERR rax, AF_E_INVALID, "a comma-separated list"
        lea     rdi, [n_empty]
        xor     esi, esi
        lea     rdx, [rsp]
        call    af_http_parse_u64
        AF_CHECK_ERR rax, AF_E_INVALID, "an empty value"
        lea     rdi, [n_overflow]
        mov     rsi, 20
        lea     rdx, [rsp]
        call    af_http_parse_u64
        AF_CHECK_ERR rax, AF_E_INVALID, "a value past u64"
        AF_LEAVE

; --- listen addresses ------------------------------------------------------

        AF_TEST "http/ipv4_literals_parse_to_network_order", 32
        mov     dword [rsp], 0
        lea     rdi, [a_loopback]
        mov     rsi, 9
        lea     rdx, [rsp]
        call    af_http_parse_ipv4
        AF_CHECK_OK rax, "127.0.0.1 parses"
        mov     eax, dword [rsp]
        AF_CHECK_EQ rax, 0x0100007F, "127.0.0.1 in network order"
        lea     rdi, [a_zeros]
        mov     rsi, 7
        lea     rdx, [rsp]
        call    af_http_parse_ipv4
        AF_CHECK_OK rax, "0.0.0.0 parses"
        mov     eax, dword [rsp]
        AF_CHECK_EQ rax, 0, "0.0.0.0 is zero"
        lea     rdi, [a_broadcast]
        mov     rsi, 15
        lea     rdx, [rsp]
        call    af_http_parse_ipv4
        AF_CHECK_OK rax, "255.255.255.255 parses"
        mov     eax, dword [rsp]
        AF_CHECK_EQ rax, 0xFFFFFFFF, "255.255.255.255 is all ones"
        AF_LEAVE

        AF_TEST "http/an_ambiguous_ipv4_literal_is_refused", 32
        ; A leading zero is read as octal by some resolvers. An address whose
        ; value depends on who parses it is not one a listener should bind.
        lea     rdi, [a_leading0]
        mov     rsi, 9
        lea     rdx, [rsp]
        call    af_http_parse_ipv4
        AF_CHECK_ERR rax, AF_E_INVALID, "a leading zero"
        lea     rdi, [a_short]
        mov     rsi, 7
        lea     rdx, [rsp]
        call    af_http_parse_ipv4
        AF_CHECK_ERR rax, AF_E_INVALID, "three octets"
        lea     rdi, [a_long]
        mov     rsi, 11
        lea     rdx, [rsp]
        call    af_http_parse_ipv4
        AF_CHECK_ERR rax, AF_E_INVALID, "five octets"
        lea     rdi, [a_range]
        mov     rsi, 11
        lea     rdx, [rsp]
        call    af_http_parse_ipv4
        AF_CHECK_ERR rax, AF_E_INVALID, "an octet past 255"
        lea     rdi, [a_empty_part]
        mov     rsi, 8
        lea     rdx, [rsp]
        call    af_http_parse_ipv4
        AF_CHECK_ERR rax, AF_E_INVALID, "an empty octet"
        lea     rdi, [a_trailing]
        mov     rsi, 10
        lea     rdx, [rsp]
        call    af_http_parse_ipv4
        AF_CHECK_ERR rax, AF_E_INVALID, "a trailing dot"
        lea     rdi, [a_letters]
        mov     rsi, 9
        lea     rdx, [rsp]
        call    af_http_parse_ipv4
        AF_CHECK_ERR rax, AF_E_INVALID, "a letter"
        lea     rdi, [a_spaced]
        mov     rsi, 10
        lea     rdx, [rsp]
        call    af_http_parse_ipv4
        AF_CHECK_ERR rax, AF_E_INVALID, "a trailing space"
        AF_LEAVE

        AF_TEST "http/ipv6_literals_parse", 48
        lea     rdi, [rsp]
        mov     rsi, 16
        call    af_mem_zero
        lea     rdi, [a6_one]
        mov     rsi, 3
        lea     rdx, [rsp]
        call    af_http_parse_ipv6
        AF_CHECK_OK rax, "::1 parses"
        AF_CHECK_EQ qword [rsp], 0, "::1 has a zero high half"
        movzx   eax, byte [rsp + 15]
        AF_CHECK_EQ rax, 1, "::1 ends in one"

        lea     rdi, [a6_any]
        mov     rsi, 2
        lea     rdx, [rsp]
        call    af_http_parse_ipv6
        AF_CHECK_OK rax, ":: parses"
        AF_CHECK_EQ qword [rsp], 0, ":: is all zero, low half"
        AF_CHECK_EQ qword [rsp + 8], 0, ":: is all zero, high half"

        lea     rdi, [a6_full]
        mov     rsi, 39
        lea     rdx, [rsp]
        call    af_http_parse_ipv6
        AF_CHECK_OK rax, "a fully written address parses"
        movzx   eax, byte [rsp]
        AF_CHECK_EQ rax, 0x20, "first byte"
        movzx   eax, byte [rsp + 1]
        AF_CHECK_EQ rax, 0x01, "second byte"
        movzx   eax, byte [rsp + 14]
        AF_CHECK_EQ rax, 0x83, "fifteenth byte"
        movzx   eax, byte [rsp + 15]
        AF_CHECK_EQ rax, 0x29, "sixteenth byte"

        lea     rdi, [a6_short]
        mov     rsi, 22
        lea     rdx, [rsp]
        call    af_http_parse_ipv6
        AF_CHECK_OK rax, "the elided form parses"
        movzx   eax, byte [rsp]
        AF_CHECK_EQ rax, 0x20, "elided: first byte"
        movzx   eax, byte [rsp + 3]
        AF_CHECK_EQ rax, 0xb8, "elided: fourth byte"
        movzx   eax, byte [rsp + 15]
        AF_CHECK_EQ rax, 0x29, "elided: last byte"

        lea     rdi, [a6_head]
        mov     rsi, 6
        lea     rdx, [rsp]
        call    af_http_parse_ipv6
        AF_CHECK_OK rax, "a trailing elision parses"
        movzx   eax, byte [rsp]
        AF_CHECK_EQ rax, 0xfe, "fe80:: first byte"
        movzx   eax, byte [rsp + 1]
        AF_CHECK_EQ rax, 0x80, "fe80:: second byte"
        AF_CHECK_EQ qword [rsp + 8], 0, "fe80:: is zero after"
        AF_LEAVE

        AF_TEST "http/a_malformed_ipv6_literal_is_refused", 48
        lea     rdi, [a6_triple]
        mov     rsi, 4
        lea     rdx, [rsp]
        call    af_http_parse_ipv6
        AF_CHECK_ERR rax, AF_E_INVALID, "three colons"
        lea     rdi, [a6_two_gaps]
        mov     rsi, 7
        lea     rdx, [rsp]
        call    af_http_parse_ipv6
        AF_CHECK_ERR rax, AF_E_INVALID, "two elisions"
        lea     rdi, [a6_too_many]
        mov     rsi, 17
        lea     rdx, [rsp]
        call    af_http_parse_ipv6
        AF_CHECK_ERR rax, AF_E_INVALID, "nine groups"
        lea     rdi, [a6_bad_digit]
        mov     rsi, 15
        lea     rdx, [rsp]
        call    af_http_parse_ipv6
        AF_CHECK_ERR rax, AF_E_INVALID, "a non-hex digit"
        lea     rdi, [a6_v4mapped]
        mov     rsi, 16
        lea     rdx, [rsp]
        call    af_http_parse_ipv6
        AF_CHECK_ERR rax, AF_E_INVALID, "an embedded IPv4 tail"
        lea     rdi, [a6_trailing]
        mov     rsi, 14
        lea     rdx, [rsp]
        call    af_http_parse_ipv6
        AF_CHECK_ERR rax, AF_E_INVALID, "a trailing single colon"
        AF_LEAVE

; --- the error catalogue ---------------------------------------------------

        AF_TEST "http/the_catalogue_is_complete_and_consistent", 64
        call    af_http_error_count
        AF_CHECK_EQ rax, AF_HERR_COUNT, "one entry per declared error"
        mov     r12, rax
        xor     r13, r13
.entry:
        cmp     r13, r12
        jae     .entries_done
        mov     rdi, r13
        call    af_http_error_def
        AF_CHECK_TRUE rax, "every entry exists"
        mov     r14, rax
        ; A status outside the range a client understands, a missing code, or a
        ; missing message would each produce a response nothing can act on.
        mov     rax, [r14 + HED_STATUS]
        cmp     rax, 400
        setae   al
        movzx   rax, al
        AF_CHECK_TRUE rax, "the status is a failure status"
        mov     rax, [r14 + HED_STATUS]
        cmp     rax, 599
        setbe   al
        movzx   rax, al
        AF_CHECK_TRUE rax, "the status is a real status"
        AF_CHECK_TRUE qword [r14 + HED_CODE], "the entry has a code"
        AF_CHECK_TRUE qword [r14 + HED_MESSAGE], "the entry has a message"
        mov     rax, [r14 + HED_CLASS]
        cmp     rax, AF_ERRCLASS_COUNT
        setb    al
        movzx   rax, al
        AF_CHECK_TRUE rax, "the class is one of the contract's types"
        inc     r13
        jmp     .entry
.entries_done:
        AF_LEAVE

        AF_TEST "http/an_out_of_range_error_id_still_answers", 16
        ; A wrong error id must not become a null dereference in the one code
        ; path that runs when something has already gone wrong.
        mov     rdi, AF_HERR_COUNT
        call    af_http_error_def
        AF_CHECK_TRUE rax, "out of range returns an entry"
        mov     r12, rax
        AF_CHECK_EQ qword [r12 + HED_STATUS], 500, "and it is the internal one"
        mov     rdi, -1
        call    af_http_error_def
        AF_CHECK_TRUE rax, "a negative id returns an entry too"
        AF_LEAVE

        AF_TEST "http/every_status_has_a_reason_phrase", 64
        call    af_http_error_count
        mov     r12, rax
        xor     r13, r13
.reason_entry:
        cmp     r13, r12
        jae     .reasons_done
        mov     rdi, r13
        call    af_http_error_def
        mov     rdi, [rax + HED_STATUS]
        call    af_http_reason
        AF_CHECK_TRUE rax, "a reason phrase exists"
        mov     rdi, rax
        call    af_cstr_len
        AF_CHECK_TRUE rax, "and it is not empty"
        inc     r13
        jmp     .reason_entry
.reasons_done:
        mov     rdi, 200
        call    af_http_reason
        mov     rdi, rax
        call    af_cstr_len
        AF_CHECK_EQ rax, 2, "200 is OK"
        AF_LEAVE

        AF_TEST "http/every_error_class_names_a_contract_type", 16
        xor     r12, r12
.class_entry:
        cmp     r12, AF_ERRCLASS_COUNT
        jae     .classes_done
        mov     rdi, r12
        call    af_http_error_class_name
        AF_CHECK_TRUE rax, "the class has a name"
        mov     rdi, rax
        call    af_cstr_len
        cmp     rax, 8
        seta    al
        movzx   rax, al
        AF_CHECK_TRUE rax, "the name is an asmflow_*_error"
        inc     r12
        jmp     .class_entry
.classes_done:
        AF_LEAVE

        AF_TEST "http/the_structures_are_the_size_the_daemon_allocates", 16
        call    af_http_conn_struct_size
        AF_CHECK_EQ rax, HC_SIZE, "the connection record"
        call    af_http_server_struct_size
        AF_CHECK_EQ rax, HS_SIZE, "the server record"
        mov     rax, HS_SIZE
        cmp     rax, HC_SIZE
        seta    al
        movzx   rax, al
        AF_CHECK_TRUE rax, "the server holds the connection table"
        AF_LEAVE
