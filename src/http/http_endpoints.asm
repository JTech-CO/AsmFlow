; AsmFlow — endpoint dispatch and the endpoint bodies.
;
; One function decides what a complete request becomes: path, method,
; credential, then the handler. The order matters and is fixed. An unknown path
; is answered before the method is considered, because "no such endpoint" is
; true regardless of how it was asked for; the credential is checked before any
; handler runs, so no endpoint can accidentally answer without one.
;
; docs/API_CONTRACT.md 3 and 4 define what the three implemented endpoints say.
; `/healthz` reports process liveness and nothing else — it is the endpoint that
; must still answer when everything else is broken, so it reads no
; configuration, opens no database handle, and cannot fail for a reason outside
; this process.
;
; `/v1/responses` and `/v1/chat/completions` are dispatch stubs in this build.
; They apply the whole request-side contract — method, media type, body ceiling,
; JSON validity, the `model` field, and whether that alias names an enabled
; route — and then report that the upstream data plane is not present, which is
; a different fact from the daemon being unready and is reported as its own
; code. Returning an empty completion instead would be a lie a client could not
; distinguish from a real one.

        bits 64
        default rel

%include "asmflow.inc"
%include "http.inc"
%include "config.inc"
%include "json.inc"
%include "jsonw.inc"
%include "runtime.inc"
%include "errors.inc"
%include "mcp.inc"

        extern af_buf_append
        extern af_buf_clear
        extern af_buf_data
        extern af_buf_len

        extern af_jw_init
        extern af_jw_finish
        extern af_jw_begin_object
        extern af_jw_end_object
        extern af_jw_begin_array
        extern af_jw_end_array
        extern af_jw_key
        extern af_jw_string
        extern af_jw_string_n
        extern af_jw_member_string
        extern af_jw_member_uint
        extern af_jw_member_bool

        extern af_http_write_head
        extern af_http_build_error_body
        extern af_http_error_def
        extern af_http_fault
        extern af_http_check_auth

        ; The upstream engine. A generation request is handed over and the
        ; connection suspends; everything else about it happens in
        ; src/providers/.
        extern af_prov_exchange_start
        extern af_prov_family_for_endpoint
        extern af_http_ctype_is

        extern af_id_generate
        extern af_monotonic_ns
        extern af_version_str
        extern af_mem_copy
        extern af_mem_zero
        extern af_mem_eq
        extern af_cstr_len

        extern af_json_parse
        extern af_json_doc_free
        extern af_json_doc_root
        extern af_json_type
        extern af_json_member
        extern af_json_string_of

        extern af_db_is_open
        extern af_repo_get_operator_disabled
        extern af_mcp_required_ready
        extern af_mcp_required_counts

        section .rodata

k_status:     db "status", 0
k_version:    db "version", 0
k_uptime_ms:  db "uptime_ms", 0
k_config_rev: db "config_revision", 0
k_database:   db "database", 0
k_listener:   db "listener", 0
k_routes:     db "routes", 0
k_enabled:    db "enabled", 0
k_eligible:   db "eligible", 0
k_mcp:        db "mcp", 0
k_required:   db "required", 0
k_ready_count: db "ready", 0
k_object:     db "object", 0
k_data:       db "data", 0
k_id:         db "id", 0
k_created:    db "created", 0
k_owned_by:   db "owned_by", 0
k_model:      db "model", 0

v_ok:         db "ok", 0
v_ready:      db "ready", 0
v_not_ready:  db "not_ready", 0
v_list:       db "list", 0
v_model:      db "model", 0
v_asmflow:    db "asmflow", 0
v_down:       db "down", 0

ctype_json:   db "application/json", 0

        section .text

; ---------------------------------------------------------------------------
; af_http_begin_body(af_http_conn *c, af_jsonw *w) -> af_status
;
; Points a fresh writer at the connection's response buffer.
; ---------------------------------------------------------------------------
        global af_http_begin_body
af_http_begin_body:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        lea     rdi, [rbx + HC_RESPONSE]
        call    af_buf_clear
        mov     rdi, r12
        lea     rsi, [rbx + HC_RESPONSE]
        call    af_jw_init
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_commit(af_http_conn *c, u64 status, u64 head_flags) -> af_status
;
; Queues the head and the response buffer as one unit. Nothing reaches the
; outbox until the body's length is known, so a response can never be framed
; with a length it does not have.
; ---------------------------------------------------------------------------
        global af_http_commit
