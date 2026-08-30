; AsmFlow — MCP 2026-07-28 Streamable-HTTP request headers.
;
; Modern transport state is deliberately sessionless. This module has no GET,
; DELETE, session-id, or Last-Event-ID path: one JSON-RPC request owns one POST
; and, when streamed, that POST's SSE response is the cancellation boundary.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "config.inc"
%include "json.inc"
%include "mcp.inc"
%include "mcp_http.inc"

        extern af_buf_init
        extern af_buf_free_secure
        extern af_buf_data
        extern af_buf_len
        extern af_buf_append
        extern af_buf_append_byte
        extern af_buf_append_cstr
        extern af_buf_append_u64

        extern af_cstr_eq
        extern af_cstr_len
        extern af_mem_eq
        extern af_cfg_getenv
        extern af_config_hash_bytes

        extern af_json_parse
        extern af_json_doc_root
        extern af_json_doc_free
        extern af_json_type
        extern af_json_member
        extern af_json_get_string
        extern af_json_string_of
        extern af_json_array_count
        extern af_json_array_at
        extern af_json_iter_begin
        extern af_json_iter_key
        extern af_json_iter_key_len
        extern af_json_iter_value
        extern af_json_iter_next
        extern af_jsonc_integer_value

        extern af_curl_slist_append
        extern af_mcp_http_cache_auth_update

        section .rodata

hm_ctype:       db "Content-Type: application/json", 0
hm_accept:      db "Accept: application/json, text/event-stream", 0
hm_expect:      db "Expect:", 0
hm_version:     db "MCP-Protocol-Version: "
                db AF_MCP_MODERN_VERSION, 0
hm_method:      db "Mcp-Method: ", 0
hm_name:        db "Mcp-Name: ", 0
hm_param:       db "Mcp-Param-", 0
hm_sep:         db ": ", 0
hm_bearer:      db "Authorization: Bearer ", 0

mm_tools_call:  db "tools/call", 0
mk_params:      db "params", 0
mk_name:        db "name", 0
mk_arguments:   db "arguments", 0
mk_input_schema: db "inputSchema", 0
mk_properties:  db "properties", 0
mk_x_header:    db "x-mcp-header", 0

mv_true:        db "true", 0
mv_false:       db "false", 0

        section .text

; Append one static line. curl_slist_append copies the bytes.
        global af_mcp_http_slist_add_static
af_mcp_http_slist_add_static:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, [rbx + HX_SLIST]
        call    af_curl_slist_append
        test    rax, rax
        jz      .nomem
        mov     [rbx + HX_SLIST], rax
        AF_LEAVE_OK
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_mcp_http_slist_add_pair(x, prefix_cstr, value, value_len) -> af_status
        global af_mcp_http_slist_add_pair
af_mcp_http_slist_add_pair:
        AF_ENTER 64
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     qword [rsp + 32], 0
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_HTTP_HEADER_HARD_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        mov     qword [rsp + 32], 1
        lea     rdi, [rsp]
        mov     rsi, r12
        call    af_buf_append_cstr
        test    rax, rax
        js      .free_status
        lea     rdi, [rsp]
        mov     rsi, r13
        mov     rdx, r14
        call    af_buf_append
        test    rax, rax
        js      .free_status
        lea     rdi, [rsp]
        xor     esi, esi
        call    af_buf_append_byte
        test    rax, rax
        js      .free_status
        lea     rdi, [rsp]
        call    af_buf_data
        mov     rdi, [rbx + HX_SLIST]
        mov     rsi, rax
        call    af_curl_slist_append
        test    rax, rax
        jz      .nomem_free
        mov     [rbx + HX_SLIST], rax
        xor     r15d, r15d
        jmp     .free_return
.nomem_free:
        mov     r15, AF_E_NOMEM
        jmp     .free_return
.free_status:
        mov     r15, rax
.free_return:
        lea     rdi, [rsp]
        call    af_buf_free_secure
        mov     rax, r15
        AF_LEAVE
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; Resolve one SecretRef only while constructing the libcurl-owned slist. The
; bounded staging buffer is wiped immediately after curl copies the line.
        global af_mcp_http_add_auth
