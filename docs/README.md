# AsmFlow documentation index

AsmFlow is currently a specification and repository scaffold. Start with the root
`README.md`, then use this index according to the task.

## Product and architecture

- `TECHNICAL_WHITEPAPER_KR.md`: full technical specification and implementation constraints.
- `DESIGN_WHITEPAPER_KR.md`: TUI information architecture, responsive terminal behavior, and design system.
- `../ARCHITECTURE.md`: concise normative architecture and invariants.
- `FILE_TREE.md`: directory ownership and module boundaries.
- `GLOSSARY.md`: canonical terminology.

## Contracts

- `API_CONTRACT.md`: HTTP data plane and Unix-domain control-plane contracts.
- `CONFIGURATION.md`: configuration semantics and safe examples.
- `MCP_COMPATIBILITY.md`: modern/legacy MCP era detection and transport behavior.
- `SECURITY_MODEL.md`: assets, trust boundaries, threats, controls, and residual risks.

## Delivery

- `TEST_STRATEGY.md`: unit, parity, contract, fault, soak, security, and benchmark gates.
- `BUILD_AND_RELEASE.md`: toolchain, artifacts, packaging, SBOM, and release gates.
- `../HARNESS.md`: phase sequence, measurable Definitions of Done, runbook, and stop rules.
- `../AGENTS.md`: Codex-facing repository invariants.
- `../PROGRESS.md`: current implementation phase and session handoff.

## Architecture decisions

The `decisions/` directory records choices that are expensive to reverse. A change that
weakens an invariant or changes a process/protocol boundary requires a new ADR rather
than a silent edit.