af_http_commit:
        AF_ENTER 48
        mov     rbx, rdi
        mov     [rsp], rsi                      ; status
        mov     [rsp + 8], rdx                  ; head flags

        ; docs/API_CONTRACT.md 2: generation responses are not to be stored.
        ; Deciding it here rather than at each call site means it holds for the
        ; errors those endpoints produce as well as for their successes.
        cmp     qword [rbx + HC_ENDPOINT], AF_EP_RESPONSES
        jb      .no_store_decided
        or      qword [rsp + 8], AF_HEAD_NO_STORE
.no_store_decided:

        lea     rdi, [rbx + HC_RESPONSE]
        call    af_buf_len
        mov     [rsp + 16], rax

        ; A refused message ends the connection, so its response says so. The
        ; client is told to stop reusing the connection in the same breath it is
        ; told what was wrong, rather than discovering it on the next write.
        xor     eax, eax
        test    qword [rbx + HC_FLAGS], HC_F_KEEP_ALIVE
        jz      .keep_alive_decided
        test    qword [rbx + HC_FLAGS], HC_F_FAULT | HC_F_CLOSING
        jnz     .keep_alive_decided
        mov     eax, 1
.keep_alive_decided:
        mov     [rsp + 24], rax

        lea     rdi, [rbx + HC_OUTBOX]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 16]
        lea     rcx, [rbx + HC_REQUEST_ID]
        mov     r8, [rsp + 24]
        mov     r9, [rsp + 8]
        call    af_http_write_head
        test    rax, rax
        js      .done

        lea     rdi, [rbx + HC_RESPONSE]
        call    af_buf_data
        mov     r12, rax
        test    r12, r12
        jz      .no_body
        lea     rdi, [rbx + HC_OUTBOX]
        mov     rsi, r12
        mov     rdx, [rsp + 16]
        call    af_buf_append
        test    rax, rax
        js      .done
.no_body:
        or      qword [rbx + HC_FLAGS], HC_F_RESPONDED
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_assign_request_id(af_http_conn *c) -> void
; ---------------------------------------------------------------------------
        global af_http_assign_request_id
af_http_assign_request_id:
        AF_ENTER 0
        mov     rbx, rdi
        lea     rdi, [rbx + HC_REQUEST_ID]
        mov     rsi, AF_HTTP_REQUEST_ID_MAX
        call    af_mem_zero
        lea     rdi, [rbx + HC_REQUEST_ID]
        call    af_id_generate
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_send_error(af_http_conn *c, u64 error_id) -> af_status
;
; The one path by which a client learns a request was refused.
; ---------------------------------------------------------------------------
        global af_http_send_error
af_http_send_error:
        AF_ENTER 32
        mov     rbx, rdi
        mov     rdi, rsi
        call    af_http_error_def
        mov     r12, rax

        ; The idle sweep answers without having gone through the dispatcher, so
        ; the id is minted here when nothing has minted one yet. A response
        ; without a correlation id is a response an operator cannot match to
        ; anything in a client's log.
        cmp     byte [rbx + HC_REQUEST_ID], 0
        jne     .have_id
        mov     rdi, rbx
        call    af_http_assign_request_id
.have_id:

        lea     rdi, [rbx + HC_RESPONSE]
        call    af_buf_clear
        lea     rdi, [rbx + HC_RESPONSE]
        mov     rsi, r12
        lea     rdx, [rbx + HC_REQUEST_ID]
        call    af_http_build_error_body
        test    rax, rax
        js      .done

        mov     rdi, rbx
        mov     rsi, [r12 + HED_STATUS]
        mov     rdx, [r12 + HED_HEAD_FLAGS]
        call    af_http_commit
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_route_for_alias(af_config *cfg, const char *alias, u64 len)
;   -> af_cfg_route * (NULL when no route names it)
; ---------------------------------------------------------------------------
        global af_http_route_for_alias
af_http_route_for_alias:
        AF_ENTER 32
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        test    rsi, rsi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        xor     r14, r14
.loop:
        cmp     r14, [rbx + CFG_ROUTE_COUNT]
        jae     .none
        mov     rax, r14
        imul    rax, rax, RTE_SIZE
        add     rax, [rbx + CFG_ROUTES]
        mov     r15, rax
        cmp     qword [r15 + RTE_MODEL_ALIAS_LEN], r13
        jne     .next
        mov     rdi, [r15 + RTE_MODEL_ALIAS]
        mov     rsi, r12
        mov     rdx, r13
        call    af_mem_eq
        test    rax, rax
        jnz     .found
