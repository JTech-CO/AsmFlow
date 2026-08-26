# Build and Release Plan

## 1. Target

- Linux x86-64.
- NASM ELF64 objects.
- GCC or Clang linker driver.
- Dynamic system libraries for llhttp, libcurl, SQLite, ncursesw, and Jansson.
- User-level deployment first.

## 2. Planned packages

Development dependencies on Debian/Ubuntu-like systems are expected to include:

```text
nasm
build-essential or clang/lld
libllhttp-dev
libcurl4-openssl-dev
libsqlite3-dev
libncursesw5-dev or distribution equivalent
libjansson-dev
python3
valgrind
gdb
pkg-config
```

Exact minimum versions are fixed after M1 compatibility tests. Documentation should distinguish tested
versions from theoretical minimums.

## 3. Build modes

### Debug

- DWARF symbols;
- assertions and ownership canaries;
- no strip;
- conservative optimization;
- optional verbose state tracing without secrets;
- suitable for GDB/Valgrind.

### Release

- PIE;
- non-executable stack;
- RELRO/NOW where applicable;
- stripped binary plus separate debug symbols if distributed;
- no debug payload logging;
- deterministic version/build metadata.

## 4. Planned Make targets

```text
make build-debug
make build-release
make test-unit
make test-contract
make test-integration
make test-routing-parity
make test-security
make valgrind
make bench
make package
make verify-package
```

At specification stage only `make check`, `make test`, `make validate`, and source `make package` exist.

## 5. Versioning

- `VERSION` is the canonical project version.
- `asmflowd --version`, `asmflow-tui --version`, release tag, changelog, and artifact name must match.
- Specification scaffold uses `0.1.0-spec` and is not a runtime release.
- Runtime prereleases use SemVer prerelease identifiers, for example `0.4.0-alpha.1`.

## 6. Release contents

```text
asmflow-<version>-linux-x86_64/
├── bin/asmflowd
├── bin/asmflow-tui
├── bin/asmflowctl          # if separate
├── share/asmflow/asmflow.schema.json
├── share/asmflow/asmflow.example.json
├── share/man/man1/asmflow-tui.1
├── share/man/man1/asmflowctl.1
├── share/man/man5/asmflow.json.5
├── share/man/man8/asmflowd.8
├── share/systemd/user/asmflow.service
├── LICENSE
├── NOTICE
├── THIRD_PARTY_NOTICES.md
├── SBOM.spdx.json
└── SHA256SUMS
```

## 7. systemd user service

The service:

- runs as the current user;
- uses restrictive umask;
- restarts only on failure with bounded delay;
- does not place secrets on command line;
- reads secrets from an operator-managed environment file or credential mechanism;
- restricts coredumps in production examples;
- preserves access needed for configured MCP child commands.

Hardening directives must be tested against actual MCP use. Do not claim sandboxing that blocks required
functionality and is disabled in practice.

## 8. Reproducibility

Release workflow records:

- source commit;
- NASM/linker/library versions;
- runner OS image;
- build flags;
- generated file hashes;
- SBOM;
- separate debug symbol hash.

A reproducible check compares two clean builds in controlled environments. Differences are documented before
release.

## 9. Signing and checksums

- SHA-256 checksums required.
- GitHub artifact attestation/signing is added when release automation is implemented.
- Tags should be signed where maintainer workflow permits.
- The project never asks users to pipe an unauthenticated remote script directly into a shell.

## 10. CI workflow

Pull request:

- repository validation;
- unit/contract tests;
- build and linker-security inspection;
- selected Valgrind;
- package manifest dry run.

Scheduled/release:

- broader dependency matrix;
- fuzz smoke/corpus;
- long soak;
- benchmark comparison;
- package installation test;
- SBOM and checksum generation.

## 11. Release blocking conditions

- invariant failure;
- memory invalid access or definite leak;
- secret leak;
- modern/legacy MCP ambiguity;
- mixed provider stream;
- zombie child;
- package missing license/notice/schema;
- version mismatch;
- unreviewed architecture drift;
- benchmark regression above approved tolerance without explanation.

## 12. Upgrade and rollback

- stop daemon gracefully;
- back up config and database;
- verify new binary and schema compatibility;
- apply transactional migration;
- retain previous binary and backup until readiness passes;
- rollback executable and restore backup if migration is not backward-compatible.

Automatic destructive rollback is not attempted.
