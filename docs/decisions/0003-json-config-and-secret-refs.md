# ADR 0003: JSON configuration and environment secret references

- **Status:** Accepted
- **Date:** 2026-08-02

## Context

Adding TOML/YAML would require another parser. Plaintext keys in configuration create avoidable leakage.

## Decision

Use versioned JSON configuration and JSON Schema. Secrets are represented by environment-variable references;
plaintext values are rejected.

## Consequences

- Parser capability is reused.
- Human editing is less friendly than TOML but examples and validation compensate.
- Secret managers beyond environment references require later explicit design.
