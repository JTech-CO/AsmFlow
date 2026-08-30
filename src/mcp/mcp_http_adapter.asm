; AsmFlow — MCP Streamable HTTP lifecycle and response policy.
;
; The curl reactor in mcp_http_engine.asm owns descriptors and byte buffers.
; This module owns the transport-neutral MCP policy at the other side of that
; boundary: one POST per child, adapter generation, bounded configuration
; snapshots, response classification, cache identity, cancellation, and the
; serial HTTP inventory sequence.  Modern and legacy wire construction remain
; physically separate in mcp_http_modern.asm and mcp_http_legacy.asm.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "config.inc"
%include "runtime.inc"
%include "mcp.inc"
%include "mcp_http.inc"

        extern af_alloc
        extern af_free
        extern af_mem_zero
        extern af_mem_eq
        extern af_cstr_len
        extern af_cstr_eq
        extern af_config_hash_bytes

        extern af_buf_init
        extern af_buf_free_secure
        extern af_buf_clear
        extern af_buf_data
        extern af_buf_len
        extern af_buf_append
        extern af_buf_append_byte

        extern af_config_retain

        extern af_curl_error_ordinals
        extern af_curl_set_url
        extern af_curl_set_protocols
        extern af_curl_set_follow_location
        extern af_curl_disable_proxy
        extern af_curl_set_tls_verify
        extern af_curl_set_nosignal
        extern af_curl_set_post
        extern af_curl_set_headers
        extern af_curl_set_connect_timeout_ms
        extern af_curl_set_timeout_ms
        extern af_curl_set_low_speed
        extern af_curl_set_accept_encoding
        extern af_curl_multi_add

        extern af_mcp_http_slot_alloc
        extern af_mcp_http_slot_release
        extern af_mcp_http_transfer_cancel
        extern af_mcp_http_modern_headers
        extern af_mcp_http_legacy_headers
        extern af_mcp_http_legacy_start_get
        extern af_mcp_http_legacy_cancel_notification
        extern af_mcp_http_sse_consume

        extern af_mcp_send_discover
        extern af_mcp_request
        extern af_mcp_begin_inventory
        extern af_mcp_advance
        extern af_mcp_on_message
        extern af_mcp_child_failed

        section .rodata

mha_protocols: db "http,https", 0
mha_initialized: db "notifications/initialized", 0
mha_cancelled:   db "notifications/cancelled", 0
mha_tools:       db "tools/list", 0
mha_resources:   db "resources/list", 0
mha_prompts:     db "prompts/list", 0
mha_modern_version: db AF_MCP_MODERN_VERSION, 0
mha_legacy_version: db AF_MCP_LEGACY_VERSION, 0

; HTTP inventory is serial, so resources/prompts cannot borrow the private
; constant in mcp_era.asm after tools/list has completed.  This is the same
; immutable modern metadata contract, not a second negotiated representation.
mha_modern_params:
        db '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",'
        db '"io.modelcontextprotocol/clientInfo":{"name":"AsmFlow","version":"'
        db AF_VERSION_STRING
        db '"},"io.modelcontextprotocol/clientCapabilities":{}}}', 0

        section .text

