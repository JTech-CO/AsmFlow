# ADR 0007: Re-export Jansson's macro accessors through a C shim

- Status: Accepted
- Date: 2026-08-26
- Supersedes the open question recorded in `PROGRESS.md` on 2026-08-02:
  "whether the Jansson boundary should link directly or expose a very small C
  shim for ownership-safe accessors".

## Context

Jansson exposes several of its accessors as preprocessor macros rather than
functions. `json_typeof(value)` expands to `((value)->type)`, and the whole
`json_is_*` family is built on it. Assembly cannot call a macro.

Two options were available.

The first was to hard-code the `json_t` layout in NASM and read the type field
directly. That layout is not part of Jansson's compatibility promise. It has
been stable in practice across 2.x, but a change to it would not produce a link
error or a compile error: every parsed document would simply be interpreted as
the wrong type, silently, at runtime. The failure would surface as a
configuration that validates differently after a distribution upgrade.

The second was to compile the macros into real functions once, in C.

## Decision

`src/ffi/json_shim.c` re-exports the accessors AsmFlow needs as ordinary
functions. Every function in it is a one-line forwarding of a macro or a struct
field. It contains no validation, no limit, no policy, no allocation, and no
decision of any kind, which keeps it within the "ABI adapters only" rule in
`AGENTS.md` invariant 2.

Two further pieces of Jansson knowledge live on that side of the boundary for
the same reason: the size of `json_error_t`, which assembly would otherwise have
to reproduce, and the numeric values of the parse flags, which are returned by
`af_jsonc_parse_flags` rather than duplicated.

The type ordinals are not taken on faith. `af_jsonc_type_ordinals` writes the
compiler's own enumerator values into an array, and
`tests/asm/test_json.asm` asserts they match the constants in
`include/json.inc`. A Jansson release that renumbered the enum fails that test
rather than reinterpreting documents.

## Consequences

- The `json_t` layout is no longer a build-time assumption of the assembly.
- Depth, size, element-count, and duplicate-key policy stay entirely in
  `src/json/json.asm`, above the shim. Jansson's own depth ceiling is a
  compile-time constant and it has no per-string ceiling at all, so those limits
  had to be implemented here regardless.
- The depth check runs on raw bytes *before* the parse. A document nested a
  million levels deep is refused without first building a million nodes, which
  is what makes the ceiling a defence rather than a report.
- One more C translation unit appears in the SBOM boundary, and both binaries
  link it: the daemon parses configuration and upstream payloads, the console
  parses the NDJSON control protocol.
