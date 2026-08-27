; AsmFlow — which target serves this request.
;
; The rules are stated twice on purpose: here, and in `tests/route_oracle.py`.
; `tests/test_routing_parity.py` runs both over the same corpus and fails on
; any disagreement, which is the only way this layer can be checked. A routing
; defect produces a valid-looking answer from the wrong provider; there is no
; crash to notice and no error to log, so the test cannot be "does it work" —
; it has to be "does it agree with an independent statement of the rules".
;
; That is why the code below follows the whitepaper's ordering literally rather
; than in whatever order is cheapest. Filtering happens in the documented
; sequence and preserves configured order; every tie-break is applied even when
; the preceding key already decided the comparison. A shortcut that is correct
; today is a shortcut the oracle does not take, and the parity test would then
; be comparing two different algorithms that happen to agree.
;
; Nothing here reads a clock, allocates, or mutates provider state. Given the
; same request and the same candidate set it returns the same answer, every
; time — which is what makes M7 DoD 2 (a hundred identical repetitions)
; a property of the code rather than of the test's luck.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "config.inc"
%include "routing.inc"

        extern af_routing_provider
        extern af_health_refresh
        extern af_health_admit

        section .text

; ---------------------------------------------------------------------------
; af_route_id_compare(const char *a, const char *b) -> i64
;
; Bytewise, unsigned: negative when a sorts first, 0 when equal, positive
; otherwise. The last tie-break in every policy, so that two targets identical
; in every configured respect still order deterministically.
; ---------------------------------------------------------------------------
        global af_route_id_compare
af_route_id_compare:
        test    rdi, rdi
        jz      .a_null
        test    rsi, rsi
        jz      .b_null
        xor     ecx, ecx
.loop:
        movzx   eax, byte [rdi + rcx]
        movzx   edx, byte [rsi + rcx]
        cmp     eax, edx
        jne     .differ
        test    eax, eax
        jz      .equal
        inc     rcx
        jmp     .loop
.differ:
        sub     rax, rdx
        ret
.equal:
        xor     eax, eax
        ret
.a_null:
        test    rsi, rsi
        jz      .equal
        mov     rax, -1
        ret
.b_null:
        mov     eax, 1
        ret

; ---------------------------------------------------------------------------
; af_route_candidates(const af_route_request *rq, af_route_candidate *out,
;                     u64 max) -> i64
;
; The eligible targets, in configured order. Negative on a bad argument;
; otherwise the count, which may be zero.
;
; The six filters are the whitepaper's, in its order: disabled provider,
; unsupported endpoint family, unsupported required capability, an open circuit
; whose cooldown has not elapsed, concurrency at its ceiling, and a target this
; request has already tried.
; ---------------------------------------------------------------------------
        global af_route_candidates
af_route_candidates:
        AF_ENTER 96
;   [rsp +  0]  request      [rsp + 24]  count so far
;   [rsp +  8]  out          [rsp + 32]  target index
;   [rsp + 16]  max          [rsp + 40]  the route
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     [rsp], rdi
        mov     [rsp + 8], rsi
        mov     [rsp + 16], rdx
        mov     qword [rsp + 24], 0
        mov     qword [rsp + 32], 0

        mov     rbx, rdi
        mov     rax, [rbx + RQ_ROUTE]
        test    rax, rax
        jz      .invalid
        mov     [rsp + 40], rax
        mov     r15, [rbx + RQ_CONFIG]
        test    r15, r15
        jz      .invalid

.scan:
        mov     rax, [rsp + 40]
        mov     rcx, [rsp + 32]
        cmp     rcx, [rax + RTE_TARGET_COUNT]
        jae     .done
        cmp     rcx, AF_ROUTING_MAX_TARGETS
        jae     .done                           ; the tried-set is one word

        ; The target record.
        mov     r12, rcx
        imul    r12, r12, RTG_SIZE
        add     r12, [rax + RTE_TARGETS]

        ; --- 6. already tried by this request --------------------------------
        ; Checked first among the cheap tests because a retry re-runs this walk
        ; and the set is the thing that changed.
        mov     rcx, [rsp + 32]
        mov     rax, 1
        shl     rax, cl
        test    [rbx + RQ_TRIED], rax
        jnz     .next

        ; The provider the target names.
        mov     rax, [r12 + RTG_PROVIDER_INDEX]
        cmp     rax, 0
        jl      .next
        cmp     rax, [r15 + CFG_PROVIDER_COUNT]
        jae     .next
        imul    rax, rax, PRV_SIZE
        add     rax, [r15 + CFG_PROVIDERS]
        mov     r13, rax

        ; --- 1. provider disabled --------------------------------------------
        cmp     qword [r13 + PRV_ENABLED], 0
        je      .next

        ; --- 2. endpoint family unsupported ----------------------------------
        ; The route advertises a family; the provider has to actually speak it.
        mov     rax, [rbx + RQ_FAMILY]
        cmp     rax, AF_EPF_RESPONSES
        jne     .want_chat
        test    qword [r13 + PRV_CAPABILITIES], AF_CAP_RESPONSES
        jz      .next
        mov     rcx, [r13 + PRV_ADAPTER]
        cmp     rcx, AF_ADAPTER_OPENAI_DUAL
        je      .family_ok
        cmp     rcx, AF_ADAPTER_OPENAI_RESPONSES
        jne     .next
        jmp     .family_ok
