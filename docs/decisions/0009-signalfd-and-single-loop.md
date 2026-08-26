# ADR 0009: Signals arrive through the event loop, not through handlers

- Status: Accepted
- Date: 2026-08-27

## Context

`asmflowd` owns a SQLite handle, libcurl state, MCP child processes, and a
control socket. It has to shut down cleanly on SIGTERM: stop accepting, drain
what is in flight, stop the children, close the database — the sequence
`HARNESS.md` M11 DoD 6 requires.

A conventional signal handler cannot do any of that. It runs at an arbitrary
instruction boundary and may call only async-signal-safe functions;
`sqlite3_close_v2` is not one, nor is anything that takes a lock the interrupted
code might already hold. The usual workaround is to set a flag and check it
later, which still needs the loop to wake up, and still leaves a window where a
second signal arrives while the first is being handled.

## Decision

The daemon blocks SIGINT, SIGTERM, SIGQUIT, SIGHUP, SIGPIPE, and SIGCHLD before
anything else happens, and opens a `signalfd` for that set. No handler ever runs.
Each signal becomes an ordinary readable event on a descriptor the single event
loop already knows how to dispatch, and shutdown therefore runs on the normal
path with the whole runtime available.

SIGPIPE is in the set for a different reason: writing to a socket whose peer has
gone would otherwise terminate the process. Blocked, the write returns `EPIPE`
and the connection is closed the same way every other failure is.

The signal descriptor is drained in a loop rather than read once, so a second
SIGTERM that queued while the first was being handled is not lost.

Everything else keeps its default disposition. A daemon that caught SIGSEGV
would hide exactly the defect the crash tests in `tests/test_asm_crash.py` exist
to surface.

## Consequences

- Shutdown is ordinary code. It can log, close a database, and wait for a child,
  because it is not running in a signal context.
- The blocked set is inherited across `fork`, so the MCP supervisor in M8 must
  restore the default mask in the child before `execve`. A third-party MCP server
  that started with SIGTERM blocked would be unkillable by ordinary means. This
  is written here because it is the kind of thing that is obvious now and
  invisible in six months.
- `SIGCHLD` is already in the set, so M8's child reaping has its wakeup source
  waiting for it.
- The daemon must not create threads without revisiting this: the mask is
  per-thread, and a thread created before the block would keep the default
  disposition.
