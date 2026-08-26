; AsmFlow — provider, route, and MCP-server array parsing.
;
; These three arrays carry the cross-entry rules that no per-field check can
; express: identifiers must be unique, a route target must name a provider that
; exists, `max_attempts` cannot exceed the number of targets, and a route that
; advertises the Responses family needs at least one target whose provider
; advertises it too.
;
; Resolution happens here as well. `RT_PROVIDER_INDEX` is filled in during
; validation so the router never has to search by string at request time; a
; target that cannot be resolved is a rejection, not a runtime surprise.

        bits 64
        default rel

%include "asmflow.inc"
%include "json.inc"
%include "config.inc"

        extern af_arena_calloc
        extern af_cstr_len
        extern af_mem_eq

        extern af_json_array_at
        extern af_json_type

        extern af_cfg_check_keys
        extern af_cfg_err_push_index
        extern af_cfg_err_truncate
        extern af_cfg_err_depth
        extern af_cfg_fail_here

        extern af_cfg_req_str
        extern af_cfg_req_int
        extern af_cfg_req_bool
        extern af_cfg_opt_bool
        extern af_cfg_req_enum
        extern af_cfg_req_obj
        extern af_cfg_req_arr

        extern af_cfg_intern
        extern af_cfg_id_valid
        extern af_cfg_model_alias_valid
        extern af_cfg_url_check
        extern af_cfg_load_auth
        extern af_cfg_load_timeouts
        extern af_cfg_load_capabilities
        extern af_cfg_load_health
        extern af_cfg_enum_lookup
        extern af_json_string_of

        extern k_providers, k_routes
        extern k_id, k_display_name, k_adapter, k_base_url, k_auth, k_enabled
        extern k_required, k_max_concurrency, k_timeouts, k_capabilities
        extern k_health, k_allow_insecure
        extern k_model_alias, k_endpoint_families, k_policy, k_fallback
        extern k_targets, k_max_attempts, k_retryable, k_provider_id
        extern k_upstream_model, k_priority, k_weight

        extern tbl_adapter, tbl_policy, tbl_endpoint_family, tbl_retryable
        extern keys_provider, keys_route, keys_fallback, keys_route_target

        extern m_bad_id, m_bad_alias, m_bad_url, m_dup_id, m_dup_alias
        extern m_unknown_provider, m_attempts, m_bad_enum_value
        extern m_responses_target

        section .text

; ---------------------------------------------------------------------------
; af_cfg_load_providers(json_t *root, af_config *cfg, af_cfg_error *err)
;   -> af_status
;
; Locals:
;   [rsp +  0] string pointer scratch      [rsp +  8] string length scratch
;   [rsp + 16] {array, count} pair         [rsp + 32] entry index
;   [rsp + 40] pointer depth before array  [rsp + 48] pointer depth per entry
;   [rsp + 56] current entry json_t *      [rsp + 64] nested-object scratch
; ---------------------------------------------------------------------------
        global af_cfg_load_providers
af_cfg_load_providers:
        AF_ENTER 96
        mov     rbx, rdi                ; root
        mov     r12, rsi                ; config
        mov     r13, rdx                ; error

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 40], rax

        mov     rdi, rbx
        lea     rsi, [k_providers]
        xor     edx, edx
        mov     rcx, AF_MAX_PROVIDERS
        mov     r8, r13
        lea     r9, [rsp + 16]
        call    af_cfg_req_arr
        test    rax, rax
        js      .done

        mov     rax, [rsp + 24]
        mov     [r12 + CFG_PROVIDER_COUNT], rax
        test    rax, rax
        jz      .finish

        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, rax
        mov     rdx, PRV_SIZE
        call    af_arena_calloc
        test    rax, rax
        jz      .nomem
        mov     [r12 + CFG_PROVIDERS], rax

        mov     qword [rsp + 32], 0
