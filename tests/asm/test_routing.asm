; AsmFlow — the routing layer's decidable parts (HARNESS.md M7).
;
; `tests/test_routing_parity.py` checks selection against the Python oracle over
; a large corpus. What is left for here is everything the oracle does not have
; an opinion about, and everything the parity corpus takes as given:
;
;   * the circuit-breaker state machine, whose transitions are driven by time
;     and by outcomes rather than by a selection;
;   * the EWMA, which must never produce a floating-point-shaped surprise;
;   * the runtime state tables, which are keyed by identifier precisely so that
;     a reload cannot move a circuit from one provider to another; and
;   * the derivation of endpoint-family support from adapter and capabilities,
;     which the parity corpus supplies rather than computes.
;
; The state machine is the part worth the most attention. A circuit that opens
; one failure too late, or reopens one probe too early, produces traffic that
; looks entirely normal — so the transitions are asserted one at a time against
; a clock the test controls.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "config.inc"
%include "routing.inc"
%include "test.inc"

%define AF_TEST_TAG route

; The breaker tests build a provider state and a provider record side by side
; on the stack. `af_cfg_provider` is PRV_SIZE bytes with its health block at
; offset 128, so a slot sized for the health block alone would write past the
; frame — which is how the first version of these tests crashed.
%define ST 0
%define PV 128

        extern af_routing_init
        extern af_routing_free
        extern af_routing_provider
        extern af_routing_route
        extern af_routing_now_ns
        extern af_routing_set_now
        extern af_routing_struct_size
        extern af_prov_state_struct_size

        extern af_health_refresh
        extern af_health_admit
        extern af_health_begin
        extern af_health_end
        extern af_health_ewma
        extern af_health_success
        extern af_health_failure
        extern af_health_state_name
        extern af_health_get
        extern af_health_active

        extern af_route_id_compare
        extern af_route_candidate_struct_size
        extern af_route_request_struct_size

        extern af_prov_provider_supports

        extern af_alloc
        extern af_free
        extern af_mem_zero
        extern af_cstr_eq

        section .rodata

id_a:    db "alpha", 0
id_b:    db "bravo", 0
id_c:    db "charlie", 0
id_ab:   db "alpha", 0
n_open:  db "open", 0
n_half:  db "half_open", 0

        section .text

; ---------------------------------------------------------------------------
; The tables.
; ---------------------------------------------------------------------------

        AF_TEST "route/state_is_keyed_by_identifier_not_by_position", 64
        ; A reload can reorder providers. A circuit that opened against `bravo`
        ; has to stay `bravo`'s, which is only true if the key is the name.
        call    af_routing_struct_size
        mov     r12, rax
        mov     rdi, r12
        call    af_alloc
        AF_CHECK_TRUE rax, "allocated"
        mov     rbx, rax
        mov     rdi, rbx
        call    af_routing_init
        AF_CHECK_OK rax, "init"

        mov     rdi, rbx
        lea     rsi, [id_a]
        call    af_routing_provider
        AF_CHECK_TRUE rax, "alpha created"
        mov     r13, rax
        mov     qword [r13 + PS_HEALTH], AF_HEALTH_OPEN

        mov     rdi, rbx
        lea     rsi, [id_b]
        call    af_routing_provider
        AF_CHECK_TRUE rax, "bravo created"
        AF_CHECK_NE rax, r13, "a different provider gets a different record"

        ; The same name comes back to the same record, and a copy of the name
        ; works as well as the original pointer.
        mov     rdi, rbx
        lea     rsi, [id_ab]
        call    af_routing_provider
        AF_CHECK_EQ rax, r13, "the name is the key, not the pointer"
        AF_CHECK_EQ qword [rax + PS_HEALTH], AF_HEALTH_OPEN, "and its state came with it"

        mov     rdi, rbx
        call    af_routing_free
        mov     rdi, rbx
        call    af_free
        AF_TEST_END

        AF_TEST "route/a_route_cursor_survives_and_is_its_own", 64
        call    af_routing_struct_size
        mov     rdi, rax
        call    af_alloc
        AF_CHECK_TRUE rax, "allocated"
        mov     rbx, rax
        mov     rdi, rbx
        call    af_routing_init

        mov     rdi, rbx
        lea     rsi, [id_a]
        call    af_routing_route
        AF_CHECK_TRUE rax, "route created"
        mov     r13, rax
        AF_CHECK_EQ qword [r13 + RS_CURSOR], 0, "a new cursor starts at zero"
        mov     qword [r13 + RS_CURSOR], 41

        mov     rdi, rbx
        lea     rsi, [id_b]
        call    af_routing_route
        AF_CHECK_EQ qword [rax + RS_CURSOR], 0, "another route has its own"

        mov     rdi, rbx
        lea     rsi, [id_a]
        call    af_routing_route
        AF_CHECK_EQ qword [rax + RS_CURSOR], 41, "and the first one kept its place"

        mov     rdi, rbx
        call    af_routing_free
        mov     rdi, rbx
        call    af_free
        AF_TEST_END

