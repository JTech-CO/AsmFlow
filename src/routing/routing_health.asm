; AsmFlow — provider health, the circuit breaker, and observed latency.
;
; This is what the runtime knows about a provider that the configuration does
; not: how it has been behaving. It is kept apart from the configuration
; snapshot on purpose. A snapshot is immutable and replaceable; a circuit that
; opened because a provider is down must survive the reload that happens while
; it is down, and must survive it *for that provider* rather than for whoever
; ends up at the same array index afterwards. So state is keyed by identifier
; and the key is an owned copy — a reload frees the snapshot's strings.
;
; Every deadline here is monotonic (whitepaper 4.3). A circuit whose cooldown
; was measured against the wall clock would reopen early, or never, when an
; operator corrected the system time; the failure would look like a routing
; defect and would be reproducible only by moving the clock again.
;
; The state machine, stated once so the code below can be read against it:
;
;   healthy   --failure--> degraded          (below the failure threshold)
;   degraded  --failure--> open              (at the threshold)
;   degraded  --success--> healthy           (at the success threshold)
;   open      --cooldown-> half_open         (time, not an event)
;   half_open --success--> healthy           (at the success threshold)
;   half_open --failure--> open, longer      (the probe answered the question)
;   disabled                                 (the operator's decision only)

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "config.inc"
%include "routing.inc"

        extern af_mem_zero
        extern af_mem_copy
        extern af_cstr_len
        extern af_cstr_eq
        extern af_alloc
        extern af_free
        extern af_monotonic_now

        section .rodata

n_healthy:   db "healthy", 0
n_degraded:  db "degraded", 0
n_open:      db "open", 0
n_half_open: db "half_open", 0
n_disabled:  db "disabled", 0
n_unknown:   db "unknown", 0

        section .data.rel.ro progbits align=8

health_names:
        dq n_healthy
        dq n_degraded
        dq n_open
        dq n_half_open
        dq n_disabled

        section .text

; ---------------------------------------------------------------------------
; af_routing_init(af_routing *rt) -> af_status
; ---------------------------------------------------------------------------
        global af_routing_init
af_routing_init:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rsi, RTB_SIZE
        call    af_mem_zero
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_routing_free(af_routing *rt) -> void
;
; Releases the owned identifier copies. The table itself belongs to whoever
; allocated it, which is the daemon context.
; ---------------------------------------------------------------------------
        global af_routing_free
af_routing_free:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi

        xor     r12, r12
.providers:
        cmp     r12, [rbx + RTB_PROVIDER_COUNT]
        jae     .routes_start
        mov     rax, r12
        imul    rax, rax, PS_SIZE
        add     rax, rbx
        add     rax, RTB_PROVIDERS
        mov     rdi, [rax + PS_ID]
        test    rdi, rdi
        jz      .next_provider
        mov     r13, rax
        call    af_free
        mov     qword [r13 + PS_ID], 0
.next_provider:
        inc     r12
        jmp     .providers

.routes_start:
        xor     r12, r12
.routes:
        cmp     r12, [rbx + RTB_ROUTE_COUNT]
        jae     .done
        mov     rax, r12
        imul    rax, rax, RS_SIZE
        add     rax, rbx
        add     rax, RTB_ROUTES
        mov     rdi, [rax + RS_ID]
        test    rdi, rdi
        jz      .next_route
        mov     r13, rax
        call    af_free
        mov     qword [r13 + RS_ID], 0
.next_route:
        inc     r12
        jmp     .routes
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_routing_own_id(const char *id) -> char * (owned copy, NULL on failure)
;
; Runtime state outlives the snapshot that named it: a reload frees every
; string the configuration owned, and a circuit that is open has to stay open
; for the provider it was opened against. Keying on a borrowed pointer would
; make that key dangle at the first reload.
; ---------------------------------------------------------------------------
        global af_routing_own_id
af_routing_own_id:
        AF_ENTER 32
        test    rdi, rdi
        jz      .none
        mov     rbx, rdi
        call    af_cstr_len
        mov     r12, rax
        lea     rdi, [r12 + 1]
        call    af_alloc
        test    rax, rax
        jz      .none
        mov     r13, rax
        mov     rdi, r13
        mov     rsi, rbx
        lea     rdx, [r12 + 1]
        call    af_mem_copy
        mov     rax, r13
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_routing_provider(af_routing *rt, const char *id) -> af_prov_state *
;
; The state for `id`, created on first sight. NULL when the table is full,
; which a configuration the validator accepted cannot cause: the table is the
; schema's own maximum.
; ---------------------------------------------------------------------------
        global af_routing_provider
af_routing_provider:
        AF_ENTER 32
        test    rdi, rdi
        jz      .none
        test    rsi, rsi
        jz      .none
        mov     rbx, rdi
        mov     r12, rsi

        xor     r13, r13
.scan:
        cmp     r13, [rbx + RTB_PROVIDER_COUNT]
        jae     .create
        mov     r14, r13
        imul    r14, r14, PS_SIZE
        add     r14, rbx
        add     r14, RTB_PROVIDERS
        mov     rdi, [r14 + PS_ID]
        test    rdi, rdi
        jz      .next
        mov     rsi, r12
        call    af_cstr_eq
        test    rax, rax
        jnz     .found
.next:
        inc     r13
        jmp     .scan
.found:
        mov     rax, r14
        AF_LEAVE

.create:
        cmp     r13, AF_ROUTING_MAX_PROVIDERS
        jae     .none
        mov     r14, r13
        imul    r14, r14, PS_SIZE
        add     r14, rbx
        add     r14, RTB_PROVIDERS
        mov     rdi, r14
        mov     rsi, PS_SIZE
        call    af_mem_zero
        mov     rdi, r12
        call    af_routing_own_id
        test    rax, rax
        jz      .none
        mov     [r14 + PS_ID], rax
        mov     qword [r14 + PS_HEALTH], AF_HEALTH_HEALTHY
        inc     qword [rbx + RTB_PROVIDER_COUNT]
        mov     rax, r14
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_routing_route(af_routing *rt, const char *id) -> af_route_state *
;
; The round-robin cursor lives here rather than on the snapshot, because the
; whitepaper is explicit that a reload changing the target set keeps the cursor
; and applies the new count to it.
; ---------------------------------------------------------------------------
        global af_routing_route
af_routing_route:
        AF_ENTER 32
        test    rdi, rdi
        jz      .none
        test    rsi, rsi
        jz      .none
        mov     rbx, rdi
        mov     r12, rsi

        xor     r13, r13
.scan:
        cmp     r13, [rbx + RTB_ROUTE_COUNT]
        jae     .create
        mov     r14, r13
        imul    r14, r14, RS_SIZE
        add     r14, rbx
        add     r14, RTB_ROUTES
        mov     rdi, [r14 + RS_ID]
        test    rdi, rdi
        jz      .next
        mov     rsi, r12
        call    af_cstr_eq
        test    rax, rax
        jnz     .found
.next:
        inc     r13
        jmp     .scan
.found:
        mov     rax, r14
        AF_LEAVE

.create:
        cmp     r13, AF_ROUTING_MAX_ROUTES
        jae     .none
        mov     r14, r13
        imul    r14, r14, RS_SIZE
        add     r14, rbx
        add     r14, RTB_ROUTES
        mov     rdi, r14
        mov     rsi, RS_SIZE
        call    af_mem_zero
        mov     rdi, r12
        call    af_routing_own_id
        test    rax, rax
        jz      .none
        mov     [r14 + RS_ID], rax
        inc     qword [rbx + RTB_ROUTE_COUNT]
        mov     rax, r14
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_routing_now_ns(af_routing *rt) -> u64
;
; The monotonic clock, or whatever a test pinned it to. A circuit-breaker
; timeline that could only be tested by sleeping would be a timeline nobody
; tests at the boundaries.
; ---------------------------------------------------------------------------
        global af_routing_now_ns
af_routing_now_ns:
        AF_ENTER 0
        test    rdi, rdi
        jz      .real
        mov     rax, [rdi + RTB_CLOCK_OVERRIDE]
        test    rax, rax
        jz      .real
        AF_LEAVE
.real:
        call    af_monotonic_now
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_routing_set_now(af_routing *rt, u64 ns) -> void
; ---------------------------------------------------------------------------
        global af_routing_set_now
af_routing_set_now:
        test    rdi, rdi
        jz      .done
        mov     [rdi + RTB_CLOCK_OVERRIDE], rsi
.done:
        ret

; ---------------------------------------------------------------------------
; af_health_refresh(af_prov_state *s, u64 now_ns) -> void
;
; The one transition time makes on its own. Everything else in the machine is
; driven by a request's outcome; a cooldown expiring is driven by nothing, so
; it is applied whenever the state is looked at.
; ---------------------------------------------------------------------------
        global af_health_refresh
af_health_refresh:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        cmp     qword [rdi + PS_HEALTH], AF_HEALTH_OPEN
        jne     .done
        mov     rax, [rdi + PS_OPEN_UNTIL]
        cmp     rsi, rax
        jb      .done
        mov     qword [rdi + PS_HEALTH], AF_HEALTH_HALF_OPEN
        mov     qword [rdi + PS_PROBES], 0
        mov     qword [rdi + PS_SUCCESSES], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_health_admit(const af_prov_state *s) -> i64 (1 = a request may be sent)
;
; Call af_health_refresh first: this reads the state, it does not advance it.
; ---------------------------------------------------------------------------
        global af_health_admit
af_health_admit:
        test    rdi, rdi
        jz      .no
        mov     rax, [rdi + PS_HEALTH]
        cmp     rax, AF_HEALTH_HEALTHY
        je      .yes
        cmp     rax, AF_HEALTH_DEGRADED
        je      .yes
        cmp     rax, AF_HEALTH_HALF_OPEN
        jne     .no
        ; A half-open circuit admits one probe and no more. Admitting a second
        ; would send real traffic to a provider that has not yet answered the
        ; question the first one is asking.
        mov     rax, [rdi + PS_PROBES]
        cmp     rax, AF_HALF_OPEN_PROBES
        jae     .no
.yes:
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_health_begin(af_prov_state *s) -> i64 (1 when this attempt is a probe)
;
; Claims a concurrency slot. The return value has to be carried by the caller
; until the attempt ends, because the state may have changed by then and
; "was this a probe" is not recoverable from it afterwards.
; ---------------------------------------------------------------------------
        global af_health_begin
af_health_begin:
        AF_ENTER 0
        test    rdi, rdi
        jz      .none
        inc     qword [rdi + PS_ACTIVE]
        inc     qword [rdi + PS_REQUESTS]
        cmp     qword [rdi + PS_HEALTH], AF_HEALTH_HALF_OPEN
        jne     .none
        inc     qword [rdi + PS_PROBES]
        mov     eax, 1
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_health_end(af_prov_state *s, i64 was_probe) -> void
;
; Releases the slot. Called from exactly one place — the exchange's teardown —
; so that every way an attempt can end releases it (M7 DoD 9).
; ---------------------------------------------------------------------------
        global af_health_end
af_health_end:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        cmp     qword [rdi + PS_ACTIVE], 0
        je      .probe
        dec     qword [rdi + PS_ACTIVE]
.probe:
        test    rsi, rsi
        jz      .done
        cmp     qword [rdi + PS_PROBES], 0
        je      .done
        dec     qword [rdi + PS_PROBES]
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_health_ewma(u64 old_us, u64 observed_us) -> u64
;
;   new = alpha * observed + (1 - alpha) * old
;
; as an integer ratio, because a routing decision must not depend on floating
; point rounding. The observed value is clamped to at least one microsecond so
; that "measured, and very fast" stays distinguishable from "never measured",
; which is the difference between ranking first and ranking after everything
; measured.
; ---------------------------------------------------------------------------
        global af_health_ewma
af_health_ewma:
        AF_ENTER 0
        mov     rax, rsi
        test    rax, rax
        jnz     .have_observed
        mov     eax, 1
.have_observed:
        test    rdi, rdi
        jz      .first                          ; nothing measured before

        ; (observed * NUM + old * (DEN - NUM)) / DEN, with the multiply checked:
        ; both terms are microsecond counts bounded by the request timeout, so
        ; an overflow means something upstream is already wrong.
        mov     rcx, rax
        imul    rcx, rcx, AF_EWMA_ALPHA_NUM
        jo      .first
        mov     rdx, rdi
        imul    rdx, rdx, (AF_EWMA_ALPHA_DEN - AF_EWMA_ALPHA_NUM)
        jo      .first
        add     rcx, rdx
        jc      .first
        mov     rax, rcx
        xor     edx, edx
        mov     rcx, AF_EWMA_ALPHA_DEN
        div     rcx
        test    rax, rax
        jnz     .done
        mov     eax, 1                          ; never round down to "unknown"
.done:
        AF_LEAVE
.first:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_health_success(af_prov_state *s, const af_cfg_provider *p, u64 latency_us)
;   -> void
; ---------------------------------------------------------------------------
        global af_health_success
af_health_success:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     qword [rbx + PS_FAILURES], 0
        inc     qword [rbx + PS_SUCCESSES]

        mov     rdi, [rbx + PS_EWMA]
        mov     rsi, r13
        call    af_health_ewma
        mov     [rbx + PS_EWMA], rax

        mov     rax, [rbx + PS_HEALTH]
        cmp     rax, AF_HEALTH_HEALTHY
        je      .done
        cmp     rax, AF_HEALTH_DISABLED
        je      .done
        cmp     rax, AF_HEALTH_OPEN
        je      .done                           ; a success while open is stale

        ; degraded or half-open: enough consecutive successes closes it.
        mov     r14, 1
        test    r12, r12
        jz      .have_threshold
        mov     r14, [r12 + PRV_HEALTH + HLT_SUCC_THR]
        test    r14, r14
        jnz     .have_threshold
        mov     r14, 1
.have_threshold:
        mov     rax, [rbx + PS_SUCCESSES]
        cmp     rax, r14
        jb      .done
        mov     qword [rbx + PS_HEALTH], AF_HEALTH_HEALTHY
        mov     qword [rbx + PS_BACKOFF_MS], 0
        mov     qword [rbx + PS_SUCCESSES], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_health_failure(af_prov_state *s, const af_cfg_provider *p, u64 now_ns)
;   -> void
;
; A failed half-open probe returns to open with a longer cooldown. Returning to
; the original cooldown instead would make a provider that is down for an hour
; receive a probe every `open_cooldown_ms` for that hour, which is the
; behaviour a circuit breaker exists to avoid.
; ---------------------------------------------------------------------------
        global af_health_failure
af_health_failure:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        mov     qword [rbx + PS_SUCCESSES], 0
        inc     qword [rbx + PS_FAILURES]
        inc     qword [rbx + PS_FAILED]

        cmp     qword [rbx + PS_HEALTH], AF_HEALTH_DISABLED
        je      .done

        ; The configured cooldown, and the failure threshold.
        mov     r14, 1000                       ; cooldown ms
        mov     r15, 1                          ; failure threshold
        test    r12, r12
        jz      .have_config
        mov     rax, [r12 + PRV_HEALTH + HLT_COOLDOWN_MS]
        test    rax, rax
        jz      .cooldown_default
        mov     r14, rax
.cooldown_default:
        mov     rax, [r12 + PRV_HEALTH + HLT_FAIL_THR]
        test    rax, rax
        jz      .have_config
        mov     r15, rax
.have_config:

        cmp     qword [rbx + PS_HEALTH], AF_HEALTH_HALF_OPEN
        je      .probe_failed

        mov     rax, [rbx + PS_FAILURES]
        cmp     rax, r15
        jae     .trip
        mov     qword [rbx + PS_HEALTH], AF_HEALTH_DEGRADED
        AF_LEAVE

.trip:
        mov     [rbx + PS_BACKOFF_MS], r14
        jmp     .open_it

.probe_failed:
        ; Double the previous cooldown, bounded, so a long outage is probed
        ; less and less often rather than at a fixed rate.
        mov     rax, [rbx + PS_BACKOFF_MS]
        test    rax, rax
        jnz     .have_backoff
        mov     rax, r14
.have_backoff:
        add     rax, rax
        jc      .cap
        mov     rcx, r14
        imul    rcx, rcx, AF_HEALTH_MAX_BACKOFF
        jo      .cap
        cmp     rax, rcx
        jbe     .backoff_ready
.cap:
        mov     rax, r14
        imul    rax, rax, AF_HEALTH_MAX_BACKOFF
.backoff_ready:
        mov     [rbx + PS_BACKOFF_MS], rax

.open_it:
        mov     qword [rbx + PS_HEALTH], AF_HEALTH_OPEN
        mov     qword [rbx + PS_PROBES], 0
        inc     qword [rbx + PS_OPENED]
        mov     rax, [rbx + PS_BACKOFF_MS]
        imul    rax, rax, NS_PER_MS
        add     rax, r13
        mov     [rbx + PS_OPEN_UNTIL], rax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_health_state_name(i64 state) -> const char *
; ---------------------------------------------------------------------------
        global af_health_state_name
af_health_state_name:
        cmp     rdi, AF_HEALTH_COUNT
        jae     .unknown
        lea     rax, [health_names]
        mov     rax, [rax + rdi*8]
        ret
.unknown:
        lea     rax, [n_unknown]
        ret

; ---------------------------------------------------------------------------
; Accessors, so a test reads the layout rather than restating it.
; ---------------------------------------------------------------------------
        global af_routing_struct_size
af_routing_struct_size:
        mov     rax, RTB_SIZE
        ret

        global af_prov_state_struct_size
af_prov_state_struct_size:
        mov     rax, PS_SIZE
        ret

        global af_health_get
af_health_get:
        test    rdi, rdi
        jz      .zero
        mov     rax, [rdi + PS_HEALTH]
        ret
.zero:
        xor     eax, eax
        ret

        global af_health_active
af_health_active:
        test    rdi, rdi
        jz      .zero
        mov     rax, [rdi + PS_ACTIVE]
        ret
.zero:
        xor     eax, eax
        ret
