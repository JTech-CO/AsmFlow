# Runtime source boundaries

Each directory is populated only as its milestone begins; see `PROGRESS.md` for the
current phase.

- `platform/linux_x86_64`: entry points, syscalls, signals, epoll, process, files, clocks.
- `memory`: allocators, arenas, buffers, string views, checked size arithmetic.
- `core`: result/error, IDs, queues, timers, snapshots.
- `json`: bounded JSON ABI and normalized accessors.
- `config`: configuration model, schema-equivalent validation, secret references, path policy.
- `http`: listener, HTTP envelope, response writer, SSE framing.
- `providers`: upstream request/response adapters.
- `routing`: pure candidate filtering, selection, circuit, fallback eligibility.
- `mcp`: modern/legacy adapters and process/HTTP supervision.
- `storage`: SQLite migrations and repositories.
- `control`: Unix-domain NDJSON protocol.
- `tui`: separate ncursesw client.
- `ffi`: minimal C shims with no application policy.
