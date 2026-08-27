; AsmFlow — what an upstream failure means.
;
; libcurl reports about a hundred distinct `CURLcode` values. A gateway needs
; far fewer distinctions, but it needs them to be exact, because two decisions
; hang off this classification and they pull in opposite directions:
;
;   - whether the caller may be told to try again (`asmflow.retryable`), and
;   - whether AsmFlow itself may try a different target (`fallback.retryable`).
;
; The two are not the same question. A connect failure is retryable both ways.
; A TLS failure is retryable neither way: a certificate that does not verify is
; a policy answer, and repeating the request will produce the same answer while
; a fallback would silently prefer whichever target has the weakest TLS
; posture. That is the reason TLS is separated from "could not connect" here
; rather than folded into it.
;
; Nothing in this file talks to libcurl. src/ffi/curl_shim.c reports the
; enumerators, af_prov_check_ordinals asserts AsmFlow's mirrored copies against
; them at startup, and the mapping below then works in numbers this repository
; owns. A CURLcode absent from the table is classified as an unclassified
; upstream failure, which is deliberately the non-retryable answer: a failure
; nobody has reasoned about is not one to repeat automatically.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "http.inc"
%include "config.inc"
%include "provider.inc"

        extern af_curl_poll_ordinals
        extern af_curl_error_ordinals
        extern af_curl_multi_ordinals

        section .data.rel.ro progbits align=8

; The nine values af_curl_poll_ordinals reports, in its order.
poll_expected:
        dq AF_CURL_POLL_NONE
        dq AF_CURL_POLL_IN
        dq AF_CURL_POLL_OUT
        dq AF_CURL_POLL_INOUT
        dq AF_CURL_POLL_REMOVE
        dq AF_CURL_SOCKET_TIMEOUT
        dq AF_CURL_CSELECT_IN
        dq AF_CURL_CSELECT_OUT
        dq AF_CURL_CSELECT_ERR

; The sixteen values af_curl_error_ordinals reports, in its order.
error_expected:
        dq AF_CURLE_OK
        dq AF_CURLE_RESOLVE_PROXY
        dq AF_CURLE_RESOLVE_HOST
        dq AF_CURLE_CONNECT
        dq AF_CURLE_TIMEDOUT
        dq AF_CURLE_SSL_CONNECT
        dq AF_CURLE_PEER_VERIFY
        dq AF_CURLE_SSL_CACERT_BADFILE
        dq AF_CURLE_SSL_ISSUER
        dq AF_CURLE_GOT_NOTHING
        dq AF_CURLE_PARTIAL_FILE
        dq AF_CURLE_RECV
        dq AF_CURLE_SEND
        dq AF_CURLE_WRITE
        dq AF_CURLE_ABORTED_BY_CALLBACK
        dq AF_CURLE_UNSUPPORTED_PROTO

; The CURLcode-to-af_status table, as pairs. Order is irrelevant; a linear scan
; over sixteen entries costs nothing next to a network round trip, and a table
; is what a test can read back.
;
; CURLE_WRITE_ERROR is how libcurl reports that our own write callback refused
; the data, which happens when the client has gone or a ceiling was passed. It
; is mapped to cancellation, and the exchange's own flags say which of the two
; it actually was.
curl_map:
        dq AF_CURLE_RESOLVE_PROXY,       AF_E_UP_DNS_FAILED
        dq AF_CURLE_RESOLVE_HOST,        AF_E_UP_DNS_FAILED
        dq AF_CURLE_CONNECT,             AF_E_UP_CONNECT_FAILED
        dq AF_CURLE_SSL_CONNECT,         AF_E_UP_TLS
        dq AF_CURLE_PEER_VERIFY,         AF_E_UP_TLS
        dq AF_CURLE_SSL_CACERT_BADFILE,  AF_E_UP_TLS
        dq AF_CURLE_SSL_ISSUER,          AF_E_UP_TLS
        dq AF_CURLE_GOT_NOTHING,         AF_E_UP_MALFORMED
        dq AF_CURLE_PARTIAL_FILE,        AF_E_UP_MALFORMED
        dq AF_CURLE_RECV,                AF_E_UP_MALFORMED
        dq AF_CURLE_SEND,                AF_E_UP_MALFORMED
        dq AF_CURLE_WRITE,               AF_E_UP_CANCELLED
        dq AF_CURLE_ABORTED_BY_CALLBACK, AF_E_UP_CANCELLED
        dq AF_CURLE_UNSUPPORTED_PROTO,   AF_E_UP_CONNECT_FAILED
curl_map_end:
%define CURL_MAP_COUNT ((curl_map_end - curl_map) / 16)

