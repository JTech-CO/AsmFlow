# AsmFlow Examples

- `asmflow.minimal.json`: one loopback OpenAI-compatible Chat provider and one route.
- `asmflow.full.json`: dual endpoint families, safe fallback, SecretRefs, and disabled MCP examples.
- `env.example`: environment-variable names only; copy values into a secure local environment file.
- `curl-chat-completions.sh`: Chat Completions request to the local gateway.
- `curl-responses.sh`: Responses request to the local gateway.
- `systemd/asmflow.service`: user service template for future runtime releases.

No example contains a functional API key. `gpt-example` and `qwen-example` are placeholders and must be
replaced with models available to the configured provider.
