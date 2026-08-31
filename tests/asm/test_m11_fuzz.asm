; AsmFlow — deterministic M11 parser/framer fuzz entry points.
;
; tests/test_fuzz_smoke.py starts this test binary once per mutated input and
; passes the exact bytes as ASMFLOW_FUZZ_HEX.  Keeping the target wrappers in
; assembly preserves the production layouts and ownership rules here; Python
; chooses bytes and enforces process limits but decides no parser outcome.
;
; With no environment input each registered test uses its built-in seed.  The
; ordinary unit gate therefore exercises every wrapper, and the fuzz campaign
; is an extension of the same leak-checked runner rather than a second harness.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "json.inc"
%include "config.inc"
%include "http.inc"
%include "mcp.inc"
%include "test.inc"

%define AF_TEST_TAG m11_fuzz

%define M11_FUZZ_MAX       8192
%define M11_FUZZ_LINE_MAX  (M11_FUZZ_MAX + 1)
%define M11_BUFFER_SIZE    32

        extern getenv

        extern af_alloc
        extern af_free
        extern af_mem_copy
        extern af_mem_zero
        extern af_mem_eq_ci
        extern af_cstr_len

        extern af_buf_init
        extern af_buf_free
        extern af_buf_append
        extern af_buf_append_byte
        extern af_buf_data
        extern af_buf_len

        extern af_json_scan_depth
        extern af_json_parse
        extern af_json_doc_free

        extern af_cfg_err_init
        extern af_cfg_err_free
        extern af_config_parse
        extern af_config_release
        extern af_cfg_url_check

        extern af_http_conn_init_buffers
        extern af_http_conn_release
        extern af_http_conn_feed
        extern af_llhttp_request_init

        extern af_prov_sse_scan

        extern af_mcp_frame_lines
        extern af_mcp_calls_release

        extern af_ctl_frame_next
        extern af_ctl_frame_consume

        ; M11 structured redaction boundary.  A missing implementation is a
        ; link failure, never a skipped fuzz target.
        extern af_redact_header_value

        section .rodata

fuzz_env: db "ASMFLOW_FUZZ_HEX", 0

seed_json: db `{"items":[1,true,null,"text"]}`
seed_json_len equ $ - seed_json
seed_config: db `{}`
seed_config_len equ $ - seed_config
seed_http: db "GET /healthz HTTP/1.1", 13, 10
           db "Host: localhost", 13, 10, 13, 10
seed_http_len equ $ - seed_http
seed_url: db "https://example.invalid/v1"
seed_url_len equ $ - seed_url
seed_sse: db "data: one", 10, 10
seed_sse_len equ $ - seed_sse
seed_mcp: db `{"jsonrpc":"2.0","method":"ping"}`
seed_mcp_len equ $ - seed_mcp
seed_control: db `{"id":1,"method":"system.version"}`
seed_control_len equ $ - seed_control
seed_redaction: db "authorization", 0, "Bearer top-secret"
seed_redaction_len equ $ - seed_redaction

h_authorization:       db "authorization"
h_authorization_len    equ $ - h_authorization
h_proxy_authorization: db "proxy-authorization"
h_proxy_authorization_len equ $ - h_proxy_authorization
h_cookie:              db "cookie"
h_cookie_len           equ $ - h_cookie
h_set_cookie:          db "set-cookie"
h_set_cookie_len       equ $ - h_set_cookie
h_custom:              db "x-asmflow-secret", 0
h_custom_len           equ $ - h_custom - 1
redacted:               db "[REDACTED]"
redacted_len            equ $ - redacted

        section .text

; ---------------------------------------------------------------------------
; af_m11_hex_nibble(u8 byte) -> i64 (0..15, or -1)
; ---------------------------------------------------------------------------
af_m11_hex_nibble:
        movzx   eax, dil
        cmp     al, '0'
        jb      .invalid
        cmp     al, '9'
        jbe     .digit
        cmp     al, 'a'
        jb      .upper
        cmp     al, 'f'
        ja      .invalid
        sub     eax, 'a' - 10
        ret
