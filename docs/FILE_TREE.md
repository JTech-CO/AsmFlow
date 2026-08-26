# AsmFlow File Tree and Ownership

```text
AsmFlow/
├── README.md                         # public project overview and status
├── .gitattributes                     # LF and binary/text normalization
├── LICENSE                           # Apache License 2.0 full text
├── NOTICE                            # project copyright/notice
├── CONTRIBUTING.md                   # contribution and assembly rules
├── CODE_OF_CONDUCT.md                # community conduct policy
├── SECURITY.md                       # vulnerability reporting and secure defaults
├── CHANGELOG.md                      # release history
├── ROADMAP.md                        # milestone scope
├── ARCHITECTURE.md                   # concise normative architecture
├── HARNESS.md                        # Codex phase gates and runbook
├── AGENTS.md                         # repository-wide Codex invariants
├── PROGRESS.md                       # session handoff
├── VERSION                           # canonical version
├── Makefile                          # validation now, build targets later
├── config/
│   └── asmflow.schema.json           # machine-readable config contract
├── docs/
│   ├── README.md                      # documentation index
│   ├── TECHNICAL_WHITEPAPER_KR.md    # detailed technical design
│   ├── DESIGN_WHITEPAPER_KR.md       # TUI/UX design system
│   ├── API_CONTRACT.md               # data/control interfaces
│   ├── CONFIGURATION.md              # config semantics and examples
│   ├── MCP_COMPATIBILITY.md          # protocol-era adapters
│   ├── SECURITY_MODEL.md             # threats, controls, residual risks
│   ├── TEST_STRATEGY.md              # test layers and gates
│   ├── BUILD_AND_RELEASE.md           # build/package/release process
│   ├── FILE_TREE.md                   # this file
│   ├── GLOSSARY.md                    # shared terminology
│   └── decisions/                     # architecture decision records
├── examples/
│   ├── README.md
│   ├── asmflow.minimal.json
│   ├── asmflow.full.json
│   ├── curl-chat-completions.sh
│   ├── curl-responses.sh
│   ├── env.example
│   └── systemd/asmflow.service
├── tests/
│   ├── README.md
│   ├── route_oracle.py
│   ├── test_route_oracle.py
│   ├── test_contracts.py
│   ├── mock_provider.py
│   ├── mock_mcp_stdio.py
│   └── fixtures/
├── scripts/
│   ├── validate_repo.py
│   └── package.sh
├── include/
│   └── README.md                      # future public assembly include policy
├── packaging/
│   ├── README.md
│   └── systemd/asmflow.service
├── src/
│   ├── README.md
│   ├── platform/linux_x86_64/         # OS/ABI adapters
│   ├── memory/                        # allocators, arenas, buffers
│   ├── core/                          # results, errors, IDs, timers
│   ├── json/                          # JSON wrappers
│   ├── http/                          # listener and framing
│   ├── providers/                     # upstream adapters
│   ├── routing/                       # pure routing policy
│   ├── mcp/                           # MCP protocol/supervision
│   ├── storage/                       # SQLite and migrations
│   ├── control/                       # UDS control protocol
│   ├── tui/                           # separate TUI binary
│   └── ffi/                           # minimal C ABI shims
└── .github/
    ├── workflows/ci.yml
    ├── ISSUE_TEMPLATE/
    ├── pull_request_template.md
    └── dependabot.yml
```

## Ownership rules

- Public behavior belongs in root docs and `docs/`.
- Machine contracts belong in `config/` and `tests/fixtures/`.
- Runtime code belongs only in `src/`.
- Reusable exported assembly definitions belong in `include/` after a real second consumer exists.
- Packaging files are not runtime source.
- Python in `tests/` and `scripts/` cannot be imported by runtime binaries.
- `.github/` automation must call the same Make targets developers use locally.