.next:
        inc     r14
        jmp     .loop
.found:
        mov     rax, r15
        AF_LEAVE
.none:
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_route_is_eligible(void *rt, af_config *cfg, af_cfg_route *route)
;   -> i64 (1 = at least one target could serve it)
;
; Eligibility at this milestone means a target whose provider is enabled in the
; configuration and has not been disabled by an operator. Health state and
; circuit breaking join this in M7; until they exist, treating an unhealthy
; provider as eligible is the honest answer, because nothing is measuring it.
; ---------------------------------------------------------------------------
        global af_http_route_is_eligible
af_http_route_is_eligible:
        AF_ENTER 48
        xor     eax, eax
        test    rsi, rsi
        jz      .done
        test    rdx, rdx
        jz      .done
        mov     rbx, rdi                        ; runtime, may be NULL
        mov     r12, rsi                        ; config
        mov     r13, rdx                        ; route
        xor     r14, r14
.loop:
        cmp     r14, [r13 + RTE_TARGET_COUNT]
        jae     .none
        mov     rax, r14
        imul    rax, rax, RTG_SIZE
        add     rax, [r13 + RTE_TARGETS]
        mov     r15, rax

        mov     rax, [r15 + RTG_PROVIDER_INDEX]
        cmp     rax, 0
        jl      .next
        cmp     rax, [r12 + CFG_PROVIDER_COUNT]
        jae     .next
        imul    rax, rax, PRV_SIZE
        add     rax, [r12 + CFG_PROVIDERS]
        mov     [rsp], rax                      ; provider
        cmp     qword [rax + PRV_ENABLED], 0
        je      .next

        ; Operator state lives in the database rather than the file, precisely
        ; so a reload cannot re-enable something somebody turned off. A daemon
        ; without a database — a unit test standing up a listener alone — falls
        ; back to the configuration's own answer.
        test    rbx, rbx
        jz      .eligible
        mov     rdi, [rbx + RT_DB]
        test    rdi, rdi
        jz      .eligible
        call    af_db_is_open
        test    rax, rax
        jz      .eligible
        mov     rdi, [rbx + RT_DB]
        mov     rax, [rsp]
        mov     rsi, [rax + PRV_ID]
        lea     rdx, [rsp + 8]
        mov     qword [rsp + 8], 0
        call    af_repo_get_operator_disabled
        test    rax, rax
        js      .eligible                       ; no row yet: not disabled
        cmp     qword [rsp + 8], 0
        jne     .next
.eligible:
        mov     eax, 1
        AF_LEAVE
.next:
        inc     r14
        jmp     .loop
.none:
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_ep_healthz(af_http_conn *c) -> af_status
;
; Liveness. If this code runs at all, the event loop dispatched to it, which is
; the whole claim. docs/API_CONTRACT.md 3.
; ---------------------------------------------------------------------------
        global af_http_ep_healthz
af_http_ep_healthz:
        AF_ENTER (JW_SIZE + 32)
        mov     rbx, rdi
        mov     rdi, rbx
        lea     rsi, [rsp]
        call    af_http_begin_body
        test    rax, rax
        js      .done

        lea     rdi, [rsp]
        call    af_jw_begin_object
        lea     rdi, [rsp]
        lea     rsi, [k_status]
        lea     rdx, [v_ok]
        call    af_jw_member_string
        ; The version span is static but not NUL-terminated, so it is written
        ; by length rather than as a C string.
        lea     rdi, [rsp + JW_SIZE]
        call    af_version_str
        mov     r12, rax
        lea     rdi, [rsp]
        lea     rsi, [k_version]
        call    af_jw_key
        lea     rdi, [rsp]
        mov     rsi, r12
        mov     rdx, [rsp + JW_SIZE]
        call    af_jw_string_n

        mov     rdi, rbx
        call    af_http_uptime_ms
        mov     [rsp + JW_SIZE], rax
        lea     rdi, [rsp]
        lea     rsi, [k_uptime_ms]
        mov     rdx, [rsp + JW_SIZE]
        call    af_jw_member_uint

        lea     rdi, [rsp]
        call    af_jw_end_object
        lea     rdi, [rsp]
        call    af_jw_finish
        test    rax, rax
        js      .done

        mov     rdi, rbx
        mov     rsi, 200
        xor     edx, edx
        call    af_http_commit
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_uptime_ms(af_http_conn *c) -> u64
; ---------------------------------------------------------------------------
        global af_http_uptime_ms