af_mcp_http_add_auth:
        AF_ENTER 96
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rax, [rbx + HX_CHILD]
        test    rax, rax
        jz      .invalid
        mov     r12, [rax + MC_CFG]
        test    r12, r12
        jz      .invalid
        mov     r13, [r12 + MCP_AUTH + AUTH_TYPE]
        cmp     r13, AF_AUTH_NONE
        jne     .has_auth
        mov     rdi, [rbx + HX_CHILD]
        xor     esi, esi
        call    af_mcp_http_cache_auth_update
        AF_LEAVE

.has_auth:
        mov     rdi, [r12 + MCP_AUTH + AUTH_ENV]
        test    rdi, rdi
        jz      .secret_missing
        call    af_cfg_getenv
        test    rax, rax
        jz      .secret_missing
        mov     [rsp + 40], rax
        mov     rdi, rax
        call    af_cstr_len
        test    rax, rax
        jz      .secret_missing
        cmp     rax, 65536
        ja      .secret_invalid
        mov     [rsp + 48], rax
        xor     rcx, rcx
.scan_secret:
        cmp     rcx, [rsp + 48]
        jae     .secret_safe
        mov     rdx, [rsp + 40]
        movzx   eax, byte [rdx + rcx]
        cmp     al, 32
        jb      .secret_invalid
        cmp     al, 127
        je      .secret_invalid
        inc     rcx
        jmp     .scan_secret
.secret_safe:
        mov     rdi, [rsp + 40]
        mov     rsi, [rsp + 48]
        call    af_config_hash_bytes
        mov     [rsp + 56], rax
        mov     rdi, [rbx + HX_CHILD]
        mov     rsi, rax
        call    af_mcp_http_cache_auth_update

        cmp     r13, AF_AUTH_BEARER_ENV
        jne     .custom_header
        mov     rdi, rbx
        lea     rsi, [hm_bearer]
        mov     rdx, [rsp + 40]
        mov     rcx, [rsp + 48]
        call    af_mcp_http_slist_add_pair
        AF_LEAVE

.custom_header:
        cmp     r13, AF_AUTH_HEADER_ENV
        jne     .secret_invalid
        mov     r14, [r12 + MCP_AUTH + AUTH_HEADER]
        test    r14, r14
        jz      .secret_invalid
        mov     qword [rsp + 32], 0
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_HTTP_HEADER_HARD_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        mov     qword [rsp + 32], 1
        lea     rdi, [rsp]
        mov     rsi, r14
        call    af_buf_append_cstr
        test    rax, rax
        js      .free_status
        lea     rdi, [rsp]
        lea     rsi, [hm_sep]
        call    af_buf_append_cstr
        test    rax, rax
        js      .free_status
        lea     rdi, [rsp]
        mov     rsi, [rsp + 40]
        mov     rdx, [rsp + 48]
        call    af_buf_append
        test    rax, rax
        js      .free_status
        lea     rdi, [rsp]
        xor     esi, esi
        call    af_buf_append_byte
        test    rax, rax
        js      .free_status
        lea     rdi, [rsp]
        call    af_buf_data
        mov     rdi, [rbx + HX_SLIST]
        mov     rsi, rax
        call    af_curl_slist_append
        test    rax, rax
        jz      .nomem_status
        mov     [rbx + HX_SLIST], rax
        xor     r15d, r15d
        jmp     .free_return
.nomem_status:
        mov     r15, AF_E_NOMEM
        jmp     .free_return
.free_status:
        mov     r15, rax
.free_return:
        lea     rdi, [rsp]
        call    af_buf_free_secure
        mov     rax, r15
        AF_LEAVE
.secret_missing:
        AF_LEAVE_ERR AF_E_CFG_SECRET_MISSING
.secret_invalid:
        AF_LEAVE_ERR AF_E_CFG_PLAINTEXT
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; Build one Mcp-Param-* header from a validated primitive argument.
af_mcp_http_add_param:
        AF_ENTER 96
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rcx, rcx
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        cmp     r13, 0
        je      .invalid
        cmp     r13, 64
        ja      .invalid
        xor     r15, r15
.token:
        cmp     r15, r13
        jae     .token_ok
        movzx   eax, byte [r12 + r15]
        cmp     al, '0'
        jb      .maybe_alpha
        cmp     al, '9'
        jbe     .token_next
.maybe_alpha:
        cmp     al, 'A'
        jb      .maybe_lower
        cmp     al, 'Z'
        jbe     .token_next
.maybe_lower:
        cmp     al, 'a'
        jb      .maybe_dash
        cmp     al, 'z'
        jbe     .token_next
