; AsmFlow — isolated MCP 2025-11-25 Streamable-HTTP headers.
;
; Session ID, GET stream and Last-Event-ID exist only in the LH_* allocation
; described by include/mcp_http.inc. Modern code neither imports these helpers
; nor has storage at the corresponding offsets.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "config.inc"
%include "mcp.inc"
%include "mcp_http.inc"

        extern af_buf_data
        extern af_buf_len
        extern af_mcp_http_slist_add_static
        extern af_mcp_http_slist_add_pair
        extern af_mcp_http_add_auth
        extern af_mcp_http_slot_alloc
        extern af_mcp_http_slot_release
        extern af_mcp_http_prepare_common
        extern af_mcp_http_activate
        extern af_curl_set_http_get
        extern af_curl_set_headers
        extern af_mcp_cancel_legacy

        section .rodata

hl_ctype:       db "Content-Type: application/json", 0
hl_accept:      db "Accept: application/json, text/event-stream", 0
hl_accept_sse:  db "Accept: text/event-stream", 0
hl_expect:      db "Expect:", 0
hl_version:     db "MCP-Protocol-Version: "
                db AF_MCP_LEGACY_VERSION, 0
hl_session:     db "Mcp-Session-Id: ", 0
hl_last_event:  db "Last-Event-ID: ", 0

        section .text

; Add the bounded owned legacy session only after initialize completed. The
; initialize request itself deliberately has neither version nor session.
af_mcp_http_legacy_add_session:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rax, [rbx + HX_CHILD]
        test    rax, rax
        jz      .invalid
        cmp     qword [rax + MC_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_LEGACY
        jne     .invalid
        mov     r12, [rax + MC_ADAPTER]
        test    r12, r12
        jz      .invalid
        lea     rdi, [r12 + LH_SESSION]
        call    af_buf_len
        test    rax, rax
        jz      .ok
        mov     rcx, rax
        lea     rdi, [r12 + LH_SESSION]
        call    af_buf_data
        mov     rdx, rax
        mov     rdi, rbx
        lea     rsi, [hl_session]
        call    af_mcp_http_slist_add_pair
        AF_LEAVE
.ok:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_mcp_http_legacy_headers(x, is_initialize) -> af_status
        global af_mcp_http_legacy_headers
af_mcp_http_legacy_headers:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        lea     rsi, [hl_ctype]
        call    af_mcp_http_slist_add_static
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [hl_accept]
        call    af_mcp_http_slist_add_static
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [hl_expect]
        call    af_mcp_http_slist_add_static
        test    rax, rax
        js      .done
        test    r12, r12
        jnz     .auth
        mov     rdi, rbx
        lea     rsi, [hl_version]
        call    af_mcp_http_slist_add_static
        test    rax, rax
        js      .done
        mov     rdi, rbx
        call    af_mcp_http_legacy_add_session
        test    rax, rax
        js      .done
.auth:
        mov     rdi, rbx
        call    af_mcp_http_add_auth
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_mcp_http_legacy_get_headers(x) -> af_status
        global af_mcp_http_legacy_get_headers
af_mcp_http_legacy_get_headers:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, rbx
        lea     rsi, [hl_accept_sse]
        call    af_mcp_http_slist_add_static
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [hl_version]
        call    af_mcp_http_slist_add_static
        test    rax, rax
        js      .done
        mov     rdi, rbx
        call    af_mcp_http_legacy_add_session
        test    rax, rax
        js      .done

        mov     rax, [rbx + HX_CHILD]
        mov     r12, [rax + MC_ADAPTER]
        lea     rdi, [r12 + LH_LAST_EVENT]
        call    af_buf_len
        test    rax, rax
        jz      .auth
        mov     rcx, rax
        lea     rdi, [r12 + LH_LAST_EVENT]
        call    af_buf_data
        mov     rdx, rax
        mov     rdi, rbx
        lea     rsi, [hl_last_event]
        call    af_mcp_http_slist_add_pair
        test    rax, rax
        js      .done
.auth:
        mov     rdi, rbx
        call    af_mcp_http_add_auth
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_http_legacy_start_get(child) -> af_status
;
; The advisory GET exists only in this legacy translation unit. It borrows
; the common slot/security setup, then explicitly selects HTTP GET and the
; session/Last-Event-ID header set before publishing the transfer.
; ---------------------------------------------------------------------------
        global af_mcp_http_legacy_start_get
af_mcp_http_legacy_start_get:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + MC_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_LEGACY
        jne     .invalid
        cmp     qword [rbx + MC_HTTP_GET], 0
        jne     .ok
        mov     rax, [rbx + MC_SUP]
        test    rax, rax
        jz      .invalid
        lea     rdi, [rax + MS_HTTP]
        call    af_mcp_http_slot_alloc
        test    rax, rax
        jz      .limit
        mov     r12, rax
        mov     qword [r12 + HX_METHOD], AF_MCP_HTTP_METHOD_GET
        mov     rdi, r12
        mov     rsi, rbx
        xor     edx, edx
        xor     ecx, ecx
        call    af_mcp_http_prepare_common
        test    rax, rax
        js      .release
        mov     rdi, r12
        call    af_mcp_http_legacy_get_headers
        test    rax, rax
        js      .release
        mov     rdi, [r12 + HX_EASY]
        call    af_curl_set_http_get
        test    eax, eax
        jnz     .curl
        mov     rdi, [r12 + HX_EASY]
        mov     rsi, [r12 + HX_SLIST]
        call    af_curl_set_headers
        test    eax, eax
        jnz     .curl
        mov     rdi, r12
        mov     rsi, rbx
        call    af_mcp_http_activate
        test    rax, rax
        js      .release
        mov     rax, [rbx + MC_ADAPTER]
        or      qword [rax + LH_FLAGS], AF_MCP_LH_F_GET_STARTED
.ok:
        AF_LEAVE_OK
.curl:
        mov     rax, AF_E_MCP_PROTOCOL
.release:
        mov     [rsp], rax
        mov     rdi, r12
        call    af_mcp_http_slot_release
        mov     rax, [rsp]
        AF_LEAVE
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_mcp_http_legacy_cancel_notification(child, call) -> af_status
; Encoding is shared JSON-RPC, while selecting this notification is an
; explicit legacy-adapter decision.
        global af_mcp_http_legacy_cancel_notification
af_mcp_http_legacy_cancel_notification:
        AF_ENTER 0
        call    af_mcp_cancel_legacy
        AF_LEAVE