.want_chat:
        test    qword [r13 + PRV_CAPABILITIES], AF_CAP_CHAT_COMPLETIONS
        jz      .next
        mov     rcx, [r13 + PRV_ADAPTER]
        cmp     rcx, AF_ADAPTER_OPENAI_DUAL
        je      .family_ok
        cmp     rcx, AF_ADAPTER_OPENAI_CHAT
        jne     .next
.family_ok:

        ; --- 3. required capability unsupported ------------------------------
        mov     rax, [rbx + RQ_CAPS]
        mov     rcx, [r13 + PRV_CAPABILITIES]
        and     rcx, rax
        cmp     rcx, rax
        jne     .next

        ; The runtime state, and the one transition time makes on its own.
        mov     rdi, [rbx + RQ_ROUTING]
        mov     rsi, [r13 + PRV_ID]
        call    af_routing_provider
        test    rax, rax
        jz      .next
        mov     r14, rax
        mov     rdi, r14
        mov     rsi, [rbx + RQ_NOW_NS]
        call    af_health_refresh

        ; --- 4. an open circuit whose cooldown has not elapsed ---------------
        mov     rdi, r14
        call    af_health_admit
        test    rax, rax
        jz      .next

        ; --- 5. concurrency at its ceiling -----------------------------------
        mov     rax, [r14 + PS_ACTIVE]
        mov     rcx, [r13 + PRV_MAX_CONCURRENCY]
        test    rcx, rcx
        jz      .capacity_ok                    ; unset means unbounded
        cmp     rax, rcx
        jae     .next
.capacity_ok:

        ; Eligible. Flatten it.
        mov     rax, [rsp + 24]
        cmp     rax, [rsp + 16]
        jae     .done                           ; the caller's array is full
        imul    rax, rax, RC_SIZE
        add     rax, [rsp + 8]
        mov     [rax + RC_TARGET], r12
        mov     [rax + RC_PROVIDER], r13
        mov     [rax + RC_STATE], r14
        mov     rcx, [rsp + 32]
        mov     [rax + RC_INDEX], rcx
        mov     rcx, [r12 + RTG_PRIORITY]
        mov     [rax + RC_PRIORITY], rcx
        mov     rcx, [r12 + RTG_WEIGHT]
        mov     [rax + RC_WEIGHT], rcx
        mov     rcx, [r14 + PS_HEALTH]
        mov     [rax + RC_HEALTH], rcx
        mov     rcx, [r14 + PS_EWMA]
        mov     [rax + RC_LATENCY], rcx
        mov     rcx, [r13 + PRV_ID]
        mov     [rax + RC_PROVIDER_ID], rcx
        inc     qword [rsp + 24]

.next:
        inc     qword [rsp + 32]
        jmp     .scan
.done:
        mov     rax, [rsp + 24]
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_route_beats_priority(const af_route_candidate *a, const af_route_candidate *b)
;   -> i64 (1 when a is preferred)
;
; (priority, configured index, provider id), all three applied.
; ---------------------------------------------------------------------------
        global af_route_beats_priority
af_route_beats_priority:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     rax, [rbx + RC_PRIORITY]
        cmp     rax, [r12 + RC_PRIORITY]
        jl      .yes                            ; signed: lower priority wins
        jg      .no
        mov     rax, [rbx + RC_INDEX]
        cmp     rax, [r12 + RC_INDEX]
        jb      .yes
        ja      .no
        mov     rdi, [rbx + RC_PROVIDER_ID]
        mov     rsi, [r12 + RC_PROVIDER_ID]
        call    af_route_id_compare
        cmp     rax, 0
        jl      .yes
.no:
        xor     eax, eax
        AF_LEAVE
.yes:
        mov     eax, 1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_route_beats_latency(const af_route_candidate *a, const af_route_candidate *b)
