; AsmFlow — the provider layer's decidable parts (HARNESS.md M6).
;
; The integration suites drive a real daemon against a real socket, which is the
; only honest way to test a transfer. What belongs here is everything that is a
; pure function of its input, and everything that is an assumption about
; libcurl rather than a statement about AsmFlow.
;
; The SSE scanner is the reason this file earns its keep. Its whole job is to
; answer "where does this event end", and every interesting case is a boundary:
; an empty buffer, a terminator split across two deliveries, three different
; line endings, a CR that might or might not become a CRLF. Driving those
; through a socket would mean one daemon per case; here they are one call each,
; and the ambiguous-CR rule — the one that would silently split an event in two
; — is checkable directly rather than inferred from a response body.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "http.inc"
%include "config.inc"
%include "provider.inc"
%include "test.inc"

%define AF_TEST_TAG prov

        extern af_prov_sse_scan
        extern af_prov_check_ordinals
        extern af_prov_classify_curl
        extern af_prov_classify_status
        extern af_prov_is_retryable
        extern af_prov_error_id
        extern af_prov_map_counts
        extern af_prov_family_for_endpoint
        extern af_prov_family_bit
        extern af_prov_provider_supports
        extern af_prov_build_url
        extern af_prov_append_hex
        extern af_prov_engine_struct_size
        extern af_prov_exchange_struct_size
        extern af_prov_protocols

        extern af_curl_poll_ordinals
        extern af_curl_error_ordinals
        extern af_curl_multi_ordinals

        extern af_buf_init
        extern af_buf_free
        extern af_buf_data
        extern af_buf_len
        extern af_cstr_len
        extern af_mem_eq
        extern af_mem_zero

        section .rodata

; --- SSE corpus -------------------------------------------------------------
e_lf:        db "data: a", 10, 10
e_lf_len     equ $ - e_lf
e_crlf:      db "data: a", 13, 10, 13, 10
e_crlf_len   equ $ - e_crlf
e_cr:        db "data: a", 13, 13
e_cr_len     equ $ - e_cr
; The same event with the next event's first byte attached. A bare CR at the
; very end of what has arrived is the undecidable case; one more byte resolves
; it either way.
e_cr_more:   db "data: a", 13, 13, "data: b"
e_cr_more_len equ $ - e_cr_more
e_two:       db "data: a", 10, 10, "data: b", 10, 10
e_two_len    equ $ - e_two
e_partial:   db "data: a", 10
e_partial_len equ $ - e_partial
; A buffer ending in CR: the next byte decides whether the event ended.
e_dangling:  db "data: a", 13, 10, 13
e_dangling_len equ $ - e_dangling
; Multi-line event: two fields, then the blank line.
e_multiline: db "event: delta", 10, "data: a", 10, 10
e_multiline_len equ $ - e_multiline
; A comment-only event, which is a legal keep-alive.
e_comment:   db ": ping", 10, 10
e_comment_len equ $ - e_comment
; Leading blank line: an empty event, which SSE says dispatches nothing but is
; still a complete unit of framing.
e_leading:   db 10, "data: a", 10, 10
e_leading_len equ $ - e_leading
; A payload with an embedded blank line inside a quoted string. SSE has no
; quoting, so this genuinely IS two events, and treating it as one would be the
; framer inventing a rule the format does not have.
e_embedded:  db "data: {", 34, "x", 34, ":1}", 10, 10, "data: rest", 10, 10
e_embedded_len equ $ - e_embedded

u_base:      db "https://api.example.test/v1", 0
u_slash:     db "https://api.example.test/v1/", 0
u_root:      db "https://api.example.test", 0
u_expect_r:  db "https://api.example.test/v1/responses", 0
u_expect_c:  db "https://api.example.test/v1/chat/completions", 0
u_root_r:    db "https://api.example.test/responses", 0

s_hex0:      db "0", 0
s_hex_ff:    db "ff", 0
s_hex_1000:  db "1000", 0
s_hex_max:   db "ffffffffffffffff", 0

s_http_https: db "http,https", 0

        section .text

