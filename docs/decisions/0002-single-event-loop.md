# ADR 0002: Single-owner, single-thread event loop for 1.0

- **Status:** Accepted
- **Date:** 2026-08-02

## Context

Threads add synchronization, shared lifetime, SQLite, and libcurl safety complexity to a memory-unsafe assembly
codebase.

## Decision

`asmflowd` starts with one event-loop thread owning mutable runtime state. Linux readiness APIs and libcurl
multi handle network concurrency. TUI is a separate process.

## Consequences

- Ownership and deterministic routing are easier to audit.
- Blocking callbacks and long SQL transactions are forbidden.
- Threads require benchmark evidence and a new ADR.