.entry_loop:
        mov     rax, [rsp + 32]
        cmp     rax, [r12 + CFG_PROVIDER_COUNT]
        jae     .finish

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 48], rax
        mov     rdi, r13
        mov     rsi, [rsp + 32]
        call    af_cfg_err_push_index

        mov     rdi, [rsp + 16]
        mov     rsi, [rsp + 32]
        lea     rdx, [rsp + 56]
        call    af_json_array_at
        test    rax, rax
        js      .done
        mov     r14, [rsp + 56]         ; provider object

        ; r15 = the destination record
        mov     rax, [rsp + 32]
        imul    rax, rax, PRV_SIZE
        add     rax, [r12 + CFG_PROVIDERS]
        mov     r15, rax

        mov     rdi, r14
        lea     rsi, [keys_provider]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        ; id
        mov     rdi, r14
        lea     rsi, [k_id]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_id_valid
        test    rax, rax
        jz      .bad_id
        mov     rax, [rsp + 8]
        mov     [r15 + PRV_ID_LEN], rax
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + PRV_ID]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        ; Uniqueness against every earlier entry. Quadratic, over at most 256
        ; entries loaded once at startup; an index would be more code than the
        ; comparison it replaces.
        mov     rdi, [r12 + CFG_PROVIDERS]
        mov     rsi, [rsp + 32]
        mov     rdx, PRV_SIZE
        mov     rcx, PRV_ID
        mov     r8, [r15 + PRV_ID]
        call    af_cfg_find_duplicate
        test    rax, rax
        jnz     .duplicate_id

        ; display_name
        mov     rdi, r14
        lea     rsi, [k_display_name]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .bad_name
        cmp     rax, 128
        ja      .bad_name
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + PRV_DISPLAY_NAME]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        ; adapter
        mov     rdi, r14
        lea     rsi, [k_adapter]
        lea     rdx, [tbl_adapter]
        mov     rcx, r13
        lea     r8, [r15 + PRV_ADAPTER]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done

        ; allow_insecure_private_http must be read before base_url, because the
        ; URL policy depends on it.
        mov     rdi, r14
        lea     rsi, [k_allow_insecure]
        mov     rdx, r13
        lea     rcx, [r15 + PRV_ALLOW_INSECURE]
        xor     r8d, r8d
        call    af_cfg_opt_bool
        test    rax, rax
        js      .done

        ; base_url
        mov     rdi, r14
        lea     rsi, [k_base_url]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .bad_url
        cmp     rax, 2048
        ja      .bad_url
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        mov     rdx, [r15 + PRV_ALLOW_INSECURE]
        xor     ecx, ecx
        call    af_cfg_url_check
        test    rax, rax
        js      .bad_url
        mov     rax, [rsp + 8]
        mov     [r15 + PRV_BASE_URL_LEN], rax
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + PRV_BASE_URL]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        ; enabled, required, max_concurrency
        mov     rdi, r14
        lea     rsi, [k_enabled]
        mov     rdx, r13
        lea     rcx, [r15 + PRV_ENABLED]
        call    af_cfg_req_bool
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_required]
        mov     rdx, r13
        lea     rcx, [r15 + PRV_REQUIRED]
        call    af_cfg_req_bool
        test    rax, rax
        js      .done

        mov     rdi, r14
        lea     rsi, [k_max_concurrency]
        mov     rdx, 1
        mov     rcx, 4096
        mov     r8, r13
        lea     r9, [r15 + PRV_MAX_CONCURRENCY]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        ; auth
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_auth]
        mov     rdx, r13
        lea     rcx, [rsp + 64]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        lea     rsi, [r12 + CFG_ARENA]
        mov     rdx, r13
        lea     rcx, [r15 + PRV_AUTH]
        call    af_cfg_load_auth
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        ; timeouts
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_timeouts]
        mov     rdx, r13
        lea     rcx, [rsp + 64]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        mov     rsi, r13
        lea     rdx, [r15 + PRV_TIMEOUTS]
        call    af_cfg_load_timeouts
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        ; capabilities
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_capabilities]
        mov     rdx, r13
        lea     rcx, [rsp + 64]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        mov     rsi, r13
        lea     rdx, [r15 + PRV_CAPABILITIES]
        call    af_cfg_load_capabilities
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        ; health
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_health]
        mov     rdx, r13
        lea     rcx, [rsp + 64]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        lea     rsi, [r12 + CFG_ARENA]
        mov     rdx, r13
        lea     rcx, [r15 + PRV_HEALTH]
        call    af_cfg_load_health
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        mov     rdi, r13
        mov     rsi, [rsp + 48]
        call    af_cfg_err_truncate
        inc     qword [rsp + 32]
        jmp     .entry_loop

