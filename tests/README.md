# Tests

The test tree combines native assembly tests, live daemon/client integration suites,
protocol fixtures, and test-only reference oracles.

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

- `route_oracle.py`: test-only expected routing behavior.
- `test_route_oracle.py`: deterministic policy and fallback invariants.
- `test_contracts.py`: examples, secret references, OpenAI/MCP fixtures, and schema basics.
- `mock_provider.py`: local OpenAI-compatible HTTP/SSE mock.
- `mock_mcp_stdio.py`: modern and legacy MCP stdio mock.
- `fixtures/`: versioned protocol corpus.
- `mock_control_server.py`: deterministic NDJSON control peer for operator-client tests.
- `test_tui_layout.py`: 80x24, 100x30, and 140x40 goldens, responsive collapse,
  bounded narrow/too-small modes, truthful action hints, and terminal-control
  escaping.
- `test_tui_keyboard.py`: keyboard navigation, provider stable-ID refresh,
  transactional refresh/selection rollback, command palette, confirmation
  cancel/accept paths, and resize redraw.
- `test_tui_mono.py`: text-state parity for `--mono`, `NO_COLOR`, and a zero-colour
  ASCII terminal.
- `test_tui_terminal_restore.py`: PTY termios, cursor, and alternate-screen recovery
  after quit, SIGINT, SIGHUP, presentation failure, and daemon disconnect.
- `test_cli_contract.py`: `asmflowctl` JSON/table envelopes, usage/runtime exit codes,
  bounded stalled-peer behavior, live-daemon/high-bit config-hash round trips.
- `test_security.py`: non-loopback endpoint authentication, provider credential
  injection rejection, and payload-free mutation audit rows.
- `test_redaction.py`: seeded secret non-disclosure across control, diagnostics,
  CLI, database companions, normal logs, and SIGKILL output.
- `test_permissions.py`: owner/type/mode and no-follow checks for config, state,
  SQLite companions, and the control socket.
- `test_fuzz_smoke.py`: reproducible per-process campaigns for eight bounded native
  parser/framer/redaction targets.
- `test_crash_recovery.py`: SIGKILL WAL, migration, persisted metadata, and stale
  Unix-socket recovery.
- `test_graceful_shutdown.py`: bounded accept-stop/in-flight/MCP/SQLite shutdown order.

`make gate-m11` runs the seven focused M11 targets after all earlier milestone gates,
including the M10 operator-client suites and Valgrind coverage. Assembly parity tests
consume the same fixture corpus rather than duplicating expected values.