af_http_uptime_ms:
        AF_ENTER 32
        xor     eax, eax
        mov     rbx, rdi
        mov     r12, [rbx + HC_SERVER]
        test    r12, r12
        jz      .done
        mov     r13, [r12 + HS_RT]
        test    r13, r13
        jz      .done
        lea     rdi, [rsp]
        mov     qword [rsp], 0
        call    af_monotonic_ns
        test    rax, rax
        js      .zero
        mov     rax, [rsp]
        sub     rax, [r13 + RT_STARTED_NS]
        jc      .zero
        xor     edx, edx
        mov     rcx, 1000000
        div     rcx
        AF_LEAVE
.zero:
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_ep_readyz(af_http_conn *c) -> af_status
;
; Dependency readiness, which is a different question from liveness: a daemon
; whose database went away is alive and not ready. docs/API_CONTRACT.md 3.
; ---------------------------------------------------------------------------
        global af_http_ep_readyz
af_http_ep_readyz:
        AF_ENTER (JW_SIZE + 64)
        mov     rbx, rdi
        mov     r12, [rbx + HC_SERVER]
        mov     r13, 0
        test    r12, r12
        jz      .no_rt
        mov     r13, [r12 + HS_RT]
.no_rt:

        ; Ready means: startup finished, no shutdown in progress, and the
        ; database is open.
        xor     r14, r14                        ; ready
        test    r13, r13
        jz      .state_known
        cmp     qword [r13 + RT_READY], 0
        je      .state_known
        cmp     qword [r13 + RT_SHUTTING_DOWN], 0
        jne     .state_known
        mov     rdi, [r13 + RT_DB]
        test    rdi, rdi
        jz      .state_known
        call    af_db_is_open
        test    rax, rax
        jz      .state_known
        mov     rdi, [r13 + RT_MCP]
        call    af_mcp_required_ready
        test    rax, rax
        jz      .state_known
        mov     r14, 1
.state_known:
        mov     [rsp + JW_SIZE], r14

        mov     rdi, rbx
        lea     rsi, [rsp]
        call    af_http_begin_body
        test    rax, rax
        js      .done

        lea     rdi, [rsp]
        call    af_jw_begin_object
        lea     rdi, [rsp]
        lea     rsi, [k_status]
        call    af_jw_key
        cmp     qword [rsp + JW_SIZE], 0
        je      .say_not_ready
        lea     rsi, [v_ready]
        jmp     .say_status
.say_not_ready:
        lea     rsi, [v_not_ready]
.say_status:
        lea     rdi, [rsp]
        call    af_jw_string

        xor     r15, r15                        ; config revision
        test    r13, r13
        jz      .no_cfg_rev
        mov     rax, [r13 + RT_CONFIG]
        test    rax, rax
        jz      .no_cfg_rev
        mov     r15, [rax + CFG_REVISION]
.no_cfg_rev:
        lea     rdi, [rsp]
        lea     rsi, [k_config_rev]
        mov     rdx, r15
        call    af_jw_member_uint

        lea     rdi, [rsp]
        lea     rsi, [k_database]
        call    af_jw_key
        xor     r15, r15
        test    r13, r13
        jz      .db_known
        mov     rdi, [r13 + RT_DB]
        test    rdi, rdi
        jz      .db_known
        call    af_db_is_open
        mov     r15, rax
.db_known:
        test    r15, r15
        jz      .db_down
        lea     rsi, [v_ready]
        jmp     .db_emit
.db_down:
        lea     rsi, [v_down]
.db_emit:
        lea     rdi, [rsp]
        call    af_jw_string

        lea     rdi, [rsp]
        lea     rsi, [k_listener]
        lea     rdx, [v_ready]
        call    af_jw_member_string

        ; Bounded dependency detail: counts explain readiness without exposing
        ; server identifiers, stderr, inventory, or any payload-derived value.
        mov     qword [rsp + JW_SIZE + 8], 0
        mov     qword [rsp + JW_SIZE + 16], 0
        test    r13, r13
        jz      .mcp_counts_known
        mov     rdi, [r13 + RT_MCP]
        lea     rsi, [rsp + JW_SIZE + 8]
        lea     rdx, [rsp + JW_SIZE + 16]
        call    af_mcp_required_counts