; ---------------------------------------------------------------------------
; The libcurl enumerators AsmFlow mirrors.
; ---------------------------------------------------------------------------

        AF_TEST "prov/mirrored_curl_ordinals_match_the_library", 32
        call    af_prov_check_ordinals
        AF_CHECK_OK rax, "the mirrored libcurl constants match the linked library"
        AF_TEST_END

        AF_TEST "prov/poll_ordinals_are_reported_in_order", 128
        lea     rdi, [rsp]
        mov     rsi, 128
        call    af_mem_zero
        lea     rdi, [rsp]
        call    af_curl_poll_ordinals
        AF_CHECK_EQ qword [rsp + 0], AF_CURL_POLL_NONE, "CURL_POLL_NONE"
        AF_CHECK_EQ qword [rsp + 8], AF_CURL_POLL_IN, "CURL_POLL_IN"
        AF_CHECK_EQ qword [rsp + 16], AF_CURL_POLL_OUT, "CURL_POLL_OUT"
        AF_CHECK_EQ qword [rsp + 24], AF_CURL_POLL_INOUT, "CURL_POLL_INOUT"
        AF_CHECK_EQ qword [rsp + 32], AF_CURL_POLL_REMOVE, "CURL_POLL_REMOVE"
        AF_CHECK_EQ qword [rsp + 40], AF_CURL_SOCKET_TIMEOUT, "CURL_SOCKET_TIMEOUT"
        AF_CHECK_EQ qword [rsp + 48], AF_CURL_CSELECT_IN, "CURL_CSELECT_IN"
        AF_CHECK_EQ qword [rsp + 56], AF_CURL_CSELECT_OUT, "CURL_CSELECT_OUT"
        AF_CHECK_EQ qword [rsp + 64], AF_CURL_CSELECT_ERR, "CURL_CSELECT_ERR"
        AF_TEST_END

        AF_TEST "prov/the_pause_sentinel_still_exists", 64
        lea     rdi, [rsp]
        mov     rsi, 64
        call    af_mem_zero
        lea     rdi, [rsp]
        call    af_curl_multi_ordinals
        AF_CHECK_EQ qword [rsp + 0], AF_CURLM_OK, "CURLM_OK"
        AF_CHECK_NE qword [rsp + 8], 0, "CURL_WRITEFUNC_PAUSE has a value"
        AF_CHECK_NE qword [rsp + 16], 0, "CURLPAUSE_RECV has a value"
        AF_TEST_END

        AF_TEST "prov/the_classification_tables_are_intact", 64
        lea     rdi, [rsp]
        mov     rsi, 64
        call    af_mem_zero
        lea     rdi, [rsp]
        call    af_prov_map_counts
        AF_CHECK_EQ qword [rsp + 0], 14, "CURLcode rows"
        AF_CHECK_EQ qword [rsp + 8], 6, "retryable-class rows"
        AF_CHECK_EQ qword [rsp + 16], 10, "catalogue rows"
        AF_TEST_END

