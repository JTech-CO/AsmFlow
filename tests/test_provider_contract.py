"""Requests reaching a provider, and responses coming back (HARNESS.md M6 1-2).

The properties here are about what survives the trip. AsmFlow is allowed to
change exactly one thing in a request body — `model` — and is allowed to change
nothing at all in a response body. Everything else in this file is a way of
asking whether that is true for some particular shape of document.
"""
from __future__ import annotations

import json
import unittest

from tests.http_harness import ResponseStream, request_bytes
from tests.mock_provider import echo_handler, json_handler
from tests.provider_harness import (
    DEFAULT_UPSTREAM_MODEL,
    ProviderGateway,
    chat_request,
    responses_request,
)

CANNED = {
    "id": "chatcmpl-mock",
    "object": "chat.completion",
    "created": 1700000000,
    "model": DEFAULT_UPSTREAM_MODEL,
    "choices": [
        {
            "index": 0,
            "message": {"role": "assistant", "content": "hi"},
            "finish_reason": "stop",
        }
    ],
    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
}


class RoundTripTests(unittest.TestCase):
    """M6 DoD 1: a non-streaming request and response make the round trip."""

    def test_chat_completions_round_trips(self) -> None:
        with ProviderGateway(json_handler(CANNED)) as fixture:
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(200, response.status)
            self.assertEqual(CANNED, response.json())

    def test_responses_round_trips(self) -> None:
        payload = {"id": "resp_mock", "object": "response", "output": []}
        with ProviderGateway(json_handler(payload)) as fixture:
            response = fixture.post_json("/v1/responses", responses_request())
            self.assertEqual(200, response.status)
            self.assertEqual(payload, response.json())

    def test_each_family_reaches_its_own_upstream_path(self) -> None:
        """The alias is AsmFlow's; the path is the provider's API shape."""
        with ProviderGateway(json_handler(CANNED)) as fixture:
            fixture.post_json("/v1/chat/completions", chat_request())
            fixture.post_json("/v1/responses", responses_request())
            targets = [request.target for request in fixture.requests]
            self.assertEqual(["/v1/chat/completions", "/v1/responses"], targets)

    def test_the_response_carries_a_request_id(self) -> None:
        with ProviderGateway(json_handler(CANNED)) as fixture:
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertIsNotNone(response.header("x-asmflow-request-id"))

    def test_a_generation_response_is_not_to_be_stored(self) -> None:
        with ProviderGateway(json_handler(CANNED)) as fixture:
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual("no-store", response.header("cache-control"))


class ConnectionReuseTests(unittest.TestCase):
    """A suspended connection has to become an ordinary one again.

    Every other test here sends `Connection: close`, which never exercises the
    path where a connection is answered from a libcurl callback and then has to
    go back to reading. These do.
    """

    def request(self, close: bool) -> bytes:
        body = chat_request().encode()
        return request_bytes(
            method="POST",
            target="/v1/chat/completions",
            headers=[
                ("Content-Type", "application/json"),
                ("Content-Length", str(len(body))),
            ],
            body=body,
            close=close,
        )

    def test_a_connection_serves_a_second_request_after_an_upstream_call(self) -> None:
        with ProviderGateway(json_handler(CANNED)) as fixture:
            sock = fixture.connect()
            sock.settimeout(20.0)
            try:
                stream = ResponseStream(sock)
                sock.sendall(self.request(close=False))
                first = stream.next()
                self.assertEqual(200, first.status)
                self.assertEqual("keep-alive", first.header("connection"))

                sock.sendall(self.request(close=True))
                second = stream.next()
                self.assertEqual(200, second.status)
                self.assertEqual(CANNED, second.json())
            finally:
                sock.close()
            self.assertEqual(2, len(fixture.requests))

    def test_a_request_pipelined_during_an_upstream_call_is_answered_after_it(
        self,
    ) -> None:
        """It has to wait, and it has to be answered second.

        A connection suspended on a provider must not parse the next request,
        or two responses would be produced for one connection with no ordering
        between them.
        """
        import threading
        import time

        gate = threading.Event()

        def hold_then_answer(request, writer):
            gate.wait(15.0)
            writer.json_response(CANNED)

        with ProviderGateway(hold_then_answer, request_ms=30000) as fixture:
            sock = fixture.connect()
            sock.settimeout(20.0)
            try:
                # Both requests in one write, while the first is still upstream.
                sock.sendall(self.request(close=False))
                deadline = time.monotonic() + 10.0
                while not fixture.requests and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertEqual(1, len(fixture.requests))
                sock.sendall(self.request(close=True))
                time.sleep(0.3)
                # Still one: the second was not parsed while the first was out.
                self.assertEqual(1, len(fixture.requests))

                gate.set()
                stream = ResponseStream(sock)
                first = stream.next()
                second = stream.next()
                self.assertEqual(200, first.status)
                self.assertEqual(200, second.status)
            finally:
                gate.set()
                sock.close()
            self.assertEqual(2, len(fixture.requests))