.mcp_counts_known:
        lea     rdi, [rsp]
        lea     rsi, [k_mcp]
        call    af_jw_key
        lea     rdi, [rsp]
        call    af_jw_begin_object
        lea     rdi, [rsp]
        lea     rsi, [k_required]
        mov     rdx, [rsp + JW_SIZE + 8]
        call    af_jw_member_uint
        lea     rdi, [rsp]
        lea     rsi, [k_ready_count]
        mov     rdx, [rsp + JW_SIZE + 16]
        call    af_jw_member_uint
        lea     rdi, [rsp]
        call    af_jw_end_object

        ; Route counts, which is what makes this endpoint tell an operator
        ; something they can act on rather than just a colour.
        mov     rdi, r13
        call    af_http_count_routes
        mov     [rsp + JW_SIZE + 8], rax        ; enabled
        mov     [rsp + JW_SIZE + 16], rdx       ; eligible

        lea     rdi, [rsp]
        lea     rsi, [k_routes]
        call    af_jw_key
        lea     rdi, [rsp]
        call    af_jw_begin_object
        lea     rdi, [rsp]
        lea     rsi, [k_enabled]
        mov     rdx, [rsp + JW_SIZE + 8]
        call    af_jw_member_uint
        lea     rdi, [rsp]
        lea     rsi, [k_eligible]
        mov     rdx, [rsp + JW_SIZE + 16]
        call    af_jw_member_uint
        lea     rdi, [rsp]
        call    af_jw_end_object

        lea     rdi, [rsp]
        call    af_jw_end_object
        lea     rdi, [rsp]
        call    af_jw_finish
        test    rax, rax
        js      .done

        mov     rdi, rbx
        mov     rsi, 200
        cmp     qword [rsp + JW_SIZE], 0
        jne     .status_chosen
        mov     rsi, 503
.status_chosen:
        xor     edx, edx
        call    af_http_commit
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_count_routes(void *rt) -> rax = enabled, rdx = eligible
; ---------------------------------------------------------------------------
        global af_http_count_routes
af_http_count_routes:
        AF_ENTER 32
        mov     qword [rsp], 0                  ; enabled
        mov     qword [rsp + 8], 0              ; eligible
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, [rbx + RT_CONFIG]
        test    r12, r12
        jz      .done
        xor     r13, r13
.loop:
        cmp     r13, [r12 + CFG_ROUTE_COUNT]
        jae     .done
        mov     rax, r13
        imul    rax, rax, RTE_SIZE
        add     rax, [r12 + CFG_ROUTES]
        mov     r14, rax
        cmp     qword [r14 + RTE_ENABLED], 0
        je      .next
        inc     qword [rsp]
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r14
        call    af_http_route_is_eligible
        test    rax, rax
        jz      .next
        inc     qword [rsp + 8]
.next:
        inc     r13
        jmp     .loop
.done:
        mov     rax, [rsp]
        mov     rdx, [rsp + 8]
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_ep_models(af_http_conn *c) -> af_status
;
; docs/API_CONTRACT.md 4: enabled model aliases, not upstream inventory. The
; provider that would serve an alias, its base URL, and its credentials are not
; part of a model object and are not emitted here.
; ---------------------------------------------------------------------------
        global af_http_ep_models
af_http_ep_models:
        AF_ENTER (JW_SIZE + 64)
        mov     rbx, rdi
        mov     r12, [rbx + HC_SERVER]
        xor     r13, r13
        test    r12, r12
        jz      .no_rt
        mov     r13, [r12 + HS_RT]
.no_rt:
        xor     r14, r14                        ; config
        test    r13, r13
        jz      .no_cfg
        mov     r14, [r13 + RT_CONFIG]
.no_cfg:

        mov     rdi, rbx
        lea     rsi, [rsp]
        call    af_http_begin_body
        test    rax, rax
        js      .done

        lea     rdi, [rsp]
        call    af_jw_begin_object
        lea     rdi, [rsp]
        lea     rsi, [k_object]
        lea     rdx, [v_list]
        call    af_jw_member_string
        lea     rdi, [rsp]
        lea     rsi, [k_data]
        call    af_jw_key
        lea     rdi, [rsp]
        call    af_jw_begin_array

        test    r14, r14
        jz      .listed
        xor     r15, r15