; ---------------------------------------------------------------------------
; The circuit breaker.
; ---------------------------------------------------------------------------

        AF_TEST "route/a_circuit_opens_at_the_failure_threshold", (PV + PRV_SIZE + 64)
        lea     rdi, [rsp + ST]
        mov     rsi, PS_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + PV]
        mov     rsi, PRV_SIZE
        call    af_mem_zero
        mov     qword [rsp + PV + PRV_HEALTH + HLT_FAIL_THR], 3
        mov     qword [rsp + PV + PRV_HEALTH + HLT_SUCC_THR], 2
        mov     qword [rsp + PV + PRV_HEALTH + HLT_COOLDOWN_MS], 5000

        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_HEALTHY, "starts healthy"

        ; Below the threshold the provider is degraded, and still eligible:
        ; one failure is not evidence enough to stop using it.
        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        mov     rdx, 1000
        call    af_health_failure
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_DEGRADED, "one failure degrades"
        lea     rdi, [rsp + ST]
        call    af_health_admit
        AF_CHECK_TRUE rax, "degraded still admits"

        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        mov     rdx, 2000
        call    af_health_failure
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_DEGRADED, "two is still degraded"

        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        mov     rdx, 3000
        call    af_health_failure
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_OPEN, "the third opens it"
        lea     rdi, [rsp + ST]
        call    af_health_admit
        AF_CHECK_FALSE rax, "an open circuit admits nothing"
        AF_CHECK_EQ qword [rsp + ST + PS_OPENED], 1, "and it counted"
        AF_TEST_END

        AF_TEST "route/a_cooldown_reopens_the_circuit_by_time_alone", (PV + PRV_SIZE + 64)
        lea     rdi, [rsp + ST]
        mov     rsi, PS_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + PV]
        mov     rsi, PRV_SIZE
        call    af_mem_zero
        mov     qword [rsp + PV + PRV_HEALTH + HLT_FAIL_THR], 1
        mov     qword [rsp + PV + PRV_HEALTH + HLT_SUCC_THR], 1
        mov     qword [rsp + PV + PRV_HEALTH + HLT_COOLDOWN_MS], 5000

        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        mov     rdx, 1000000                    ; now = 1ms
        call    af_health_failure
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_OPEN, "opened"
        ; 1ms + 5000ms, in nanoseconds.
        AF_CHECK_EQ qword [rsp + ST + PS_OPEN_UNTIL], 1000000 + 5000 * 1000000, \
                    "the deadline is the configured cooldown"

        ; One nanosecond early is still open. The boundary is where a breaker
        ; that used > instead of >= would look right in every other test.
        lea     rdi, [rsp + ST]
        mov     rsi, 1000000 + 5000 * 1000000 - 1
        call    af_health_refresh
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_OPEN, "one nanosecond early"

        lea     rdi, [rsp + ST]
        mov     rsi, 1000000 + 5000 * 1000000
        call    af_health_refresh
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_HALF_OPEN, "exactly on time"
        lea     rdi, [rsp + ST]
        call    af_health_admit
        AF_CHECK_TRUE rax, "half-open admits a probe"
        AF_TEST_END

        AF_TEST "route/half_open_admits_one_probe_and_no_more", (PV + PRV_SIZE + 64)
        lea     rdi, [rsp + ST]
        mov     rsi, PS_SIZE
        call    af_mem_zero
        mov     qword [rsp + ST + PS_HEALTH], AF_HEALTH_HALF_OPEN

        lea     rdi, [rsp + ST]
        call    af_health_admit
        AF_CHECK_TRUE rax, "the first probe is admitted"
        lea     rdi, [rsp + ST]
        call    af_health_begin
        AF_CHECK_TRUE rax, "and it is a probe"
        AF_CHECK_EQ qword [rsp + ST + PS_ACTIVE], 1, "it holds a slot"

        lea     rdi, [rsp + ST]
        call    af_health_admit
        AF_CHECK_FALSE rax, "a second is not admitted while the first is out"

        lea     rdi, [rsp + ST]
        mov     rsi, 1
        call    af_health_end
        AF_CHECK_EQ qword [rsp + ST + PS_ACTIVE], 0, "the slot went back"
        lea     rdi, [rsp + ST]
        call    af_health_admit
        AF_CHECK_TRUE rax, "and another probe may go"
        AF_TEST_END

        AF_TEST "route/a_failed_probe_reopens_with_a_longer_cooldown", (PV + PRV_SIZE + 64)
        lea     rdi, [rsp + ST]
        mov     rsi, PS_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + PV]
        mov     rsi, PRV_SIZE
        call    af_mem_zero
        mov     qword [rsp + PV + PRV_HEALTH + HLT_FAIL_THR], 1
        mov     qword [rsp + PV + PRV_HEALTH + HLT_SUCC_THR], 1
        mov     qword [rsp + PV + PRV_HEALTH + HLT_COOLDOWN_MS], 1000

        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        xor     edx, edx
        call    af_health_failure
        AF_CHECK_EQ qword [rsp + ST + PS_BACKOFF_MS], 1000, "the first cooldown"

        lea     rdi, [rsp + ST]
        mov     rsi, 1000 * 1000000
        call    af_health_refresh
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_HALF_OPEN, "half-open"

        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        mov     rdx, 1000 * 1000000
        call    af_health_failure
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_OPEN, "the probe failed"
        AF_CHECK_EQ qword [rsp + ST + PS_BACKOFF_MS], 2000, "and the wait doubled"

        ; It keeps doubling, and then it stops. A provider down for an hour
        ; should be probed less and less; a provider that recovers should still
        ; be noticed within a bounded time.
        mov     r12, 8
