# ADR 0008: Configuration is its own module, not part of `json/`

- Status: Accepted
- Date: 2026-08-26

## Context

`ARCHITECTURE.md` 4 writes the dependency chain as `json/config -> storage`,
which reads as one node. `AGENTS.md` also states that `src/json` contains "JSON
dependency wrappers and normalized accessors, not policy".

Configuration validation is policy, and a lot of it: which keys exist, which
values are legal, which cross-references must resolve, which combinations are
refused. Roughly two thousand lines of it. Putting that in `src/json` would
contradict the rule in the same sentence that authorises the directory.

## Decision

`src/json/` keeps the bounded parser and the normalised accessors, and holds no
policy. `src/config/` holds the configuration model, the schema-equivalent
validator, the secret references, and the path expansion. The dependency runs
one way: `config` calls `json`, and `json` knows nothing about configuration.

The console does not link `src/config` at all. It reads and changes state
through the control socket, so it has no reason to parse the daemon's
configuration file, and the Makefile enforces that by never handing those
objects to its link line.

## Consequences

- `ARCHITECTURE.md` 4 and the `AGENTS.md` source-boundary list both gain a
  `config/` entry; the diagram's `json/config` node becomes two.
- A change to a validation rule cannot accidentally alter parser behaviour,
  because the parser cannot see the rule.
- The runtime still applies the schema's rules directly rather than through a
  JSON Schema library, as `HARNESS.md` M3 requires. The duplication between
  `config/asmflow.schema.json` and `src/config/` is checked rather than trusted:
  `tests/test_config_parity.py` runs both over the same corpus and fails on any
  accept/reject disagreement.
- A third implementation exists on purpose. `tests/config_corpus.py` states the
  rules a third time, in Python, so that a disagreement identifies which of the
  three is wrong instead of only that something is.
