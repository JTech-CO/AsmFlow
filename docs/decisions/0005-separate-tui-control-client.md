# ADR 0005: Separate TUI process over Unix-domain control socket

- **Status:** Accepted
- **Date:** 2026-08-02

## Context

Combining ncurses with the gateway event loop couples terminal crashes, resize behavior, and rendering latency to
request processing. Direct SQLite access creates multiple writers and state bypass.

## Decision

`asmflow-tui` and `asmflowctl` are separate control-only processes. They share one
bounded NDJSON socket client, but retain separate entry points and presentation policy:
only the interactive TUI links ncursesw, while the short-lived CLI emits deterministic
JSON or terminal-safe tables. Neither client links storage, providers, SQLite, or
libcurl. Both read and mutate state only through the mode-0600 Unix-domain control
socket, and `asmflowd` remains the sole SQLite writer.

## Consequences

- Daemon can run headless and survive TUI exit.
- A versioned control protocol is required.
- TUI snapshots may be briefly stale and must display that state.
- Automation can use a one-request CLI without importing daemon policy or persistence.
- The shared transport must stay bounded and presentation-neutral; TUI/CLI formatting
  cannot migrate into the daemon.
