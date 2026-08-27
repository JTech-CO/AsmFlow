# ADR 0011 — libcurl's multi interface runs inside AsmFlow's event loop

- Status: accepted
- Date: 2026-08-27
- Supersedes: none
- Related: ADR 0002 (single event loop), ADR 0006 (llhttp as a syntax parser),
  ADR 0010 (HTTP connection lifecycle)

## Context

M6 gives the gateway an upstream side. AsmFlow does not implement HTTP client
behaviour — TLS, connection reuse, chunked decoding, HTTP/2 negotiation — and
`ARCHITECTURE.md` names libcurl as the component that does.

libcurl offers three ways to run several transfers at once, and the choice
between them is not a matter of taste.

`curl_easy_perform` runs one transfer to completion and blocks. `curl_multi_perform`
with `curl_multi_wait` (or `curl_multi_poll`) runs many, and still blocks: the
wait belongs to libcurl. Either would give the daemon a second place where it
waits for descriptors.

`curl_multi_socket_action` inverts that. libcurl tells the embedder which
descriptors to watch and for what, and when to call back next; the embedder
owns the wait and calls in when something happens.

## Decision

AsmFlow uses `curl_multi_socket_action`. An upstream socket is registered in the
same epoll set as the listener, the control socket, the idle timer, and the
signal descriptor, through the same `af_loop_add`. libcurl's timer request is a
`timerfd` and therefore also an ordinary loop source.

Three rules follow from that and are enforced in the code:

**AsmFlow deregisters upstream descriptors; it never closes one.** They belong
to libcurl, which reuses connections across transfers. `af_loop_del` was already
written to deregister without closing, for the same reason. `scripts/gate_m6.py`
checks that the socket callback contains no `close`.

**A timer request of zero milliseconds arms the timerfd for one nanosecond.**
libcurl forbids re-entering `curl_multi_socket_action` from inside a callback it
is currently making, and "call me back immediately" is exactly the request that
invites it. Going through the loop expresses the same thing without the
re-entry.

**The completion queue is drained after every action.** A message left in it is
a client left waiting on a transfer that has already finished.

## Consequences

The daemon has one answer to "what is this process waiting for", and it is the
one epoll set. A slow provider cannot make the control socket unresponsive,
because nothing about a provider is ever waited on outside the loop.

The cost is that the integration is not the shortest way to use libcurl. The
socket and timer callbacks have to be right, and a mistake in them shows up as
a transfer that stalls rather than as a compile error. That is the reason
`tests/test_provider_faults.py` includes a stalled-stream case and a
backpressure case: both would hang rather than fail if the loop integration
were wrong, and both have a timeout that turns a hang into a failure.

The alternative — running libcurl on its own thread — was not seriously
considered. ADR 0002 rules out shared writable memory between threads, so an
upstream response would have to cross a queue to reach the connection that
asked for it, and the connection table would need locking it currently does not
have. That is a large change to the ownership model in exchange for avoiding
two callbacks.

## Not decided here

Whether HTTP/2 to a provider is required for 1.0 or merely accepted when
libcurl negotiates it. Nothing above depends on the answer: the socket callback
reports whatever descriptors the chosen protocol needs.