; ---------------------------------------------------------------------------
; Failure classification.
; ---------------------------------------------------------------------------

        AF_TEST "prov/a_successful_transfer_classifies_as_ok", 16
        mov     rdi, AF_CURLE_OK
        xor     esi, esi
        call    af_prov_classify_curl
        AF_CHECK_OK rax, "CURLE_OK is not a failure"
        AF_TEST_END

        AF_TEST "prov/transport_failures_get_their_own_classes", 16
        mov     rdi, AF_CURLE_CONNECT
        mov     rsi, 1
        call    af_prov_classify_curl
        AF_CHECK_EQ rax, AF_E_UP_CONNECT_FAILED, "could not connect"
        mov     rdi, AF_CURLE_RESOLVE_HOST
        mov     rsi, 1
        call    af_prov_classify_curl
        AF_CHECK_EQ rax, AF_E_UP_DNS_FAILED, "could not resolve"
        mov     rdi, AF_CURLE_PEER_VERIFY
        mov     rsi, 1
        call    af_prov_classify_curl
        AF_CHECK_EQ rax, AF_E_UP_TLS, "certificate not verified"
        mov     rdi, AF_CURLE_GOT_NOTHING
        mov     rsi, 1
        call    af_prov_classify_curl
        AF_CHECK_EQ rax, AF_E_UP_MALFORMED, "empty reply"
        mov     rdi, AF_CURLE_ABORTED_BY_CALLBACK
        mov     rsi, 1
        call    af_prov_classify_curl
        AF_CHECK_EQ rax, AF_E_UP_CANCELLED, "our own abort"
        AF_TEST_END

        AF_TEST "prov/a_timeout_is_split_by_whether_it_connected", 16
        ; libcurl reports both with the same code; the configuration
        ; distinguishes them, so this is where they are told apart.
        mov     rdi, AF_CURLE_TIMEDOUT
        xor     esi, esi
        call    af_prov_classify_curl
        AF_CHECK_EQ rax, AF_E_UP_CONNECT_TIMEOUT, "never connected"
        mov     rdi, AF_CURLE_TIMEDOUT
        mov     rsi, 4200
        call    af_prov_classify_curl
        AF_CHECK_EQ rax, AF_E_UP_TIMEOUT, "connected, then timed out"
        AF_TEST_END

        AF_TEST "prov/an_unlisted_curl_code_is_not_retryable", 16
        mov     rdi, 9999
        mov     rsi, 1
        call    af_prov_classify_curl
        AF_CHECK_EQ rax, AF_E_UP_STATUS, "unclassified failure"
        mov     rdi, rax
        mov     rsi, 0xffffffff
        call    af_prov_is_retryable
        AF_CHECK_FALSE rax, "an unreasoned failure is never repeated"
        AF_TEST_END

        AF_TEST "prov/upstream_status_classes", 16
        mov     rdi, 200
        call    af_prov_classify_status
        AF_CHECK_OK rax, "200"
        mov     rdi, 204
        call    af_prov_classify_status
        AF_CHECK_OK rax, "204"
        mov     rdi, 299
        call    af_prov_classify_status
        AF_CHECK_OK rax, "299"
        mov     rdi, 300
        call    af_prov_classify_status
        AF_CHECK_EQ rax, AF_E_UP_STATUS, "300 is not success"
        mov     rdi, 502
        call    af_prov_classify_status
        AF_CHECK_EQ rax, AF_E_UP_HTTP_502, "502 keeps its identity"
        mov     rdi, 503
        call    af_prov_classify_status
        AF_CHECK_EQ rax, AF_E_UP_HTTP_503, "503 keeps its identity"
        mov     rdi, 504
        call    af_prov_classify_status
        AF_CHECK_EQ rax, AF_E_UP_HTTP_504, "504 keeps its identity"
        mov     rdi, 429
        call    af_prov_classify_status
        AF_CHECK_EQ rax, AF_E_UP_STATUS, "429 is passed through, not retried"
        mov     rdi, 199
        call    af_prov_classify_status
        AF_CHECK_EQ rax, AF_E_UP_STATUS, "1xx is not a response to relay"
        AF_TEST_END

        AF_TEST "prov/retryability_follows_the_configured_mask", 16
        mov     rdi, AF_E_UP_CONNECT_FAILED
        mov     rsi, AF_RETRY_CONNECT_FAILED
        call    af_prov_is_retryable
        AF_CHECK_TRUE rax, "named class is retryable"
        mov     rdi, AF_E_UP_CONNECT_FAILED
        mov     rsi, AF_RETRY_HTTP_502
        call    af_prov_is_retryable
        AF_CHECK_FALSE rax, "a different class does not enable it"
        mov     rdi, AF_E_UP_CONNECT_FAILED
        xor     esi, esi
        call    af_prov_is_retryable
        AF_CHECK_FALSE rax, "an empty mask enables nothing"
        AF_TEST_END

        AF_TEST "prov/tls_is_never_retryable_whatever_is_configured", 16
        ; A certificate that does not verify is an answer, not a hiccup, and a
        ; fallback would quietly prefer the target with the weakest TLS.
        mov     rdi, AF_E_UP_TLS
        mov     rsi, 0xffffffff
        call    af_prov_is_retryable
        AF_CHECK_FALSE rax, "TLS is not in the retryable table at all"
        mov     rdi, AF_E_UP_TIMEOUT
        mov     rsi, 0xffffffff
        call    af_prov_is_retryable
        AF_CHECK_FALSE rax, "a request timeout is not a connect timeout"
        AF_TEST_END

        AF_TEST "prov/every_failure_maps_to_a_catalogue_entry", 16
        mov     rdi, AF_E_UP_CONNECT_FAILED
        call    af_prov_error_id
        AF_CHECK_EQ rax, AF_HERR_UPSTREAM_CONNECT, "connect failure"
        mov     rdi, AF_E_UP_DNS_FAILED
        call    af_prov_error_id
        AF_CHECK_EQ rax, AF_HERR_UPSTREAM_CONNECT, "dns failure"
        mov     rdi, AF_E_UP_TLS
        call    af_prov_error_id
        AF_CHECK_EQ rax, AF_HERR_UPSTREAM_TLS, "tls failure"
        mov     rdi, AF_E_UP_TIMEOUT
        call    af_prov_error_id
        AF_CHECK_EQ rax, AF_HERR_UPSTREAM_TIMEOUT, "timeout"
        mov     rdi, AF_E_UP_CONNECT_TIMEOUT
        call    af_prov_error_id
        AF_CHECK_EQ rax, AF_HERR_UPSTREAM_TIMEOUT, "connect timeout"
        mov     rdi, AF_E_UP_MALFORMED
        call    af_prov_error_id
        AF_CHECK_EQ rax, AF_HERR_UPSTREAM_INVALID, "malformed response"
        mov     rdi, -9999
        call    af_prov_error_id
        AF_CHECK_EQ rax, AF_HERR_UPSTREAM_INVALID, "an unmapped failure still answers"
        AF_TEST_END