.upper:
        cmp     al, 'A'
        jb      .invalid
        cmp     al, 'F'
        ja      .invalid
        sub     eax, 'A' - 10
        ret
.digit:
        sub     eax, '0'
        ret
.invalid:
        mov     rax, -1
        ret

; ---------------------------------------------------------------------------
; af_m11_fuzz_input(default, default_len, out_owned, out_len) -> af_status
;
; The returned block is always owned, including for the built-in default, so
; every target has one unambiguous cleanup path and the runner can detect it if
; that path is missed.
; ---------------------------------------------------------------------------
af_m11_fuzz_input:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     qword [r13], 0
        mov     qword [r14], 0

        lea     rdi, [fuzz_env]
        call    getenv wrt ..plt
        test    rax, rax
        jz      .copy_default
        mov     r15, rax
        mov     rdi, r15
        call    af_cstr_len
        test    rax, 1
        jnz     .invalid
        shr     rax, 1
        cmp     rax, M11_FUZZ_MAX
        ja      .limit
        mov     [rsp], rax                      ; decoded byte count
        mov     rdi, rax
        test    rdi, rdi
        jnz     .allocate_hex
        mov     edi, 1
.allocate_hex:
        call    af_alloc
        test    rax, rax
        jz      .nomem
        mov     [rsp + 8], rax                  ; owned output
        mov     qword [rsp + 16], 0             ; cursor
.decode:
        mov     rcx, [rsp + 16]
        cmp     rcx, [rsp]
        jae     .success
        movzx   edi, byte [r15 + rcx * 2]
        call    af_m11_hex_nibble
        test    rax, rax
        js      .invalid_allocated
        shl     rax, 4
        mov     [rsp + 24], rax
        mov     rcx, [rsp + 16]
        movzx   edi, byte [r15 + rcx * 2 + 1]
        call    af_m11_hex_nibble
        test    rax, rax
        js      .invalid_allocated
        or      rax, [rsp + 24]
        mov     rcx, [rsp + 16]
        mov     rdx, [rsp + 8]
        mov     [rdx + rcx], al
        inc     qword [rsp + 16]
        jmp     .decode

.copy_default:
        cmp     r12, M11_FUZZ_MAX
        ja      .limit
        test    r12, r12
        jz      .allocate_default
        test    rbx, rbx
        jz      .invalid
.allocate_default:
        mov     [rsp], r12
        mov     rdi, r12
        test    rdi, rdi
        jnz     .default_size_ready
        mov     edi, 1
.default_size_ready:
        call    af_alloc
        test    rax, rax
        jz      .nomem
        mov     [rsp + 8], rax
        test    r12, r12
        jz      .success
        mov     rdi, rax
        mov     rsi, rbx
        mov     rdx, r12
        call    af_mem_copy

.success:
        mov     rax, [rsp + 8]
        mov     [r13], rax
        mov     rax, [rsp]
        mov     [r14], rax
        AF_LEAVE_OK
.invalid_allocated:
        mov     rdi, [rsp + 8]
        call    af_free
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM

; ---------------------------------------------------------------------------
; af_m11_default_sensitive(name, len) -> i64
; Test oracle for the four mandatory headers plus this fixture's configured
; header. The production decision remains af_redact_header_value's.
; ---------------------------------------------------------------------------
af_m11_default_sensitive:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        cmp     r12, h_authorization_len
        jne     .proxy
        mov     rdi, rbx
        lea     rsi, [h_authorization]
        mov     rdx, r12
        call    af_mem_eq_ci
        test    rax, rax
        jnz     .yes
.proxy:
        cmp     r12, h_proxy_authorization_len
        jne     .cookie
        mov     rdi, rbx
        lea     rsi, [h_proxy_authorization]
        mov     rdx, r12
        call    af_mem_eq_ci
        test    rax, rax
        jnz     .yes
.cookie:
        cmp     r12, h_cookie_len
        jne     .set_cookie
        mov     rdi, rbx
        lea     rsi, [h_cookie]
        mov     rdx, r12
        call    af_mem_eq_ci
        test    rax, rax
        jnz     .yes