.finish:
        mov     rdi, r13
        mov     rsi, [rsp + 40]
        call    af_cfg_err_truncate
        AF_LEAVE_OK

.bad_id:
        mov     rdi, r13
        lea     rsi, [k_id]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_id]
        call    af_cfg_fail_here
        AF_LEAVE
.duplicate_id:
        mov     rdi, r13
        lea     rsi, [k_id]
        mov     rdx, AF_E_CFG_DUPLICATE
        lea     rcx, [m_dup_id]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_name:
        mov     rdi, r13
        lea     rsi, [k_display_name]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_enum_value]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_url:
        mov     rdi, r13
        lea     rsi, [k_base_url]
        mov     rdx, AF_E_CFG_URL
        lea     rcx, [m_bad_url]
        call    af_cfg_fail_here
        AF_LEAVE
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_find_duplicate(void *base, u64 count, u64 stride, u64 field_offset,
;                       const char *candidate) -> i64 (1 = duplicate found)
;
; Scans the first `count` records for one whose string field equals
; `candidate`. Used for provider ids, route ids, model aliases, and MCP ids.
; ---------------------------------------------------------------------------
        global af_cfg_find_duplicate
af_cfg_find_duplicate:
        AF_ENTER 32
        test    r8, r8
        jz      .no
        mov     rbx, rdi                ; base
        mov     r12, rsi                ; count
        mov     [rsp + 16], rdx         ; stride
        mov     [rsp + 24], rcx         ; field offset
        mov     r13, r8                 ; candidate
        mov     rdi, r13
        call    af_cstr_len
        mov     [rsp], rax              ; candidate length
        xor     r14, r14
.loop:
        cmp     r14, r12
        jae     .no
        mov     rax, r14
        imul    rax, [rsp + 16]
        add     rax, rbx
        add     rax, [rsp + 24]
        mov     r15, [rax]              ; existing string
        test    r15, r15
        jz      .next
        mov     rdi, r15
        call    af_cstr_len
        cmp     rax, [rsp]
        jne     .next
        mov     rdi, r15
        mov     rsi, r13
        mov     rdx, rax
        call    af_mem_eq
        test    rax, rax
        jnz     .yes
.next:
        inc     r14
        jmp     .loop
.yes:
        mov     eax, 1
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_bitmask_from_array(json_t *array, u64 count, const void *table,
;                           af_cfg_error *err, u64 *out) -> af_status
;
; Reads an array of enum strings into a bitmask, rejecting an unknown member and
; a repeated one. Used for `endpoint_families` and `fallback.retryable`.
; ---------------------------------------------------------------------------
        global af_cfg_bitmask_from_array
af_cfg_bitmask_from_array:
        AF_ENTER 64
        mov     rbx, rdi                ; array
        mov     r12, rsi                ; count
        mov     [rsp + 40], rdx         ; table
        mov     r13, rcx                ; error
        mov     r14, r8                 ; out
        xor     r15, r15                ; accumulated bits

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 48], rax

        xor     rax, rax
        mov     [rsp + 32], rax         ; index
