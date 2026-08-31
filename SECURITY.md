# Security Policy

## Supported versions

AsmFlow is pre-release software. The `0.10.0` M11 milestone is implemented and security
tested, but no binary release is supported for production use yet. Once releases begin,
the newest minor release line will receive security fixes until the first stable `1.x`
policy is published.

| Version | Supported |
|---|---|
| `0.10.0` development milestone | Security reports accepted; not production-supported |
| `0.1.0-spec` through `0.9.x` | No |
| Runtime builds from untagged branches | No |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub private
vulnerability reporting when enabled, or contact the maintainers through the private
contact method listed in repository metadata.

Include:

- affected commit or version;
- operating system and CPU;
- minimal reproduction steps;
- security impact and preconditions;
- logs with credentials, prompts, response bodies, tokens, and personal data removed;
- whether the issue is already public.

The project aims to acknowledge credible reports within three business days, provide an
initial assessment within seven business days, and coordinate a fix and disclosure plan
based on severity. These are targets, not contractual service levels.

## Security-sensitive areas

The following surfaces deserve special scrutiny:

- assembly/C ABI boundaries and stack alignment;
- buffer sizing, integer overflow, and lifetime ownership;
- HTTP request smuggling, oversized bodies, malformed SSE, and client disconnects;
- secret references, header redaction, and opt-in payload logging;
- routing retries that could duplicate billable requests;
- MCP command execution, environment inheritance, working directories, and restart loops;
- MCP protocol-version fallback and mismatched HTTP/body metadata;
- Unix-domain socket permissions and non-loopback listener configuration;
- SQLite file permissions, migration integrity, and crash recovery.

## Safe defaults

- Data-plane listener binds to `127.0.0.1` unless explicitly changed.
- Control-plane access uses a per-user Unix-domain socket with mode `0600`.
- Control peers must present an exact Linux `SO_PEERCRED` record for the daemon's
  effective UID; malformed or different-UID peers fail closed.
- Configuration and state live in owner-only directories. Config/database symlinks,
  FIFOs, wrong owners, and group/world permission bits are rejected rather than repaired.
- API keys are referenced by environment-variable name; plaintext secret values are
  rejected by configuration validation.
- MCP stdio commands are executed as an argument vector without invoking a shell.
- Prompt and response bodies are not persisted by default.
- Authorization, cookie, proxy-authorization, and configured secret headers are redacted.
- Diagnostic export always excludes payloads and secret values; mutation audit rows
  retain only time, peer identity, static action/outcome, and normalized status.
- Fallback is prohibited after the first downstream byte has been forwarded.
- Plain HTTP remote endpoints are rejected unless the destination is loopback or an
  operator-approved private-network exception.
- SIGTERM stops new accepts before a bounded in-flight drain, then stops MCP and closes
  SQLite. SIGKILL recovery is verified on the next start against WAL and a stale socket.

## Out of scope

Reports that require an operator to deliberately disable documented safety controls may
be treated as hardening suggestions rather than vulnerabilities. Third-party model or
MCP server defects should be reported to their maintainers unless AsmFlow amplifies or
misrepresents the risk.