class ModelRewriteTests(unittest.TestCase):
    """docs/API_CONTRACT.md 5: the alias is replaced by the upstream model."""

    def test_the_alias_is_replaced_by_the_configured_upstream_model(self) -> None:
        with ProviderGateway(echo_handler()) as fixture:
            fixture.post_json("/v1/chat/completions", chat_request())
            forwarded = fixture.requests[0].json()
            self.assertEqual(DEFAULT_UPSTREAM_MODEL, forwarded["model"])

    def test_two_routes_rewrite_to_their_own_models(self) -> None:
        def two_aliases(document):
            first = document["routes"][0]
            second = json.loads(json.dumps(first))
            second["id"] = "second-route"
            second["model_alias"] = "fast"
            second["targets"][0]["upstream_model"] = "provider-model-1b"
            document["routes"].append(second)

        with ProviderGateway(echo_handler(), mutate=two_aliases) as fixture:
            fixture.post_json("/v1/chat/completions", chat_request("general"))
            fixture.post_json("/v1/chat/completions", chat_request("fast"))
            models = [request.json()["model"] for request in fixture.requests]
            self.assertEqual([DEFAULT_UPSTREAM_MODEL, "provider-model-1b"], models)


class PassThroughTests(unittest.TestCase):
    """M6 DoD 2: fields AsmFlow has no opinion about survive the trip."""

    def test_unknown_fields_reach_the_provider(self) -> None:
        extra = {
            "temperature": 0.25,
            "top_p": 1,
            "some_future_field": {"nested": [1, 2, {"deep": True}]},
            "stop": ["\n\n", "END"],
            "seed": 424242,
        }
        with ProviderGateway(echo_handler()) as fixture:
            fixture.post_json("/v1/chat/completions", chat_request(**extra))
            forwarded = fixture.requests[0].json()
            for key, value in extra.items():
                self.assertEqual(value, forwarded[key], key)

    def test_a_unicode_payload_is_not_re_encoded(self) -> None:
        """A gateway that normalised text would change what was asked for."""
        content = "안녕하세요 — ☃ — \U0001f600"
        body = json.dumps(
            {"model": "general", "messages": [{"role": "user", "content": content}]}
        )
        with ProviderGateway(echo_handler()) as fixture:
            fixture.post_json("/v1/chat/completions", body)
            forwarded = fixture.requests[0].json()
            self.assertEqual(content, forwarded["messages"][0]["content"])

    def test_member_order_is_preserved(self) -> None:
        body = json.dumps(
            {"zeta": 1, "model": "general", "alpha": 2, "messages": [], "mid": 3}
        )
        with ProviderGateway(echo_handler()) as fixture:
            fixture.post_json("/v1/chat/completions", body)
            forwarded = json.loads(
                fixture.requests[0].body.decode("utf-8"),
                object_pairs_hook=lambda pairs: [name for name, _ in pairs],
            )
            self.assertEqual(["zeta", "model", "alpha", "messages", "mid"], forwarded)

    def test_a_response_body_is_returned_byte_for_byte(self) -> None:
        """Not merely equal as JSON: the same bytes."""
        raw = b'{"spaced" : [1,2,3] ,"note":"\xed\x95\x9c"}'

        def handler(request, writer):
            writer.head(
                200,
                {
                    "Content-Type": "application/json",
                    "Content-Length": str(len(raw)),
                },
            )
            writer.raw(raw)

        with ProviderGateway(handler) as fixture:
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(raw, response.body)