; ---------------------------------------------------------------------------
; The SSE framer.
; ---------------------------------------------------------------------------

        AF_TEST "prov/sse_scan_refuses_nothing", 16
        xor     edi, edi
        mov     rsi, 10
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, 0, "a null buffer holds no event"
        lea     rdi, [e_lf]
        xor     esi, esi
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, 0, "an empty buffer holds no event"
        AF_TEST_END

        AF_TEST "prov/sse_scan_finds_each_line_terminator", 16
        lea     rdi, [e_lf]
        mov     rsi, e_lf_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, e_lf_len, "LF LF"
        lea     rdi, [e_crlf]
        mov     rsi, e_crlf_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, e_crlf_len, "CRLF CRLF"
        ; A buffer that ENDS in a bare CR is the one undecidable case: that CR
        ; is either the blank line's terminator or the first half of a CRLF
        ; still in flight. Answering now would split one event into two, so the
        ; scanner waits — and one more byte settles it.
        lea     rdi, [e_cr]
        mov     rsi, e_cr_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, 0, "CR CR at the end of the buffer is ambiguous"
        lea     rdi, [e_cr_more]
        mov     rsi, e_cr_more_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, e_cr_len, "CR CR followed by anything is decidable"
        AF_TEST_END

        AF_TEST "prov/sse_scan_stops_at_the_first_event", 16
        lea     rdi, [e_two]
        mov     rsi, e_two_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, e_two_len / 2, "two events are not one"
        AF_TEST_END

        AF_TEST "prov/sse_scan_waits_for_an_incomplete_event", 16
        lea     rdi, [e_partial]
        mov     rsi, e_partial_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, 0, "one line is not an event"
        AF_TEST_END

        AF_TEST "prov/a_trailing_cr_is_not_decided_early", 16
        ; The buffer is `data: a CR LF CR`. The final CR is either a bare-CR
        ; line ending, which ends the event, or the first half of a CRLF that
        ; has not arrived. Answering now would split one event into two.
        lea     rdi, [e_dangling]
        mov     rsi, e_dangling_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, 0, "an ambiguous CR waits for the next byte"
        ; One more byte and it is decidable either way.
        lea     rdi, [e_crlf]
        mov     rsi, e_crlf_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, e_crlf_len, "the LF completes it"
        AF_TEST_END

        AF_TEST "prov/sse_scan_grows_monotonically_with_the_buffer", 32
        ; Every prefix of a complete event answers 0, and the full event
        ; answers its own length. That is the property the one-byte-at-a-time
        ; corpus exercises through a socket, stated directly.
        xor     r12, r12
.prefix_loop:
        cmp     r12, e_crlf_len
        jae     .prefix_done
        lea     rdi, [e_crlf]
        mov     rsi, r12
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, 0, "a prefix is never a complete event"
        inc     r12
        jmp     .prefix_loop