.set_cookie:
        cmp     r12, h_set_cookie_len
        jne     .custom
        mov     rdi, rbx
        lea     rsi, [h_set_cookie]
        mov     rdx, r12
        call    af_mem_eq_ci
        test    rax, rax
        jnz     .yes
.custom:
        cmp     r12, h_custom_len
        jne     .no
        mov     rdi, rbx
        lea     rsi, [h_custom]
        mov     rdx, r12
        call    af_mem_eq_ci
        test    rax, rax
        jnz     .yes
.no:
        xor     eax, eax
        AF_LEAVE
.yes:
        mov     eax, 1
        AF_LEAVE

; ---------------------------------------------------------------------------
; JSON: pre-allocation depth scan and full bounded parse/finalize.
; ---------------------------------------------------------------------------
        AF_TEST "m11/fuzz/json/input", 96
        lea     rdi, [seed_json]
        mov     rsi, seed_json_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_m11_fuzz_input
        mov     r13, rax
        AF_CHECK_OK r13, "fuzz input decoding"
        test    r13, r13
        js      .done
        mov     rbx, [rsp]
        mov     r12, [rsp + 8]

        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, 64
        call    af_json_scan_depth
        mov     r13, rax
        xor     r14d, r14d
        test    r13, r13
        setle   r14b
        AF_CHECK_TRUE r14, "depth scan returns success or an error status"

        mov     qword [rsp + 16 + AF_JSONLIM_MAX_BYTES], M11_FUZZ_MAX
        mov     qword [rsp + 16 + AF_JSONLIM_MAX_DEPTH], 64
        mov     qword [rsp + 16 + AF_JSONLIM_MAX_STRING], 4096
        mov     qword [rsp + 16 + AF_JSONLIM_MAX_ELEMS], 1024
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 16]
        lea     rcx, [rsp + 48]
        call    af_json_parse
        mov     r13, rax
        xor     r14d, r14d
        test    r13, r13
        setle   r14b
        AF_CHECK_TRUE r14, "JSON parser returns success or an error status"
        test    r13, r13
        jnz     .release_input
        lea     rdi, [rsp + 48]
        call    af_json_doc_free
.release_input:
        mov     rdi, rbx
        call    af_free
.done:
        AF_TEST_END

; ---------------------------------------------------------------------------
; Configuration: transactional candidate ownership and cfg_error finalizer.
; ---------------------------------------------------------------------------
        AF_TEST "m11/fuzz/config/input", 112
        lea     rdi, [seed_config]
        mov     rsi, seed_config_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_m11_fuzz_input
        mov     r13, rax
        AF_CHECK_OK r13, "fuzz input decoding"
        test    r13, r13
        js      .done
        mov     rbx, [rsp]
        mov     r12, [rsp + 8]
        mov     qword [rsp + 16 + CFGERR_SIZE], 0

        lea     rdi, [rsp + 16]
        call    af_cfg_err_init
        mov     r13, rax
        AF_CHECK_OK r13, "configuration error context init"
        test    r13, r13
        js      .free_error
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 16]
        lea     rcx, [rsp + 16 + CFGERR_SIZE]
        call    af_config_parse
        mov     r13, rax
        xor     r14d, r14d
        test    r13, r13
        setle   r14b
        AF_CHECK_TRUE r14, "configuration parser returns success or an error status"
        test    r13, r13
        jnz     .free_error
        mov     rdi, [rsp + 16 + CFGERR_SIZE]
        call    af_config_release
.free_error:
        lea     rdi, [rsp + 16]
        call    af_cfg_err_free
        mov     rdi, rbx
        call    af_free
.done:
        AF_TEST_END

