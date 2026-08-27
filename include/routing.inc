; AsmFlow — routing, health, and the circuit breaker.
;
; This is the layer HARNESS.md calls the project's core value and its riskiest
; stretch, for a reason worth stating: a routing defect does not look like a
; defect. A request that went to the wrong target still gets an answer, and the
; answer still looks right. Nothing crashes, nothing is refused, and the only
; symptom is that a provider the operator meant to drain kept receiving
; traffic, or a circuit that should have opened did not.
;
; So the arrangement here is built to be checkable rather than merely correct.
; `tests/route_oracle.py` states the selection rules in Python; the functions in
; `src/routing/` state them in assembly; and a corpus runs both over the same
; inputs and fails on any disagreement. Everything in this header exists to make
; those two statements comparable — the candidate record below carries exactly
; the fields the oracle's `Candidate` carries, in the same meaning.
;
; Ownership: runtime state is keyed by identifier, not by array position. A
; reload can reorder providers, add one, or remove one, and a circuit that was
; open must stay open for the provider it was opened against — not for whoever
; now occupies index 3.

%ifndef ASMFLOW_ROUTING_INC
%define ASMFLOW_ROUTING_INC

; --- capacity ---------------------------------------------------------------
; The schema's own maxima. Sizing the tables to them means a configuration the
; validator accepted can always be served, and the tables are still fixed.
%define AF_ROUTING_MAX_PROVIDERS 256
%define AF_ROUTING_MAX_ROUTES    256

; A route may name at most 64 targets (config/asmflow.schema.json), which is why
; the already-tried set is one 64-bit word rather than a bitmap with a length.
%define AF_ROUTING_MAX_TARGETS 64

; --- health states ----------------------------------------------------------
; The five states themselves are AF_HEALTH_* in asmflow.inc, where they have
; been since M0 alongside the other schema-facing enumerations. Only the count
; belongs here, because only this layer iterates over them.
%define AF_HEALTH_COUNT 5

; --- EWMA -------------------------------------------------------------------
; new = alpha * observed + (1 - alpha) * old, as an integer ratio so no float
; ever enters a routing decision. 1/4 is responsive enough to follow a provider
; degrading without letting one slow request move the ranking on its own.
%define AF_EWMA_ALPHA_NUM 1
%define AF_EWMA_ALPHA_DEN 4

; A latency nothing has measured yet. Ranked after every measured candidate and
; before every half-open one, which is what the oracle does with `None`.
%define AF_LATENCY_UNKNOWN 0

; --- af_route_candidate (72 bytes) ------------------------------------------
; One eligible target, flattened. The fields mirror `Candidate` in
; tests/route_oracle.py one for one; anything the oracle does not have is not
; here, because a field the parity test cannot see is a field that can drift.
;
;   +0   target          af_cfg_route_target * (BORROWED from the snapshot)
;   +8   provider        af_cfg_provider *     (BORROWED)
;   +16  state           af_prov_state *       (BORROWED, runtime)
;   +24  configured_index  position in the route's target array
;   +32  priority        signed, from the target
;   +40  weight          from the target
;   +48  health          AF_HEALTH_*
;   +56  latency_us      EWMA, or AF_LATENCY_UNKNOWN
;   +64  provider_id     const char * (for the bytewise tie-break)
%define RC_TARGET     0
%define RC_PROVIDER   8
%define RC_STATE      16
%define RC_INDEX      24
%define RC_PRIORITY   32
%define RC_WEIGHT     40
%define RC_HEALTH     48
%define RC_LATENCY    56
%define RC_PROVIDER_ID 64
%define RC_SIZE       72