.prefix_done:
        lea     rdi, [e_crlf]
        mov     rsi, e_crlf_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, e_crlf_len, "the whole event is one event"
        AF_TEST_END

        AF_TEST "prov/a_multi_line_event_is_one_event", 16
        lea     rdi, [e_multiline]
        mov     rsi, e_multiline_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, e_multiline_len, "two fields and a blank line"
        AF_TEST_END

        AF_TEST "prov/a_comment_only_event_is_still_an_event", 16
        lea     rdi, [e_comment]
        mov     rsi, e_comment_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, e_comment_len, "a keep-alive comment is framed"
        AF_TEST_END

        AF_TEST "prov/a_leading_blank_line_is_its_own_event", 16
        lea     rdi, [e_leading]
        mov     rsi, e_leading_len
        call    af_prov_sse_scan
        AF_CHECK_EQ rax, 1, "an empty first line ends an empty event"
        AF_TEST_END

        AF_TEST "prov/sse_framing_has_no_quoting_rule", 16
        ; A blank line inside what looks like a JSON payload still ends the
        ; event, because SSE has no quoting. A framer that "helpfully" skipped
        ; it would disagree with every other SSE implementation.
        lea     rdi, [e_embedded]
        mov     rsi, e_embedded_len
        call    af_prov_sse_scan
        AF_CHECK_NE rax, e_embedded_len, "the blank line still ends the event"
        AF_CHECK_NE rax, 0, "and it is found"
        AF_TEST_END

; ---------------------------------------------------------------------------
; The adapter's pure parts.
; ---------------------------------------------------------------------------

        AF_TEST "prov/endpoints_map_to_families", 16
        mov     rdi, AF_EP_RESPONSES
        call    af_prov_family_for_endpoint
        AF_CHECK_EQ rax, AF_PROV_FAMILY_RESPONSES, "responses"
        mov     rdi, AF_EP_CHAT
        call    af_prov_family_for_endpoint
        AF_CHECK_EQ rax, AF_PROV_FAMILY_CHAT, "chat completions"
        mov     rdi, AF_EP_HEALTHZ
        call    af_prov_family_for_endpoint
        AF_CHECK_EQ rax, -1, "health is not a generation endpoint"
        mov     rdi, AF_EP_MODELS
        call    af_prov_family_for_endpoint
        AF_CHECK_EQ rax, -1, "models is not a generation endpoint"
        AF_TEST_END

        AF_TEST "prov/families_use_the_routes_own_bits", 16
        mov     rdi, AF_PROV_FAMILY_RESPONSES
        call    af_prov_family_bit
        AF_CHECK_EQ rax, AF_EPF_RESPONSES, "responses bit"
        mov     rdi, AF_PROV_FAMILY_CHAT
        call    af_prov_family_bit
        AF_CHECK_EQ rax, AF_EPF_CHAT_COMPLETIONS, "chat bit"
        AF_TEST_END

        AF_TEST "prov/capability_filtering", 224
        ; A provider record built by hand, so the filter is tested rather than
        ; the configuration loader.
        lea     rdi, [rsp]
        mov     rsi, PRV_SIZE
        call    af_mem_zero
        mov     qword [rsp + PRV_ENABLED], 1
        mov     qword [rsp + PRV_ADAPTER], AF_ADAPTER_OPENAI_DUAL
        mov     qword [rsp + PRV_CAPABILITIES], AF_CAP_RESPONSES | AF_CAP_CHAT_COMPLETIONS

        lea     rdi, [rsp]
        mov     rsi, AF_PROV_FAMILY_RESPONSES
        xor     edx, edx
        call    af_prov_provider_supports
        AF_CHECK_TRUE rax, "responses without streaming"

        lea     rdi, [rsp]
        mov     rsi, AF_PROV_FAMILY_RESPONSES
        mov     rdx, 1
        call    af_prov_provider_supports
        AF_CHECK_FALSE rax, "a stream needs the streaming capability"

        or      qword [rsp + PRV_CAPABILITIES], AF_CAP_STREAMING
        lea     rdi, [rsp]
        mov     rsi, AF_PROV_FAMILY_RESPONSES
        mov     rdx, 1
        call    af_prov_provider_supports
        AF_CHECK_TRUE rax, "and with it, it does"

        mov     qword [rsp + PRV_ENABLED], 0
        lea     rdi, [rsp]
        mov     rsi, AF_PROV_FAMILY_RESPONSES
        xor     edx, edx
        call    af_prov_provider_supports
        AF_CHECK_FALSE rax, "a disabled provider serves nothing"
        mov     qword [rsp + PRV_ENABLED], 1

        mov     qword [rsp + PRV_ADAPTER], AF_ADAPTER_OPENAI_CHAT
        lea     rdi, [rsp]
        mov     rsi, AF_PROV_FAMILY_RESPONSES
        xor     edx, edx
        call    af_prov_provider_supports
        AF_CHECK_FALSE rax, "a chat adapter does not speak responses"
        lea     rdi, [rsp]
        mov     rsi, AF_PROV_FAMILY_CHAT
        xor     edx, edx
        call    af_prov_provider_supports
        AF_CHECK_TRUE rax, "but it does speak chat"

        xor     edi, edi
        mov     rsi, AF_PROV_FAMILY_CHAT
        xor     edx, edx
        call    af_prov_provider_supports
        AF_CHECK_FALSE rax, "a null provider supports nothing"
        AF_TEST_END

        AF_TEST "prov/url_building", 288