; ---------------------------------------------------------------------------
; HTTP: the real bounded connection inbox, llhttp request envelope, AsmFlow
; callbacks, framing policy, endpoint dispatch, and response builder.  The
; standalone server carries only the production limits this connection reads;
; no socket or loop is involved and cleanup uses the production finalizer.
; ---------------------------------------------------------------------------
%define HF_SERVER     0
%define HF_CONN       HS_CONNS
%define HF_INPUT_PTR  (HS_CONNS + HC_SIZE)
%define HF_INPUT_LEN  (HS_CONNS + HC_SIZE + 8)
        AF_TEST "m11/fuzz/http/input", (HS_CONNS + HC_SIZE + 32)
        lea     rdi, [rsp + HF_SERVER]
        mov     rsi, HS_CONNS
        call    af_mem_zero
        lea     rdi, [rsp + HF_CONN]
        mov     rsi, HC_SIZE
        call    af_mem_zero
        mov     qword [rsp + HF_SERVER + HS_HEADER_MAX], M11_FUZZ_MAX
        mov     qword [rsp + HF_SERVER + HS_BODY_MAX], M11_FUZZ_MAX
        mov     qword [rsp + HF_CONN + HC_FD], -1
        lea     rax, [rsp + HF_SERVER]
        mov     [rsp + HF_CONN + HC_SERVER], rax

        lea     rdi, [rsp + HF_CONN]
        call    af_http_conn_init_buffers
        mov     r13, rax
        AF_CHECK_OK r13, "HTTP connection buffers init"
        test    r13, r13
        js      .release_conn
        lea     rdi, [rsp + HF_CONN + HC_PARSER]
        lea     rsi, [rsp + HF_CONN]
        call    af_llhttp_request_init

        lea     rdi, [seed_http]
        mov     rsi, seed_http_len
        lea     rdx, [rsp + HF_INPUT_PTR]
        lea     rcx, [rsp + HF_INPUT_LEN]
        call    af_m11_fuzz_input
        mov     r13, rax
        AF_CHECK_OK r13, "fuzz input decoding"
        test    r13, r13
        js      .release_conn
        mov     rbx, [rsp + HF_INPUT_PTR]
        mov     r12, [rsp + HF_INPUT_LEN]

        lea     rdi, [rsp + HF_CONN + HC_INBOX]
        mov     rsi, rbx
        mov     rdx, r12
        call    af_buf_append
        mov     r13, rax
        AF_CHECK_OK r13, "HTTP fuzz bytes fit the bounded inbox"
        test    r13, r13
        js      .release_input

        lea     rdi, [rsp + HF_CONN]
        call    af_http_conn_feed
        mov     r13, rax
        xor     r14d, r14d
        test    r13, r13
        setle   r14b
        AF_CHECK_TRUE r14, "HTTP envelope returns success or an error status"
        lea     rdi, [rsp + HF_CONN + HC_INBOX]
        call    af_buf_len
        mov     r13, rax
        xor     r14d, r14d
        cmp     r13, M11_FUZZ_MAX
        setbe   r14b
        AF_CHECK_TRUE r14, "HTTP retained bytes remain bounded"
.release_input:
        mov     rdi, rbx
        call    af_free
.release_conn:
        lea     rdi, [rsp + HF_CONN]
        call    af_http_conn_release
        AF_TEST_END
%undef HF_SERVER
%undef HF_CONN
%undef HF_INPUT_PTR
%undef HF_INPUT_LEN

; ---------------------------------------------------------------------------
; URL: both strict default and private-address opt-in classifiers.
; ---------------------------------------------------------------------------
        AF_TEST "m11/fuzz/url/input", 48
        lea     rdi, [seed_url]
        mov     rsi, seed_url_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_m11_fuzz_input
        mov     r13, rax
        AF_CHECK_OK r13, "fuzz input decoding"
        test    r13, r13
        js      .done
        mov     rbx, [rsp]
        mov     r12, [rsp + 8]

        mov     qword [rsp + 16], 0
        mov     rdi, rbx
        mov     rsi, r12
        xor     edx, edx
        lea     rcx, [rsp + 16]
        call    af_cfg_url_check
        mov     r13, rax
        xor     r14d, r14d
        test    r13, r13
        setle   r14b
        AF_CHECK_TRUE r14, "strict URL classifier returns a status"

        mov     qword [rsp + 24], 0
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, 1
        lea     rcx, [rsp + 24]
        call    af_cfg_url_check
        mov     r13, rax
        xor     r14d, r14d
        test    r13, r13
        setle   r14b
        AF_CHECK_TRUE r14, "private-opt-in URL classifier returns a status"
        mov     rdi, rbx
        call    af_free
