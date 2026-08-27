# ADR 0012 — Routing state is keyed by identifier and outlives the snapshot

- Status: accepted
- Date: 2026-08-27
- Related: ADR 0008 (configuration module boundary), ADR 0011 (libcurl in the loop)

## Context

M7 gives providers a health state, a circuit breaker, and an observed latency,
and gives routes a round-robin cursor. All of it is mutable, and all of it has
to survive a configuration reload — a circuit that opened because a provider is
down has to stay open across the reload that an operator performs *because* it
is down.

A configuration snapshot is the wrong place for it. A snapshot is immutable
once published and is replaced wholesale on reload (`docs/CONFIGURATION.md` 13),
so state stored in one would be discarded exactly when it matters most.

Array position is the wrong key. A reload can add a provider, remove one, or
reorder them. Keying on index would move an open circuit from the provider it
was opened against to whoever now occupies that slot, and the symptom would be
a healthy provider receiving no traffic while a broken one received all of it.

## Decision

Routing state lives in one block owned by the daemon, separate from every
snapshot, and is keyed by the provider or route identifier. The key is an owned
copy of that identifier, because a reload frees every string the snapshot
owned.

Three consequences follow and are enforced:

**The selector is a pure function.** `af_route_candidates` and
`af_route_select` read state and configuration and return a decision. They
read no clock, allocate nothing, and mutate nothing — the caller passes the
current time in. That is what makes M7 DoD 2 (a hundred identical repetitions
of the same scenario) a property of the code rather than a property of the
test's luck, and `scripts/gate_m7.py` checks the call list directly rather than
inferring purity from the repetitions passing.

**The rules are stated twice.** `tests/route_oracle.py` states them in Python
and never links into the product; `src/routing/` states them in assembly;
`tests/test_routing_parity.py` runs both over a generated corpus and fails on
any disagreement in either the candidate set or the selection. This is not
belt-and-braces. A routing defect answers the request, and the answer parses,
and nothing is logged — so "does it work" is not a question a test can ask.
"Does it agree with an independent statement of the rules" is.

**Every deadline is monotonic.** A cooldown measured against the wall clock
would reopen early, or never, the moment an operator corrected the system time,
and the failure would look like a routing defect reproducible only by moving
the clock again.

## Consequences

The daemon carries a fixed 32 KB of routing state sized to the schema's own
maxima, so a configuration the validator accepted can always be served and the
table is still a fixed array.

State accumulates for identifiers that no longer appear in any snapshot. A
provider removed from the configuration keeps its record until the daemon
restarts. That is deliberate: an identifier that comes back — a provider
removed and restored during an incident — comes back to its own history rather
than to a blank one. The cost is bounded by the table size.

The parity corpus supplies two things the oracle takes as given: whether a
provider serves an endpoint family, which AsmFlow derives from its adapter and
capability bits, and that an open circuit past its cooldown is half-open. Both
are asserted separately in `tests/asm/test_routing.asm`, so neither is
unchecked; they are simply checked somewhere other than the parity test, and
`tests/test_routing_parity.py` says so at the top.

## Not decided here

Whether routing state should be persisted across a daemon restart. The database
already holds operator decisions such as "this provider is disabled", which
must survive; health is an observation rather than a decision, and an
observation that is minutes old at startup would be worse than no observation.
Nothing currently persists it.