;   -> i64 (1 when a is preferred)
;
; (half-open last, unknown after measured, lower EWMA, configured index,
; provider id).
;
; The two rank keys are the substance. A half-open target is a probe, not a
; choice: sending ordinary traffic to it because it happens to have the lowest
; recorded latency would defeat the circuit breaker that put it there. And an
; unmeasured target ranks after every measured one rather than before, because
; "no data" is not evidence of being fast.
; ---------------------------------------------------------------------------
        global af_route_beats_latency
af_route_beats_latency:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi

        ; half-open rank
        xor     r13, r13
        cmp     qword [rbx + RC_HEALTH], AF_HEALTH_HALF_OPEN
        jne     .a_rank_done
        mov     r13, 1
.a_rank_done:
        xor     r14, r14
        cmp     qword [r12 + RC_HEALTH], AF_HEALTH_HALF_OPEN
        jne     .b_rank_done
        mov     r14, 1
.b_rank_done:
        cmp     r13, r14
        jb      .yes
        ja      .no

        ; unknown-latency rank
        xor     r13, r13
        cmp     qword [rbx + RC_LATENCY], AF_LATENCY_UNKNOWN
        jne     .a_known
        mov     r13, 1
.a_known:
        xor     r14, r14
        cmp     qword [r12 + RC_LATENCY], AF_LATENCY_UNKNOWN
        jne     .b_known
        mov     r14, 1
.b_known:
        cmp     r13, r14
        jb      .yes
        ja      .no

        ; measured latency
        mov     rax, [rbx + RC_LATENCY]
        cmp     rax, [r12 + RC_LATENCY]
        jb      .yes
        ja      .no

        mov     rax, [rbx + RC_INDEX]
        cmp     rax, [r12 + RC_INDEX]
        jb      .yes
        ja      .no
        mov     rdi, [rbx + RC_PROVIDER_ID]
        mov     rsi, [r12 + RC_PROVIDER_ID]
        call    af_route_id_compare
        cmp     rax, 0
        jl      .yes
.no:
        xor     eax, eax
        AF_LEAVE
.yes:
        mov     eax, 1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_route_select(i64 policy, const af_route_candidate *c, u64 count,
;                 u64 cursor) -> i64
;
; The index into `c` of the chosen candidate, or -1 when there is none.
;
; Round-robin needs no sort. The oracle sorts by (configured_index,
; provider_id), and af_route_candidates emits candidates in configured order
; with strictly increasing indices, so the sorted order and the emitted order
; are the same sequence. That is asserted rather than assumed: a corpus case
; with an out-of-order set would fail the parity test rather than quietly
; diverge.
; ---------------------------------------------------------------------------
        global af_route_select
af_route_select:
        AF_ENTER 48
        test    rsi, rsi
        jz      .none
        test    rdx, rdx
        jz      .none
        mov     [rsp], rdi                      ; policy
        mov     rbx, rsi                        ; candidates
        mov     r12, rdx                        ; count
        mov     [rsp + 8], rcx                  ; cursor

        ; Every policy is named. A default branch would quietly serve a policy
        ; added to the schema later as whichever one it fell through to, and
        ; the only symptom would be traffic distributed by the wrong rule.
        cmp     rdi, AF_POLICY_ROUND_ROBIN
        je      .round_robin
        cmp     rdi, AF_POLICY_PRIORITY
        je      .by_comparison
        cmp     rdi, AF_POLICY_LEAST_LATENCY
        jne     .none

.by_comparison:
        ; Both remaining policies are "the best under a comparison", so they
        ; differ only in which comparison.
        xor     r13, r13                        ; best index
        mov     r14, 1                          ; candidate index
.scan:
        cmp     r14, r12
        jae     .chosen
        mov     rdi, r14
        imul    rdi, rdi, RC_SIZE
        add     rdi, rbx
        mov     rsi, r13
        imul    rsi, rsi, RC_SIZE
        add     rsi, rbx
        cmp     qword [rsp], AF_POLICY_LEAST_LATENCY
        je      .by_latency
        call    af_route_beats_priority
        jmp     .compared
.by_latency:
        call    af_route_beats_latency
.compared:
        test    rax, rax
        jz      .keep
        mov     r13, r14
.keep:
        inc     r14
        jmp     .scan
.chosen:
        mov     rax, r13
        AF_LEAVE

.round_robin:
        mov     rax, [rsp + 8]
        xor     edx, edx
        div     r12                             ; rdx = cursor mod count
        mov     rax, rdx
        AF_LEAVE
.none:
        mov     rax, -1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_route_candidate_struct_size() -> u64
; af_route_request_struct_size() -> u64
; ---------------------------------------------------------------------------
        global af_route_candidate_struct_size
af_route_candidate_struct_size:
        mov     rax, RC_SIZE
        ret

        global af_route_request_struct_size
af_route_request_struct_size:
        mov     rax, RQ_SIZE
        ret
