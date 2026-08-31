; AsmFlow — M11 security regression tests.
;
; These tests exercise the small policy helpers directly.  Socket acceptance and
; provider dispatch both use these helpers, so malformed peer credentials and an
; injected header value cannot take an untested branch around the policy.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "control.inc"
%include "test.inc"

%define AF_TEST_TAG m11sec

        extern af_buf_init
        extern af_buf_free
        extern af_buf_clear_secure
        extern af_buf_consume_secure
        extern af_buf_append
        extern af_buf_data
        extern af_buf_len
        extern af_buf_cap

        extern af_ctl_validate_peer_credentials
        extern af_prov_validate_header_value

        extern af_mem_zero

        section .rodata

secret_bytes:   db "request-secret"
secret_len      equ $ - secret_bytes
consume_bytes:  db "secret"
consume_tail:   db "remain"
consume_len     equ $ - consume_bytes
consume_prefix_len equ consume_tail - consume_bytes
consume_tail_len equ $ - consume_tail

value_valid:    db "sk-live_ABC-123.~", 0
value_valid_len equ $ - value_valid - 1
value_empty:    db 0
value_cr:       db "token", 13, "tail", 0
value_lf:       db "token", 10, "tail", 0
value_tab:      db "token", 9, "tail", 0
value_del:      db "token", 127, "tail", 0
value_bound:    db "abcd", 0

        section .text

; A secure clear is different from an ordinary clear: the allocation stays
; reusable, but every byte the allocator could later expose is zeroed.
AF_TEST "m11/security_buffer_clear_wipes_capacity", 256
%define SEC_BUF  0
%define SEC_ZERO 64
        lea     rdi, [rsp + SEC_BUF]
        mov     rsi, 128
        call    af_buf_init
        AF_CHECK_OK rax, "secure buffer init"

        lea     rdi, [rsp + SEC_BUF]
        lea     rsi, [secret_bytes]
        mov     rdx, secret_len
        call    af_buf_append
        AF_CHECK_OK rax, "secret append"

        lea     rdi, [rsp + SEC_BUF]
        call    af_buf_data
        mov     r12, rax
        lea     rdi, [rsp + SEC_BUF]
        call    af_buf_cap
        mov     r13, rax
        AF_CHECK_TRUE r13, "secret buffer has an allocation"

        lea     rdi, [rsp + SEC_ZERO]
        mov     rsi, 128
        call    af_mem_zero
        lea     rdi, [rsp + SEC_BUF]
        call    af_buf_clear_secure

        lea     rdi, [rsp + SEC_BUF]
        call    af_buf_data
        AF_CHECK_EQ rax, r12, "secure clear keeps the allocation"
        lea     rdi, [rsp + SEC_BUF]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "secure clear resets length"
        lea     rdi, [rsp + SEC_BUF]
        call    af_buf_cap
        AF_CHECK_EQ rax, r13, "secure clear keeps capacity"
        lea     r14, [rsp + SEC_ZERO]
        AF_CHECK_MEM_EQ r12, r14, r13, \
                        "secure clear zeroes the full capacity"

        lea     rdi, [rsp + SEC_BUF]
        call    af_buf_free
AF_TEST_END

; The raw HTTP inbox may already contain a pipelined next request. Secure
; consumption therefore has to preserve that remainder while erasing every
; byte outside the new logical length, rather than clearing the whole buffer.
AF_TEST "m11/security_buffer_consume_wipes_vacated_bytes", 256
%define CON_BUF  0
%define CON_ZERO 64
        lea     rdi, [rsp + CON_BUF]
        mov     rsi, 128
        call    af_buf_init
        AF_CHECK_OK rax, "secure consume buffer init"

        lea     rdi, [rsp + CON_BUF]
        lea     rsi, [consume_bytes]
        mov     rdx, consume_len
        call    af_buf_append
        AF_CHECK_OK rax, "secure consume input append"
        lea     rdi, [rsp + CON_BUF]
        call    af_buf_data
        mov     r12, rax
        lea     rdi, [rsp + CON_BUF]
        call    af_buf_cap
        mov     r13, rax

        lea     rdi, [rsp + CON_ZERO]
        mov     rsi, 128
        call    af_mem_zero
        lea     rdi, [rsp + CON_BUF]
        mov     rsi, consume_prefix_len
        call    af_buf_consume_secure
        AF_CHECK_OK rax, "secure consume succeeds"

        lea     rdi, [rsp + CON_BUF]
        call    af_buf_len
        AF_CHECK_EQ rax, consume_tail_len, "secure consume preserves remainder length"
        lea     r14, [consume_tail]
        AF_CHECK_MEM_EQ r12, r14, consume_tail_len, \
                        "secure consume shifts the remainder"

        lea     rbx, [r12 + consume_tail_len]
        lea     r14, [rsp + CON_ZERO]
        mov     r15, r13
        sub     r15, consume_tail_len
        AF_CHECK_MEM_EQ rbx, r14, r15, \
                        "secure consume zeroes every vacated byte"

        lea     rdi, [rsp + CON_BUF]
        call    af_buf_free
AF_TEST_END