.maybe_dash:
        cmp     al, '-'
        jne     .invalid
.token_next:
        inc     r15
        jmp     .token
.token_ok:
        mov     qword [rsp + 32], 0
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_HTTP_HEADER_HARD_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        mov     qword [rsp + 32], 1
        lea     rdi, [rsp]
        lea     rsi, [hm_param]
        call    af_buf_append_cstr
        test    rax, rax
        js      .free_status
        lea     rdi, [rsp]
        mov     rsi, r12
        mov     rdx, r13
        call    af_buf_append
        test    rax, rax
        js      .free_status
        lea     rdi, [rsp]
        lea     rsi, [hm_sep]
        call    af_buf_append_cstr
        test    rax, rax
        js      .free_status

        mov     rdi, r14
        call    af_json_type
        cmp     rax, AF_JSON_STRING
        je      .string
        cmp     rax, AF_JSON_INTEGER
        je      .integer
        cmp     rax, AF_JSON_TRUE
        je      .true
        cmp     rax, AF_JSON_FALSE
        je      .false
        jmp     .invalid_free
.string:
        mov     rdi, r14
        lea     rsi, [rsp + 40]
        lea     rdx, [rsp + 48]
        call    af_json_string_of
        test    rax, rax
        js      .free_status
        xor     rcx, rcx
.string_scan:
        cmp     rcx, [rsp + 48]
        jae     .append_string
        mov     rdx, [rsp + 40]
        movzx   eax, byte [rdx + rcx]
        cmp     al, 32
        jb      .invalid_free
        cmp     al, 127
        jae     .invalid_free
        inc     rcx
        jmp     .string_scan
.append_string:
        lea     rdi, [rsp]
        mov     rsi, [rsp + 40]
        mov     rdx, [rsp + 48]
        call    af_buf_append
        jmp     .value_appended
.integer:
        mov     rdi, r14
        call    af_jsonc_integer_value
        test    rax, rax
        jns     .positive_integer
        mov     [rsp + 56], rax
        lea     rdi, [rsp]
        mov     esi, '-'
        call    af_buf_append_byte
        test    rax, rax
        js      .free_status
        mov     rax, [rsp + 56]
        neg     rax
.positive_integer:
        lea     rdi, [rsp]
        mov     rsi, rax
        call    af_buf_append_u64
        jmp     .value_appended
.true:
        lea     rdi, [rsp]
        lea     rsi, [mv_true]
        call    af_buf_append_cstr
        jmp     .value_appended
.false:
        lea     rdi, [rsp]
        lea     rsi, [mv_false]
        call    af_buf_append_cstr
.value_appended:
        test    rax, rax
        js      .free_status
        lea     rdi, [rsp]
        xor     esi, esi
        call    af_buf_append_byte
        test    rax, rax
        js      .free_status
        lea     rdi, [rsp]
        call    af_buf_data
        mov     rdi, [rbx + HX_SLIST]
        mov     rsi, rax
        call    af_curl_slist_append
        test    rax, rax
        jz      .nomem_free
        mov     [rbx + HX_SLIST], rax
        xor     r15d, r15d
        jmp     .free_return
.invalid_free:
        mov     r15, AF_E_MCP_PROTOCOL
        jmp     .free_return
.nomem_free:
        mov     r15, AF_E_NOMEM
        jmp     .free_return
.free_status:
        mov     r15, rax
.free_return:
        lea     rdi, [rsp]
        call    af_buf_free_secure
        mov     rax, r15
        AF_LEAVE
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; Parse tools/call once, mirror Mcp-Name, then emit only arguments explicitly
; annotated by the committed tool inputSchema's x-mcp-header property.
af_mcp_http_add_tool_metadata:
        AF_ENTER 352