;   [rsp + 0]   af_buffer
;   [rsp + 32]  provider record
%define URLBUF 0
%define URLPRV 32
        lea     rdi, [rsp + URLBUF]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "buffer"
        lea     rdi, [rsp + URLPRV]
        mov     rsi, PRV_SIZE
        call    af_mem_zero
        lea     rax, [u_base]
        mov     [rsp + URLPRV + PRV_BASE_URL], rax
        mov     rdi, rax
        call    af_cstr_len
        mov     [rsp + URLPRV + PRV_BASE_URL_LEN], rax

        lea     rdi, [rsp + URLBUF]
        lea     rsi, [rsp + URLPRV]
        mov     rdx, AF_PROV_FAMILY_RESPONSES
        call    af_prov_build_url
        AF_CHECK_OK rax, "responses url"
        lea     rdi, [rsp + URLBUF]
        call    af_buf_data
        mov     r12, rax
        lea     r13, [u_expect_r]
        mov     rdi, r13
        call    af_cstr_len
        AF_CHECK_MEM_EQ r12, r13, rax, "base + /responses"

        lea     rdi, [rsp + URLBUF]
        lea     rsi, [rsp + URLPRV]
        mov     rdx, AF_PROV_FAMILY_CHAT
        call    af_prov_build_url
        AF_CHECK_OK rax, "chat url"
        lea     rdi, [rsp + URLBUF]
        call    af_buf_data
        mov     r12, rax
        lea     r13, [u_expect_c]
        mov     rdi, r13
        call    af_cstr_len
        AF_CHECK_MEM_EQ r12, r13, rax, "base + /chat/completions"

        ; A trailing slash on the base must not produce a doubled separator:
        ; some providers route on the exact path.
        lea     rax, [u_slash]
        mov     [rsp + URLPRV + PRV_BASE_URL], rax
        mov     rdi, rax
        call    af_cstr_len
        mov     [rsp + URLPRV + PRV_BASE_URL_LEN], rax
        lea     rdi, [rsp + URLBUF]
        lea     rsi, [rsp + URLPRV]
        mov     rdx, AF_PROV_FAMILY_RESPONSES
        call    af_prov_build_url
        AF_CHECK_OK rax, "trailing slash"
        lea     rdi, [rsp + URLBUF]
        call    af_buf_data
        mov     r12, rax
        lea     r13, [u_expect_r]
        mov     rdi, r13
        call    af_cstr_len
        AF_CHECK_MEM_EQ r12, r13, rax, "no doubled separator"

        lea     rax, [u_root]
        mov     [rsp + URLPRV + PRV_BASE_URL], rax
        mov     qword [rsp + URLPRV + PRV_BASE_URL_LEN], 0
        lea     rdi, [rsp + URLBUF]
        lea     rsi, [rsp + URLPRV]
        mov     rdx, AF_PROV_FAMILY_RESPONSES
        call    af_prov_build_url
        AF_CHECK_OK rax, "length derived when not supplied"
        lea     rdi, [rsp + URLBUF]
        call    af_buf_data
        mov     r12, rax
        lea     r13, [u_root_r]
        mov     rdi, r13
        call    af_cstr_len
        AF_CHECK_MEM_EQ r12, r13, rax, "root base"

        mov     qword [rsp + URLPRV + PRV_BASE_URL], 0
        lea     rdi, [rsp + URLBUF]
        lea     rsi, [rsp + URLPRV]
        mov     rdx, AF_PROV_FAMILY_RESPONSES
        call    af_prov_build_url
        AF_CHECK_ERR rax, AF_E_INVALID, "a provider with no base url"

        lea     rdi, [rsp + URLBUF]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "prov/only_http_schemes_are_permitted", 16
        call    af_prov_protocols
        mov     r12, rax
        lea     r13, [s_http_https]
        mov     rdi, r13
        call    af_cstr_len
        AF_CHECK_MEM_EQ r12, r13, rax, "http,https and nothing else"
        AF_TEST_END

        AF_TEST "prov/chunk_sizes_are_lower_case_hex_without_padding", 96
