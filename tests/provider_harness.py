"""A gateway pointed at a mock provider, for the M6 suites.

Kept apart from `http_harness` on purpose. That one describes a listener with
no upstream, which is still what the M5 suites need; this one adds the second
half of the path and nothing else.
"""
from __future__ import annotations

from tests.http_harness import Gateway
from tests.mock_provider import MockProvider

DEFAULT_ALIAS = "general"
DEFAULT_UPSTREAM_MODEL = "provider-model-7b"


def provider_config(
    base_url: str,
    *,
    adapter: str = "openai_dual",
    families=("responses", "chat_completions"),
    responses: bool = True,
    chat: bool = True,
    streaming: bool = True,
    alias: str = DEFAULT_ALIAS,
    upstream_model: str = DEFAULT_UPSTREAM_MODEL,
    connect_ms: int = 2000,
    request_ms: int = 30000,
    idle_stream_ms: int = 5000,
    auth: dict | None = None,
    extra_targets=(),
):
    """A mutate function that repoints the base document at `base_url`."""

    def mutate(document: dict) -> None:
        provider = document["providers"][0]
        provider["id"] = "mock-provider"
        provider["display_name"] = "Mock Provider"
        provider["adapter"] = adapter
        provider["base_url"] = base_url
        provider["auth"] = auth or {"type": "none"}
        provider["allow_insecure_private_http"] = True
        provider["timeouts"] = {
            "connect_ms": connect_ms,
            "request_ms": request_ms,
            "idle_stream_ms": idle_stream_ms,
        }
        provider["capabilities"] = {
            "responses": responses,
            "chat_completions": chat,
            "streaming": streaming,
            "tools": True,
            "vision": False,
            "json_schema": False,
        }
        route = document["routes"][0]
        route["model_alias"] = alias
        route["endpoint_families"] = list(families)
        route["targets"] = [
            {
                "provider_id": "mock-provider",
                "upstream_model": upstream_model,
                "priority": 10,
                "weight": 1,
            }
        ]
        for extra in extra_targets:
            route["targets"].append(extra)

    return mutate


class ProviderGateway:
    """A mock provider and a gateway configured to reach it."""

    def __init__(self, handler, *, mutate=None, **config) -> None:
        self.provider = MockProvider(handler)
        base = provider_config(self.provider.base_url, **config)

        def configure(document):
            base(document)
            if mutate is not None:
                mutate(document)

        try:
            self.gateway = Gateway(mutate=configure)
        except Exception:
            self.provider.close()
            raise

    # --- what the tests reach for -----------------------------------------
    @property
    def requests(self):
        return self.provider.requests

    def post_json(self, target, payload, **kwargs):
        return self.gateway.post_json(target, payload, **kwargs)

    def send_raw(self, payload, timeout=15.0):
        return self.gateway.send_raw(payload, timeout=timeout)

    def connect(self, timeout=15.0):
        return self.gateway.connect(timeout=timeout)

    def descriptor_count(self):
        return self.gateway.descriptor_count()

    def alive(self):
        return self.gateway.alive()

    def close(self) -> None:
        try:
            self.gateway.close()
        finally:
            self.provider.close()

    def __enter__(self) -> "ProviderGateway":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def chat_request(alias: str = DEFAULT_ALIAS, stream: bool = False, **extra) -> str:
    import json

    payload = {
        "model": alias,
        "messages": [{"role": "user", "content": "hello"}],
    }
    if stream:
        payload["stream"] = True
    payload.update(extra)
    return json.dumps(payload)


def responses_request(alias: str = DEFAULT_ALIAS, stream: bool = False, **extra) -> str:
    import json

    payload = {"model": alias, "input": "hello"}
    if stream:
        payload["stream"] = True
    payload.update(extra)
    return json.dumps(payload)
