# Tests

Current tests validate the specification scaffold. They do not claim that AsmFlow runtime exists.

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

- `route_oracle.py`: test-only expected routing behavior.
- `test_route_oracle.py`: deterministic policy and fallback invariants.
- `test_contracts.py`: examples, secret references, OpenAI/MCP fixtures, and schema basics.
- `mock_provider.py`: local OpenAI-compatible HTTP/SSE mock.
- `mock_mcp_stdio.py`: modern and legacy MCP stdio mock.
- `fixtures/`: versioned protocol corpus.

Future assembly parity tests must consume the same fixture corpus rather than duplicating expected values.