.loop:
        cmp     r15, [r14 + CFG_ROUTE_COUNT]
        jae     .listed
        mov     rax, r15
        imul    rax, rax, RTE_SIZE
        add     rax, [r14 + CFG_ROUTES]
        mov     [rsp + JW_SIZE], rax
        cmp     qword [rax + RTE_ENABLED], 0
        je      .next

        ; An alias nothing can currently serve is listed only when the operator
        ; asked for that. The default is to advertise what can be used.
        cmp     qword [r14 + CFG_LST_EXPOSE_UNAVAIL], 0
        jne     .emit
        mov     rdi, r13
        mov     rsi, r14
        mov     rdx, [rsp + JW_SIZE]
        call    af_http_route_is_eligible
        test    rax, rax
        jz      .next
.emit:
        lea     rdi, [rsp]
        call    af_jw_begin_object
        lea     rdi, [rsp]
        lea     rsi, [k_id]
        mov     rax, [rsp + JW_SIZE]
        mov     rdx, [rax + RTE_MODEL_ALIAS]
        call    af_jw_member_string
        lea     rdi, [rsp]
        lea     rsi, [k_object]
        lea     rdx, [v_model]
        call    af_jw_member_string
        lea     rdi, [rsp]
        lea     rsi, [k_created]
        xor     edx, edx
        call    af_jw_member_uint
        lea     rdi, [rsp]
        lea     rsi, [k_owned_by]
        lea     rdx, [v_asmflow]
        call    af_jw_member_string
        lea     rdi, [rsp]
        call    af_jw_end_object
.next:
        inc     r15
        jmp     .loop

.listed:
        lea     rdi, [rsp]
        call    af_jw_end_array
        lea     rdi, [rsp]
        call    af_jw_end_object
        lea     rdi, [rsp]
        call    af_jw_finish
        test    rax, rax
        js      .done

        mov     rdi, rbx
        mov     rsi, 200
        xor     edx, edx
        call    af_http_commit
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_ep_generation(af_http_conn *c) -> af_status
;
; The shared front half of `/v1/responses` and `/v1/chat/completions`. Both
; endpoints have the same request-side contract, and both end in the same place
; in this build.
; ---------------------------------------------------------------------------
        global af_http_ep_generation
af_http_ep_generation:
        AF_ENTER 128
;   [rsp +  0]  body length          [rsp + 32]  alias length
;   [rsp +  8]  body pointer         [rsp + 40]  the `model` member
;   [rsp + 16]  configuration        [rsp + 48]  af_json_limits
;   [rsp + 24]  alias pointer        [rsp + 80]  af_json_doc
%define GEN_LIMITS 48
%define GEN_DOC    80
        mov     rbx, rdi

        ; A body is required, and it has to say it is JSON.
        test    qword [rbx + HC_FLAGS], HC_F_HAVE_CL | HC_F_HAVE_TE
        jz      .length_required
        test    qword [rbx + HC_FLAGS], HC_F_HAVE_CTYPE
        jz      .bad_ctype
        mov     rdi, rbx
        lea     rsi, [ctype_json]
        call    af_http_ctype_is
        test    rax, rax
        jz      .bad_ctype

        lea     rdi, [rbx + HC_BODY]
        call    af_buf_len
        test    rax, rax
        jz      .bad_json
        mov     [rsp], rax
        lea     rdi, [rbx + HC_BODY]
        call    af_buf_data
        mov     [rsp + 8], rax
        test    rax, rax
        jz      .bad_json

        ; The configured JSON ceilings, so a request body is bounded by the
        ; same numbers the configuration file is.
        mov     r12, [rbx + HC_SERVER]
        xor     r13, r13
        test    r12, r12
        jz      .no_config
        mov     rax, [r12 + HS_RT]
        test    rax, rax
        jz      .no_config
        mov     r13, [rax + RT_CONFIG]
.no_config:
        mov     [rsp + 16], r13

        mov     rax, [rsp]
        mov     [rsp + GEN_LIMITS + AF_JSONLIM_MAX_BYTES], rax
        mov     qword [rsp + GEN_LIMITS + AF_JSONLIM_MAX_DEPTH], 32
        mov     qword [rsp + GEN_LIMITS + AF_JSONLIM_MAX_STRING], 1048576
        mov     qword [rsp + GEN_LIMITS + AF_JSONLIM_MAX_ELEMS], 100000
        test    r13, r13
        jz      .limits_ready
        mov     rax, [r13 + CFG_LIM_JSON_DEPTH]
        mov     [rsp + GEN_LIMITS + AF_JSONLIM_MAX_DEPTH], rax
        mov     rax, [r13 + CFG_LIM_JSON_STR_MAX]
        mov     [rsp + GEN_LIMITS + AF_JSONLIM_MAX_STRING], rax