%define MT_REQ_LIMITS 0
%define MT_REQ_DOC    32
%define MT_INV_LIMITS 64
%define MT_INV_DOC    96
%define MT_REQ_ROOT   128
%define MT_PARAMS     136
%define MT_ARGS       144
%define MT_NAME_PTR   152
%define MT_NAME_LEN   160
%define MT_INV_ROOT   168
%define MT_INV_COUNT  176
%define MT_INDEX      184
%define MT_TOOL       192
%define MT_TOOL_NAME  200
%define MT_TOOL_NLEN  208
%define MT_SCHEMA     216
%define MT_PROPS      224
%define MT_ITER       232
%define MT_PROP_KEY   240
%define MT_PROP_SPEC  248
%define MT_SUFFIX     256
%define MT_SUFFIX_LEN 264
%define MT_ARG        272
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     qword [rsp + MT_REQ_DOC + AF_JSONDOC_ROOT], 0
        mov     qword [rsp + MT_INV_DOC + AF_JSONDOC_ROOT], 0
        lea     rdi, [rbx + HX_BODY]
        call    af_buf_len
        mov     [rsp + MT_REQ_LIMITS + AF_JSONLIM_MAX_BYTES], rax
        mov     qword [rsp + MT_REQ_LIMITS + AF_JSONLIM_MAX_DEPTH], 64
        mov     qword [rsp + MT_REQ_LIMITS + AF_JSONLIM_MAX_STRING], 1048576
        mov     qword [rsp + MT_REQ_LIMITS + AF_JSONLIM_MAX_ELEMS], 100000
        lea     rdi, [rbx + HX_BODY]
        call    af_buf_data
        mov     rdi, rax
        mov     rsi, [rsp + MT_REQ_LIMITS + AF_JSONLIM_MAX_BYTES]
        lea     rdx, [rsp + MT_REQ_LIMITS]
        lea     rcx, [rsp + MT_REQ_DOC]
        call    af_json_parse
        test    rax, rax
        js      .done
        lea     rdi, [rsp + MT_REQ_DOC]
        call    af_json_doc_root
        mov     [rsp + MT_REQ_ROOT], rax
        mov     rdi, rax
        lea     rsi, [mk_params]
        lea     rdx, [rsp + MT_PARAMS]
        call    af_json_member
        test    rax, rax
        js      .protocol
        mov     rdi, [rsp + MT_PARAMS]
        lea     rsi, [mk_name]
        lea     rdx, [rsp + MT_NAME_PTR]
        lea     rcx, [rsp + MT_NAME_LEN]
        call    af_json_get_string
        test    rax, rax
        js      .protocol
        mov     rdi, rbx
        lea     rsi, [hm_name]
        mov     rdx, [rsp + MT_NAME_PTR]
        mov     rcx, [rsp + MT_NAME_LEN]
        call    af_mcp_http_slist_add_pair
        test    rax, rax
        js      .done
        mov     rdi, [rsp + MT_PARAMS]
        lea     rsi, [mk_arguments]
        lea     rdx, [rsp + MT_ARGS]
        call    af_json_member
        cmp     rax, AF_E_NOTFOUND
        je      .ok
        test    rax, rax
        js      .protocol

        mov     rax, [rbx + HX_CHILD]
        test    rax, rax
        jz      .protocol
        lea     rdi, [rax + MC_TOOLS]
        call    af_buf_len
        test    rax, rax
        jz      .ok
        mov     [rsp + MT_INV_LIMITS + AF_JSONLIM_MAX_BYTES], rax
        mov     qword [rsp + MT_INV_LIMITS + AF_JSONLIM_MAX_DEPTH], 64
        mov     qword [rsp + MT_INV_LIMITS + AF_JSONLIM_MAX_STRING], 1048576
        mov     qword [rsp + MT_INV_LIMITS + AF_JSONLIM_MAX_ELEMS], 100000
        mov     rax, [rbx + HX_CHILD]
        lea     rdi, [rax + MC_TOOLS]
        call    af_buf_data
        mov     rdi, rax
        mov     rsi, [rsp + MT_INV_LIMITS + AF_JSONLIM_MAX_BYTES]
        lea     rdx, [rsp + MT_INV_LIMITS]
        lea     rcx, [rsp + MT_INV_DOC]
        call    af_json_parse
        test    rax, rax
        js      .protocol
        lea     rdi, [rsp + MT_INV_DOC]
        call    af_json_doc_root
        mov     [rsp + MT_INV_ROOT], rax
        mov     rdi, rax
        call    af_json_array_count
        mov     [rsp + MT_INV_COUNT], rax
        mov     qword [rsp + MT_INDEX], 0