; Which normalised failures each `fallback.retryable` bit covers. The schema
; names six classes; AsmFlow's status space is finer, so the mapping is stated
; rather than assumed to be an identity.
retry_map:
        dq AF_E_UP_CONNECT_FAILED,  AF_RETRY_CONNECT_FAILED
        dq AF_E_UP_DNS_FAILED,      AF_RETRY_DNS_FAILED
        dq AF_E_UP_CONNECT_TIMEOUT, AF_RETRY_CONNECT_TIMEOUT
        dq AF_E_UP_HTTP_502,        AF_RETRY_HTTP_502
        dq AF_E_UP_HTTP_503,        AF_RETRY_HTTP_503
        dq AF_E_UP_HTTP_504,        AF_RETRY_HTTP_504
retry_map_end:
%define RETRY_MAP_COUNT ((retry_map_end - retry_map) / 16)

; Which catalogue entry a normalised failure is answered with.
herr_map:
        dq AF_E_UP_CONNECT_FAILED,  AF_HERR_UPSTREAM_CONNECT
        dq AF_E_UP_DNS_FAILED,      AF_HERR_UPSTREAM_CONNECT
        dq AF_E_UP_CONNECT_TIMEOUT, AF_HERR_UPSTREAM_TIMEOUT
        dq AF_E_UP_TIMEOUT,         AF_HERR_UPSTREAM_TIMEOUT
        dq AF_E_UP_TLS,             AF_HERR_UPSTREAM_TLS
        dq AF_E_UP_MALFORMED,       AF_HERR_UPSTREAM_INVALID
        dq AF_E_UP_STATUS,          AF_HERR_UPSTREAM_INVALID
        dq AF_E_UP_HTTP_502,        AF_HERR_UPSTREAM_INVALID
        dq AF_E_UP_HTTP_503,        AF_HERR_UPSTREAM_INVALID
        dq AF_E_UP_HTTP_504,        AF_HERR_UPSTREAM_TIMEOUT
herr_map_end:
%define HERR_MAP_COUNT ((herr_map_end - herr_map) / 16)

        section .text

; ---------------------------------------------------------------------------
; af_prov_check_ordinals() -> af_status
;
; Asserts that the constants in include/provider.inc are the constants the
; linked libcurl actually uses. Called once at startup; a mismatch stops the
; daemon rather than producing a gateway that watches the wrong descriptors for
; the wrong events and reports the wrong failures.
; ---------------------------------------------------------------------------
        global af_prov_check_ordinals
af_prov_check_ordinals:
        AF_ENTER 256
;   [rsp +   0]  poll ordinals   (9 x 8)
;   [rsp +  72]  multi ordinals  (3 x 8)
;   [rsp +  96]  error ordinals  (16 x 8)
%define ORD_POLL  0
%define ORD_MULTI 72
%define ORD_ERROR 96
        lea     rdi, [rsp + ORD_POLL]
        call    af_curl_poll_ordinals
        lea     rdi, [rsp + ORD_MULTI]
        call    af_curl_multi_ordinals
        lea     rdi, [rsp + ORD_ERROR]
        call    af_curl_error_ordinals

        lea     rbx, [rsp + ORD_POLL]
        lea     r12, [poll_expected]
        mov     r13, AF_CURL_POLL_ORDINALS
        xor     ecx, ecx
.poll_loop:
        cmp     rcx, r13
        jae     .poll_ok
        mov     rax, [rbx + rcx*8]
        cmp     rax, [r12 + rcx*8]
        jne     .mismatch
        inc     rcx
        jmp     .poll_loop
.poll_ok:

        lea     rbx, [rsp + ORD_ERROR]
        lea     r12, [error_expected]
        mov     r13, AF_CURL_ERROR_ORDINALS
        xor     ecx, ecx
.error_loop:
        cmp     rcx, r13
        jae     .error_ok
        mov     rax, [rbx + rcx*8]
        cmp     rax, [r12 + rcx*8]
        jne     .mismatch
        inc     rcx
        jmp     .error_loop
.error_ok:

        ; CURLM_OK is the only multi code assembly compares against, and the
        ; pause sentinel is checked for presence rather than value: the value
        ; lives in the shim, and what matters here is that libcurl still has
        ; one to give.
        cmp     qword [rsp + ORD_MULTI], AF_CURLM_OK
        jne     .mismatch
        cmp     qword [rsp + ORD_MULTI + 8], 0
        je      .mismatch
        AF_LEAVE_OK

.mismatch:
        AF_LEAVE_ERR AF_E_UNSUPPORTED