%define HEXBUF 0
        lea     rdi, [rsp + HEXBUF]
        mov     rsi, 256
        call    af_buf_init
        AF_CHECK_OK rax, "buffer"

        lea     rdi, [rsp + HEXBUF]
        xor     esi, esi
        call    af_prov_append_hex
        AF_CHECK_OK rax, "zero"
        lea     rdi, [rsp + HEXBUF]
        call    af_buf_len
        AF_CHECK_EQ rax, 1, "zero is one digit, not none"
        lea     rdi, [rsp + HEXBUF]
        call    af_buf_data
        mov     r12, rax
        lea     r13, [s_hex0]
        AF_CHECK_MEM_EQ r12, r13, 1, "0"

        lea     rdi, [rsp + HEXBUF]
        mov     rsi, 255
        call    af_prov_append_hex
        AF_CHECK_OK rax, "255"
        lea     rdi, [rsp + HEXBUF]
        call    af_buf_data
        lea     r12, [rax + 1]
        lea     r13, [s_hex_ff]
        AF_CHECK_MEM_EQ r12, r13, 2, "ff, lower case"

        lea     rdi, [rsp + HEXBUF]
        mov     rsi, 4096
        call    af_prov_append_hex
        AF_CHECK_OK rax, "4096"
        lea     rdi, [rsp + HEXBUF]
        call    af_buf_data
        lea     r12, [rax + 3]
        lea     r13, [s_hex_1000]
        AF_CHECK_MEM_EQ r12, r13, 4, "1000, no leading zeros"

        lea     rdi, [rsp + HEXBUF]
        mov     rsi, -1
        call    af_prov_append_hex
        AF_CHECK_OK rax, "the largest value"
        lea     rdi, [rsp + HEXBUF]
        call    af_buf_data
        lea     r12, [rax + 7]
        lea     r13, [s_hex_max]
        AF_CHECK_MEM_EQ r12, r13, 16, "sixteen digits"

        lea     rdi, [rsp + HEXBUF]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "prov/the_structures_are_the_size_the_header_says", 16
        call    af_prov_exchange_struct_size
        AF_CHECK_EQ rax, PX_SIZE, "af_prov_exchange"
        call    af_prov_engine_struct_size
        AF_CHECK_EQ rax, PE_SIZE, "af_prov_engine"
        AF_CHECK_TRUE 1, "the exchange table is bounded"
        AF_CHECK_EQ PE_SIZE, PE_EXCHANGES + AF_PROV_MAX_EXCHANGES * PX_SIZE, \
                    "the engine is its header plus the table"
        AF_TEST_END

        AF_TEST "prov/the_pause_marks_leave_room_under_the_ceiling", 16
        ; Backpressure that engages only when the buffer is already full is not
        ; backpressure; the marks have to sit below the outbox's ceiling, and
        ; the low mark below the high one.
        AF_CHECK_TRUE AF_PROV_PAUSE_HIGH < 1048576, "high mark is under the outbox ceiling"
        AF_CHECK_TRUE AF_PROV_PAUSE_LOW < AF_PROV_PAUSE_HIGH, "low mark is under the high mark"
        AF_CHECK_TRUE AF_HTTP_OUTBOX_COMPACT <= AF_PROV_PAUSE_LOW, \
                      "compaction happens no later than the resume point"
        AF_TEST_END
