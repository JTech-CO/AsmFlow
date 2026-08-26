# ADR 0005: Separate TUI process over Unix-domain control socket

- **Status:** Accepted
- **Date:** 2026-08-02

## Context

Combining ncurses with the gateway event loop couples terminal crashes, resize behavior, and rendering latency to
request processing. Direct SQLite access creates multiple writers and state bypass.

## Decision

`asmflow-tui` is a separate process. It reads and mutates state only through a mode-0600 Unix-domain control
socket. `asmflowd` remains the sole SQLite writer.

## Consequences

- Daemon can run headless and survive TUI exit.
- A versioned control protocol is required.
- TUI snapshots may be briefly stale and must display that state.
