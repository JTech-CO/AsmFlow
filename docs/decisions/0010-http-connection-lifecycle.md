# ADR 0010: One idle sweep and a lingering close for data-plane connections

- Status: Accepted
- Date: 2026-08-27

## Context

The data-plane listener has to enforce `listener.idle_timeout_ms` and has to end
connections in a way that does not destroy the response it just wrote. Both
turned out to be decisions rather than details.

**Timing out.** A connection may sit half-delivered indefinitely — the slowloris
shape — and the connection table is bounded, so a slot held by a peer that will
never finish is a slot denied to everyone else. The obvious implementation gives
each connection its own timer. On Linux that means a `timerfd` per connection,
which doubles the descriptor cost of a connection and puts a second registration
in the event loop for every accept, in order to enforce a property that is not
about any individual connection: no member of the table may sit inactive longer
than the timeout.

**Closing.** The listener refuses malformed and oversized requests, and the
refusal has to reach a client that is frequently still transmitting when it is
made. Calling `close(2)` on a socket whose receive queue still holds unread bytes
makes the kernel send RST rather than FIN, and an RST discards data the peer has
not yet read — including, reliably, the response explaining the refusal. The
first one-byte-fragmentation test found this immediately: the same request that
answered correctly when written in one call produced no response at all when
written one byte at a time.

## Decision

**The idle timeout is one `timerfd` for the whole listener**, firing every 250 ms
and sweeping the connection table. A connection whose last activity is older than
the configured timeout is closed; one that has a request part-delivered is first
told `408 request_timeout`, because a client that gets a silent disconnection
cannot tell a timeout from a crash.

The sweep interval is a resolution, not the timeout itself: the timeout is a
ceiling on inactivity, so being closed up to 250 ms late is within what the
setting means, and the alternative is a wakeup rate tied to the shortest timeout
any operator might configure.

**A connection that has been answered and is due to close is drained first.**
The write side is shut down with `shutdown(fd, SHUT_WR)`, so the peer sees FIN
and receives everything already written, and the connection is kept in the table
reading and discarding whatever else the peer sends until it stops. The slot is
released on EOF.

A draining connection deliberately does not refresh its activity timestamp. That
is what lets the same idle sweep reclaim a slot from a peer that has been told to
go away and does not, so the drain cannot itself become a way to hold a slot.

## Consequences

- A connection costs one descriptor, not two, and one loop registration, not
  two. The listener holds 128 connections with 129 descriptors plus the timer.
- The sweep is O(table size) every 250 ms — 128 comparisons, four times a
  second — rather than O(1) per expiry. At this table size that is not a cost
  worth a per-connection timer; at a table size where it were, the table would
  need a different structure regardless.
- A refused request reliably receives its explanation, which is what makes the
  status codes in `docs/API_CONTRACT.md` 7 observable by a client rather than
  merely emitted by the daemon.
- The drain adds a state a connection can be in, and therefore a state the fault
  suite has to cover: `tests/test_http_faults.py` asserts that a peer that never
  closes, one that resets, and one that is refused mid-transmission all end with
  the descriptor count back at its baseline.
- Requests are answered from inside the parse, in `on_message_complete`, so a
  pipelined batch is answered in order by construction. What bounds a pipelining
  client is the outbox ceiling rather than a per-message pause: an append that no
  longer fits ends the connection the same way any other protocol failure does.