.grow:
        test    r12, r12
        jz      .grown
        mov     rax, [rsp + ST + PS_BACKOFF_MS]
        imul    rax, rax, 1000000
        lea     rdi, [rsp + ST]
        mov     rsi, rax
        call    af_health_refresh
        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        xor     edx, edx
        call    af_health_failure
        dec     r12
        jmp     .grow
.grown:
        AF_CHECK_EQ qword [rsp + ST + PS_BACKOFF_MS], 1000 * AF_HEALTH_MAX_BACKOFF, \
                    "the backoff stops growing"
        AF_TEST_END

        AF_TEST "route/a_probe_that_succeeds_closes_the_circuit", (PV + PRV_SIZE + 64)
        lea     rdi, [rsp + ST]
        mov     rsi, PS_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + PV]
        mov     rsi, PRV_SIZE
        call    af_mem_zero
        mov     qword [rsp + PV + PRV_HEALTH + HLT_SUCC_THR], 2
        mov     qword [rsp + ST + PS_HEALTH], AF_HEALTH_HALF_OPEN
        mov     qword [rsp + ST + PS_BACKOFF_MS], 8000

        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        mov     rdx, 1500
        call    af_health_success
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_HALF_OPEN, \
                    "one success is not the threshold"

        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        mov     rdx, 1500
        call    af_health_success
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_HEALTHY, "the second closes it"
        AF_CHECK_EQ qword [rsp + ST + PS_BACKOFF_MS], 0, "and the backoff is forgotten"
        AF_TEST_END

        AF_TEST "route/a_success_resets_the_failure_run", (PV + PRV_SIZE + 64)
        lea     rdi, [rsp + ST]
        mov     rsi, PS_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + PV]
        mov     rsi, PRV_SIZE
        call    af_mem_zero
        mov     qword [rsp + PV + PRV_HEALTH + HLT_FAIL_THR], 3
        mov     qword [rsp + PV + PRV_HEALTH + HLT_SUCC_THR], 1

        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        xor     edx, edx
        call    af_health_failure
        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        xor     edx, edx
        call    af_health_failure
        AF_CHECK_EQ qword [rsp + ST + PS_FAILURES], 2, "two in a row"

        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        mov     rdx, 900
        call    af_health_success
        AF_CHECK_EQ qword [rsp + ST + PS_FAILURES], 0, "a success clears the run"
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_HEALTHY, "and closes the degradation"

        ; So two more failures do NOT open it: the run started again.
        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        xor     edx, edx
        call    af_health_failure
        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        xor     edx, edx
        call    af_health_failure
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_DEGRADED, "still degraded"
        AF_TEST_END

        AF_TEST "route/a_disabled_provider_ignores_health_entirely", (PV + PRV_SIZE + 64)
        lea     rdi, [rsp + ST]
        mov     rsi, PS_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + PV]
        mov     rsi, PRV_SIZE
        call    af_mem_zero
        mov     qword [rsp + PV + PRV_HEALTH + HLT_SUCC_THR], 1
        mov     qword [rsp + ST + PS_HEALTH], AF_HEALTH_DISABLED

        lea     rdi, [rsp + ST]
        call    af_health_admit
        AF_CHECK_FALSE rax, "disabled admits nothing"
        lea     rdi, [rsp + ST]
        lea     rsi, [rsp + PV]
        mov     rdx, 100
        call    af_health_success
        AF_CHECK_EQ qword [rsp + ST + PS_HEALTH], AF_HEALTH_DISABLED, \
                    "and a success does not re-enable it"
        AF_TEST_END