.limits_ready:

        mov     rdi, [rsp + 8]
        mov     rsi, [rsp]
        lea     rdx, [rsp + GEN_LIMITS]
        lea     rcx, [rsp + GEN_DOC]
        call    af_json_parse
        test    rax, rax
        js      .bad_json

        lea     rdi, [rsp + GEN_DOC]
        call    af_json_doc_root
        mov     r14, rax
        mov     rdi, r14
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .free_and_invalid_field

        mov     rdi, r14
        lea     rsi, [k_model]
        lea     rdx, [rsp + 40]
        call    af_json_member
        test    rax, rax
        js      .free_and_missing_model
        mov     rdi, [rsp + 40]
        call    af_json_type
        cmp     rax, AF_JSON_STRING
        jne     .free_and_invalid_field

        mov     rdi, [rsp + 40]
        lea     rsi, [rsp + 24]
        lea     rdx, [rsp + 32]
        call    af_json_string_of
        test    rax, rax
        js      .free_and_invalid_field

        ; The alias has to name a route that exists and is enabled. That much of
        ; routing is a configuration lookup rather than a policy decision, so it
        ; is answerable now and answered now; choosing among a route's targets
        ; is what waits for the router.
        mov     r13, [rsp + 16]
        test    r13, r13
        jz      .free_and_unknown_alias
        mov     rdi, r13
        mov     rsi, [rsp + 24]
        mov     rdx, [rsp + 32]
        call    af_http_route_for_alias
        test    rax, rax
        jz      .free_and_unknown_alias
        mov     r15, rax
        cmp     qword [r15 + RTE_ENABLED], 0
        je      .free_and_route_disabled

        ; Everything the gateway can decide on its own has been decided. The
        ; request now goes upstream, and this connection stops being answerable
        ; until it comes back: af_prov_exchange_start returns AF_OK having
        ; written nothing, and the response is produced from libcurl's
        ; callbacks (ADR 0011).
        mov     r12, [rbx + HC_SERVER]
        test    r12, r12
        jz      .free_and_unavailable
        mov     r12, [r12 + HS_RT]
        test    r12, r12
        jz      .free_and_unavailable
        mov     r12, [r12 + RT_PROV]
        test    r12, r12
        jz      .free_and_unsupported

        mov     rdi, [rbx + HC_ENDPOINT]
        call    af_prov_family_for_endpoint
        cmp     rax, 0
        jl      .free_and_unsupported
        mov     r14, rax

        ; The parsed document goes with the request. A fallback attempt has to
        ; re-emit the body against a different upstream model, so it has to
        ; outlive this function; on success the exchange owns it, and on
        ; failure it comes back and is released below.
        mov     rdi, r12
        mov     rsi, rbx
        mov     rdx, r15
        mov     rcx, r14
        lea     r8, [rsp + GEN_DOC]
        call    af_prov_exchange_start
        mov     r14, rax
        test    r14, r14
        jns     .suspended

        lea     rdi, [rsp + GEN_DOC]
        call    af_json_doc_free
        mov     rdi, rbx
        cmp     r14, AF_E_ROUTE_NO_TARGET
        je      .no_target
        cmp     r14, AF_E_ROUTE_CAPACITY
        je      .capacity
        mov     rsi, AF_HERR_INTERNAL
        call    af_http_send_error
        AF_LEAVE
.no_target:
        mov     rsi, AF_HERR_NO_TARGET
        call    af_http_send_error
        AF_LEAVE
.capacity:
        mov     rsi, AF_HERR_CAPACITY
        call    af_http_send_error
        AF_LEAVE
.suspended:
        AF_LEAVE_OK

.free_and_unsupported:
        lea     rdi, [rsp + GEN_DOC]
        call    af_json_doc_free
        mov     rdi, rbx
        mov     rsi, AF_HERR_UNSUPPORTED_BUILD
        call    af_http_send_error
        AF_LEAVE
.free_and_unavailable:
        lea     rdi, [rsp + GEN_DOC]
        call    af_json_doc_free
        mov     rdi, rbx
        mov     rsi, AF_HERR_NOT_READY
        call    af_http_send_error
        AF_LEAVE