; Linux returns struct ucred as exactly three 32-bit fields.  A truncated or
; oversized optlen must not be interpreted, and a different UID must not be
; admitted merely because it could open the pathname before permissions changed.
AF_TEST "m11/control_peer_credentials_are_exact_and_same_euid", 256
%define PEER_CONN  0
%define PEER_UCRED 128
        lea     rdi, [rsp + PEER_CONN]
        mov     rsi, CONN_SIZE
        call    af_mem_zero
        mov     dword [rsp + PEER_UCRED + 0], 4242
        mov     dword [rsp + PEER_UCRED + 4], 1001
        mov     dword [rsp + PEER_UCRED + 8], 1001

        lea     rdi, [rsp + PEER_CONN]
        lea     rsi, [rsp + PEER_UCRED]
        mov     rdx, 8
        mov     rcx, 1001
        call    af_ctl_validate_peer_credentials
        AF_CHECK_ERR rax, AF_E_INVALID, "truncated SO_PEERCRED is rejected"
        AF_CHECK_EQ qword [rsp + PEER_CONN + CONN_PEER_PID], 0, \
                    "truncated credentials are not recorded"

        lea     rdi, [rsp + PEER_CONN]
        lea     rsi, [rsp + PEER_UCRED]
        mov     rdx, 16
        mov     rcx, 1001
        call    af_ctl_validate_peer_credentials
        AF_CHECK_ERR rax, AF_E_INVALID, "oversized SO_PEERCRED is rejected"

        lea     rdi, [rsp + PEER_CONN]
        lea     rsi, [rsp + PEER_UCRED]
        mov     rdx, 12
        mov     rcx, 1002
        call    af_ctl_validate_peer_credentials
        AF_CHECK_ERR rax, AF_E_PERM, "a different effective UID is rejected"
        AF_CHECK_EQ qword [rsp + PEER_CONN + CONN_PEER_UID], 0, \
                    "unauthorised credentials are not recorded"

        lea     rdi, [rsp + PEER_CONN]
        lea     rsi, [rsp + PEER_UCRED]
        mov     rdx, 12
        mov     rcx, 1001
        call    af_ctl_validate_peer_credentials
        AF_CHECK_OK rax, "same-EUID credentials are accepted"
        AF_CHECK_EQ qword [rsp + PEER_CONN + CONN_PEER_PID], 4242, \
                    "accepted peer PID is recorded"
        AF_CHECK_EQ qword [rsp + PEER_CONN + CONN_PEER_UID], 1001, \
                    "accepted peer UID is recorded"
AF_TEST_END

; Environment variables are C strings, but libcurl header lines are not a safe
; place for arbitrary C-string bytes.  The validator is bounded, rejects empty
; credentials and every ASCII control byte (including CR/LF injection), and
; reports the already-validated length to the caller.
AF_TEST "m11/provider_header_secret_is_bounded_and_visible", 32
        mov     qword [rsp], -1
        lea     rdi, [value_valid]
        mov     rsi, 64
        lea     rdx, [rsp]
        call    af_prov_validate_header_value
        AF_CHECK_OK rax, "visible provider secret is valid"
        AF_CHECK_EQ qword [rsp], value_valid_len, "validated length is exact"

        mov     qword [rsp], -1
        lea     rdi, [value_bound]
        mov     rsi, 5
        lea     rdx, [rsp]
        call    af_prov_validate_header_value
        AF_CHECK_OK rax, "the bound includes the terminating NUL"
        AF_CHECK_EQ qword [rsp], 4, "boundary value length"

        mov     qword [rsp], -1
        lea     rdi, [value_bound]
        mov     rsi, 4
        lea     rdx, [rsp]
        call    af_prov_validate_header_value
        AF_CHECK_ERR rax, AF_E_LIMIT, "missing NUL inside the bound is rejected"
        AF_CHECK_EQ qword [rsp], -1, "failure does not publish a partial length"
AF_TEST_END

AF_TEST "m11/provider_header_secret_rejects_empty_and_controls", 32
        mov     qword [rsp], -1
        lea     rdi, [value_empty]
        mov     rsi, 8
        lea     rdx, [rsp]
        call    af_prov_validate_header_value
        AF_CHECK_ERR rax, AF_E_INVALID, "empty provider secret is rejected"

        lea     rdi, [value_cr]
        mov     rsi, 32
        lea     rdx, [rsp]
        call    af_prov_validate_header_value
        AF_CHECK_ERR rax, AF_E_INVALID, "CR header injection is rejected"

        lea     rdi, [value_lf]
        mov     rsi, 32
        lea     rdx, [rsp]
        call    af_prov_validate_header_value
        AF_CHECK_ERR rax, AF_E_INVALID, "LF header injection is rejected"

        lea     rdi, [value_tab]
        mov     rsi, 32
        lea     rdx, [rsp]
        call    af_prov_validate_header_value
        AF_CHECK_ERR rax, AF_E_INVALID, "other C0 controls are rejected"

        lea     rdi, [value_del]
        mov     rsi, 32
        lea     rdx, [rsp]
        call    af_prov_validate_header_value
        AF_CHECK_ERR rax, AF_E_INVALID, "DEL is rejected"
AF_TEST_END