.loop:
        mov     rax, [rsp + 32]
        cmp     rax, r12
        jae     .ok
        mov     rdi, r13
        mov     rsi, rax
        call    af_cfg_err_push_index
        mov     rdi, rbx
        mov     rsi, [rsp + 32]
        lea     rdx, [rsp + 16]
        call    af_json_array_at
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 16]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_json_string_of
        test    rax, rax
        js      .bad_member
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        mov     rdx, [rsp + 40]
        lea     rcx, [rsp + 24]
        call    af_cfg_enum_lookup
        test    rax, rax
        js      .bad_member
        mov     rax, [rsp + 24]
        test    r15, rax
        jnz     .bad_member             ; uniqueItems
        or      r15, rax
        mov     rdi, r13
        mov     rsi, [rsp + 48]
        call    af_cfg_err_truncate
        inc     qword [rsp + 32]
        jmp     .loop
.ok:
        mov     [r14], r15
        AF_LEAVE_OK
.bad_member:
        mov     rdi, r13
        xor     esi, esi
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_enum_value]
        call    af_cfg_fail_here
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_routes(json_t *root, af_config *cfg, af_cfg_error *err)
;   -> af_status
;
; Must run after af_cfg_load_providers: target resolution needs the provider
; table.
; ---------------------------------------------------------------------------
        global af_cfg_load_routes
af_cfg_load_routes:
        AF_ENTER 128
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 40], rax

        mov     rdi, rbx
        lea     rsi, [k_routes]
        xor     edx, edx
        mov     rcx, AF_MAX_ROUTES
        mov     r8, r13
        lea     r9, [rsp + 16]
        call    af_cfg_req_arr
        test    rax, rax
        js      .done

        mov     rax, [rsp + 24]
        mov     [r12 + CFG_ROUTE_COUNT], rax
        test    rax, rax
        jz      .finish

        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, rax
        mov     rdx, RTE_SIZE
        call    af_arena_calloc
        test    rax, rax
        jz      .nomem
        mov     [r12 + CFG_ROUTES], rax

        mov     qword [rsp + 32], 0
.entry_loop:
        mov     rax, [rsp + 32]
        cmp     rax, [r12 + CFG_ROUTE_COUNT]
        jae     .finish

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 48], rax
        mov     rdi, r13
        mov     rsi, [rsp + 32]
        call    af_cfg_err_push_index

        mov     rdi, [rsp + 16]
        mov     rsi, [rsp + 32]
        lea     rdx, [rsp + 56]
        call    af_json_array_at
        test    rax, rax
        js      .done
        mov     r14, [rsp + 56]         ; route object

        mov     rax, [rsp + 32]
        imul    rax, rax, RTE_SIZE
        add     rax, [r12 + CFG_ROUTES]
        mov     r15, rax

        mov     rdi, r14
        lea     rsi, [keys_route]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        ; id
        mov     rdi, r14
        lea     rsi, [k_id]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_id_valid
        test    rax, rax
        jz      .bad_id
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + RTE_ID]
        call    af_cfg_intern
        test    rax, rax
        js      .done
        mov     rdi, [r12 + CFG_ROUTES]
        mov     rsi, [rsp + 32]
        mov     rdx, RTE_SIZE
        mov     rcx, RTE_ID
        mov     r8, [r15 + RTE_ID]
        call    af_cfg_find_duplicate
        test    rax, rax
        jnz     .duplicate_id

        ; model_alias, unique across routes because a request selects by it
        mov     rdi, r14
        lea     rsi, [k_model_alias]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_model_alias_valid
        test    rax, rax
        jz      .bad_alias
        mov     rax, [rsp + 8]
        mov     [r15 + RTE_MODEL_ALIAS_LEN], rax
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + RTE_MODEL_ALIAS]
        call    af_cfg_intern
        test    rax, rax
        js      .done
        mov     rdi, [r12 + CFG_ROUTES]
        mov     rsi, [rsp + 32]
        mov     rdx, RTE_SIZE
        mov     rcx, RTE_MODEL_ALIAS
        mov     r8, [r15 + RTE_MODEL_ALIAS]
        call    af_cfg_find_duplicate
        test    rax, rax
        jnz     .duplicate_alias

        mov     rdi, r14
        lea     rsi, [k_enabled]
        mov     rdx, r13
        lea     rcx, [r15 + RTE_ENABLED]
        call    af_cfg_req_bool
        test    rax, rax
        js      .done

        ; endpoint_families
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_endpoint_families]
        mov     rdx, 1
        mov     rcx, 2
        mov     r8, r13
        lea     r9, [rsp + 80]
        call    af_cfg_req_arr
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 80]
        mov     rsi, [rsp + 88]
        lea     rdx, [tbl_endpoint_family]
        mov     rcx, r13
        lea     r8, [r15 + RTE_ENDPOINT_FAMILIES]
        call    af_cfg_bitmask_from_array
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        mov     rdi, r14
        lea     rsi, [k_policy]
        lea     rdx, [tbl_policy]
        mov     rcx, r13
        lea     r8, [r15 + RTE_POLICY]
        call    af_cfg_req_enum
        test    rax, rax
        js      .done

        ; targets first, so max_attempts can be checked against their count
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_targets]
        mov     rdx, 1
        mov     rcx, AF_MAX_ROUTE_TARGETS
        mov     r8, r13
        lea     r9, [rsp + 80]
        call    af_cfg_req_arr
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 80]
        mov     rsi, [rsp + 88]
        mov     rdx, r12
        mov     rcx, r13
        mov     r8, r15
        call    af_cfg_load_targets
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        ; fallback
        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 72], rax
        mov     rdi, r14
        lea     rsi, [k_fallback]
        mov     rdx, r13
        lea     rcx, [rsp + 64]
        call    af_cfg_req_obj
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 64]
        mov     rsi, r13
        mov     rdx, r15
        call    af_cfg_load_fallback
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, [rsp + 72]
        call    af_cfg_err_truncate

        ; A Responses route needs a target that can actually serve Responses.
        ; docs/CONFIGURATION.md 10: "A Responses request can use only a target
        ; that advertises Responses unless an explicit converter adapter
        ; exists." There is no converter in 1.0, so this is a load-time rule.
        mov     rax, [r15 + RTE_ENDPOINT_FAMILIES]
        test    rax, AF_EPF_RESPONSES
        jz      .families_ok
        mov     rdi, r12
        mov     rsi, r15
        mov     rdx, AF_CAP_RESPONSES
        call    af_cfg_route_has_capable_target
        test    rax, rax
        jz      .no_responses_target