class RequestHeaderTests(unittest.TestCase):
    """What AsmFlow sends upstream, and what it refuses to send."""

    def test_the_provider_credential_is_sent(self) -> None:
        def with_key(document):
            document["providers"][0]["auth"] = {
                "type": "bearer_env",
                "env": "MOCK_PROVIDER_KEY",
            }

        # The daemon builds its own environment rather than inheriting one, so
        # the secret has to be handed to it on purpose — which is why this
        # cannot go through ProviderGateway.
        from tests.http_harness import Gateway
        from tests.mock_provider import MockProvider
        from tests.provider_harness import provider_config

        provider = MockProvider(json_handler(CANNED))
        try:
            base = provider_config(provider.base_url)

            def configure(document):
                base(document)
                with_key(document)

            with Gateway(
                mutate=configure,
                extra_env={"MOCK_PROVIDER_KEY": "sk-mock-value"},
            ) as gateway:
                gateway.post_json("/v1/chat/completions", chat_request())
                self.assertEqual(
                    "Bearer sk-mock-value",
                    provider.requests[0].header("authorization"),
                )
        finally:
            provider.close()

    def test_a_named_header_credential_is_sent_under_its_own_name(self) -> None:
        from tests.http_harness import Gateway
        from tests.mock_provider import MockProvider
        from tests.provider_harness import provider_config

        provider = MockProvider(json_handler(CANNED))
        try:
            base = provider_config(provider.base_url)

            def configure(document):
                base(document)
                document["providers"][0]["auth"] = {
                    "type": "header_env",
                    "header": "X-Api-Key",
                    "value": {"source": "env", "name": "MOCK_PROVIDER_KEY"},
                }

            with Gateway(
                mutate=configure,
                extra_env={"MOCK_PROVIDER_KEY": "sk-named-value"},
            ) as gateway:
                gateway.post_json("/v1/chat/completions", chat_request())
                self.assertEqual(
                    "sk-named-value", provider.requests[0].header("x-api-key")
                )
                self.assertIsNone(provider.requests[0].header("authorization"))
        finally:
            provider.close()

    def test_the_clients_credential_is_never_forwarded(self) -> None:
        """The listener's token authenticates the client to AsmFlow, and to
        nobody else. Forwarding it would hand a provider a key to this gateway.
        """
        from tests.http_harness import Gateway
        from tests.mock_provider import MockProvider
        from tests.provider_harness import provider_config

        provider = MockProvider(json_handler(CANNED))
        try:
            base = provider_config(provider.base_url)

            def configure(document):
                base(document)
                document["listener"]["auth"] = {
                    "type": "bearer_env",
                    "env": "ASMFLOW_LISTENER_TOKEN",
                }

            with Gateway(
                mutate=configure,
                extra_env={"ASMFLOW_LISTENER_TOKEN": "client-side-token"},
            ) as gateway:
                response = gateway.post_json(
                    "/v1/chat/completions",
                    chat_request(),
                    headers=[("Authorization", "Bearer client-side-token")],
                )
                self.assertEqual(200, response.status)
                forwarded = provider.requests[0].header("authorization")
                self.assertIsNone(forwarded)
        finally:
            provider.close()

    def test_no_client_header_is_forwarded(self) -> None:
        with ProviderGateway(json_handler(CANNED)) as fixture:
            fixture.post_json(
                "/v1/chat/completions",
                chat_request(),
                headers=[("X-Client-Marker", "should-not-appear")],
            )
            self.assertIsNone(fixture.requests[0].header("x-client-marker"))

    def test_the_user_agent_names_asmflow(self) -> None:
        with ProviderGateway(json_handler(CANNED)) as fixture:
            fixture.post_json("/v1/chat/completions", chat_request())
            agent = fixture.requests[0].header("user-agent", "")
            self.assertTrue(agent.startswith("AsmFlow/"), agent)

    def test_no_expect_continue_is_sent(self) -> None:
        """A provider that ignores the continuation would stall every request."""
        with ProviderGateway(json_handler(CANNED)) as fixture:
            fixture.post_json("/v1/chat/completions", chat_request())
            self.assertIsNone(fixture.requests[0].header("expect"))

    def test_no_compressed_encoding_is_requested(self) -> None:
        """AsmFlow forwards bytes; asking for a coding it would then have to
        undo would make the bytes it forwards no longer the bytes it received.
        """
        with ProviderGateway(json_handler(CANNED)) as fixture:
            fixture.post_json("/v1/chat/completions", chat_request())
            self.assertIsNone(fixture.requests[0].header("accept-encoding"))


