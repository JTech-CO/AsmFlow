; AsmFlow — deciding which protocol a server speaks, and then using it.
;
; docs/MCP_COMPATIBILITY.md 4: spawn, send the modern `server/discover` probe,
; and stay modern if it answers. A non-modern error, an invalid response, or a
; probe that times out sends the child down the legacy path instead —
; `initialize`, then the `initialized` notification, and only then any real
; work.
;
; Two rules make this safe rather than merely convenient.
;
; The eras are never interleaved. Nothing is sent between the probe and the
; decision, so a server cannot receive a modern request and a legacy one in the
; same session and answer both plausibly — which is how a "working" integration
; ends up in a state neither side agrees on.
;
; The decision lasts exactly one process lifetime (M8 DoD 5). A restarted
; server may be a different build; carrying the era across a restart would mean
; speaking the previous process's protocol to the new one, and the resulting
; failure would look like the server's fault rather than the supervisor's.
;
; ADR 0004 is why the legacy path is a separate sequence rather than a flag on
; the modern one: two protocol revisions sharing a code path share their state,
; and a field from one leaking into the other is a defect that only appears
; against servers nobody has locally.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "json.inc"
%include "config.inc"
%include "mcp.inc"

        extern af_mem_eq
        extern af_mem_copy
        extern af_add_size
        extern af_mul_size
        extern af_buf_init
        extern af_buf_free
        extern af_buf_len
        extern af_buf_data
        extern af_buf_append
        extern af_monotonic_now
        extern af_free
        extern af_mcp_own_cstr

        extern af_json_parse
        extern af_json_doc_root
        extern af_json_doc_free
        extern af_json_type
        extern af_json_member
        extern af_json_get_array
        extern af_json_array_at
        extern af_json_string_of
        extern af_json_get_string
        extern af_json_get_integer
        extern af_jsonc_dump
        extern af_jsonc_dump_free

        extern af_mcp_request
        extern af_mcp_notify
        extern af_mcp_call_release

        section .rodata

m_initialize2: db "initialize", 0
p_initialize2:
        db '{"protocolVersion":"2025-11-25","clientInfo":{"name":"AsmFlow",'
        db '"version":"'
        db AF_VERSION_STRING
        db '"},"capabilities":{}}', 0
m_initialized2: db "notifications/initialized", 0
m_tools2:       db "tools/list", 0
m_resources2:   db "resources/list", 0
m_prompts2:     db "prompts/list", 0

; Modern calls carry the same request metadata as the discovery fixture.
; Legacy inventory calls deliberately pass NULL params instead.
p_modern_inventory:
        db '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",'
        db '"io.modelcontextprotocol/clientInfo":{"name":"AsmFlow","version":"'
        db AF_VERSION_STRING
        db '"},"io.modelcontextprotocol/clientCapabilities":{}}}', 0

k_supported_versions: db "supportedVersions", 0
k_protocol_version:   db "protocolVersion", 0
k_tools:              db "tools", 0
k_resources:          db "resources", 0
k_prompts:            db "prompts", 0
k_name:               db "name", 0
k_uri:                db "uri", 0
k_input_schema:       db "inputSchema", 0
k_ttl_ms:             db "ttlMs", 0
k_cache_scope:        db "cacheScope", 0
v_scope_public:       db "public", 0
v_scope_private:      db "private", 0
v_modern2:             db AF_MCP_MODERN_VERSION, 0
v_legacy2:             db AF_MCP_LEGACY_VERSION, 0
%define V_MODERN2_LEN 10
%define V_LEGACY2_LEN 10

; af_buffer is an embedded 32-byte value throughout af_mcp_child/call. This
; expression follows that public embedding rather than restating field offsets.
%define ERA_BUFFER_SIZE (MC_RESOURCES - MC_TOOLS)

        section .text

; Commit an owned negotiated version only after its era-specific response has
; validated. Allocation happens before the old pointer is released, so failure
; cannot expose a half-updated process view.
af_mcp_commit_version:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, r12
        call    af_mcp_own_cstr
        test    rax, rax
        jz      .nomem
        mov     r13, rax
        mov     rdi, [rbx + MC_VERSION]
        test    rdi, rdi
        jz      .store
        call    af_free
.store:
        mov     [rbx + MC_VERSION], r13
        AF_LEAVE_OK
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_find_call(af_mcp_child *child, i64 kind) -> af_mcp_call *
;
; The call of that kind, whatever state it is in, or NULL.
; ---------------------------------------------------------------------------
        global af_mcp_find_call
af_mcp_find_call:
        AF_ENTER 16
        test    rdi, rdi
        jz      .none
        mov     rbx, rdi
        mov     r12, rsi
        xor     rcx, rcx
.scan:
        cmp     rcx, AF_MCP_MAX_CALLS
        jae     .none
        mov     rax, rcx
        imul    rax, rax, CL_SIZE
        add     rax, rbx
        add     rax, MC_CALLS
        cmp     qword [rax + CL_STATE], AF_MCP_CALL_FREE
        je      .next
        cmp     qword [rax + CL_KIND], r12
        je      .done
.next:
        inc     rcx
        jmp     .scan
.done:
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_advance(af_mcp_child *child) -> void
;
; Moves the child along whatever it is waiting for. Called after every read and
; from the sweep, so progress does not depend on which of the two noticed
; first.
; ---------------------------------------------------------------------------
        global af_mcp_advance
af_mcp_advance:
        AF_ENTER 48
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     qword [rsp + 8], 0             ; fresh-process legacy switch

        cmp     qword [rbx + MC_STATE], AF_MCP_S_PROBING
        je      .probing
        cmp     qword [rbx + MC_STATE], AF_MCP_S_READY
        je      .ready
        cmp     qword [rbx + MC_STATE], AF_MCP_S_DEGRADED
        je      .ready
        AF_LEAVE

; --- probing ----------------------------------------------------------------
.probing:
        ; The modern probe first.
        mov     rdi, rbx
        mov     rsi, AF_MCP_CALL_DISCOVER
        call    af_mcp_find_call
        test    rax, rax
        jz      .check_initialize
        mov     r12, rax
        cmp     qword [r12 + CL_STATE], AF_MCP_CALL_DONE
        jne     .waiting
        cmp     qword [r12 + CL_STATUS], 0
        jne     .discover_refused

        ; A JSON-RPC success is not enough to select an era. The result must
        ; actually advertise the version AsmFlow speaks.
        mov     rdi, r12
        call    af_mcp_validate_modern_discover
        test    rax, rax
        js      .discover_invalid

        mov     rdi, rbx
        lea     rsi, [v_modern2]
        call    af_mcp_commit_version
        test    rax, rax
        js      .adapter_failed

        ; The validated modern decision lasts for this process lifetime.
        mov     qword [rbx + MC_ERA], AF_ERA_MODERN
        or      qword [rbx + MC_FLAGS], AF_MC_F_PROBED
        mov     rdi, r12
        call    af_mcp_call_release
        mov     rdi, rbx
        call    af_mcp_begin_inventory
        test    rax, rax
        js      .adapter_failed
        mov     qword [rbx + MC_STATE], AF_MCP_S_READY
        AF_LEAVE

.discover_invalid:
        mov     [rsp], rax
        ; A successful HTTP response is already positive modern-era evidence.
        ; A malformed discover result or an empty version intersection is not
        ; permission to reinterpret that endpoint as legacy.
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .discover_fallback
        cmp     qword [rax + MCP_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .discover_fallback
        mov     rdi, r12
        call    af_mcp_call_release
        jmp     .no_legacy

.discover_refused:
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .stdio_discover_refused
        cmp     qword [rax + MCP_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .stdio_discover_refused

        ; Only an unrecognised bare HTTP 400 is evidence for the isolated
        ; legacy adapter. A correlated JSON-RPC error (including version
        ; negotiation), authentication/rate/server errors, transport errors,
        ; and timeouts are all modern or inconclusive and must not fall back.
        mov     rax, [r12 + CL_STATUS]
        mov     [rsp], rax
        test    qword [r12 + CL_FLAGS], AF_MCP_CL_F_BARE_REFUSAL
        jnz     .discover_fallback
        mov     rdi, r12
        call    af_mcp_call_release
        jmp     .no_legacy

.stdio_discover_refused:
        ; A completed refusal leaves no modern request in flight and may use
        ; same-process fallback. A timeout is different: cancellation is only
        ; advisory, so legacy initialize must run in a fresh child process.
        cmp     qword [r12 + CL_STATUS], AF_E_MCP_TIMEOUT
        jne     .discover_completed_refusal
        mov     qword [rsp], AF_E_MCP_TIMEOUT
        mov     qword [rsp + 8], 1
        jmp     .discover_fallback
.discover_completed_refusal:
        mov     qword [rsp], AF_E_MCP_ERA
.discover_fallback:
        mov     rdi, r12
        call    af_mcp_call_release
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .no_legacy
        test    qword [rax + MCP_PROTO_LEGACY], AF_MCP_LEGACY_2025_11_25
        jz      .no_legacy

        cmp     qword [rsp + 8], 0
        je      .same_process_legacy
        or      qword [rbx + MC_FLAGS], AF_MC_F_LEGACY_NEXT
        mov     rdi, rbx
        mov     rsi, AF_E_MCP_TIMEOUT
        call    af_mcp_child_failed_local
        AF_LEAVE

.same_process_legacy:
        mov     r13, 5000
        mov     rcx, [rax + MCP_STARTUP_TIMEOUT]
        test    rcx, rcx
        jz      .legacy_timeout
        mov     r13, rcx
.legacy_timeout:
        mov     rdi, rbx
        lea     rsi, [m_initialize2]
        lea     rdx, [p_initialize2]
        mov     rcx, AF_MCP_CALL_INITIALIZE
        mov     r8, r13
        call    af_mcp_request
        test    rax, rax
        jz      .request_failed
        AF_LEAVE

.no_legacy:
        mov     rdi, rbx
        mov     rsi, [rsp]
        call    af_mcp_child_failed_local
        AF_LEAVE

.check_initialize:
        mov     rdi, rbx
        mov     rsi, AF_MCP_CALL_INITIALIZE
        call    af_mcp_find_call
        test    rax, rax
        jz      .request_failed
        mov     r12, rax
        cmp     qword [r12 + CL_STATE], AF_MCP_CALL_DONE
        jne     .waiting
        cmp     qword [r12 + CL_STATUS], 0
        jne     .initialize_refused

        mov     rdi, r12
        call    af_mcp_validate_legacy_initialize
        test    rax, rax
        js      .initialize_invalid

        mov     rdi, rbx
        lea     rsi, [v_legacy2]
        call    af_mcp_commit_version
        test    rax, rax
        js      .adapter_failed

        mov     rdi, r12
        call    af_mcp_call_release
        mov     qword [rbx + MC_ERA], AF_ERA_LEGACY
        or      qword [rbx + MC_FLAGS], AF_MC_F_PROBED
        ; The revision requires the notification before anything else.
        mov     rdi, rbx
        lea     rsi, [m_initialized2]
        xor     edx, edx
        call    af_mcp_notify
        test    rax, rax
        js      .adapter_failed
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .legacy_begin_inventory
        cmp     qword [rax + MCP_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .legacy_begin_inventory
        ; HTTP notifications are independent POST exchanges. The completion
        ; hook begins inventory only after the legacy initialized POST has
        ; completed, preserving the revision's wire order.
        mov     qword [rbx + MC_STATE], AF_MCP_S_READY
        AF_LEAVE
.legacy_begin_inventory:
        mov     rdi, rbx
        call    af_mcp_begin_inventory
        test    rax, rax
        js      .adapter_failed
        mov     qword [rbx + MC_STATE], AF_MCP_S_READY
        AF_LEAVE

.initialize_invalid:
        mov     [rsp], rax
        jmp     .initialize_failed
.initialize_refused:
        mov     qword [rsp], AF_E_MCP_VERSION
.initialize_failed:
        mov     rdi, r12
        call    af_mcp_call_release
        mov     rdi, rbx
        mov     rsi, [rsp]
        call    af_mcp_child_failed_local
        AF_LEAVE

.request_failed:
        mov     rdi, rbx
        mov     rsi, AF_E_MCP_PROTOCOL
        call    af_mcp_child_failed_local
        AF_LEAVE

.adapter_failed:
        mov     rsi, rax
        mov     rdi, rbx
        call    af_mcp_child_failed_local
        AF_LEAVE

.waiting:
        AF_LEAVE

; --- ready ------------------------------------------------------------------
.ready:
        ; Collect whichever inventory list has come back and ask for the next.
        mov     rdi, rbx
        mov     rsi, AF_MCP_CALL_TOOLS
        lea     rdx, [rbx + MC_TOOLS]
        lea     rcx, [rbx + MC_TOOL_COUNT]
        call    af_mcp_collect_list
        mov     rdi, rbx
        mov     rsi, AF_MCP_CALL_RESOURCES
        lea     rdx, [rbx + MC_RESOURCES]
        lea     rcx, [rbx + MC_RES_COUNT]
        call    af_mcp_collect_list
        mov     rdi, rbx
        mov     rsi, AF_MCP_CALL_PROMPTS
        lea     rdx, [rbx + MC_PROMPTS]
        lea     rcx, [rbx + MC_PROMPT_COUNT]
        call    af_mcp_collect_list
        mov     rdi, rbx
        call    af_mcp_http_advance_inventory
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_begin_inventory(af_mcp_child *child) -> af_status
;
; The three list calls, issued together. They are independent of one another
; and a server that answers them in any order is answering correctly.
; AF_MC_F_LISTED is committed only after all three frames are queued. A partial
; allocation/send is rolled back so the caller can fail the child rather than
; leave it apparently ready with an incomplete inventory transaction.
; ---------------------------------------------------------------------------
        global af_mcp_begin_inventory
af_mcp_begin_inventory:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        test    qword [rbx + MC_FLAGS], AF_MC_F_LISTED
        jnz     .ok
        and     qword [rbx + MC_FLAGS], ~(AF_MC_F_TOOLS_CURRENT | AF_MC_F_HTTP_RESOURCES_ISSUED | AF_MC_F_HTTP_PROMPTS_ISSUED)
        xor     r14d, r14d
        xor     r15d, r15d

        mov     r12, 10000
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .have_timeout
        mov     rcx, [rax + MCP_TIMEOUTS + TMO_REQUEST_MS]
        test    rcx, rcx
        jz      .have_timeout
        mov     r12, rcx
.have_timeout:
        cmp     qword [rbx + MC_ERA], AF_ERA_MODERN
        je      .modern_params
        cmp     qword [rbx + MC_ERA], AF_ERA_LEGACY
        jne     .protocol
        xor     r13d, r13d                    ; legacy list calls omit params
        jmp     .send
.modern_params:
        lea     r13, [p_modern_inventory]
.send:

        mov     rdi, rbx
        lea     rsi, [m_tools2]
        mov     rdx, r13
        mov     rcx, AF_MCP_CALL_TOOLS
        mov     r8, r12
        call    af_mcp_request
        test    rax, rax
        jz      .send_failed
        mov     r14, rax

        ; A Streamable-HTTP server owns one request-scoped POST at a time.
        ; The completion path issues resources then prompts in order; stdio
        ; retains the original independent/concurrent list calls.
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .send_resources
        cmp     qword [rax + MCP_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        je      .mark_issued

.send_resources:

        mov     rdi, rbx
        lea     rsi, [m_resources2]
        mov     rdx, r13
        mov     rcx, AF_MCP_CALL_RESOURCES
        mov     r8, r12
        call    af_mcp_request
        test    rax, rax
        jz      .send_failed
        mov     r15, rax

        mov     rdi, rbx
        lea     rsi, [m_prompts2]
        mov     rdx, r13
        mov     rcx, AF_MCP_CALL_PROMPTS
        mov     r8, r12
        call    af_mcp_request
        test    rax, rax
        jz      .send_failed

.mark_issued:
        or      qword [rbx + MC_FLAGS], AF_MC_F_LISTED
        call    af_monotonic_now
        mov     [rbx + MC_FETCHED_NS], rax
.ok:
        AF_LEAVE_OK

.send_failed:
        test    r15, r15
        jz      .release_first
        mov     rdi, r15
        call    af_mcp_call_release
.release_first:
        test    r14, r14
        jz      .protocol
        mov     rdi, r14
        call    af_mcp_call_release
.protocol:
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_collect_list(af_mcp_child *child, i64 kind, af_buffer *into,
;                     u64 *count) -> void
;
; A successful result must be an object containing the kind-specific array.
; Only that array is compact-encoded into the cache; unrelated response fields
; are protocol envelope, not inventory. The replacement is built independently
; and committed only after every fallible step succeeds, so a failed refresh
; leaves both the prior bytes and prior count intact.
;
; tools/list is the required M8 capability. Its current-batch bit is cleared by
; af_mcp_begin_inventory, set only after a validated transactional commit, and
; cleared with DEGRADED on error/timeout/invalid shape. resources and prompts
; are optional: their stale caches survive failure without making usable tools
; unavailable.
; ---------------------------------------------------------------------------
; A required string member is borrowed only for the duration of this check.
; Its explicit Jansson length, rather than C-string termination, decides
; whether the protocol supplied a nonempty name/URI.
af_mcp_require_nonempty_string:
        AF_ENTER 32
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_json_get_string
        test    rax, rax
        js      .done
        cmp     qword [rsp + 8], 0
        je      .protocol
        AF_LEAVE_OK
.protocol:
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL
.done:
        AF_LEAVE

%define ACL_RESULT_LEN   0
%define ACL_RESULT_PTR   8
%define ACL_ARRAY_PTR    16
%define ACL_ARRAY_COUNT  24
%define ACL_DUMP_PTR     32
%define ACL_DUMP_LEN     40
%define ACL_SCRATCH_INIT 48
%define ACL_ITEM_INDEX   56
%define ACL_LIMITS       64
%define ACL_DOC          96
%define ACL_SCRATCH      128
%define ACL_TTL_MS       160
%define ACL_SCOPE        168
%define ACL_NOW          176
%define ACL_TTL_NS       184
%define ACL_STR_PTR      192
%define ACL_STR_LEN      200
        global af_mcp_collect_list
af_mcp_collect_list:
        AF_ENTER 208
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r15, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     qword [rsp + ACL_DUMP_PTR], 0
        mov     qword [rsp + ACL_SCRATCH_INIT], 0
        mov     qword [rsp + ACL_DOC + AF_JSONDOC_ROOT], 0
        mov     qword [rsp + ACL_TTL_MS], 0
        mov     qword [rsp + ACL_SCOPE], AF_MCP_CACHE_PRIVATE
        call    af_mcp_find_call
        test    rax, rax
        jz      .done
        mov     r12, rax
        cmp     qword [r12 + CL_STATE], AF_MCP_CALL_DONE
        jne     .done
        cmp     qword [r12 + CL_STATUS], 0
        jne     .failed_release

        lea     rdi, [r12 + CL_RESULT]
        call    af_buf_len
        mov     [rsp + ACL_RESULT_LEN], rax
        test    rax, rax
        jz      .failed_release
        lea     rdi, [r12 + CL_RESULT]
        call    af_buf_data
        test    rax, rax
        jz      .failed_release
        mov     [rsp + ACL_RESULT_PTR], rax

        ; Parse the untrusted result under explicit byte/depth/string/element
        ; bounds before looking up the required member.
        mov     qword [rsp + ACL_LIMITS + AF_JSONLIM_MAX_BYTES], AF_MCP_INVENTORY_MAX
        mov     qword [rsp + ACL_LIMITS + AF_JSONLIM_MAX_DEPTH], 64
        mov     qword [rsp + ACL_LIMITS + AF_JSONLIM_MAX_STRING], 1048576
        mov     qword [rsp + ACL_LIMITS + AF_JSONLIM_MAX_ELEMS], 100000
        mov     rdi, [rsp + ACL_RESULT_PTR]
        mov     rsi, [rsp + ACL_RESULT_LEN]
        lea     rdx, [rsp + ACL_LIMITS]
        lea     rcx, [rsp + ACL_DOC]
        call    af_json_parse
        test    rax, rax
        js      .failed_cleanup

        lea     rdi, [rsp + ACL_DOC]
        call    af_json_doc_root
        mov     [rsp + ACL_RESULT_PTR], rax
        mov     rdi, rax
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .failed_cleanup

        ; HTTP inventory metadata is validated before the transactional cache
        ; replacement. Missing modern ttlMs is immediately stale; the legacy
        ; adapter applies a bounded local minute because that revision has no
        ; server TTL field. Unknown/wrong-typed cacheScope is not guessed.
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .select_array
        cmp     qword [rax + MCP_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .select_array
        mov     rdi, [rsp + ACL_RESULT_PTR]
        lea     rsi, [k_ttl_ms]
        lea     rdx, [rsp + ACL_TTL_MS]
        call    af_json_get_integer
        test    rax, rax
        jns     .ttl_present
        cmp     rax, AF_E_NOTFOUND
        jne     .failed_cleanup
        cmp     qword [rbx + MC_ERA], AF_ERA_LEGACY
        jne     .ttl_ready
        mov     qword [rsp + ACL_TTL_MS], 60000
        jmp     .ttl_ready
.ttl_present:
        cmp     qword [rsp + ACL_TTL_MS], 0
        jg      .ttl_positive
        mov     qword [rsp + ACL_TTL_MS], 0
        jmp     .ttl_ready
.ttl_positive:
        cmp     qword [rsp + ACL_TTL_MS], AF_MCP_CACHE_TTL_MAX_MS
        jbe     .ttl_ready
        mov     qword [rsp + ACL_TTL_MS], AF_MCP_CACHE_TTL_MAX_MS
.ttl_ready:
        mov     rdi, [rsp + ACL_RESULT_PTR]
        lea     rsi, [k_cache_scope]
        lea     rdx, [rsp + ACL_STR_PTR]
        lea     rcx, [rsp + ACL_STR_LEN]
        call    af_json_get_string
        test    rax, rax
        jns     .scope_present
        cmp     rax, AF_E_NOTFOUND
        jne     .failed_cleanup
        jmp     .select_array
.scope_present:
        cmp     qword [rsp + ACL_STR_LEN], 6
        jne     .scope_private
        mov     rdi, [rsp + ACL_STR_PTR]
        lea     rsi, [v_scope_public]
        mov     rdx, 6
        call    af_mem_eq
        test    rax, rax
        jz      .scope_private
        mov     qword [rsp + ACL_SCOPE], AF_MCP_CACHE_PUBLIC
        jmp     .select_array
.scope_private:
        cmp     qword [rsp + ACL_STR_LEN], 7
        jne     .failed_cleanup
        mov     rdi, [rsp + ACL_STR_PTR]
        lea     rsi, [v_scope_private]
        mov     rdx, 7
        call    af_mem_eq
        test    rax, rax
        jz      .failed_cleanup
        mov     qword [rsp + ACL_SCOPE], AF_MCP_CACHE_PRIVATE

.select_array:

        cmp     r15, AF_MCP_CALL_TOOLS
        je      .tools_key
        cmp     r15, AF_MCP_CALL_RESOURCES
        je      .resources_key
        cmp     r15, AF_MCP_CALL_PROMPTS
        je      .prompts_key
        jmp     .failed_cleanup
.tools_key:
        lea     rsi, [k_tools]
        jmp     .get_array
.resources_key:
        lea     rsi, [k_resources]
        jmp     .get_array
.prompts_key:
        lea     rsi, [k_prompts]
.get_array:
        mov     rdi, [rsp + ACL_RESULT_PTR]
        lea     rdx, [rsp + ACL_ARRAY_PTR]
        lea     rcx, [rsp + ACL_ARRAY_COUNT]
        call    af_json_get_array
        test    rax, rax
        js      .failed_cleanup

        ; Validate every untrusted array element before the transactional
        ; cache commit. Required tools need an addressable name and an object
        ; input schema. Optional resources and prompts are validated too, but
        ; their failure path deliberately preserves the prior optional cache.
        mov     qword [rsp + ACL_ITEM_INDEX], 0
.validate_item:
        mov     rax, [rsp + ACL_ITEM_INDEX]
        cmp     rax, [rsp + ACL_ARRAY_COUNT]
        jae     .items_valid
        mov     rdi, [rsp + ACL_ARRAY_PTR]
        mov     rsi, rax
        lea     rdx, [rsp + ACL_RESULT_PTR]
        call    af_json_array_at
        test    rax, rax
        js      .failed_cleanup
        mov     rdi, [rsp + ACL_RESULT_PTR]
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .failed_cleanup

        cmp     r15, AF_MCP_CALL_TOOLS
        je      .validate_tool
        cmp     r15, AF_MCP_CALL_RESOURCES
        je      .validate_resource
        ; prompts/list: every entry has a nonempty name.
        mov     rdi, [rsp + ACL_RESULT_PTR]
        lea     rsi, [k_name]
        call    af_mcp_require_nonempty_string
        test    rax, rax
        js      .failed_cleanup
        jmp     .item_valid

.validate_resource:
        ; Resources are operator-addressable only with both their stable URI
        ; and display name present as nonempty strings.
        mov     rdi, [rsp + ACL_RESULT_PTR]
        lea     rsi, [k_name]
        call    af_mcp_require_nonempty_string
        test    rax, rax
        js      .failed_cleanup
        mov     rdi, [rsp + ACL_RESULT_PTR]
        lea     rsi, [k_uri]
        call    af_mcp_require_nonempty_string
        test    rax, rax
        js      .failed_cleanup
        jmp     .item_valid

.validate_tool:
        mov     rdi, [rsp + ACL_RESULT_PTR]
        lea     rsi, [k_name]
        call    af_mcp_require_nonempty_string
        test    rax, rax
        js      .failed_cleanup
        mov     rdi, [rsp + ACL_RESULT_PTR]
        lea     rsi, [k_input_schema]
        lea     rdx, [rsp + ACL_RESULT_PTR]
        call    af_json_member
        test    rax, rax
        js      .failed_cleanup
        mov     rdi, [rsp + ACL_RESULT_PTR]
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .failed_cleanup

.item_valid:
        inc     qword [rsp + ACL_ITEM_INDEX]
        jmp     .validate_item

.items_valid:

        mov     rdi, [rsp + ACL_ARRAY_PTR]
        lea     rsi, [rsp + ACL_DUMP_LEN]
        call    af_jsonc_dump
        test    rax, rax
        jz      .failed_cleanup
        mov     [rsp + ACL_DUMP_PTR], rax
        cmp     qword [rsp + ACL_DUMP_LEN], AF_MCP_INVENTORY_MAX
        ja      .failed_cleanup

        ; Build the replacement in independent owned storage. No fallible
        ; operation touches the cached inventory, so allocation/append failure
        ; leaves the previous bytes and count exactly intact.
        lea     rdi, [rsp + ACL_SCRATCH]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        test    rax, rax
        js      .failed_cleanup
        mov     qword [rsp + ACL_SCRATCH_INIT], 1
        lea     rdi, [rsp + ACL_SCRATCH]
        mov     rsi, [rsp + ACL_DUMP_PTR]
        mov     rdx, [rsp + ACL_DUMP_LEN]
        call    af_buf_append
        test    rax, rax
        js      .failed_cleanup

        ; Every fallible step succeeded. Replace the old owned buffer, then
        ; transfer the scratch af_buffer value into the embedded destination.
        ; The stack copy is deliberately not freed after this ownership move.
        mov     rdi, r13
        call    af_buf_free
        mov     rdi, r13
        lea     rsi, [rsp + ACL_SCRATCH]
        mov     rdx, ERA_BUFFER_SIZE
        call    af_mem_copy
        mov     qword [rsp + ACL_SCRATCH_INIT], 0

        test    r14, r14
        jz      .commit_state
        mov     rax, [rsp + ACL_ARRAY_COUNT]
        mov     [r14], rax
.commit_state:
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .commit_readiness
        cmp     qword [rax + MCP_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .commit_readiness
        call    af_monotonic_now
        mov     [rsp + ACL_NOW], rax
        mov     [rbx + MC_FETCHED_NS], rax
        mov     rax, [rsp + ACL_SCOPE]
        mov     [rbx + MC_CACHE_SCOPE], rax
        mov     rdi, [rsp + ACL_TTL_MS]
        mov     rsi, NS_PER_MS
        lea     rdx, [rsp + ACL_TTL_NS]
        call    af_mul_size
        test    rax, rax
        js      .failed_cleanup
        mov     rdi, [rsp + ACL_NOW]
        mov     rsi, [rsp + ACL_TTL_NS]
        lea     rdx, [rsp + ACL_TTL_NS]
        call    af_add_size
        test    rax, rax
        js      .failed_cleanup
        mov     rax, [rsp + ACL_TTL_NS]
        mov     [rbx + MC_EXPIRES_NS], rax
.commit_readiness:
        cmp     r15, AF_MCP_CALL_TOOLS
        jne     .success_cleanup
        or      qword [rbx + MC_FLAGS], AF_MC_F_TOOLS_CURRENT
        mov     qword [rbx + MC_STATE], AF_MCP_S_READY
.success_cleanup:
        mov     rdi, [rsp + ACL_DUMP_PTR]
        call    af_jsonc_dump_free
        mov     qword [rsp + ACL_DUMP_PTR], 0
        lea     rdi, [rsp + ACL_DOC]
        call    af_json_doc_free
        jmp     .release

.failed_cleanup:
        cmp     qword [rsp + ACL_SCRATCH_INIT], 0
        je      .free_dump
        lea     rdi, [rsp + ACL_SCRATCH]
        call    af_buf_free
.free_dump:
        mov     rdi, [rsp + ACL_DUMP_PTR]
        test    rdi, rdi
        jz      .free_doc
        call    af_jsonc_dump_free
.free_doc:
        lea     rdi, [rsp + ACL_DOC]
        call    af_json_doc_free
.failed_release:
        cmp     r15, AF_MCP_CALL_TOOLS
        jne     .release
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_TOOLS_CURRENT
        mov     qword [rbx + MC_STATE], AF_MCP_S_DEGRADED
.release:
        mov     rdi, r12
        call    af_mcp_call_release
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_validate_modern_discover(const af_mcp_call *call) -> af_status
;
; Modern negotiation is committed only when the bounded result object contains
; the version AsmFlow supports. Pointers returned below are borrowed from the
; local document and never survive af_json_doc_free.
; ---------------------------------------------------------------------------
%define VMD_LIMITS 64
%define VMD_DOC    96
        global af_mcp_validate_modern_discover
af_mcp_validate_modern_discover:
        AF_ENTER 128
        test    rdi, rdi
        jz      .protocol_direct
        mov     rbx, rdi

        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_len
        test    rax, rax
        jz      .protocol_direct
        mov     [rsp], rax
        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_data
        test    rax, rax
        jz      .protocol_direct
        mov     [rsp + 8], rax

        mov     rax, [rsp]
        mov     [rsp + VMD_LIMITS + AF_JSONLIM_MAX_BYTES], rax
        mov     qword [rsp + VMD_LIMITS + AF_JSONLIM_MAX_DEPTH], 64
        mov     qword [rsp + VMD_LIMITS + AF_JSONLIM_MAX_STRING], 1048576
        mov     qword [rsp + VMD_LIMITS + AF_JSONLIM_MAX_ELEMS], 100000
        mov     rdi, [rsp + 8]
        mov     rsi, [rsp]
        lea     rdx, [rsp + VMD_LIMITS]
        lea     rcx, [rsp + VMD_DOC]
        call    af_json_parse
        test    rax, rax
        js      .protocol_direct

        lea     rdi, [rsp + VMD_DOC]
        call    af_json_doc_root
        mov     [rsp + 16], rax
        mov     rdi, rax
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .protocol_free

        mov     rdi, [rsp + 16]
        lea     rsi, [k_supported_versions]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_json_get_array
        test    rax, rax
        js      .version_free

        xor     r12d, r12d
.version_loop:
        cmp     r12, [rsp + 32]
        jae     .version_free
        mov     rdi, [rsp + 24]
        mov     rsi, r12
        lea     rdx, [rsp + 40]
        call    af_json_array_at
        test    rax, rax
        js      .protocol_free
        mov     rdi, [rsp + 40]
        lea     rsi, [rsp + 48]
        lea     rdx, [rsp + 56]
        call    af_json_string_of
        test    rax, rax
        js      .protocol_free
        cmp     qword [rsp + 56], V_MODERN2_LEN
        jne     .next_version
        mov     rdi, [rsp + 48]
        lea     rsi, [v_modern2]
        mov     rdx, V_MODERN2_LEN
        call    af_mem_eq
        test    rax, rax
        jnz     .valid_free
.next_version:
        inc     r12
        jmp     .version_loop

.valid_free:
        xor     r13d, r13d
        jmp     .free_return
.version_free:
        mov     r13, AF_E_MCP_VERSION
        jmp     .free_return
.protocol_free:
        mov     r13, AF_E_MCP_PROTOCOL
.free_return:
        lea     rdi, [rsp + VMD_DOC]
        call    af_json_doc_free
        mov     rax, r13
        AF_LEAVE
.protocol_direct:
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL

; ---------------------------------------------------------------------------
; af_mcp_validate_legacy_initialize(const af_mcp_call *call) -> af_status
;
; Legacy accepts exactly its negotiated revision. It does not inspect or reuse
; any modern metadata/state.
; ---------------------------------------------------------------------------
%define VLI_LIMITS 64
%define VLI_DOC    96
        global af_mcp_validate_legacy_initialize
af_mcp_validate_legacy_initialize:
        AF_ENTER 128
        test    rdi, rdi
        jz      .protocol_direct
        mov     rbx, rdi

        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_len
        test    rax, rax
        jz      .protocol_direct
        mov     [rsp], rax
        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_data
        test    rax, rax
        jz      .protocol_direct
        mov     [rsp + 8], rax

        mov     rax, [rsp]
        mov     [rsp + VLI_LIMITS + AF_JSONLIM_MAX_BYTES], rax
        mov     qword [rsp + VLI_LIMITS + AF_JSONLIM_MAX_DEPTH], 64
        mov     qword [rsp + VLI_LIMITS + AF_JSONLIM_MAX_STRING], 1048576
        mov     qword [rsp + VLI_LIMITS + AF_JSONLIM_MAX_ELEMS], 100000
        mov     rdi, [rsp + 8]
        mov     rsi, [rsp]
        lea     rdx, [rsp + VLI_LIMITS]
        lea     rcx, [rsp + VLI_DOC]
        call    af_json_parse
        test    rax, rax
        js      .protocol_direct

        lea     rdi, [rsp + VLI_DOC]
        call    af_json_doc_root
        mov     [rsp + 16], rax
        mov     rdi, rax
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .protocol_free

        mov     rdi, [rsp + 16]
        lea     rsi, [k_protocol_version]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_json_get_string
        test    rax, rax
        js      .version_free
        cmp     qword [rsp + 32], V_LEGACY2_LEN
        jne     .version_free
        mov     rdi, [rsp + 24]
        lea     rsi, [v_legacy2]
        mov     rdx, V_LEGACY2_LEN
        call    af_mem_eq
        test    rax, rax
        jz      .version_free

        xor     r13d, r13d
        jmp     .free_return
.version_free:
        mov     r13, AF_E_MCP_VERSION
        jmp     .free_return
.protocol_free:
        mov     r13, AF_E_MCP_PROTOCOL
.free_return:
        lea     rdi, [rsp + VLI_DOC]
        call    af_json_doc_free
        mov     rax, r13
        AF_LEAVE
.protocol_direct:
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL

; ---------------------------------------------------------------------------
; af_mcp_child_failed_local(af_mcp_child *child, af_status why) -> void
;
; A thin forward so this module does not have to import the supervisor's
; scheduling: the era decision knows a child is unusable, and the supervisor
; owns what happens next.
; ---------------------------------------------------------------------------
        extern af_mcp_child_failed
        extern af_mcp_http_advance_inventory
        global af_mcp_child_failed_local
af_mcp_child_failed_local:
        AF_ENTER 0
        call    af_mcp_child_failed
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_era_of(const af_mcp_child *child) -> i64
; af_mcp_state_of(const af_mcp_child *child) -> i64
; ---------------------------------------------------------------------------
        global af_mcp_era_of
af_mcp_era_of:
        test    rdi, rdi
        jz      .zero
        mov     rax, [rdi + MC_ERA]
        ret
.zero:
        xor     eax, eax
        ret

        global af_mcp_state_of
af_mcp_state_of:
        test    rdi, rdi
        jz      .zero
        mov     rax, [rdi + MC_STATE]
        ret
.zero:
        xor     eax, eax
        ret
