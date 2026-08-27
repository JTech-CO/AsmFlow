; AsmFlow — building a routing scenario from outside the daemon (M7 DoD 1).
;
; The parity test needs to put the assembly selector and `tests/route_oracle.py`
; in front of the same scenario and compare their answers. A scenario is a
; configuration snapshot, a set of provider runtime states, and a request — all
; of which normally come from a file, a database, and a socket.
;
; These builders let a harness assemble one directly. They exist only in the
; test binary and are the whole reason `tests/ffi/route_corpus.c` can be written
; without knowing a single structure offset: the layouts stay here, in the
; header that owns them, and the C side names fields rather than addresses.
;
; Nothing here decides anything. Every function stores what it is given.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "config.inc"
%include "routing.inc"

        extern af_mem_zero
        extern af_routing_provider
        extern af_routing_route

        section .text

; ---------------------------------------------------------------------------
; af_rt_sizes(u64 *out7) -> void
;
; provider, target, route, config, request, candidate, routing.
; ---------------------------------------------------------------------------
        global af_rt_sizes
af_rt_sizes:
        test    rdi, rdi
        jz      .done
        mov     qword [rdi + 0],  PRV_SIZE
        mov     qword [rdi + 8],  RTG_SIZE
        mov     qword [rdi + 16], RTE_SIZE
        mov     qword [rdi + 24], CFG_SIZE
        mov     qword [rdi + 32], RQ_SIZE
        mov     qword [rdi + 40], RC_SIZE
        mov     qword [rdi + 48], RTB_SIZE
.done:
        ret

; ---------------------------------------------------------------------------
; af_rt_set_provider(void *providers, u64 index, const char *id, i64 adapter,
;                    u64 capabilities, i64 enabled) -> void *
;
; Returns the record, so the caller can pass it back for the fields that do not
; fit in six arguments.
; ---------------------------------------------------------------------------
        global af_rt_set_provider
af_rt_set_provider:
        AF_ENTER 32
        test    rdi, rdi
        jz      .none
        mov     rax, rsi
        imul    rax, rax, PRV_SIZE
        add     rax, rdi
        mov     rbx, rax
        mov     r12, rdx                        ; id
        mov     r13, rcx                        ; adapter
        mov     r14, r8                         ; capabilities
        mov     r15, r9                         ; enabled

        mov     rdi, rbx
        mov     rsi, PRV_SIZE
        call    af_mem_zero
        mov     [rbx + PRV_ID], r12
        mov     [rbx + PRV_ADAPTER], r13
        mov     [rbx + PRV_CAPABILITIES], r14
        mov     [rbx + PRV_ENABLED], r15
        mov     qword [rbx + PRV_MAX_CONCURRENCY], 1
        mov     rax, rbx
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_rt_provider_limits(void *provider, u64 max_concurrency, u64 fail_threshold,
;                       u64 success_threshold, u64 cooldown_ms) -> void
; ---------------------------------------------------------------------------
        global af_rt_provider_limits
af_rt_provider_limits:
        test    rdi, rdi
        jz      .done
        mov     [rdi + PRV_MAX_CONCURRENCY], rsi
        mov     [rdi + PRV_HEALTH + HLT_FAIL_THR], rdx
        mov     [rdi + PRV_HEALTH + HLT_SUCC_THR], rcx
        mov     [rdi + PRV_HEALTH + HLT_COOLDOWN_MS], r8
.done:
        ret

; ---------------------------------------------------------------------------
; af_rt_set_target(void *targets, u64 index, i64 provider_index,
;                  const char *upstream_model, i64 priority, i64 weight) -> void
; ---------------------------------------------------------------------------
        global af_rt_set_target
af_rt_set_target:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rax, rsi
        imul    rax, rax, RTG_SIZE
        add     rax, rdi
        mov     rbx, rax
        mov     r12, rdx
        mov     r13, rcx
        mov     r14, r8
        mov     r15, r9

        mov     rdi, rbx
        mov     rsi, RTG_SIZE
        call    af_mem_zero
        mov     [rbx + RTG_PROVIDER_INDEX], r12
        mov     [rbx + RTG_UPSTREAM_MODEL], r13
        mov     [rbx + RTG_PRIORITY], r14
        mov     [rbx + RTG_WEIGHT], r15
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_rt_set_route(void *route, const char *id, u64 families, i64 policy,
;                 void *targets, u64 target_count) -> void
; ---------------------------------------------------------------------------
        global af_rt_set_route