.free_and_invalid_field:
        lea     rdi, [rsp + GEN_DOC]
        call    af_json_doc_free
        mov     rdi, rbx
        mov     rsi, AF_HERR_INVALID_FIELD
        call    af_http_send_error
        AF_LEAVE
.free_and_missing_model:
        lea     rdi, [rsp + GEN_DOC]
        call    af_json_doc_free
        mov     rdi, rbx
        mov     rsi, AF_HERR_MISSING_MODEL
        call    af_http_send_error
        AF_LEAVE
.free_and_unknown_alias:
        lea     rdi, [rsp + GEN_DOC]
        call    af_json_doc_free
        mov     rdi, rbx
        mov     rsi, AF_HERR_UNKNOWN_ALIAS
        call    af_http_send_error
        AF_LEAVE
.free_and_route_disabled:
        lea     rdi, [rsp + GEN_DOC]
        call    af_json_doc_free
        mov     rdi, rbx
        mov     rsi, AF_HERR_ROUTE_DISABLED
        call    af_http_send_error
        AF_LEAVE

.length_required:
        mov     rdi, rbx
        mov     rsi, AF_HERR_LENGTH_REQUIRED
        call    af_http_send_error
        AF_LEAVE
.bad_ctype:
        mov     rdi, rbx
        mov     rsi, AF_HERR_UNSUPPORTED_CTYPE
        call    af_http_send_error
        AF_LEAVE
.bad_json:
        mov     rdi, rbx
        mov     rsi, AF_HERR_INVALID_JSON
        call    af_http_send_error
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_dispatch(af_http_conn *c) -> af_status
;
; Called once per complete message, from inside the parse. Every response a
; client receives leaves through here.
; ---------------------------------------------------------------------------
        global af_http_dispatch
af_http_dispatch:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi

        ; A correlation id for every response, refused or not: an operator
        ; reading a client's log and the daemon's needs them to share a key.
        mov     rdi, rbx
        call    af_http_assign_request_id

        ; A refusal recorded during the parse is answered as it stands.
        test    qword [rbx + HC_FLAGS], HC_F_FAULT
        jz      .no_fault
        mov     rdi, rbx
        mov     rsi, [rbx + HC_FAULT]
        call    af_http_send_error
        AF_LEAVE
.no_fault:

        mov     rax, [rbx + HC_ENDPOINT]
        cmp     rax, AF_EP_UNKNOWN
        je      .unknown_path

        ; Method before credential would tell an unauthenticated caller which
        ; methods an endpoint has; credential before path would tell them which
        ; paths exist. The path is public — it is in the contract — and the
        ; method is not worth disclosing, so the order is path, credential,
        ; method.
        mov     rdi, rbx
        call    af_http_check_auth
        test    rax, rax
        js      .fault_recorded

        mov     rax, [rbx + HC_ENDPOINT]
        cmp     rax, AF_EP_RESPONSES
        jae     .want_post

        cmp     qword [rbx + HC_METHOD], AF_HTTP_M_GET
        jne     .method_get_only
        mov     rax, [rbx + HC_ENDPOINT]
        cmp     rax, AF_EP_HEALTHZ
        je      .healthz
        cmp     rax, AF_EP_READYZ
        je      .readyz
        mov     rdi, rbx
        call    af_http_ep_models
        AF_LEAVE
.healthz:
        mov     rdi, rbx
        call    af_http_ep_healthz
        AF_LEAVE
.readyz:
        mov     rdi, rbx
        call    af_http_ep_readyz
        AF_LEAVE

.want_post:
        cmp     qword [rbx + HC_METHOD], AF_HTTP_M_POST
        jne     .method_post_only
        mov     rdi, rbx
        call    af_http_ep_generation
        AF_LEAVE

.unknown_path:
        mov     rdi, rbx
        mov     rsi, AF_HERR_UNKNOWN_PATH
        call    af_http_send_error
        AF_LEAVE
.method_get_only:
        mov     rdi, rbx
        mov     rsi, AF_HERR_METHOD_GET_ONLY
        call    af_http_send_error
        AF_LEAVE
.method_post_only:
        mov     rdi, rbx
        mov     rsi, AF_HERR_METHOD_POST_ONLY
        call    af_http_send_error
        AF_LEAVE
.fault_recorded:
        mov     rdi, rbx
        mov     rsi, [rbx + HC_FAULT]
        call    af_http_send_error
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