; ---------------------------------------------------------------------------
; af_prov_classify_curl(i64 curl_code, i64 connect_time_us) -> af_status
;
; AF_OK when the transfer succeeded. Otherwise the normalised failure.
;
; A timeout is split by whether a connection was ever established, because
; `fallback.retryable` distinguishes `connect_timeout` from a request that
; timed out after connecting, and libcurl reports both as CURLE_OPERATION_TIMEDOUT.
; ---------------------------------------------------------------------------
        global af_prov_classify_curl
af_prov_classify_curl:
        AF_ENTER 0
        test    rdi, rdi
        jz      .ok
        cmp     rdi, AF_CURLE_TIMEDOUT
        je      .timeout

        lea     rcx, [curl_map]
        xor     edx, edx
.scan:
        cmp     rdx, CURL_MAP_COUNT * 16
        jae     .unclassified
        mov     rax, [rcx + rdx]
        cmp     rax, rdi
        je      .found
        add     rdx, 16
        jmp     .scan
.found:
        mov     rax, [rcx + rdx + 8]
        AF_LEAVE

.timeout:
        ; No time spent connecting means the connection never came up.
        test    rsi, rsi
        jnz     .request_timeout
        mov     rax, AF_E_UP_CONNECT_TIMEOUT
        AF_LEAVE
.request_timeout:
        mov     rax, AF_E_UP_TIMEOUT
        AF_LEAVE

.unclassified:
        mov     rax, AF_E_UP_STATUS
        AF_LEAVE
.ok:
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; af_prov_classify_status(i64 http_status) -> af_status
;
; A 2xx is success. 502, 503, and 504 are the three the configuration can name
; as retryable, so they keep their identity; every other non-2xx becomes
; AF_E_UP_STATUS, which is passed through to the client rather than retried.
; ---------------------------------------------------------------------------
        global af_prov_classify_status
af_prov_classify_status:
        AF_ENTER 0
        cmp     rdi, 200
        jb      .other
        cmp     rdi, 300
        jae     .not_2xx
        AF_LEAVE_OK
.not_2xx:
        cmp     rdi, 502
        je      .e502
        cmp     rdi, 503
        je      .e503
        cmp     rdi, 504
        je      .e504
.other:
        mov     rax, AF_E_UP_STATUS
        AF_LEAVE
.e502:
        mov     rax, AF_E_UP_HTTP_502
        AF_LEAVE
.e503:
        mov     rax, AF_E_UP_HTTP_503
        AF_LEAVE
.e504:
        mov     rax, AF_E_UP_HTTP_504
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_is_retryable(af_status code, u64 retryable_mask) -> i64
;
; 1 when the route's `fallback.retryable` names this failure class. Anything
; not in the table answers 0: a class the operator did not name is not one to
; guess about, and a class AsmFlow has not reasoned about is not one to repeat.
; ---------------------------------------------------------------------------
        global af_prov_is_retryable
af_prov_is_retryable:
        AF_ENTER 0
        lea     rcx, [retry_map]
        xor     edx, edx
.scan:
        cmp     rdx, RETRY_MAP_COUNT * 16
        jae     .no
        mov     rax, [rcx + rdx]
        cmp     rax, rdi
        je      .found
        add     rdx, 16
        jmp     .scan
.found:
        mov     rax, [rcx + rdx + 8]
        and     rax, rsi
        jz      .no
        mov     eax, 1
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_error_id(af_status code) -> u64 (AF_HERR_*)
;
; Which catalogue entry the client is answered with. An unmapped failure is
; answered as an invalid upstream response, which is the honest statement: the
; gateway could not turn what the provider did into an answer.
; ---------------------------------------------------------------------------
        global af_prov_error_id
af_prov_error_id:
        AF_ENTER 0
        lea     rcx, [herr_map]
        xor     edx, edx
.scan:
        cmp     rdx, HERR_MAP_COUNT * 16
        jae     .fallback
        mov     rax, [rcx + rdx]
        cmp     rax, rdi
        je      .found
        add     rdx, 16
        jmp     .scan
.found:
        mov     rax, [rcx + rdx + 8]
        AF_LEAVE
.fallback:
        mov     rax, AF_HERR_UPSTREAM_INVALID
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_map_counts(u64 *out3) -> void
;
; The three table lengths, so a test can assert the tables were not truncated
; by an edit rather than counting rows by eye.
; ---------------------------------------------------------------------------
        global af_prov_map_counts
af_prov_map_counts:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     qword [rdi], CURL_MAP_COUNT
        mov     qword [rdi + 8], RETRY_MAP_COUNT
        mov     qword [rdi + 16], HERR_MAP_COUNT
.done:
        AF_LEAVE
