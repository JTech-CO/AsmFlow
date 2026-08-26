## Summary

Describe the problem, the bounded change, and why this repository is the correct layer.

## Phase and contract

- Current HARNESS phase:
- Related issue/ADR:
- Affected protocol or configuration contract:

## Verification

```text
make check
# Add the phase-specific commands and their results.
```

- [ ] All current phase gates pass.
- [ ] New behavior has deterministic tests or fixtures.
- [ ] Assembly/Python reference parity is demonstrated where applicable.
- [ ] Failure and cancellation paths are tested.
- [ ] `PROGRESS.md` is updated.

## Invariants

- [ ] Core policy and state-machine logic remains in assembly.
- [ ] C shims expose mechanisms only and do not own product policy.
- [ ] No fallback occurs after response commitment.
- [ ] `asmflow-tui` does not access SQLite directly.
- [ ] MCP modern and legacy protocol paths remain version-isolated.
- [ ] No secret, prompt/output payload, database, binary, log, or core dump is committed.

## Documentation and compatibility

- [ ] User-visible behavior and configuration changes are documented.
- [ ] Compatibility impact and migration steps are stated.
- [ ] `CHANGELOG.md` is updated when appropriate.
- [ ] An ADR is included for an architecture or invariant change.

## Security review notes

State whether the change modifies listener exposure, authentication, secret resolution,
child-process execution, file permissions, logging/redaction, or upstream TLS handling.