.families_ok:

        mov     rdi, r13
        mov     rsi, [rsp + 48]
        call    af_cfg_err_truncate
        inc     qword [rsp + 32]
        jmp     .entry_loop

.finish:
        mov     rdi, r13
        mov     rsi, [rsp + 40]
        call    af_cfg_err_truncate
        AF_LEAVE_OK

.bad_id:
        mov     rdi, r13
        lea     rsi, [k_id]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_id]
        call    af_cfg_fail_here
        AF_LEAVE
.duplicate_id:
        mov     rdi, r13
        lea     rsi, [k_id]
        mov     rdx, AF_E_CFG_DUPLICATE
        lea     rcx, [m_dup_id]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_alias:
        mov     rdi, r13
        lea     rsi, [k_model_alias]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_alias]
        call    af_cfg_fail_here
        AF_LEAVE
.duplicate_alias:
        mov     rdi, r13
        lea     rsi, [k_model_alias]
        mov     rdx, AF_E_CFG_DUPLICATE
        lea     rcx, [m_dup_alias]
        call    af_cfg_fail_here
        AF_LEAVE
.no_responses_target:
        mov     rdi, r13
        lea     rsi, [k_targets]
        mov     rdx, AF_E_CFG_REF
        lea     rcx, [m_responses_target]
        call    af_cfg_fail_here
        AF_LEAVE
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_targets(json_t *array, u64 count, af_config *cfg,
;                     af_cfg_error *err, af_cfg_route *route) -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_load_targets
af_cfg_load_targets:
        AF_ENTER 96
        mov     rbx, rdi                ; array
        mov     [rsp + 40], rsi         ; count
        mov     r12, rdx                ; config
        mov     r13, rcx                ; error
        mov     r14, r8                 ; route

        mov     [r14 + RTE_TARGET_COUNT], rsi
        lea     rdi, [r12 + CFG_ARENA]
        mov     rdx, RT_SIZE
        call    af_arena_calloc
        test    rax, rax
        jz      .nomem
        mov     [r14 + RTE_TARGETS], rax

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp + 48], rax

        mov     qword [rsp + 32], 0