.tool_loop:
        mov     rax, [rsp + MT_INDEX]
        cmp     rax, [rsp + MT_INV_COUNT]
        jae     .ok
        mov     rdi, [rsp + MT_INV_ROOT]
        mov     rsi, rax
        lea     rdx, [rsp + MT_TOOL]
        call    af_json_array_at
        test    rax, rax
        js      .protocol
        mov     rdi, [rsp + MT_TOOL]
        lea     rsi, [mk_name]
        lea     rdx, [rsp + MT_TOOL_NAME]
        lea     rcx, [rsp + MT_TOOL_NLEN]
        call    af_json_get_string
        test    rax, rax
        js      .next_tool
        mov     rax, [rsp + MT_TOOL_NLEN]
        cmp     rax, [rsp + MT_NAME_LEN]
        jne     .next_tool
        mov     rdi, [rsp + MT_TOOL_NAME]
        mov     rsi, [rsp + MT_NAME_PTR]
        mov     rdx, rax
        call    af_mem_eq
        test    rax, rax
        jnz     .tool_found
.next_tool:
        inc     qword [rsp + MT_INDEX]
        jmp     .tool_loop
.tool_found:
        mov     rdi, [rsp + MT_TOOL]
        lea     rsi, [mk_input_schema]
        lea     rdx, [rsp + MT_SCHEMA]
        call    af_json_member
        test    rax, rax
        js      .ok
        mov     rdi, [rsp + MT_SCHEMA]
        lea     rsi, [mk_properties]
        lea     rdx, [rsp + MT_PROPS]
        call    af_json_member
        test    rax, rax
        js      .ok
        mov     rdi, [rsp + MT_PROPS]
        call    af_json_iter_begin
        mov     [rsp + MT_ITER], rax
.prop_loop:
        mov     rax, [rsp + MT_ITER]
        test    rax, rax
        jz      .ok
        mov     rdi, rax
        call    af_json_iter_key
        mov     [rsp + MT_PROP_KEY], rax
        mov     rdi, [rsp + MT_ITER]
        call    af_json_iter_value
        mov     [rsp + MT_PROP_SPEC], rax
        mov     rdi, rax
        lea     rsi, [mk_x_header]
        lea     rdx, [rsp + MT_SUFFIX]
        lea     rcx, [rsp + MT_SUFFIX_LEN]
        call    af_json_get_string
        cmp     rax, AF_E_NOTFOUND
        je      .next_prop
        test    rax, rax
        js      .protocol
        mov     rdi, [rsp + MT_ARGS]
        mov     rsi, [rsp + MT_PROP_KEY]
        lea     rdx, [rsp + MT_ARG]
        call    af_json_member
        cmp     rax, AF_E_NOTFOUND
        je      .next_prop
        test    rax, rax
        js      .protocol
        mov     rdi, rbx
        mov     rsi, [rsp + MT_SUFFIX]
        mov     rdx, [rsp + MT_SUFFIX_LEN]
        mov     rcx, [rsp + MT_ARG]
        call    af_mcp_http_add_param
        test    rax, rax
        js      .done
.next_prop:
        mov     rdi, [rsp + MT_PROPS]
        mov     rsi, [rsp + MT_ITER]
        call    af_json_iter_next
        mov     [rsp + MT_ITER], rax
        jmp     .prop_loop
.protocol:
        mov     rax, AF_E_MCP_PROTOCOL
        jmp     .done
.ok:
        xor     eax, eax
.done:
        mov     r15, rax
        lea     rdi, [rsp + MT_INV_DOC]
        call    af_json_doc_free
        lea     rdi, [rsp + MT_REQ_DOC]
        call    af_json_doc_free
        mov     rax, r15
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_mcp_http_modern_headers(x, method) -> af_status
        global af_mcp_http_modern_headers
af_mcp_http_modern_headers:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        lea     rsi, [hm_ctype]
        call    af_mcp_http_slist_add_static
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [hm_accept]
        call    af_mcp_http_slist_add_static
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [hm_expect]
        call    af_mcp_http_slist_add_static
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [hm_version]
        call    af_mcp_http_slist_add_static
        test    rax, rax
        js      .done
        mov     rdi, r12
        call    af_cstr_len
        mov     rcx, rax
        mov     rdi, rbx
        lea     rsi, [hm_method]
        mov     rdx, r12
        call    af_mcp_http_slist_add_pair
        test    rax, rax
        js      .done
        mov     rdi, r12
        lea     rsi, [mm_tools_call]
        call    af_cstr_eq
        test    rax, rax
        jz      .auth
        mov     rdi, rbx
        call    af_mcp_http_add_tool_metadata
        test    rax, rax
        js      .done
.auth:
        mov     rdi, rbx
        call    af_mcp_http_add_auth
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