; ---------------------------------------------------------------------------
; Observed latency.
; ---------------------------------------------------------------------------

        AF_TEST "route/the_first_measurement_is_the_measurement", 16
        xor     edi, edi
        mov     rsi, 4000
        call    af_health_ewma
        AF_CHECK_EQ rax, 4000, "nothing to average against"
        AF_TEST_END

        AF_TEST "route/the_average_moves_toward_the_observation", 16
        ; alpha = 1/4, so new = (observed + 3*old) / 4.
        mov     rdi, 4000
        mov     rsi, 8000
        call    af_health_ewma
        AF_CHECK_EQ rax, 5000, "one step toward a slower observation"
        mov     rdi, 4000
        mov     rsi, 0
        call    af_health_ewma
        AF_CHECK_EQ rax, 3000, "and toward a faster one"
        mov     rdi, 4000
        mov     rsi, 4000
        call    af_health_ewma
        AF_CHECK_EQ rax, 4000, "a repeat of the same value does not drift"
        AF_TEST_END

        AF_TEST "route/a_measured_zero_never_reads_as_unmeasured", 16
        ; AF_LATENCY_UNKNOWN is zero, and unknown ranks after every measured
        ; candidate. A very fast provider that averaged down to zero would be
        ; demoted for being fast.
        xor     edi, edi
        xor     esi, esi
        call    af_health_ewma
        AF_CHECK_NE rax, AF_LATENCY_UNKNOWN, "a measured zero is at least one"
        mov     rdi, 1
        mov     rsi, 1
        call    af_health_ewma
        AF_CHECK_NE rax, AF_LATENCY_UNKNOWN, "and stays that way"
        AF_TEST_END

; ---------------------------------------------------------------------------
; Ordering.
; ---------------------------------------------------------------------------

        AF_TEST "route/identifiers_order_bytewise", 16
        lea     rdi, [id_a]
        lea     rsi, [id_b]
        call    af_route_id_compare
        mov     r12, 0
        cmp     rax, 0
        jge     .not_before
        mov     r12, 1
.not_before:
        AF_CHECK_TRUE r12, "alpha before bravo"
        lea     rdi, [id_b]
        lea     rsi, [id_a]
        call    af_route_id_compare
        mov     r12, 0
        cmp     rax, 0
        jle     .not_after
        mov     r12, 1
.not_after:
        AF_CHECK_TRUE r12, "and bravo after alpha"
        lea     rdi, [id_a]
        lea     rsi, [id_ab]
        call    af_route_id_compare
        AF_CHECK_EQ rax, 0, "a name equals its copy"
        AF_TEST_END

        AF_TEST "route/state_names_are_the_contract_names", 16
        mov     rdi, AF_HEALTH_OPEN
        call    af_health_state_name
        mov     rdi, rax
        lea     rsi, [n_open]
        call    af_cstr_eq
        AF_CHECK_TRUE rax, "open"
        mov     rdi, AF_HEALTH_HALF_OPEN
        call    af_health_state_name
        mov     rdi, rax
        lea     rsi, [n_half]
        call    af_cstr_eq
        AF_CHECK_TRUE rax, "half_open"
        AF_TEST_END

        AF_TEST "route/the_structures_are_the_size_the_header_says", 16
        call    af_prov_state_struct_size
        AF_CHECK_EQ rax, PS_SIZE, "af_prov_state"
        call    af_route_candidate_struct_size
        AF_CHECK_EQ rax, RC_SIZE, "af_route_candidate"
        call    af_route_request_struct_size
        AF_CHECK_EQ rax, RQ_SIZE, "af_route_request"
        call    af_routing_struct_size
        AF_CHECK_EQ rax, RTB_SIZE, "af_routing"
        AF_TEST_END