.loop:
        mov     rax, [rsp + 32]
        cmp     rax, [rsp + 40]
        jae     .ok

        mov     rdi, r13
        mov     rsi, rax
        call    af_cfg_err_push_index
        mov     rdi, rbx
        mov     rsi, [rsp + 32]
        lea     rdx, [rsp + 56]
        call    af_json_array_at
        test    rax, rax
        js      .done

        mov     rax, [rsp + 32]
        imul    rax, rax, RT_SIZE
        add     rax, [r14 + RTE_TARGETS]
        mov     r15, rax

        mov     rdi, [rsp + 56]
        lea     rsi, [keys_route_target]
        mov     rdx, r13
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, [rsp + 56]
        lea     rsi, [k_provider_id]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        call    af_cfg_id_valid
        test    rax, rax
        jz      .bad_id
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + RT_PROVIDER_ID]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        ; Resolve now: the router must never search by string at request time.
        mov     rdi, r12
        mov     rsi, [r15 + RT_PROVIDER_ID]
        lea     rdx, [r15 + RT_PROVIDER_INDEX]
        call    af_cfg_resolve_provider
        test    rax, rax
        js      .unknown_provider

        mov     rdi, [rsp + 56]
        lea     rsi, [k_upstream_model]
        mov     rdx, r13
        lea     rcx, [rsp]
        lea     r8, [rsp + 8]
        call    af_cfg_req_str
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .bad_model
        cmp     rax, 256
        ja      .bad_model
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        lea     rcx, [r15 + RT_UPSTREAM_MODEL]
        call    af_cfg_intern
        test    rax, rax
        js      .done

        mov     rdi, [rsp + 56]
        lea     rsi, [k_priority]
        mov     rdx, -2147483648
        mov     rcx, 2147483647
        mov     r8, r13
        lea     r9, [r15 + RT_PRIORITY]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, [rsp + 56]
        lea     rsi, [k_weight]
        mov     rdx, 1
        mov     rcx, 1000000
        mov     r8, r13
        lea     r9, [r15 + RT_WEIGHT]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rdi, r13
        mov     rsi, [rsp + 48]
        call    af_cfg_err_truncate
        inc     qword [rsp + 32]
        jmp     .loop
.ok:
        AF_LEAVE_OK
.bad_id:
        mov     rdi, r13
        lea     rsi, [k_provider_id]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_id]
        call    af_cfg_fail_here
        AF_LEAVE
.unknown_provider:
        mov     rdi, r13
        lea     rsi, [k_provider_id]
        mov     rdx, AF_E_CFG_REF
        lea     rcx, [m_unknown_provider]
        call    af_cfg_fail_here
        AF_LEAVE
.bad_model:
        mov     rdi, r13
        lea     rsi, [k_upstream_model]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_bad_enum_value]
        call    af_cfg_fail_here
        AF_LEAVE
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_load_fallback(json_t *obj, af_cfg_error *err, af_cfg_route *route)
;   -> af_status
;
; SECURITY_MODEL.md 10: a retry may duplicate billable work, so the attempt
; count is bounded by the number of distinct targets. `max_attempts` larger than
; the target count could only be satisfied by trying a target twice.
; ---------------------------------------------------------------------------
        global af_cfg_load_fallback