.done:
        AF_TEST_END

; ---------------------------------------------------------------------------
; SSE: the pure byte framer on whole and fragmented prefixes.
; ---------------------------------------------------------------------------
        AF_TEST "m11/fuzz/sse/input", 32
        lea     rdi, [seed_sse]
        mov     rsi, seed_sse_len
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_m11_fuzz_input
        mov     r13, rax
        AF_CHECK_OK r13, "fuzz input decoding"
        test    r13, r13
        js      .done
        mov     rbx, [rsp]
        mov     r12, [rsp + 8]

        mov     rdi, rbx
        mov     rsi, r12
        call    af_prov_sse_scan
        mov     r13, rax
        xor     r14d, r14d
        cmp     r13, r12
        setbe   r14b
        AF_CHECK_TRUE r14, "SSE frame length never exceeds supplied bytes"

        mov     r15, r12
        shr     r15, 1
        mov     rdi, rbx
        mov     rsi, r15
        call    af_prov_sse_scan
        mov     r13, rax
        xor     r14d, r14d
        cmp     r13, r15
        setbe   r14b
        AF_CHECK_TRUE r14, "fragment SSE frame length stays within its prefix"
        mov     rdi, rbx
        call    af_free
.done:
        AF_TEST_END

; ---------------------------------------------------------------------------
; MCP: stdout NDJSON framing followed by the real JSON-RPC message layer.
; ---------------------------------------------------------------------------
%define MF_INPUT_PTR MC_SIZE
%define MF_INPUT_LEN (MC_SIZE + 8)
        AF_TEST "m11/fuzz/mcp/input", (MC_SIZE + 32)
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        lea     rdi, [seed_mcp]
        mov     rsi, seed_mcp_len
        lea     rdx, [rsp + MF_INPUT_PTR]
        lea     rcx, [rsp + MF_INPUT_LEN]
        call    af_m11_fuzz_input
        mov     r13, rax
        AF_CHECK_OK r13, "fuzz input decoding"
        test    r13, r13
        js      .done
        mov     rbx, [rsp + MF_INPUT_PTR]
        mov     r12, [rsp + MF_INPUT_LEN]

        lea     rdi, [rsp + MC_INBOX]
        mov     rsi, M11_FUZZ_LINE_MAX
        call    af_buf_init
        mov     r13, rax
        AF_CHECK_OK r13, "MCP inbox init"
        test    r13, r13
        js      .release_input
        mov     qword [rsp + MC_FRAME_MAX], M11_FUZZ_MAX
        lea     rdi, [rsp + MC_INBOX]
        mov     rsi, rbx
        mov     rdx, r12
        call    af_buf_append
        mov     r13, rax
        AF_CHECK_OK r13, "MCP fuzz bytes fit the bounded inbox"
        test    r13, r13
        js      .release_mcp
        lea     rdi, [rsp + MC_INBOX]
        mov     rsi, 10
        call    af_buf_append_byte
        mov     r13, rax
        AF_CHECK_OK r13, "MCP terminator fits the bounded inbox"
        test    r13, r13
        js      .release_mcp

        lea     rdi, [rsp]
        call    af_mcp_frame_lines
        mov     r13, rax
        xor     r14d, r14d
        test    r13, r13
        setle   r14b
        AF_CHECK_TRUE r14, "MCP framer/message layer returns a status"
        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_len
        mov     r13, rax
        xor     r14d, r14d
        cmp     r13, M11_FUZZ_LINE_MAX
        setbe   r14b
        AF_CHECK_TRUE r14, "MCP retained bytes remain bounded"
.release_mcp:
        lea     rdi, [rsp]
        call    af_mcp_calls_release
        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_free
.release_input:
        mov     rdi, rbx
        call    af_free
.done:
        AF_TEST_END
%undef MF_INPUT_PTR
%undef MF_INPUT_LEN

