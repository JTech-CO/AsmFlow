# ADR 0004: Version-isolated modern and legacy MCP adapters

- **Status:** Accepted
- **Date:** 2026-08-02

## Context

MCP 2026-07-28 uses per-request metadata and changed Streamable HTTP semantics. 2025-11-25 and earlier use
initialization-based state.

## Decision

Implement separate `modern_2026` and `legacy_2025` adapters. Share only normalized inventory and operator-facing
status. Do not place session IDs or legacy initialization flags in modern state.

## Consequences

- More code, but lower protocol ambiguity.
- Compatibility fixtures are mandatory.
- New protocol eras may add adapters rather than conditions in existing ones.
