# AsmFlow Glossary

- **Adapter**: version- or provider-specific wire logic that converts a normalized request context to one
  upstream protocol without selecting policy.
- **Attempt**: one request dispatch to one upstream target.
- **Candidate**: a route target that remains after capability, health, concurrency, and tried-target filtering.
- **Commit**: the moment AsmFlow begins a client-visible response. After commit, fallback is forbidden.
- **Control plane**: local Unix-domain socket used by TUI/CLI to inspect and mutate daemon state.
- **Data plane**: OpenAI-compatible HTTP listener serving generation clients.
- **Era**: materially different MCP lifecycle model: modern per-request metadata or legacy initialization.
- **Fallback**: selecting a different eligible target after a pre-commit retryable failure.
- **Health state**: normalized provider state: healthy, degraded, open, half-open, or disabled.
- **Inventory**: normalized MCP tools, resources, prompts, capability, version, and cache metadata.
- **MCP Supervisor**: process/HTTP lifecycle manager for configured MCP servers; not an autonomous tool broker.
- **Oracle**: test-only reference implementation used to compare assembly behavior.
- **Provider**: configured upstream LLM API endpoint.
- **Route**: model alias, endpoint families, policy, fallback rule, and ordered targets.
- **SecretRef**: reference to a secret source such as an environment-variable name; never the secret value.
- **Snapshot**: immutable validated configuration/state view held by active requests.
- **Target**: provider plus upstream model and route-specific metadata.
- **TUI**: terminal user interface implemented as a process separate from the daemon.