af_rt_set_route:
        AF_ENTER 48
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r15, r8
        mov     [rsp], r9

        mov     rdi, rbx
        mov     rsi, RTE_SIZE
        call    af_mem_zero
        mov     [rbx + RTE_ID], r12
        mov     [rbx + RTE_ENDPOINT_FAMILIES], r13
        mov     [rbx + RTE_POLICY], r14
        mov     [rbx + RTE_TARGETS], r15
        mov     rax, [rsp]
        mov     [rbx + RTE_TARGET_COUNT], rax
        mov     qword [rbx + RTE_ENABLED], 1
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_rt_set_config(void *config, void *providers, u64 provider_count,
;                  void *routes, u64 route_count) -> void
;
; A snapshot with no arena behind it. Nothing in the selection path allocates
; from one, so a fixture does not need one; a fixture that had one would have
; to be torn down through af_config_release, which would make the harness look
; like it was testing configuration loading.
; ---------------------------------------------------------------------------
        global af_rt_set_config
af_rt_set_config:
        AF_ENTER 48
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r15, r8

        mov     rdi, rbx
        mov     rsi, CFG_SIZE
        call    af_mem_zero
        mov     [rbx + CFG_PROVIDERS], r12
        mov     [rbx + CFG_PROVIDER_COUNT], r13
        mov     [rbx + CFG_ROUTES], r14
        mov     [rbx + CFG_ROUTE_COUNT], r15
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_rt_apply_state(af_routing *rt, const char *provider_id, i64 health,
;                   u64 active, u64 latency_us, u64 open_until_ns) -> i64
;
; 1 when the state was recorded. Goes through af_routing_provider, so the
; fixture creates state exactly the way the daemon does.
; ---------------------------------------------------------------------------
        global af_rt_apply_state
af_rt_apply_state:
        AF_ENTER 48
        mov     [rsp], rdx                      ; health
        mov     [rsp + 8], rcx                  ; active
        mov     [rsp + 16], r8                  ; latency
        mov     [rsp + 24], r9                  ; open_until
        call    af_routing_provider
        test    rax, rax
        jz      .none
        mov     rcx, [rsp]
        mov     [rax + PS_HEALTH], rcx
        mov     rcx, [rsp + 8]
        mov     [rax + PS_ACTIVE], rcx
        mov     rcx, [rsp + 16]
        mov     [rax + PS_EWMA], rcx
        mov     rcx, [rsp + 24]
        mov     [rax + PS_OPEN_UNTIL], rcx
        mov     eax, 1
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_rt_request_init(void *request, void *routing, void *config, void *route,
;                    u64 family_bit, u64 required_caps) -> void
; ---------------------------------------------------------------------------
        global af_rt_request_init
af_rt_request_init:
        AF_ENTER 48
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r15, r8
        mov     [rsp], r9

        mov     rdi, rbx
        mov     rsi, RQ_SIZE
        call    af_mem_zero
        mov     [rbx + RQ_ROUTING], r12
        mov     [rbx + RQ_CONFIG], r13
        mov     [rbx + RQ_ROUTE], r14
        mov     [rbx + RQ_FAMILY], r15
        mov     rax, [rsp]
        mov     [rbx + RQ_CAPS], rax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_rt_request_set(void *request, u64 tried, u64 now_ns) -> void
; ---------------------------------------------------------------------------
        global af_rt_request_set
af_rt_request_set:
        test    rdi, rdi
        jz      .done
        mov     [rdi + RQ_TRIED], rsi
        mov     [rdi + RQ_NOW_NS], rdx
.done:
        ret

; ---------------------------------------------------------------------------
; af_rt_candidate_id(const void *candidates, u64 index) -> const char *
; af_rt_candidate_index(const void *candidates, u64 index) -> u64
; ---------------------------------------------------------------------------
        global af_rt_candidate_id
af_rt_candidate_id:
        test    rdi, rdi
        jz      .none
        mov     rax, rsi
        imul    rax, rax, RC_SIZE
        add     rax, rdi
        mov     rax, [rax + RC_PROVIDER_ID]
        ret
.none:
        xor     eax, eax
        ret

        global af_rt_candidate_index
af_rt_candidate_index:
        test    rdi, rdi
        jz      .none
        mov     rax, rsi
        imul    rax, rax, RC_SIZE
        add     rax, rdi
        mov     rax, [rax + RC_INDEX]
        ret
.none:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_rt_route_cursor(af_routing *rt, const char *route_id, u64 cursor) -> void
; ---------------------------------------------------------------------------
        global af_rt_route_cursor
af_rt_route_cursor:
        AF_ENTER 16
        mov     [rsp], rdx
        call    af_routing_route
        test    rax, rax
        jz      .done
        mov     rcx, [rsp]
        mov     [rax + RS_CURSOR], rcx
.done:
        AF_LEAVE
