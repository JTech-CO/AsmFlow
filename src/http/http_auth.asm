; AsmFlow — listener authentication.
;
; docs/API_CONTRACT.md 2: the credential is optional on loopback and required
; when the listener's policy asks for one. The policy is whatever the
; configuration resolved — `none`, a bearer token in `Authorization`, or a named
; header — and the secret itself came from the environment, never from the file.
;
; Two rules are deliberate.
;
; The check applies to every endpoint, health included. An operator who has
; decided this listener needs a credential has decided it for the listener, and
; a health endpoint that answers without one is a hole in exactly the deployment
; where the policy was configured on purpose.
;
; The comparison is constant-time and the length is checked first. Comparing
; byte by byte and stopping at the first difference tells a caller how much of a
; guess was right, which over enough requests is the whole token.

        bits 64
        default rel

%include "asmflow.inc"
%include "http.inc"
%include "config.inc"

        extern af_buf_data
        extern af_buf_len
        extern af_mem_eq_ci
        extern af_mem_eq_ct

        extern af_http_fault

        section .rodata

s_bearer: db "bearer", 0
%define BEARER_LEN 6

        section .text

; ---------------------------------------------------------------------------
; af_http_check_auth(af_http_conn *c) -> af_status
;
; AF_OK when the request may proceed. Otherwise the fault is recorded on the
; connection and AF_E_HTTP_AUTH is returned, so the caller stops without having
; to decide which of the two 401s applies.
; ---------------------------------------------------------------------------
        global af_http_check_auth
af_http_check_auth:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, [rbx + HC_SERVER]
        test    r12, r12
        jz      .invalid

        cmp     qword [r12 + HS_AUTH_TYPE], AF_AUTH_NONE
        je      .allowed

        ; A policy with no resolved secret cannot authenticate anybody. The
        ; configuration loader refuses a missing environment secret before
        ; readiness, so reaching here means something is wrong with the daemon
        ; rather than with the request; refusing is still the safe answer.
        mov     r13, [r12 + HS_AUTH_SECRET]
        test    r13, r13
        jz      .missing
        mov     r14, [r12 + HS_AUTH_SECRET_LEN]
        test    r14, r14
        jz      .missing

        test    qword [rbx + HC_FLAGS], HC_F_HAVE_AUTH
        jz      .missing

        lea     rdi, [rbx + HC_AUTH]
        call    af_buf_data
        mov     r15, rax
        test    r15, r15
        jz      .missing
        lea     rdi, [rbx + HC_AUTH]
        call    af_buf_len
        mov     [rsp], rax                      ; presented length

        cmp     qword [r12 + HS_AUTH_TYPE], AF_AUTH_BEARER_ENV
        jne     .compare

        ; `Bearer <token>`: the scheme is case-insensitive (RFC 9110 11.1) and
        ; exactly one space separates it from the token. Accepting several
        ; spaces, or a tab, would mean two deployments disagree about what the
        ; token is.
        mov     rax, [rsp]
        cmp     rax, BEARER_LEN + 1
        jbe     .invalid_token
        mov     rdi, r15
        lea     rsi, [s_bearer]
        mov     rdx, BEARER_LEN
        call    af_mem_eq_ci
        test    rax, rax
        jz      .invalid_token
        cmp     byte [r15 + BEARER_LEN], ' '
        jne     .invalid_token
        add     r15, BEARER_LEN + 1
        sub     qword [rsp], BEARER_LEN + 1

.compare:
        mov     rax, [rsp]
        cmp     rax, r14
        jne     .invalid_token
        mov     rdi, r15
        mov     rsi, r13
        mov     rdx, r14
        call    af_mem_eq_ct
        test    rax, rax
        jz      .invalid_token

.allowed:
        AF_LEAVE_OK

.missing:
        mov     rdi, rbx
        mov     rsi, AF_HERR_MISSING_TOKEN
        call    af_http_fault
        AF_LEAVE_ERR AF_E_HTTP_AUTH
.invalid_token:
        mov     rdi, rbx
        mov     rsi, AF_HERR_INVALID_TOKEN
        call    af_http_fault
        AF_LEAVE_ERR AF_E_HTTP_AUTH
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