; ---------------------------------------------------------------------------
; Control: accumulated-byte ceiling, UTF-8 check, CRLF and consume semantics.
; ---------------------------------------------------------------------------
%define CF_INBOX       0
%define CF_INPUT_PTR   M11_BUFFER_SIZE
%define CF_INPUT_LEN   (M11_BUFFER_SIZE + 8)
%define CF_FRAME_PTR   (M11_BUFFER_SIZE + 16)
%define CF_FRAME_LEN   (M11_BUFFER_SIZE + 24)
        AF_TEST "m11/fuzz/control/input", 96
        lea     rdi, [seed_control]
        mov     rsi, seed_control_len
        lea     rdx, [rsp + CF_INPUT_PTR]
        lea     rcx, [rsp + CF_INPUT_LEN]
        call    af_m11_fuzz_input
        mov     r13, rax
        AF_CHECK_OK r13, "fuzz input decoding"
        test    r13, r13
        js      .done
        mov     rbx, [rsp + CF_INPUT_PTR]
        mov     r12, [rsp + CF_INPUT_LEN]
        lea     rdi, [rsp + CF_INBOX]
        mov     rsi, M11_FUZZ_LINE_MAX
        call    af_buf_init
        mov     r13, rax
        AF_CHECK_OK r13, "control inbox init"
        test    r13, r13
        js      .release_input
        lea     rdi, [rsp + CF_INBOX]
        mov     rsi, rbx
        mov     rdx, r12
        call    af_buf_append
        mov     r13, rax
        AF_CHECK_OK r13, "control fuzz bytes fit the bounded inbox"
        test    r13, r13
        js      .release_control
        lea     rdi, [rsp + CF_INBOX]
        mov     rsi, 10
        call    af_buf_append_byte
        mov     r13, rax
        AF_CHECK_OK r13, "control terminator fits the bounded inbox"
        test    r13, r13
        js      .release_control

        lea     rdi, [rsp + CF_INBOX]
        mov     rsi, M11_FUZZ_LINE_MAX
        lea     rdx, [rsp + CF_FRAME_PTR]
        lea     rcx, [rsp + CF_FRAME_LEN]
        call    af_ctl_frame_next
        mov     r13, rax
        xor     r14d, r14d
        test    r13, r13
        setle   r14b
        AF_CHECK_TRUE r14, "control framer returns success or an error status"
        test    r13, r13
        jnz     .release_control
        mov     r15, [rsp + CF_FRAME_LEN]
        xor     r14d, r14d
        cmp     r15, r12
        setbe   r14b
        AF_CHECK_TRUE r14, "borrowed control frame stays within supplied bytes"
        lea     rdi, [rsp + CF_INBOX]
        mov     rsi, r15
        call    af_ctl_frame_consume
        mov     r13, rax
        AF_CHECK_OK r13, "accepted control frame is consumable"
.release_control:
        lea     rdi, [rsp + CF_INBOX]
        call    af_buf_free
.release_input:
        mov     rdi, rbx
        call    af_free
.done:
        AF_TEST_END
%undef CF_INBOX
%undef CF_INPUT_PTR
%undef CF_INPUT_LEN
%undef CF_FRAME_PTR
%undef CF_FRAME_LEN

; ---------------------------------------------------------------------------
; Redaction: mandatory headers, configured registry, binary-safe passthrough,
; exact replacement bytes, and bounded caller-owned output.
; ---------------------------------------------------------------------------
%define RD_CFG          0
%define RD_OUT          CFG_SIZE
%define RD_INPUT_PTR    (CFG_SIZE + M11_BUFFER_SIZE)
%define RD_INPUT_LEN    (CFG_SIZE + M11_BUFFER_SIZE + 8)
%define RD_REGISTRY     (CFG_SIZE + M11_BUFFER_SIZE + 16)
%define RD_NAME_LEN     (CFG_SIZE + M11_BUFFER_SIZE + 24)
%define RD_VALUE_PTR    (CFG_SIZE + M11_BUFFER_SIZE + 32)
%define RD_VALUE_LEN    (CFG_SIZE + M11_BUFFER_SIZE + 40)
        AF_TEST "m11/fuzz/redaction/input", (CFG_SIZE + 96)
        lea     rdi, [rsp + RD_CFG]
        mov     rsi, CFG_SIZE
        call    af_mem_zero
        lea     rax, [h_custom]
        mov     [rsp + RD_REGISTRY], rax
        lea     rax, [rsp + RD_REGISTRY]
        mov     [rsp + RD_CFG + CFG_LOG_REDACT], rax
        mov     qword [rsp + RD_CFG + CFG_LOG_REDACT_COUNT], 1

        lea     rdi, [rsp + RD_OUT]
        mov     rsi, M11_FUZZ_MAX + redacted_len
        call    af_buf_init
        mov     r13, rax
        AF_CHECK_OK r13, "redaction output init"
        test    r13, r13
        js      .done
        lea     rdi, [seed_redaction]
        mov     rsi, seed_redaction_len
        lea     rdx, [rsp + RD_INPUT_PTR]
        lea     rcx, [rsp + RD_INPUT_LEN]
        call    af_m11_fuzz_input
        mov     r13, rax
        AF_CHECK_OK r13, "fuzz input decoding"
        test    r13, r13
        js      .release_output
        mov     rbx, [rsp + RD_INPUT_PTR]
        mov     r12, [rsp + RD_INPUT_LEN]

        xor     r14, r14