; --- af_route_request (56 bytes) --------------------------------------------
; Everything candidate filtering needs, in one place. Six arguments is the
; register limit and this needs seven, so the choice is a struct or a spilled
; argument; a struct is also what the corpus harness can fill in directly.
;
;   +0   routing        af_routing *
;   +8   config         af_config *
;   +16  route          af_cfg_route *
;   +24  family_bit     AF_EPF_* for the endpoint being served
;   +32  required_caps  AF_CAP_* bits the request body implies
;   +40  tried          bitmap of target indices already attempted
;   +48  now_ns         monotonic, so a cooldown is decided against one reading
%define RQ_ROUTING   0
%define RQ_CONFIG    8
%define RQ_ROUTE     16
%define RQ_FAMILY    24
%define RQ_CAPS      32
%define RQ_TRIED     40
%define RQ_NOW_NS    48
%define RQ_SIZE      56

; --- af_prov_state (96 bytes) -----------------------------------------------
; What the runtime knows about a provider that the configuration does not: how
; it has been behaving.
;
;   +0   id            const char * — OWNED copy, so a reload cannot free it
;   +8   health        AF_HEALTH_*
;   +16  failures      consecutive failures, reset by a success
;   +24  successes     consecutive successes, reset by a failure
;   +32  open_until_ns monotonic deadline while open
;   +40  active        transfers in flight against this provider
;   +48  ewma_us       0 until a success has been measured
;   +56  backoff_ms    grows when a half-open probe fails
;   +64  probes        half-open probes in flight (at most one)
;   +72  requests      total attempts started
;   +80  failed        total attempts that ended in a retryable failure
;   +88  opened        how many times the circuit has opened
%define PS_ID            0
%define PS_HEALTH        8
%define PS_FAILURES      16
%define PS_SUCCESSES     24
%define PS_OPEN_UNTIL    32
%define PS_ACTIVE        40
%define PS_EWMA          48
%define PS_BACKOFF_MS    56
%define PS_PROBES        64
%define PS_REQUESTS      72
%define PS_FAILED        80
%define PS_OPENED        88
%define PS_SIZE          96

; Only one probe is admitted while half-open. The whitepaper allows a
; configured number; one is the value AsmFlow uses, because a half-open circuit
; is asking a question and one probe answers it.
%define AF_HALF_OPEN_PROBES 1

; The most a failed probe may stretch the configured cooldown. A provider that
; is down for an hour should be probed less and less often rather than every
; `open_cooldown_ms` for the whole hour — and a provider that recovers should
; still be noticed within a bounded time, which is why the growth stops.
%define AF_HEALTH_MAX_BACKOFF 16

; --- af_route_state (32 bytes) ----------------------------------------------
;   +0   id      const char * — OWNED copy
;   +8   cursor  round-robin position; survives a reload, wraps naturally
;   +16  served  requests routed through this route
;   +24  refused requests with no eligible target
%define RS_ID      0
%define RS_CURSOR  8
%define RS_SERVED  16
%define RS_REFUSED 24
%define RS_SIZE    32

; --- af_routing -------------------------------------------------------------
; The whole runtime routing state. One block, owned by the daemon context.
%define RTB_PROVIDER_COUNT 0
%define RTB_ROUTE_COUNT    8
%define RTB_CLOCK_OVERRIDE 16   ; test hook: non-zero pins "now"
%define RTB_PROVIDERS      24
%define RTB_ROUTES         (RTB_PROVIDERS + AF_ROUTING_MAX_PROVIDERS * PS_SIZE)
%define RTB_SIZE           (RTB_ROUTES + AF_ROUTING_MAX_ROUTES * RS_SIZE)

; --- selection policies -----------------------------------------------------
; The ordinals are AF_POLICY_* from asmflow.inc; nothing new is defined here.

; --- required capabilities --------------------------------------------------
; What a request body implies about the provider it needs. Inspected to filter,
; never to rewrite (docs/API_CONTRACT.md 5).
%define AF_REQ_CAP_STREAMING   AF_CAP_STREAMING
%define AF_REQ_CAP_TOOLS       AF_CAP_TOOLS
%define AF_REQ_CAP_VISION      AF_CAP_VISION
%define AF_REQ_CAP_JSON_SCHEMA AF_CAP_JSON_SCHEMA

%endif ; ASMFLOW_ROUTING_INC