; ---------------------------------------------------------------------------
; Adapter allocation.  Session and GET state exist only in the LH allocation.
; ---------------------------------------------------------------------------
af_mcp_http_adapter_free:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, [rbx + MC_ADAPTER]
        test    r12, r12
        jz      .clear
        cmp     qword [rbx + MC_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_LEGACY
        jne     .release
        lea     rdi, [r12 + LH_SESSION]
        call    af_buf_free_secure
        lea     rdi, [r12 + LH_LAST_EVENT]
        call    af_buf_free_secure
.release:
        mov     rdi, r12
        call    af_free
.clear:
        mov     qword [rbx + MC_ADAPTER], 0
        mov     qword [rbx + MC_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_UNKNOWN
.done:
        AF_LEAVE

af_mcp_http_make_modern:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, rbx
        call    af_mcp_http_adapter_free
        mov     rdi, MH_SIZE
        call    af_alloc
        test    rax, rax
        jz      .nomem
        mov     r12, rax
        mov     rdi, r12
        mov     rsi, MH_SIZE
        call    af_mem_zero
        mov     [r12 + MH_CHILD], rbx
        mov     rax, [rbx + MC_GENERATION]
        mov     [r12 + MH_GENERATION], rax
        mov     [rbx + MC_ADAPTER], r12
        mov     qword [rbx + MC_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_MODERN
        AF_LEAVE_OK
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

af_mcp_http_switch_legacy:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + MC_HTTP_POST], 0
        jne     .closed
        cmp     qword [rbx + MC_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_LEGACY
        je      .ok
        mov     rdi, rbx
        call    af_mcp_http_adapter_free
        inc     qword [rbx + MC_GENERATION]
        mov     rdi, LH_SIZE
        call    af_alloc
        test    rax, rax
        jz      .nomem
        mov     r12, rax
        mov     rdi, r12
        mov     rsi, LH_SIZE
        call    af_mem_zero
        mov     [r12 + LH_CHILD], rbx
        mov     rax, [rbx + MC_GENERATION]
        mov     [r12 + LH_GENERATION], rax
        lea     rdi, [r12 + LH_SESSION]
        mov     rsi, AF_MCP_HTTP_SESSION_MAX
        call    af_buf_init
        test    rax, rax
        js      .free
        lea     rdi, [r12 + LH_LAST_EVENT]
        mov     rsi, AF_MCP_HTTP_SESSION_MAX
        call    af_buf_init
        test    rax, rax
        js      .free
        mov     [rbx + MC_ADAPTER], r12
        mov     qword [rbx + MC_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_LEGACY
.ok:
        AF_LEAVE_OK
.free:
        mov     [rsp], rax
        lea     rdi, [r12 + LH_SESSION]
        call    af_buf_free_secure
        lea     rdi, [r12 + LH_LAST_EVENT]
        call    af_buf_free_secure
        mov     rdi, r12
        call    af_free
        mov     rax, [rsp]
        AF_LEAVE
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.closed:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; Cache identity is server-local and credential-sensitive.  Only a one-way
; fingerprint is retained; neither the credential nor its header is exposed.
; ---------------------------------------------------------------------------
        global af_mcp_http_cache_auth_update
af_mcp_http_cache_auth_update:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, [rbx + MC_CACHE_AUTH_HASH]
        mov     rdi, [rbx + MC_ID]
        test    rdi, rdi
        jz      .invalid
        call    af_cstr_len
        mov     rsi, rax
        mov     rdi, [rbx + MC_ID]
        call    af_config_hash_bytes
        rol     rax, 1
        xor     rax, r12
        mov     r14, rax
        cmp     [rbx + MC_CACHE_KEY_HASH], r14
        jne     .changed
        cmp     r13, r12
        je      .ok
.changed:
        mov     [rbx + MC_CACHE_AUTH_HASH], r12
        mov     [rbx + MC_CACHE_KEY_HASH], r14
        test    r13, r13
        jz      .ok
        ; Credential rotation invalidates only this child's committed view.
        lea     rdi, [rbx + MC_TOOLS]
        call    af_buf_clear
        lea     rdi, [rbx + MC_RESOURCES]
        call    af_buf_clear
        lea     rdi, [rbx + MC_PROMPTS]
        call    af_buf_clear
        mov     qword [rbx + MC_TOOL_COUNT], 0
        mov     qword [rbx + MC_RES_COUNT], 0
        mov     qword [rbx + MC_PROMPT_COUNT], 0
        mov     qword [rbx + MC_FETCHED_NS], 0
        mov     qword [rbx + MC_EXPIRES_NS], 0
        and     qword [rbx + MC_FLAGS], ~(AF_MC_F_LISTED | AF_MC_F_TOOLS_CURRENT | AF_MC_F_HTTP_RESOURCES_ISSUED | AF_MC_F_HTTP_PROMPTS_ISSUED)
.ok:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_http_start(child, supervisor) -> af_status
; ---------------------------------------------------------------------------
        global af_mcp_http_start
af_mcp_http_start:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .invalid
        cmp     qword [rax + MCP_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .invalid
        cmp     qword [rbx + MC_HTTP_POST], 0
        jne     .closed
        cmp     qword [rbx + MC_HTTP_GET], 0
        jne     .closed

        ; Apply validated MCP limits before the first slot allocates its owned
        ; buffers.  Every HTTP child shares these process-wide hard ceilings.
        mov     rax, [r12 + MS_RT]
        test    rax, rax
        jz      .limits_done
        mov     rax, [rax + RT_CONFIG]
        test    rax, rax
        jz      .limits_done
        mov     rcx, [rax + CFG_LIM_MCP_FRAME_MAX]
        test    rcx, rcx
        jz      .event_limit
        cmp     rcx, AF_MCP_HTTP_BODY_HARD_MAX
        jbe     .body_store
        mov     rcx, AF_MCP_HTTP_BODY_HARD_MAX
.body_store:
        mov     [r12 + MS_HTTP + HE_BODY_LIMIT], rcx
.event_limit:
        mov     rcx, [rax + CFG_LIM_SSE_EVENT_MAX]
        test    rcx, rcx
        jz      .limits_done
        cmp     rcx, AF_MCP_HTTP_EVENT_HARD_MAX
        jbe     .event_store
        mov     rcx, AF_MCP_HTTP_EVENT_HARD_MAX
.event_store:
        mov     [r12 + MS_HTTP + HE_EVENT_LIMIT], rcx
.limits_done:
        inc     qword [rbx + MC_GENERATION]
        mov     rdi, rbx
        call    af_mcp_http_make_modern
        test    rax, rax
        js      .done
        mov     qword [rbx + MC_CACHE_SCOPE], AF_MCP_CACHE_PRIVATE
        mov     qword [rbx + MC_STATE], AF_MCP_S_PROBING
        inc     qword [rbx + MC_STARTS]
        mov     rdi, rbx
        call    af_mcp_send_discover
        test    rax, rax
        jz      .request_failed
        xor     eax, eax
        AF_LEAVE
.request_failed:
        mov     rdi, rbx
        call    af_mcp_http_adapter_free
        mov     rax, AF_E_MCP_PROTOCOL
.done:
        AF_LEAVE
.closed:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_http_stop(child, cause) -> void
;
; Transfer/adapter teardown only.  The supervisor invalidates calls and
; inventories after this returns, so no completion can dereference a freed
; call.  Incrementing the generation makes every synchronous cancellation
; completion stale before it can advance the MCP state machine.
; ---------------------------------------------------------------------------
        global af_mcp_http_stop
af_mcp_http_stop:
        AF_ENTER 24
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        test    r12, r12
        jnz     .have_cause
        mov     r12, AF_E_CLOSED
.have_cause:
        inc     qword [rbx + MC_GENERATION]
        mov     r13, [rbx + MC_HTTP_POST]
        mov     qword [rbx + MC_HTTP_POST], 0
        test    r13, r13
        jz      .get
        mov     rdi, r13
        mov     rsi, r12
        call    af_mcp_http_transfer_cancel
.get:
        mov     r13, [rbx + MC_HTTP_GET]
        mov     qword [rbx + MC_HTTP_GET], 0
        test    r13, r13
        jz      .adapter
        mov     rdi, r13
        mov     rsi, r12
        call    af_mcp_http_transfer_cancel
.adapter:
        mov     rdi, rbx
        call    af_mcp_http_adapter_free
        and     qword [rbx + MC_FLAGS], ~(AF_MC_F_HTTP_RESOURCES_ISSUED | AF_MC_F_HTTP_PROMPTS_ISSUED | AF_MC_F_HTTP_NOTIFY_PENDING)
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; Common construction.  All pointers passed to curl become slot-owned or are
; retained until af_mcp_http_slot_release tears the easy handle down.
;
; af_mcp_http_prepare_common(x, child, body, body_len) -> af_status
; ---------------------------------------------------------------------------
        global af_mcp_http_prepare_common
af_mcp_http_prepare_common:
        AF_ENTER 48
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     [rsp], rdx
        mov     [rsp + 8], rcx
        mov     [rbx + HX_CHILD], r12
        mov     rax, [r12 + MC_GENERATION]
        mov     [rbx + HX_GENERATION], rax
        mov     rax, [r12 + MC_ADAPTER_KIND]
        mov     [rbx + HX_ADAPTER_KIND], rax

        mov     r13, [r12 + MC_CFG]
        test    r13, r13
        jz      .invalid
        mov     rdi, [r13 + MCP_URL]
        test    rdi, rdi
        jz      .invalid
        call    af_cstr_len
        cmp     rax, AF_MCP_HTTP_URL_MAX - 1
        ja      .limit
        mov     r14, rax
        lea     rdi, [rbx + HX_URL]
        mov     rsi, [r13 + MCP_URL]
        mov     rdx, r14
        call    af_buf_append
        test    rax, rax
        js      .done
        lea     rdi, [rbx + HX_URL]
        xor     esi, esi
        call    af_buf_append_byte
        test    rax, rax
        js      .done

        cmp     qword [rsp + 8], 0
        je      .body_done
        cmp     qword [rsp], 0
        je      .invalid
        lea     rdi, [rbx + HX_BODY]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_buf_append
        test    rax, rax
        js      .done
.body_done:
        mov     rax, [r12 + MC_SUP]
        test    rax, rax
        jz      .invalid
        mov     rax, [rax + MS_RT]
        test    rax, rax
        jz      .invalid
        mov     rdi, [rax + RT_CONFIG]
        test    rdi, rdi
        jz      .invalid
        call    af_config_retain
        test    rax, rax
        jz      .invalid
        mov     [rbx + HX_CONFIG], rax

        mov     r15, [rbx + HX_EASY]
        lea     rdi, [rbx + HX_URL]
        call    af_buf_data
        mov     rdi, r15
        mov     rsi, rax
        call    af_curl_set_url
        test    eax, eax
        jnz     .curl
        mov     rdi, r15
        lea     rsi, [mha_protocols]
        call    af_curl_set_protocols
        test    eax, eax
        jnz     .curl
        mov     rdi, r15
        xor     esi, esi
        call    af_curl_set_follow_location
        test    eax, eax
        jnz     .curl
        mov     rdi, r15
        call    af_curl_disable_proxy
        test    eax, eax
        jnz     .curl
        mov     rdi, r15
        mov     esi, 1
        mov     edx, 1
        call    af_curl_set_tls_verify
        test    eax, eax
        jnz     .curl
        mov     rdi, r15
        mov     esi, 1
        call    af_curl_set_nosignal
        test    eax, eax
        jnz     .curl
        mov     rdi, r15
        xor     esi, esi
        call    af_curl_set_accept_encoding
        test    eax, eax
        jnz     .curl

        mov     rsi, [r13 + MCP_TIMEOUTS + TMO_CONNECT_MS]
        mov     rdi, r15
        call    af_curl_set_connect_timeout_ms
        test    eax, eax
        jnz     .curl
        cmp     qword [rbx + HX_METHOD], AF_MCP_HTTP_METHOD_GET
        je      .no_total_timeout
        mov     rsi, [r13 + MCP_TIMEOUTS + TMO_REQUEST_MS]
        jmp     .set_total_timeout
.no_total_timeout:
        xor     esi, esi
.set_total_timeout:
        mov     rdi, r15
        call    af_curl_set_timeout_ms
        test    eax, eax
        jnz     .curl

        ; Convert the bounded millisecond idle limit to libcurl's whole-second
        ; low-speed interval, rounding up so policy never fires early.
        mov     rax, [r13 + MCP_TIMEOUTS + TMO_IDLE_MS]
        add     rax, 999
        jc      .overflow
        xor     edx, edx
        mov     rcx, 1000
        div     rcx
        test    rax, rax
        jnz     .idle_ready
        mov     eax, 1
.idle_ready:
        mov     rdi, r15
        mov     esi, 1
        mov     rdx, rax
        call    af_curl_set_low_speed
        test    eax, eax
        jnz     .curl
        AF_LEAVE_OK
.curl:
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL
.overflow:
        AF_LEAVE_ERR AF_E_OVERFLOW
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; Publish a fully configured easy handle to the MCP multi reactor.
        global af_mcp_http_activate
af_mcp_http_activate:
        AF_ENTER 24
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        cmp     qword [rbx + HX_METHOD], AF_MCP_HTTP_METHOD_GET
        je      .get
        cmp     qword [r12 + MC_HTTP_POST], 0
        jne     .closed
        mov     [r12 + MC_HTTP_POST], rbx
        lea     r13, [r12 + MC_HTTP_POST]
        jmp     .add
.get:
        cmp     qword [r12 + MC_HTTP_GET], 0
        jne     .closed
        mov     [r12 + MC_HTTP_GET], rbx
        lea     r13, [r12 + MC_HTTP_GET]
.add:
        mov     rax, [rbx + HX_ENGINE]
        mov     rdi, [rax + HE_MULTI]
        mov     rsi, [rbx + HX_EASY]
        call    af_curl_multi_add
        test    eax, eax
        jnz     .rollback
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_ADDED
        mov     qword [rbx + HX_STATE], AF_MCP_HTTP_X_ACTIVE
        inc     qword [r12 + MC_FRAMES_OUT]
        AF_LEAVE_OK
.rollback:
        cmp     [r13], rbx
        jne     .curl
        mov     qword [r13], 0
.curl:
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL
.closed:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_http_request(child, call, method, body, body_len) -> af_status
; ---------------------------------------------------------------------------
        global af_mcp_http_request
af_mcp_http_request:
        AF_ENTER 64
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        test    rcx, rcx
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     [rsp], rdx
        mov     [rsp + 8], rcx
        mov     [rsp + 16], r8
        cmp     qword [rbx + MC_HTTP_POST], 0
        jne     .closed

        cmp     qword [r12 + CL_KIND], AF_MCP_CALL_INITIALIZE
        jne     .adapter_ready
        cmp     qword [rbx + MC_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_MODERN
        jne     .adapter_ready
        mov     rdi, rbx
        call    af_mcp_http_switch_legacy
        test    rax, rax
        js      .done
.adapter_ready:
        mov     rax, [rbx + MC_SUP]
        test    rax, rax
        jz      .invalid
        lea     rdi, [rax + MS_HTTP]
        call    af_mcp_http_slot_alloc
        test    rax, rax
        jz      .limit
        mov     r13, rax
        mov     [r13 + HX_CALL], r12
        mov     qword [r13 + HX_METHOD], AF_MCP_HTTP_METHOD_POST
        mov     rdi, r13
        mov     rsi, rbx
        mov     rdx, [rsp + 8]
        mov     rcx, [rsp + 16]
        call    af_mcp_http_prepare_common
        test    rax, rax
        js      .release_status

        cmp     qword [rbx + MC_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_MODERN
        jne     .legacy_headers
        mov     rdi, r13
        mov     rsi, [rsp]
        call    af_mcp_http_modern_headers
        jmp     .headers_done
.legacy_headers:
        xor     esi, esi
        cmp     qword [r12 + CL_KIND], AF_MCP_CALL_INITIALIZE
        jne     .legacy_header_call
        mov     esi, 1
.legacy_header_call:
        mov     rdi, r13
        call    af_mcp_http_legacy_headers
.headers_done:
        test    rax, rax
        js      .release_status
        lea     rdi, [r13 + HX_BODY]
        call    af_buf_len
        mov     r14, rax
        lea     rdi, [r13 + HX_BODY]
        call    af_buf_data
        mov     rdi, [r13 + HX_EASY]
        mov     rsi, rax
        mov     rdx, r14
        call    af_curl_set_post
        test    eax, eax
        jnz     .curl_status
        mov     rdi, [r13 + HX_EASY]
        mov     rsi, [r13 + HX_SLIST]
        call    af_curl_set_headers
        test    eax, eax
        jnz     .curl_status
        mov     rdi, r13
        mov     rsi, rbx
        call    af_mcp_http_activate
        test    rax, rax
        js      .release_status
        AF_LEAVE_OK
.curl_status:
        mov     rax, AF_E_MCP_PROTOCOL
.release_status:
        mov     [rsp + 24], rax
        mov     rdi, r13
        call    af_mcp_http_slot_release
        mov     rax, [rsp + 24]
.done:
        AF_LEAVE
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.closed:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_http_notify(child, method, body, body_len) -> af_status
; ---------------------------------------------------------------------------
        global af_mcp_http_notify
af_mcp_http_notify:
        AF_ENTER 64
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     [rsp + 8], rdx
        mov     [rsp + 16], rcx
        cmp     qword [rbx + MC_HTTP_POST], 0
        jne     .closed
        mov     rax, [rbx + MC_SUP]
        test    rax, rax
        jz      .invalid
        lea     rdi, [rax + MS_HTTP]
        call    af_mcp_http_slot_alloc
        test    rax, rax
        jz      .limit
        mov     r13, rax
        mov     qword [r13 + HX_METHOD], AF_MCP_HTTP_METHOD_POST
        or      qword [r13 + HX_FLAGS], AF_MCP_HTTP_F_NOTIFICATION
        mov     rdi, [rsp]
        lea     rsi, [mha_initialized]
        call    af_cstr_eq
        test    rax, rax
        jz      .maybe_cancel
        or      qword [r13 + HX_FLAGS], AF_MCP_HTTP_F_INITIALIZED
        jmp     .prepare
.maybe_cancel:
        mov     rdi, [rsp]
        lea     rsi, [mha_cancelled]
        call    af_cstr_eq
        test    rax, rax
        jz      .prepare
        or      qword [r13 + HX_FLAGS], AF_MCP_HTTP_F_CANCEL_NOTICE
.prepare:
        mov     rdi, r13
        mov     rsi, rbx
        mov     rdx, [rsp + 8]
        mov     rcx, [rsp + 16]
        call    af_mcp_http_prepare_common
        test    rax, rax
        js      .release_status
        cmp     qword [rbx + MC_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_MODERN
        jne     .legacy_headers
        mov     rdi, r13
        mov     rsi, [rsp]
        call    af_mcp_http_modern_headers
        jmp     .headers_done
.legacy_headers:
        mov     rdi, r13
        xor     esi, esi
        call    af_mcp_http_legacy_headers
.headers_done:
        test    rax, rax
        js      .release_status
        lea     rdi, [r13 + HX_BODY]
        call    af_buf_len
        mov     r14, rax
        lea     rdi, [r13 + HX_BODY]
        call    af_buf_data
        mov     rdi, [r13 + HX_EASY]
        mov     rsi, rax
        mov     rdx, r14
        call    af_curl_set_post
        test    eax, eax
        jnz     .curl_status
        mov     rdi, [r13 + HX_EASY]
        mov     rsi, [r13 + HX_SLIST]
        call    af_curl_set_headers
        test    eax, eax
        jnz     .curl_status
        mov     rdi, r13
        mov     rsi, rbx
        call    af_mcp_http_activate
        test    rax, rax
        js      .release_status
        test    qword [r13 + HX_FLAGS], AF_MCP_HTTP_F_INITIALIZED
        jz      .ok
        or      qword [rbx + MC_FLAGS], AF_MC_F_HTTP_NOTIFY_PENDING
.ok:
        AF_LEAVE_OK
.curl_status:
        mov     rax, AF_E_MCP_PROTOCOL
.release_status:
        mov     [rsp + 24], rax
        mov     rdi, r13
        call    af_mcp_http_slot_release
        mov     rax, [rsp + 24]
        AF_LEAVE
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.closed:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_http_cancel_call(child, call, cause) -> af_status
; ---------------------------------------------------------------------------
        global af_mcp_http_cancel_call
af_mcp_http_cancel_call:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, [rbx + MC_HTTP_POST]
        test    r14, r14
        jz      .ok
        cmp     [r14 + HX_CALL], r12
        jne     .ok
        or      qword [r12 + CL_FLAGS], AF_MCP_CL_F_HTTP | AF_MCP_CL_F_CANCELLED
        mov     rdi, r14
        mov     rsi, r13
        call    af_mcp_http_transfer_cancel
        cmp     qword [rbx + MC_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_LEGACY
        jne     .ok
        cmp     qword [r12 + CL_KIND], AF_MCP_CALL_INITIALIZE
        je      .ok
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_http_legacy_cancel_notification
        AF_LEAVE
.ok:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; Continue the HTTP-only tools -> resources -> prompts inventory transaction.
; ---------------------------------------------------------------------------
        global af_mcp_http_advance_inventory
af_mcp_http_advance_inventory:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .done
        cmp     qword [rbx + MC_HTTP_POST], 0
        jne     .done
        test    qword [rbx + MC_FLAGS], AF_MC_F_TOOLS_CURRENT
        jz      .done
        mov     r12, 10000
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .have_timeout
        mov     rcx, [rax + MCP_TIMEOUTS + TMO_REQUEST_MS]
        test    rcx, rcx
        jz      .have_timeout
        mov     r12, rcx
.have_timeout:
        xor     r13d, r13d
        cmp     qword [rbx + MC_ERA], AF_ERA_MODERN
        jne     .params_ready
        lea     r13, [mha_modern_params]
.params_ready:
        test    qword [rbx + MC_FLAGS], AF_MC_F_HTTP_RESOURCES_ISSUED
        jnz     .prompts
        or      qword [rbx + MC_FLAGS], AF_MC_F_HTTP_RESOURCES_ISSUED
        mov     rdi, rbx
        lea     rsi, [mha_resources]
        mov     rdx, r13
        mov     rcx, AF_MCP_CALL_RESOURCES
        mov     r8, r12
        call    af_mcp_request
        test    rax, rax
        jnz     .done
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_HTTP_RESOURCES_ISSUED
        jmp     .failed
.prompts:
        test    qword [rbx + MC_FLAGS], AF_MC_F_HTTP_PROMPTS_ISSUED
        jnz     .done
        ; Wait until resources/list has been consumed and its retained call
        ; slot is free before issuing the final request.
        mov     rdi, rbx
        mov     rsi, AF_MCP_CALL_RESOURCES
        extern  af_mcp_find_call
        call    af_mcp_find_call
        test    rax, rax
        jnz     .done
        or      qword [rbx + MC_FLAGS], AF_MC_F_HTTP_PROMPTS_ISSUED
        mov     rdi, rbx
        lea     rsi, [mha_prompts]
        mov     rdx, r13
        mov     rcx, AF_MCP_CALL_PROMPTS
        mov     r8, r12
        call    af_mcp_request
        test    rax, rax
        jnz     .done
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_HTTP_PROMPTS_ISSUED
.failed:
        mov     rdi, rbx
        mov     rsi, AF_E_MCP_PROTOCOL
        call    af_mcp_child_failed
.done:
        AF_LEAVE

; Return nonzero when a CURLcode is this build's operation-timeout ordinal.
af_mcp_http_curl_is_timeout:
        AF_ENTER 128
        mov     rbx, rdi
        lea     rdi, [rsp]
        call    af_curl_error_ordinals
        xor     eax, eax
        cmp     rbx, [rsp + 32]
        sete    al
        AF_LEAVE

; Completion policy is appended below so lifecycle construction remains
; independently auditable.

; Validate an optional MCP-Protocol-Version response header against the
; physically selected adapter. Absence is interoperable; a present mismatch
; is explicit modern evidence and therefore never legacy fallback.
af_mcp_http_validate_protocol_header:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_PROTOCOL_SEEN
        jz      .ok
        lea     rdi, [rbx + HX_PROTOCOL]
        call    af_buf_len
        cmp     rax, 10
        jne     .mismatch
        lea     rdi, [rbx + HX_PROTOCOL]
        call    af_buf_data
        mov     rdi, rax
        cmp     qword [rbx + HX_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_MODERN
        jne     .legacy
        lea     rsi, [mha_modern_version]
        jmp     .compare
.legacy:
        cmp     qword [rbx + HX_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_LEGACY
        jne     .invalid
        lea     rsi, [mha_legacy_version]
.compare:
        mov     rdx, 10
        call    af_mem_eq
        test    rax, rax
        jz      .mismatch
.ok:
        AF_LEAVE_OK
.mismatch:
        AF_LEAVE_ERR AF_E_MCP_HEADER_MISMATCH
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; Commit the initialize response's owned session identifier into the isolated
; legacy allocation. Control bytes, whitespace-only values, duplicates, and
; missing identifiers are rejected before any follow-up request is possible.
af_mcp_http_commit_legacy_session:
        AF_ENTER 40
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + HX_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_LEGACY
        jne     .invalid
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_SESSION_SEEN
        jz      .protocol
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_DUP_HEADER
        jnz     .protocol
        lea     rdi, [rbx + HX_SESSION]
        call    af_buf_len
        test    rax, rax
        jz      .protocol
        cmp     rax, AF_MCP_HTTP_SESSION_MAX
        ja      .limit
        mov     r12, rax
        lea     rdi, [rbx + HX_SESSION]
        call    af_buf_data
        mov     r13, rax
        xor     r14d, r14d
.scan:
        cmp     r14, r12
        jae     .copy
        movzx   eax, byte [r13 + r14]
        cmp     al, 33
        jb      .protocol
        cmp     al, 126
        ja      .protocol
        inc     r14
        jmp     .scan
.copy:
        mov     rax, [rbx + HX_CHILD]
        test    rax, rax
        jz      .invalid
        mov     r15, [rax + MC_ADAPTER]
        test    r15, r15
        jz      .invalid
        lea     rdi, [r15 + LH_SESSION]
        call    af_buf_clear
        lea     rdi, [r15 + LH_SESSION]
        mov     rsi, r13
        mov     rdx, r12
        call    af_buf_append
        test    rax, rax
        js      .done
        or      qword [r15 + LH_FLAGS], AF_MCP_LH_F_INITIALIZED
        AF_LEAVE_OK
.protocol:
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; Mark a still-pending call done without touching a result already stored by
; af_mcp_on_message.
af_mcp_http_finish_error:
        test    rdi, rdi
        jz      .done
        cmp     qword [rdi + CL_STATE], AF_MCP_CALL_PENDING
        jne     .done
        mov     [rdi + CL_STATUS], rsi
        mov     qword [rdi + CL_STATE], AF_MCP_CALL_DONE
.done:
        ret

; Normalize a correlated JSON-RPC response and its well-known negotiation
; errors after af_mcp_on_message has stored the result/error member.
af_mcp_http_classify_correlated:
        test    rdi, rdi
        jz      .done
        or      qword [rdi + CL_FLAGS], AF_MCP_CL_F_RECOGNIZED
        cmp     qword [rdi + CL_ERROR_CODE], -32022
        jne     .header
        or      qword [rdi + CL_FLAGS], AF_MCP_CL_F_VERSION_ERROR
        mov     qword [rdi + CL_STATUS], AF_E_MCP_VERSION
        ret
.header:
        cmp     qword [rdi + CL_ERROR_CODE], -32020
        jne     .done
        or      qword [rdi + CL_FLAGS], AF_MCP_CL_F_HEADER_MISMATCH
        mov     qword [rdi + CL_STATUS], AF_E_MCP_HEADER_MISMATCH
.done:
        ret

; ---------------------------------------------------------------------------
; af_mcp_http_complete(x, CURLcode) -> void
;
; Called exactly once by the reactor. The child transfer pointer is cleared
; before slot release, and slot release precedes every state-machine advance,
; so a same-stack fallback may safely reuse the just-freed fixed slot.
; ---------------------------------------------------------------------------
        global af_mcp_http_complete
af_mcp_http_complete:
        AF_ENTER 96
; [0] child, [8] call, [16] flags, [24] failure, [32] advance,
; [40] legacy timeout cancellation, [48] initialized success
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, [rbx + HX_CHILD]
        mov     [rsp], r13
        mov     r14, [rbx + HX_CALL]
        mov     [rsp + 8], r14
        mov     rax, [rbx + HX_FLAGS]
        mov     [rsp + 16], rax
        mov     qword [rsp + 24], 0
        mov     qword [rsp + 32], 0
        mov     qword [rsp + 40], 0
        mov     qword [rsp + 48], 0

        test    r13, r13
        jz      .release
        cmp     [r13 + MC_HTTP_POST], rbx
        jne     .clear_get
        mov     qword [r13 + MC_HTTP_POST], 0
.clear_get:
        cmp     [r13 + MC_HTTP_GET], rbx
        jne     .generation
        mov     qword [r13 + MC_HTTP_GET], 0
.generation:
        mov     rax, [rbx + HX_GENERATION]
        cmp     [r13 + MC_GENERATION], rax
        jne     .release
        mov     rax, [rbx + HX_ADAPTER_KIND]
        cmp     [r13 + MC_ADAPTER_KIND], rax
        jne     .release
        inc     qword [r13 + MC_FRAMES_IN]

        test    r14, r14
        jz      .cancelled
        mov     rax, [rbx + HX_HTTP_STATUS]
        mov     [r14 + CL_HTTP_STATUS], rax
        or      qword [r14 + CL_FLAGS], AF_MCP_CL_F_HTTP
.cancelled:
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CANCELLED
        jnz     .release

        mov     rax, [rbx + HX_CAUSE]
        test    rax, rax
        jz      .curl_result
        mov     [rsp + 24], rax
        jmp     .failure
.curl_result:
        test    r12, r12
        jz      .headers
        mov     rdi, r12
        call    af_mcp_http_curl_is_timeout
        test    rax, rax
        jz      .curl_protocol
        mov     qword [rsp + 24], AF_E_MCP_TIMEOUT
        test    r14, r14
        jz      .failure
        cmp     qword [rbx + HX_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_LEGACY
        jne     .failure
        cmp     qword [r14 + CL_KIND], AF_MCP_CALL_INITIALIZE
        je      .failure
        mov     qword [rsp + 40], 1
        jmp     .failure
.curl_protocol:
        mov     qword [rsp + 24], AF_E_MCP_PROTOCOL
        jmp     .failure

.headers:
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_OVERFLOW
        jnz     .limit_failure
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_DUP_HEADER
        jnz     .protocol_failure
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_STATUS_SEEN
        jz      .protocol_failure
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_HEADERS_DONE
        jz      .protocol_failure
        mov     rax, [rbx + HX_HTTP_STATUS]
        cmp     rax, 100
        jb      .protocol_failure
        cmp     rax, 599
        ja      .protocol_failure
        cmp     rax, 300
        jb      .version
        cmp     rax, 399
        jbe     .protocol_failure
.version:
        mov     rdi, rbx
        call    af_mcp_http_validate_protocol_header
        test    rax, rax
        jns     .adapter_headers
        mov     [rsp + 24], rax
        test    r14, r14
        jz      .failure
        or      qword [r14 + CL_FLAGS], AF_MCP_CL_F_HEADER_MISMATCH
        jmp     .failure
.adapter_headers:
        cmp     qword [rbx + HX_ADAPTER_KIND], AF_MCP_HTTP_ADAPTER_MODERN
        jne     .legacy_session
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_SESSION_SEEN
        jnz     .protocol_failure
        jmp     .shape
.legacy_session:
        test    r14, r14
        jz      .shape
        cmp     qword [r14 + CL_KIND], AF_MCP_CALL_INITIALIZE
        jne     .shape
        mov     rdi, rbx
        call    af_mcp_http_commit_legacy_session
        test    rax, rax
        jns     .shape
        mov     [rsp + 24], rax
        jmp     .failure

.shape:
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_NOTIFICATION
        jnz     .notification
        cmp     qword [rbx + HX_METHOD], AF_MCP_HTTP_METHOD_GET
        je      .legacy_get
        test    r14, r14
        jz      .protocol_failure
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CONTENT_JSON
        jnz     .json
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CONTENT_SSE
        jnz     .sse

        ; Exactly one signal means "this endpoint is legacy": a bodyless,
        ; unrecognized 400 refusal to the modern discovery request.
        cmp     qword [rbx + HX_HTTP_STATUS], 400
        jne     .protocol_failure
        cmp     qword [r14 + CL_KIND], AF_MCP_CALL_DISCOVER
        jne     .protocol_failure
        cmp     qword [rbx + HX_BODY_BYTES], 0
        jne     .protocol_failure
        or      qword [r14 + CL_FLAGS], AF_MCP_CL_F_BARE_REFUSAL
        mov     qword [r14 + CL_STATUS], AF_E_MCP_ERA
        mov     qword [r14 + CL_STATE], AF_MCP_CALL_DONE
        mov     qword [rsp + 32], 1
        jmp     .release_then_actions

.notification:
        mov     rax, [rbx + HX_HTTP_STATUS]
        cmp     rax, 200
        jb      .protocol_failure
        cmp     rax, 299
        ja      .protocol_failure
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_INITIALIZED
        jz      .release_then_actions
        mov     qword [rsp + 48], 1
        jmp     .release_then_actions

.legacy_get:
        mov     rax, [rbx + HX_HTTP_STATUS]
        cmp     rax, 200
        jb      .release_then_actions
        cmp     rax, 299
        ja      .release_then_actions
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CONTENT_SSE
        jz      .release_then_actions
        mov     rdi, rbx
        call    af_mcp_http_sse_consume
        ; An advisory GET cannot complete a client call. Malformed bytes close
        ; this GET, but do not invalidate an otherwise usable POST session.
        jmp     .release_then_actions

.json:
        lea     rdi, [rbx + HX_RESPONSE]
        call    af_buf_len
        test    rax, rax
        jz      .protocol_failure
        mov     r15, rax
        lea     rdi, [rbx + HX_RESPONSE]
        call    af_buf_data
        mov     rdi, r13
        mov     rsi, rax
        mov     rdx, r15
        call    af_mcp_on_message
        test    rax, rax
        js      .protocol_failure
        cmp     qword [r14 + CL_STATE], AF_MCP_CALL_DONE
        jne     .protocol_failure
        mov     rdi, r14
        call    af_mcp_http_classify_correlated
        mov     qword [rsp + 32], 1
        jmp     .release_then_actions

.sse:
        or      qword [r14 + CL_FLAGS], AF_MCP_CL_F_SSE
        mov     rdi, rbx
        call    af_mcp_http_sse_consume
        test    rax, rax
        js      .protocol_failure
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_FINAL_SEEN
        jz      .protocol_failure
        cmp     qword [r14 + CL_STATE], AF_MCP_CALL_DONE
        jne     .protocol_failure
        or      qword [r14 + CL_FLAGS], AF_MCP_CL_F_FINAL_SEEN
        mov     rdi, r14
        call    af_mcp_http_classify_correlated
        mov     qword [rsp + 32], 1
        jmp     .release_then_actions

.limit_failure:
        mov     qword [rsp + 24], AF_E_LIMIT
        jmp     .failure
.protocol_failure:
        mov     qword [rsp + 24], AF_E_MCP_PROTOCOL
.failure:
        test    r14, r14
        jz      .notification_failure
        mov     rdi, r14
        mov     rsi, [rsp + 24]
        call    af_mcp_http_finish_error
        mov     qword [rsp + 32], 1
        jmp     .release_then_actions
.notification_failure:
        ; Failure of initialized is fatal because inventory may not overtake
        ; it. Cancellation notification failure does not erase the local
        ; timeout result or make an otherwise READY server unusable.
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_INITIALIZED
        jz      .release_then_actions
        mov     qword [rsp + 48], -1

.release_then_actions:
        mov     rdi, rbx
        call    af_mcp_http_slot_release
        mov     r13, [rsp]
        test    r13, r13
        jz      .done

        cmp     qword [rsp + 40], 0
        je      .initialized_action
        mov     rdi, r13
        mov     rsi, [rsp + 8]
        call    af_mcp_http_legacy_cancel_notification
.initialized_action:
        cmp     qword [rsp + 48], 1
        jne     .initialized_failed
        and     qword [r13 + MC_FLAGS], ~AF_MC_F_HTTP_NOTIFY_PENDING
        mov     rdi, r13
        call    af_mcp_http_legacy_start_get
        test    rax, rax
        js      .child_failed_status
        mov     rdi, r13
        call    af_mcp_begin_inventory
        test    rax, rax
        js      .child_failed_status
        jmp     .advance
.initialized_failed:
        cmp     qword [rsp + 48], -1
        jne     .advance
        and     qword [r13 + MC_FLAGS], ~AF_MC_F_HTTP_NOTIFY_PENDING
        mov     rax, [rsp + 24]
.child_failed_status:
        mov     rdi, r13
        mov     rsi, rax
        call    af_mcp_child_failed
        jmp     .done
.advance:
        cmp     qword [rsp + 32], 0
        je      .done
        mov     rdi, r13
        call    af_mcp_advance
        jmp     .done

.release:
        mov     rdi, rbx
        call    af_mcp_http_slot_release
.done:
        AF_LEAVE