.find_separator:
        cmp     r14, r12
        jae     .no_separator
        cmp     byte [rbx + r14], 0
        je      .separator
        inc     r14
        jmp     .find_separator
.separator:
        mov     [rsp + RD_NAME_LEN], r14
        lea     rax, [rbx + r14 + 1]
        mov     [rsp + RD_VALUE_PTR], rax
        mov     rax, r12
        sub     rax, r14
        dec     rax
        mov     [rsp + RD_VALUE_LEN], rax
        jmp     .redact
.no_separator:
        mov     [rsp + RD_NAME_LEN], r12
        lea     rax, [rbx + r12]
        mov     [rsp + RD_VALUE_PTR], rax
        mov     qword [rsp + RD_VALUE_LEN], 0
.redact:
        lea     rdi, [rsp + RD_CFG]
        mov     rsi, rbx
        mov     rdx, [rsp + RD_NAME_LEN]
        mov     rcx, [rsp + RD_VALUE_PTR]
        mov     r8, [rsp + RD_VALUE_LEN]
        lea     r9, [rsp + RD_OUT]
        call    af_redact_header_value
        mov     r13, rax
        AF_CHECK_OK r13, "redaction accepts bounded header/value bytes"
        test    r13, r13
        jnz     .release_input

        lea     rdi, [rsp + RD_OUT]
        call    af_buf_len
        mov     r15, rax
        xor     r13d, r13d
        cmp     r15, M11_FUZZ_MAX + redacted_len
        setbe   r13b
        AF_CHECK_TRUE r13, "redaction output remains under its caller ceiling"

        mov     rdi, rbx
        mov     rsi, [rsp + RD_NAME_LEN]
        call    af_m11_default_sensitive
        test    rax, rax
        jz      .passthrough
        AF_CHECK_EQ r15, redacted_len, "sensitive header has exact replacement length"
        lea     rdi, [rsp + RD_OUT]
        call    af_buf_data
        mov     r13, rax
        lea     r14, [redacted]
        AF_CHECK_MEM_EQ r13, r14, redacted_len, "sensitive value is exactly [REDACTED]"
        jmp     .release_input
.passthrough:
        AF_CHECK_EQ r15, qword [rsp + RD_VALUE_LEN], "ordinary header preserves value length"
        lea     rdi, [rsp + RD_OUT]
        call    af_buf_data
        mov     r13, rax
        mov     r14, [rsp + RD_VALUE_PTR]
        mov     r15, [rsp + RD_VALUE_LEN]
        AF_CHECK_MEM_EQ r13, r14, r15, "ordinary header preserves binary value bytes"
.release_input:
        mov     rdi, rbx
        call    af_free
.release_output:
        lea     rdi, [rsp + RD_OUT]
        call    af_buf_free
.done:
        AF_TEST_END
%undef RD_CFG
%undef RD_OUT
%undef RD_INPUT_PTR
%undef RD_INPUT_LEN
%undef RD_REGISTRY
%undef RD_NAME_LEN
%undef RD_VALUE_PTR
%undef RD_VALUE_LEN