af_cfg_load_fallback:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi                ; error
        mov     r13, rdx                ; route

        mov     rdi, rbx
        lea     rsi, [keys_fallback]
        mov     rdx, r12
        call    af_cfg_check_keys
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_enabled]
        mov     rdx, r12
        lea     rcx, [r13 + RTE_FB_ENABLED]
        call    af_cfg_req_bool
        test    rax, rax
        js      .done

        mov     rdi, rbx
        lea     rsi, [k_max_attempts]
        mov     rdx, 1
        mov     rcx, AF_MAX_ATTEMPTS
        mov     r8, r12
        lea     r9, [r13 + RTE_FB_MAX_ATTEMPTS]
        call    af_cfg_req_int
        test    rax, rax
        js      .done

        mov     rax, [r13 + RTE_FB_MAX_ATTEMPTS]
        cmp     rax, [r13 + RTE_TARGET_COUNT]
        ja      .too_many_attempts

        mov     rdi, r12
        call    af_cfg_err_depth
        mov     [rsp + 32], rax
        mov     rdi, rbx
        lea     rsi, [k_retryable]
        xor     edx, edx
        mov     rcx, 32
        mov     r8, r12
        lea     r9, [rsp + 16]
        call    af_cfg_req_arr
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 16]
        mov     rsi, [rsp + 24]
        lea     rdx, [tbl_retryable]
        mov     rcx, r12
        lea     r8, [r13 + RTE_FB_RETRYABLE]
        call    af_cfg_bitmask_from_array
        test    rax, rax
        js      .done
        mov     rdi, r12
        mov     rsi, [rsp + 32]
        call    af_cfg_err_truncate
        AF_LEAVE_OK

.too_many_attempts:
        mov     rdi, r12
        lea     rsi, [k_max_attempts]
        mov     rdx, AF_E_CFG_SCHEMA
        lea     rcx, [m_attempts]
        call    af_cfg_fail_here
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_resolve_provider(af_config *cfg, const char *provider_id, i64 *out)
;   -> af_status
;
; AF_E_NOTFOUND when no provider carries that id.
; ---------------------------------------------------------------------------
        global af_cfg_resolve_provider
af_cfg_resolve_provider:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, r12
        call    af_cstr_len
        mov     [rsp], rax
        xor     r14, r14
.loop:
        cmp     r14, [rbx + CFG_PROVIDER_COUNT]
        jae     .notfound
        mov     rax, r14
        imul    rax, rax, PRV_SIZE
        add     rax, [rbx + CFG_PROVIDERS]
        mov     r15, [rax + PRV_ID]
        test    r15, r15
        jz      .next
        mov     rax, [rax + PRV_ID_LEN]
        cmp     rax, [rsp]
        jne     .next
        mov     rdi, r15
        mov     rsi, r12
        mov     rdx, [rsp]
        call    af_mem_eq
        test    rax, rax
        jnz     .found
.next:
        inc     r14
        jmp     .loop
.found:
        test    r13, r13
        jz      .ok
        mov     [r13], r14
.ok:
        AF_LEAVE_OK
.notfound:
        test    r13, r13
        jz      .fail
        mov     qword [r13], -1
.fail:
        AF_LEAVE_ERR AF_E_NOTFOUND

; ---------------------------------------------------------------------------
; af_cfg_route_has_capable_target(af_config *cfg, af_cfg_route *route,
;                                 u64 capability_bit) -> i64 (1 = yes)
; ---------------------------------------------------------------------------
        global af_cfg_route_has_capable_target
af_cfg_route_has_capable_target:
        AF_ENTER 16
        mov     rbx, rdi                ; config
        mov     r12, rsi                ; route
        mov     r13, rdx                ; capability bit
        xor     r14, r14
.loop:
        cmp     r14, [r12 + RTE_TARGET_COUNT]
        jae     .no
        mov     rax, r14
        imul    rax, rax, RT_SIZE
        add     rax, [r12 + RTE_TARGETS]
        mov     rcx, [rax + RT_PROVIDER_INDEX]
        cmp     rcx, 0
        jl      .next
        mov     rax, rcx
        imul    rax, rax, PRV_SIZE
        add     rax, [rbx + CFG_PROVIDERS]
        mov     rax, [rax + PRV_CAPABILITIES]
        test    rax, r13
        jnz     .yes
.next:
        inc     r14
        jmp     .loop
.yes:
        mov     eax, 1
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE
