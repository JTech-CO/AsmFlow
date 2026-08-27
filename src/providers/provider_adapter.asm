; AsmFlow — turning a client request into an upstream request.
;
; docs/API_CONTRACT.md 5 and 6 state what this is allowed to change: `model`
; becomes the target's configured upstream model, and nothing else is
; intentionally altered. Fields AsmFlow has no opinion about are forwarded, so
; a client using a provider feature the gateway has never heard of still works.
;
; That "nothing else" is the reason the body is re-emitted through Jansson
; rather than through AsmFlow's own writer. Our writer is exact for everything
; it can name, but a JSON real has no decimal text recoverable from a double,
; and re-encoding one would change a request's meaning to make the plumbing
; tidier. Jansson parsed the document and Jansson re-emits it; the substitution
; — which field, what value, under which rule — is here.
;
; Two things are deliberately NOT forwarded.
;
; The client's credential never reaches a provider. The gateway's listener
; credential authenticates the client to AsmFlow; the provider's credential
; authenticates AsmFlow to the provider. Forwarding the first would hand a
; provider a token that grants access to this gateway.
;
; No client-supplied header is forwarded at all. A header allowlist would be a
; second security surface that has to stay correct as providers add headers,
; and nothing in the contract asks for one.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "config.inc"
%include "json.inc"
%include "http.inc"
%include "provider.inc"

        extern af_buf_init
        extern af_buf_free
        extern af_buf_free_secure
        extern af_buf_clear
        extern af_buf_data
        extern af_buf_len
        extern af_buf_append
        extern af_buf_append_byte
        extern af_buf_append_cstr

        extern af_cstr_len
        extern af_cfg_getenv

        extern af_json_parse
        extern af_json_doc_root
        extern af_json_doc_free
        extern af_json_type
        extern af_json_member
        extern af_json_string_of

        extern af_jsonc_object_set_string
        extern af_jsonc_dump
        extern af_jsonc_dump_free

        extern af_curl_slist_append
        extern af_curl_slist_free

        extern af_version_str

        section .rodata

; The upstream path for each endpoint family, appended to `base_url`.
u_responses:  db "/responses", 0
u_chat:       db "/chat/completions", 0

k_model:      db "model", 0
k_stream:     db "stream", 0

h_ctype:      db "Content-Type: application/json", 0
h_accept_sse: db "Accept: text/event-stream", 0
h_accept_json: db "Accept: application/json", 0
; An empty value removes a header libcurl would otherwise send. libcurl adds
; `Expect: 100-continue` for large bodies, and a provider that does not answer
; the continuation makes every large request pay a one-second stall.
h_no_expect:  db "Expect:", 0
h_bearer:     db "Authorization: Bearer ", 0
h_agent:      db "User-Agent: AsmFlow/", 0
h_sep:        db ": ", 0

s_protocols:  db "http,https", 0

        section .data.rel.ro progbits align=8

family_suffix:
        dq u_responses
        dq u_chat

        section .text

; ---------------------------------------------------------------------------
; af_prov_family_for_endpoint(u64 endpoint) -> i64
;
; -1 for an endpoint that is not a generation endpoint.
; ---------------------------------------------------------------------------
        global af_prov_family_for_endpoint
af_prov_family_for_endpoint:
        cmp     rdi, AF_EP_RESPONSES
        je      .responses
        cmp     rdi, AF_EP_CHAT
        je      .chat
        mov     rax, -1
        ret
.responses:
        mov     eax, AF_PROV_FAMILY_RESPONSES
        ret
.chat:
        mov     eax, AF_PROV_FAMILY_CHAT
        ret

; ---------------------------------------------------------------------------
; af_prov_family_bit(i64 family) -> u64
;
; The AF_EPF_* bit a route's `endpoint_families` uses for this family, so the
; route filter and the adapter agree on what "responses" means.
; ---------------------------------------------------------------------------
        global af_prov_family_bit
af_prov_family_bit:
        cmp     rdi, AF_PROV_FAMILY_RESPONSES
        jne     .chat
        mov     eax, AF_EPF_RESPONSES
        ret
.chat:
        mov     eax, AF_EPF_CHAT_COMPLETIONS
        ret

; ---------------------------------------------------------------------------
; af_prov_provider_supports(af_cfg_provider *p, i64 family, i64 wants_stream)
;   -> i64 (1 = eligible)
;
; The capability filter from docs/API_CONTRACT.md 5: a field that implies a
; capability filters providers that advertise it, rather than being rewritten
; away. A provider that does not advertise streaming is not asked to stream.
; ---------------------------------------------------------------------------
        global af_prov_provider_supports
af_prov_provider_supports:
        AF_ENTER 0
        test    rdi, rdi
        jz      .no
        cmp     qword [rdi + PRV_ENABLED], 0
        je      .no

        mov     rax, [rdi + PRV_CAPABILITIES]
        cmp     rsi, AF_PROV_FAMILY_RESPONSES
        jne     .want_chat
        test    rax, AF_CAP_RESPONSES
        jz      .no
        jmp     .adapter
.want_chat:
        test    rax, AF_CAP_CHAT_COMPLETIONS
        jz      .no
.adapter:
        test    rdx, rdx
        jz      .adapter_check
        test    rax, AF_CAP_STREAMING
        jz      .no
.adapter_check:
        ; The adapter names which upstream API shape the provider speaks. A
        ; provider configured as `openai_chat` cannot serve a Responses request
        ; even if it claims the capability, because the URL and body shapes
        ; differ; `openai_dual` speaks both.
        mov     rcx, [rdi + PRV_ADAPTER]
        cmp     rcx, AF_ADAPTER_OPENAI_DUAL
        je      .yes
        cmp     rsi, AF_PROV_FAMILY_RESPONSES
        jne     .need_chat_adapter
        cmp     rcx, AF_ADAPTER_OPENAI_RESPONSES
        jne     .no
        jmp     .yes
.need_chat_adapter:
        cmp     rcx, AF_ADAPTER_OPENAI_CHAT
        jne     .no
.yes:
        mov     eax, 1
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_build_url(af_buffer *out, af_cfg_provider *p, i64 family)
;   -> af_status
;
; `base_url` plus the family's path. A trailing slash on the base is dropped
; rather than producing `//`: some providers route on the exact path, and a
; doubled separator is a 404 that looks like a configuration error.
; ---------------------------------------------------------------------------
        global af_prov_build_url
af_prov_build_url:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        cmp     rdx, AF_PROV_FAMILY_CHAT
        ja      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, rbx
        call    af_buf_clear

        mov     r14, [r12 + PRV_BASE_URL]
        test    r14, r14
        jz      .invalid
        mov     r15, [r12 + PRV_BASE_URL_LEN]
        test    r15, r15
        jnz     .have_len
        mov     rdi, r14
        call    af_cstr_len
        mov     r15, rax
        test    r15, r15
        jz      .invalid
.have_len:
        cmp     byte [r14 + r15 - 1], '/'
        jne     .no_trailing
        dec     r15
        test    r15, r15
        jz      .invalid
.no_trailing:
        mov     rdi, rbx
        mov     rsi, r14
        mov     rdx, r15
        call    af_buf_append
        test    rax, rax
        js      .done

        lea     rax, [family_suffix]
        mov     rsi, [rax + r13*8]
        mov     rdi, rbx
        call    af_buf_append_cstr
        test    rax, rax
        js      .done
        ; libcurl takes a C string, and af_buffer is not NUL-terminated.
        mov     rdi, rbx
        xor     esi, esi
        call    af_buf_append_byte
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_prov_build_headers(af_prov_exchange *x) -> af_status
;
; Builds the request header list into PX_SLIST. On failure the partial list is
; released here, so a caller never has to reason about how far this got.
; ---------------------------------------------------------------------------
        global af_prov_build_headers
af_prov_build_headers:
        AF_ENTER 64
;   [rsp +  0]  the staging buffer for one header line (af_buffer)
;   [rsp + 32]  1 once the staging buffer is initialised
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, [rbx + PX_PROVIDER]
        test    r12, r12
        jz      .invalid
        xor     r13, r13                        ; the list under construction
        mov     qword [rsp + 32], 0

        mov     rdi, r13
        lea     rsi, [h_ctype]
        call    af_curl_slist_append
        test    rax, rax
        jz      .nomem
        mov     r13, rax

        mov     rdi, r13
        lea     rsi, [h_accept_json]
        test    qword [rbx + PX_FLAGS], AF_PX_F_STREAM
        jz      .accept_ready
        lea     rsi, [h_accept_sse]
.accept_ready:
        call    af_curl_slist_append
        test    rax, rax
        jz      .nomem
        mov     r13, rax

        mov     rdi, r13
        lea     rsi, [h_no_expect]
        call    af_curl_slist_append
        test    rax, rax
        jz      .nomem
        mov     r13, rax

        ; A User-Agent naming the gateway and its version. An operator reading
        ; a provider's access log should be able to tell which build produced a
        ; request without correlating timestamps.
        lea     rdi, [rsp]
        mov     rsi, 512
        call    af_buf_init
        test    rax, rax
        js      .fail_status
        mov     qword [rsp + 32], 1

        lea     rdi, [rsp]
        lea     rsi, [h_agent]
        call    af_buf_append_cstr
        test    rax, rax
        js      .fail_status
        lea     rdi, [rsp + 40]
        call    af_version_str
        mov     r14, rax
        lea     rdi, [rsp]
        mov     rsi, r14
        mov     rdx, [rsp + 40]
        call    af_buf_append
        test    rax, rax
        js      .fail_status
        lea     rdi, [rsp]
        xor     esi, esi
        call    af_buf_append_byte
        test    rax, rax
        js      .fail_status
        lea     rdi, [rsp]
        call    af_buf_data
        mov     rdi, r13
        mov     rsi, rax
        call    af_curl_slist_append
        test    rax, rax
        jz      .nomem
        mov     r13, rax

        ; The provider credential, if the provider has one. It is read from the
        ; environment at this moment rather than cached on the snapshot, so a
        ; secret exists in AsmFlow's own memory only for as long as one request
        ; needs it.
        mov     rax, [r12 + PRV_AUTH + AUTH_TYPE]
        cmp     rax, AF_AUTH_NONE
        je      .headers_done

        lea     rdi, [rsp]
        call    af_buf_clear
        mov     rax, [r12 + PRV_AUTH + AUTH_TYPE]
        cmp     rax, AF_AUTH_BEARER_ENV
        jne     .named_header
        lea     rdi, [rsp]
        lea     rsi, [h_bearer]
        call    af_buf_append_cstr
        test    rax, rax
        js      .fail_status
        jmp     .append_secret
.named_header:
        mov     rsi, [r12 + PRV_AUTH + AUTH_HEADER]
        test    rsi, rsi
        jz      .invalid_free
        lea     rdi, [rsp]
        call    af_buf_append_cstr
        test    rax, rax
        js      .fail_status
        lea     rdi, [rsp]
        lea     rsi, [h_sep]
        call    af_buf_append_cstr
        test    rax, rax
        js      .fail_status

.append_secret:
        mov     rdi, [r12 + PRV_AUTH + AUTH_ENV]
        test    rdi, rdi
        jz      .invalid_free
        call    af_cfg_getenv
        test    rax, rax
        jz      .secret_missing
        mov     r14, rax
        lea     rdi, [rsp]
        mov     rsi, r14
        call    af_buf_append_cstr
        test    rax, rax
        js      .fail_status
        lea     rdi, [rsp]
        xor     esi, esi
        call    af_buf_append_byte
        test    rax, rax
        js      .fail_status
        lea     rdi, [rsp]
        call    af_buf_data
        mov     rdi, r13
        mov     rsi, rax
        call    af_curl_slist_append
        test    rax, rax
        jz      .nomem
        mov     r13, rax

.headers_done:
        ; The staging buffer held a credential. Zeroing before releasing keeps
        ; it out of memory the allocator hands to the next request; libcurl's
        ; own copy inside the list is released by curl_slist_free_all, which is
        ; noted in docs/SECURITY_MODEL.md as the boundary of this guarantee.
        cmp     qword [rsp + 32], 0
        je      .no_staging
        lea     rdi, [rsp]
        call    af_buf_free_secure
        mov     qword [rsp + 32], 0
.no_staging:
        mov     [rbx + PX_SLIST], r13
        AF_LEAVE_OK

.secret_missing:
        mov     rax, AF_E_CFG_SECRET_MISSING
        jmp     .fail_status
.invalid_free:
        mov     rax, AF_E_INVALID
        jmp     .fail_status
.nomem:
        mov     rax, AF_E_NOMEM
.fail_status:
        mov     [rsp + 48], rax
        cmp     qword [rsp + 32], 0
        je      .fail_no_staging
        lea     rdi, [rsp]
        call    af_buf_free_secure
.fail_no_staging:
        test    r13, r13
        jz      .fail_done
        mov     rdi, r13
        call    af_curl_slist_free
.fail_done:
        mov     qword [rbx + PX_SLIST], 0
        mov     rax, [rsp + 48]
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_prov_wants_stream(json_t *root) -> i64
;
; 1 when the request asked to stream. A `stream` that is not a boolean is
; treated as absent here; the field's type is validated separately, so this
; function has one job and no opinion about malformed input.
; ---------------------------------------------------------------------------
        global af_prov_wants_stream
af_prov_wants_stream:
        AF_ENTER 16
        test    rdi, rdi
        jz      .no
        lea     rdx, [rsp]
        lea     rsi, [k_stream]
        call    af_json_member
        test    rax, rax
        js      .no
        mov     rdi, [rsp]
        call    af_json_type
        cmp     rax, AF_JSON_TRUE
        jne     .no
        mov     eax, 1
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_rewrite_body(af_buffer *out, json_t *root, const char *upstream_model)
;   -> af_status
;
; Replaces `model` and re-emits the document. The caller owns `root` and it is
; left modified: an exchange parses the body once and does not need the
; original back.
; ---------------------------------------------------------------------------
        global af_prov_rewrite_body
af_prov_rewrite_body:
        AF_ENTER 32
;   [rsp +  0]  the dumped text (Jansson's allocation)
;   [rsp +  8]  its length
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, r13
        call    af_cstr_len
        mov     r14, rax
        test    r14, r14
        jz      .invalid

        mov     rdi, r12
        lea     rsi, [k_model]
        mov     rdx, r13
        mov     rcx, r14
        call    af_jsonc_object_set_string
        test    eax, eax
        jnz     .nomem

        mov     rdi, r12
        lea     rsi, [rsp + 8]
        call    af_jsonc_dump
        test    rax, rax
        jz      .nomem
        mov     [rsp], rax

        mov     rax, [rsp + 8]
        cmp     rax, AF_PROV_REQUEST_MAX
        ja      .too_large

        mov     rdi, rbx
        call    af_buf_clear
        mov     rdi, rbx
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_buf_append
        mov     r15, rax
        mov     rdi, [rsp]
        call    af_jsonc_dump_free
        mov     rax, r15
        AF_LEAVE

.too_large:
        mov     rdi, [rsp]
        call    af_jsonc_dump_free
        AF_LEAVE_ERR AF_E_LIMIT
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_prov_protocols() -> const char *
;
; The scheme allowlist handed to libcurl. Stated by AsmFlow rather than left to
; a libcurl default, so a base_url that somehow reached this point cannot open
; a file or an SCP session.
; ---------------------------------------------------------------------------
        global af_prov_protocols
af_prov_protocols:
        lea     rax, [s_protocols]
        ret
