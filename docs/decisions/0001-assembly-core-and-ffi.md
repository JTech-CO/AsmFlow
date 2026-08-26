# ADR 0001: Assembly core with narrow C ABI libraries

- **Status:** Accepted
- **Date:** 2026-08-02

## Context

AsmFlow must be a practical assembly project, but implementing TLS, SQLite, and terminal control from scratch
would expand risk without strengthening the product thesis.

## Decision

Core runtime policy and state machines are authored in NASM x86-64. Stable system libraries may be linked
through direct C ABI calls or minimal shims. Shims contain no routing, retry, security, provider, MCP lifecycle,
or persistence policy.

## Consequences

- Project remains genuinely assembly-centric.
- ABI and ownership tests become mandatory.
- Dependency versions and symbols must be documented.
- C convenience cannot become a hidden second implementation.
