#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${ASMFLOW_BASE_URL:-http://127.0.0.1:8080}"
AUTH_ARGS=()
if [[ -n "${ASMFLOW_GATEWAY_TOKEN:-}" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer ${ASMFLOW_GATEWAY_TOKEN}")
fi

curl --fail-with-body --no-buffer \
  "${AUTH_ARGS[@]}" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "general",
    "messages": [{"role": "user", "content": "Reply with one short sentence."}],
    "stream": false
  }' \
  "${BASE_URL}/v1/chat/completions"