class CapabilityTests(unittest.TestCase):
    """docs/API_CONTRACT.md 5: capability fields filter, they do not rewrite."""

    def test_a_route_that_does_not_serve_the_family_is_not_eligible(self) -> None:
        with ProviderGateway(
            json_handler(CANNED), families=("chat_completions",)
        ) as fixture:
            response = fixture.post_json("/v1/responses", responses_request())
            self.assertEqual(503, response.status)
            self.assertEqual("no_eligible_target", response.json()["error"]["code"])

    def test_a_provider_without_the_capability_is_refused_at_load(self) -> None:
        """The stronger answer, and the one M3 already gives.

        A route whose only target cannot serve the family it advertises can
        never succeed, so it is a configuration error rather than a runtime
        one — the operator is told at startup instead of by every request.
        """
        with self.assertRaises(RuntimeError) as caught:
            ProviderGateway(json_handler(CANNED), responses=False).close()
        message = str(caught.exception)
        self.assertIn("/routes/0/targets", message)
        self.assertIn("advertises responses", message)

    def test_a_stream_request_needs_a_streaming_provider(self) -> None:
        with ProviderGateway(json_handler(CANNED), streaming=False) as fixture:
            response = fixture.post_json(
                "/v1/chat/completions", chat_request(stream=True)
            )
            self.assertEqual(503, response.status)
            self.assertEqual("no_eligible_target", response.json()["error"]["code"])

    def test_the_same_provider_still_serves_a_non_stream_request(self) -> None:
        """The filter is about the request, not a standing disqualification."""
        with ProviderGateway(json_handler(CANNED), streaming=False) as fixture:
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(200, response.status)

    def test_a_chat_only_adapter_cannot_serve_responses(self) -> None:
        with ProviderGateway(json_handler(CANNED), adapter="openai_chat") as fixture:
            response = fixture.post_json("/v1/responses", responses_request())
            self.assertEqual(503, response.status)

    def test_a_disabled_provider_leaves_no_eligible_target(self) -> None:
        def disable(document):
            document["providers"][0]["enabled"] = False

        with ProviderGateway(json_handler(CANNED), mutate=disable) as fixture:
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(503, response.status)
            self.assertEqual("no_eligible_target", response.json()["error"]["code"])


class UpstreamStatusTests(unittest.TestCase):
    """docs/API_CONTRACT.md 7: an upstream error body is worth relaying."""

    def test_an_upstream_json_error_is_passed_through_with_its_status(self) -> None:
        body = {"error": {"message": "model is loading", "type": "server_error"}}
        with ProviderGateway(json_handler(body, status=429)) as fixture:
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(429, response.status)
            self.assertEqual(body, response.json())

    def test_an_upstream_error_that_is_not_json_becomes_asmflows_own(self) -> None:
        def handler(request, writer):
            writer.head(
                500,
                {"Content-Type": "text/html", "Content-Length": "22"},
                reason="Internal Server Error",
            )
            writer.raw(b"<html>nope</html>    ")

        with ProviderGateway(handler) as fixture:
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(502, response.status)
            self.assertEqual(
                "invalid_upstream_response", response.json()["error"]["code"]
            )

    def test_a_json_array_body_is_not_relayed_as_an_error_document(self) -> None:
        """The contract's error shape is an object; an array is not one."""

        def handler(request, writer):
            body = b"[1,2,3]"
            writer.head(
                503,
                {"Content-Type": "application/json", "Content-Length": str(len(body))},
                reason="Service Unavailable",
            )
            writer.raw(body)

        with ProviderGateway(handler) as fixture:
            response = fixture.post_json("/v1/chat/completions", chat_request())
            self.assertEqual(502, response.status)


if __name__ == "__main__":
    unittest.main()
