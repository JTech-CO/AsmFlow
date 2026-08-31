# ADR 0013 — M11 local authority and recovery boundaries fail closed

- **Status:** Accepted
- **Date:** 2026-08-31
- **Related:** ADR 0002 (single event loop), ADR 0009 (signalfd and single loop)

## Context

M11 joins four boundaries that can otherwise make the same incident ambiguous:
authority-bearing local files, diagnostic output, SQLite recovery, and process
shutdown. Permissively repairing an unsafe path can hide a symlink or ownership error.
Copying a live WAL database as ordinary bytes can produce an incoherent backup.
Payload opt-ins in diagnostics can turn an incident report into a secret leak. Exiting
the reactor immediately on SIGTERM avoids stop latency but abandons responses already
committed to clients; waiting without a deadline makes service stop unreliable.

These are policy decisions and therefore remain in NASM domain code. C shims expose
only the external ABI needed by that code.

## Decision

Local authority fails closed. The daemon establishes a `0077` umask. Configuration,
state, database, and control-socket parents are verified without following the final
symlink. Private directories are owned by the daemon's real UID and have mode exactly
`0700`; existing authority files are regular, owner-readable as appropriate, and have
no group/world bits. Existing database files must also be owner-writable. Unsafe
objects are rejected, never silently repaired. A control connection is admitted only
after Linux returns an exact `struct ucred` and its UID matches the daemon's effective
UID.

Observability minimizes data. Header redaction is structured and combines mandatory
sensitive names with configured auth-header names. Diagnostic export always reports a
redacted, bounded state snapshot and hard-codes payload and secret inclusion to false.
Mutation audit rows contain only time, peer UID/PID, a static action and outcome, and a
normalized status; parameters, payloads, credentials, tool arguments, and results are
not columns.

Backup and restore use SQLite's online-backup API with checked page arithmetic. A
destination must be a fresh `O_EXCL|NOFOLLOW` path, is held at mode `0600`, is integrity
checked, and is `fsync`ed before success. Neither operation replaces or renames over an
existing path. The caller coordinates when a verified fresh restore becomes the live
database; the M12 upgrade workflow owns that higher-level operation.

SIGTERM first marks the daemon unready and stops data-plane accepts. The existing
reactor continues for at most five seconds so already in-flight HTTP/provider work can
finish. Teardown then stops MCP supervision before SQLite closes. A second termination
signal expires the grace immediately. SIGKILL has no cleanup path; the next start must
reclaim only a proven-stale control socket, let SQLite recover its WAL, and apply pending
transactional migrations before readiness.

## Consequences

- Existing installations with broad or mismatched permissions fail with an actionable
  error and require an operator to correct ownership or mode.
- Diagnostic export cannot be used to retrieve prompts, responses, tool arguments, or
  secret values, even when payload logging is separately enabled.
- Restore is deliberately a fresh-path primitive rather than an in-place replacement;
  release upgrade/rollback orchestration remains M12 work.
- Normal SIGTERM latency can extend to the five-second drain bound, while a second
  signal remains an explicit fast-stop mechanism.
- Same-process-group MCP cleanup is not a cgroup or namespace sandbox. Descendants that
  deliberately escape the saved process group remain a documented residual risk.
