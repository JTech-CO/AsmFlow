"""The HTTP contract surface, against a running gateway (HARNESS.md M5 1-3).

Every test here starts a real `asmflowd` and speaks TCP to it. The endpoints are
a contract with clients that do not exist yet, so what is checked is the
document in `docs/API_CONTRACT.md` rather than the implementation's own idea of
itself: the shapes, the status codes, and — the part that matters most — what is
absent from a response.
"""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

from tests.http_harness import Gateway

ROOT = Path(__file__).resolve().parents[1]


class HealthEndpointTests(unittest.TestCase):
    """M5 DoD 1: liveness and readiness are different questions."""

    def test_healthz_reports_process_liveness(self) -> None:
        with Gateway() as gateway:
            response = gateway.get("/healthz")
            self.assertEqual(200, response.status)
            self.assertEqual("application/json", response.header("content-type"))
            payload = response.json()
            self.assertEqual("ok", payload["status"])
            self.assertEqual(
                (ROOT / "VERSION").read_text(encoding="utf-8").strip(),
                payload["version"],
            )
            self.assertIsInstance(payload["uptime_ms"], int)
            self.assertGreaterEqual(payload["uptime_ms"], 0)

    def test_healthz_says_nothing_about_dependencies(self) -> None:
        """Liveness must not become a second readiness endpoint."""
        with Gateway() as gateway:
            payload = gateway.get("/healthz").json()
            self.assertEqual({"status", "version", "uptime_ms"}, set(payload))

    def test_readyz_reports_dependency_state(self) -> None:
        with Gateway() as gateway:
            response = gateway.get("/readyz")
            self.assertEqual(200, response.status)
            payload = response.json()
            self.assertEqual("ready", payload["status"])
            self.assertEqual("ready", payload["database"])
            self.assertEqual("ready", payload["listener"])
            self.assertIsInstance(payload["config_revision"], int)
            self.assertEqual(1, payload["routes"]["enabled"])
            self.assertEqual(1, payload["routes"]["eligible"])

    def test_readyz_counts_a_disabled_route_as_neither(self) -> None:
        def disable(document):
            document["routes"][0]["enabled"] = False

        with Gateway(mutate=disable) as gateway:
            payload = gateway.get("/readyz").json()
            self.assertEqual(0, payload["routes"]["enabled"])
            self.assertEqual(0, payload["routes"]["eligible"])

    def test_readyz_counts_an_unservable_route_as_enabled_only(self) -> None:
        """A route whose only provider is disabled is enabled and not eligible."""

        def disable_provider(document):
            document["providers"][0]["enabled"] = False

        with Gateway(mutate=disable_provider) as gateway:
            payload = gateway.get("/readyz").json()
            self.assertEqual(1, payload["routes"]["enabled"])
            self.assertEqual(0, payload["routes"]["eligible"])


class ModelsEndpointTests(unittest.TestCase):
    """M5 DoD 2: aliases, and nothing about the provider behind them."""

    def test_models_lists_enabled_aliases(self) -> None:
        with Gateway() as gateway:
            payload = gateway.get("/v1/models").json()
            self.assertEqual("list", payload["object"])
            self.assertEqual(1, len(payload["data"]))
            entry = payload["data"][0]
            self.assertEqual("general", entry["id"])
            self.assertEqual("model", entry["object"])
            self.assertEqual("asmflow", entry["owned_by"])
            self.assertEqual({"id", "object", "created", "owned_by"}, set(entry))

    def test_models_never_discloses_the_upstream(self) -> None:
        """The provider's URL and identity are not part of a model object."""
        with Gateway() as gateway:
            response = gateway.get("/v1/models")
            text = response.body.decode("utf-8")
            for secret in ("11434", "ollama", "http://", "qwen-example", "OLLAMA"):
                self.assertNotIn(secret, text)
            for name in response.headers:
                self.assertNotIn("provider", name)

    def test_a_disabled_route_is_not_listed(self) -> None:
        def disable(document):
            document["routes"][0]["enabled"] = False

        with Gateway(mutate=disable) as gateway:
            self.assertEqual([], gateway.get("/v1/models").json()["data"])

    def test_an_unservable_alias_is_hidden_by_default(self) -> None:
        def disable_provider(document):
            document["providers"][0]["enabled"] = False

        with Gateway(mutate=disable_provider) as gateway:
            self.assertEqual([], gateway.get("/v1/models").json()["data"])

    def test_expose_unavailable_models_lists_it_anyway(self) -> None:
        def disable_provider(document):
            document["providers"][0]["enabled"] = False
            document["listener"]["expose_unavailable_models"] = True

        with Gateway(mutate=disable_provider) as gateway:
            data = gateway.get("/v1/models").json()["data"]
            self.assertEqual(["general"], [entry["id"] for entry in data])


class StatusCodeTests(unittest.TestCase):
    """M5 DoD 3: method, path, and media type answer what the contract says."""

    def test_unknown_path_is_404(self) -> None:
        with Gateway() as gateway:
            response = gateway.get("/v1/nope")
            self.assertEqual(404, response.status)
            error = response.json()["error"]
            self.assertEqual("asmflow_route_error", error["type"])
            self.assertEqual("unknown_path", error["code"])

    def test_the_path_is_matched_exactly(self) -> None:
        """No prefix match, no trailing slash, no percent-decoding."""
        with Gateway() as gateway:
            for target in (
                "/healthz/",
                "/healthzz",
                "/v1/models/",
                "/v1%2Fmodels",
                "/v1/./models",
                "//v1/models",
            ):
                with self.subTest(target=target):
                    self.assertEqual(404, gateway.get(target).status)

    def test_a_query_string_does_not_change_the_path(self) -> None:
        with Gateway() as gateway:
            self.assertEqual(200, gateway.get("/healthz?verbose=1").status)

    def test_wrong_method_is_405_with_allow(self) -> None:
        with Gateway() as gateway:
            response = gateway.send_raw(
                b"POST /v1/models HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n"
                b"Connection: close\r\n\r\n"
            )
            from tests.http_harness import parse_responses

            parsed = parse_responses(response)[0]
            self.assertEqual(405, parsed.status)
            self.assertEqual("GET", parsed.header("allow"))
            self.assertEqual("method_not_allowed", parsed.json()["error"]["code"])

    def test_generation_endpoints_require_post(self) -> None:
        with Gateway() as gateway:
            for target in ("/v1/responses", "/v1/chat/completions"):
                with self.subTest(target=target):
                    response = gateway.get(target)
                    self.assertEqual(405, response.status)
                    self.assertEqual("POST", response.header("allow"))

    def test_missing_content_type_is_415(self) -> None:
        with Gateway() as gateway:
            response = gateway.send_raw(
                b"POST /v1/responses HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n"
                b"Connection: close\r\n\r\n{}"
            )
            from tests.http_harness import parse_responses

            parsed = parse_responses(response)[0]
            self.assertEqual(415, parsed.status)
            self.assertEqual("unsupported_content_type", parsed.json()["error"]["code"])

    def test_wrong_content_type_is_415(self) -> None:
        with Gateway() as gateway:
            response = gateway.post_json(
                "/v1/responses",
                "{}",
                headers=[("Content-Type", "text/plain")],
            )
            self.assertEqual(415, response.status)

    def test_a_content_type_parameter_is_accepted(self) -> None:
        """`application/json; charset=utf-8` is application/json.

        What this asserts is the absence of a 415. Where the request goes after
        that is the router's business and changes between milestones; that it
        was not refused for its media type does not.
        """
        with Gateway() as gateway:
            response = gateway.post_json(
                "/v1/responses",
                json.dumps({"model": "general"}),
                headers=[("Content-Type", "application/json; charset=utf-8")],
            )
            self.assertNotEqual(415, response.status)
            self.assertNotEqual(
                "unsupported_content_type", response.json()["error"]["code"]
            )

    def test_a_body_that_is_not_json_is_400(self) -> None:
        with Gateway() as gateway:
            response = gateway.post_json("/v1/responses", "{oops")
            self.assertEqual(400, response.status)
            self.assertEqual("invalid_json", response.json()["error"]["code"])

    def test_a_missing_model_is_400_naming_the_field(self) -> None:
        with Gateway() as gateway:
            response = gateway.post_json("/v1/chat/completions", json.dumps({"a": 1}))
            self.assertEqual(400, response.status)
            error = response.json()["error"]
            self.assertEqual("invalid_field", error["code"])
            self.assertEqual("model", error["param"])

    def test_a_model_of_the_wrong_type_is_400(self) -> None:
        with Gateway() as gateway:
            response = gateway.post_json(
                "/v1/chat/completions", json.dumps({"model": 7})
            )
            self.assertEqual(400, response.status)
            self.assertEqual("invalid_field", response.json()["error"]["code"])

    def test_an_unknown_alias_is_404(self) -> None:
        with Gateway() as gateway:
            response = gateway.post_json(
                "/v1/responses", json.dumps({"model": "no-such-alias"})
            )
            self.assertEqual(404, response.status)
            error = response.json()["error"]
            self.assertEqual("unknown_model_alias", error["code"])
            self.assertEqual("model", error["param"])

    def test_a_known_alias_is_routed_rather_than_refused(self) -> None:
        """The base fixture's only route serves chat completions.

        So the two endpoints answer differently, and the difference is the
        point: `/v1/responses` has no eligible target and says so, while
        `/v1/chat/completions` does have one and fails at the provider — which
        is not listening, because this suite has no provider. Both are routing
        answers rather than request refusals.
        """
        with Gateway() as gateway:
            responses = gateway.post_json(
                "/v1/responses", json.dumps({"model": "general"})
            )
            self.assertEqual(503, responses.status)
            error = responses.json()["error"]
            self.assertEqual("no_eligible_target", error["code"])
            self.assertEqual("asmflow_routing_error", error["type"])

            chat = gateway.post_json(
                "/v1/chat/completions", json.dumps({"model": "general"})
            )
            self.assertEqual(502, chat.status)
            error = chat.json()["error"]
            self.assertEqual("upstream_connect_failed", error["code"])
            self.assertEqual("asmflow_upstream_error", error["type"])

    def test_a_disabled_route_is_503_not_404(self) -> None:
        """The alias exists; it is turned off. Those are different answers."""

        def disable(document):
            document["routes"][0]["enabled"] = False

        with Gateway(mutate=disable) as gateway:
            response = gateway.post_json(
                "/v1/responses", json.dumps({"model": "general"})
            )
            self.assertEqual(503, response.status)
            self.assertEqual("route_disabled", response.json()["error"]["code"])


class ResponseHeaderTests(unittest.TestCase):
    """docs/API_CONTRACT.md 2: what every response carries, and what it never does."""

    def test_every_response_carries_a_request_id(self) -> None:
        with Gateway() as gateway:
            seen = set()
            for _ in range(5):
                response = gateway.get("/healthz")
                request_id = response.header("x-asmflow-request-id")
                self.assertIsNotNone(request_id)
                self.assertRegex(request_id, r"^[0-9A-HJKMNP-TV-Z]{26}$")
                seen.add(request_id)
            self.assertEqual(5, len(seen), "request ids must not repeat")

    def test_the_error_body_repeats_the_request_id(self) -> None:
        with Gateway() as gateway:
            response = gateway.get("/nope")
            self.assertEqual(
                response.header("x-asmflow-request-id"),
                response.json()["asmflow"]["request_id"],
            )

    def test_nosniff_is_always_present(self) -> None:
        with Gateway() as gateway:
            for target in ("/healthz", "/readyz", "/v1/models", "/nope"):
                with self.subTest(target=target):
                    self.assertEqual(
                        "nosniff",
                        gateway.get(target).header("x-content-type-options"),
                    )

    def test_generation_responses_are_not_stored(self) -> None:
        with Gateway() as gateway:
            response = gateway.post_json(
                "/v1/responses", json.dumps({"model": "general"})
            )
            self.assertEqual("no-store", response.header("cache-control"))

    def test_no_response_discloses_the_server_or_the_upstream(self) -> None:
        with Gateway() as gateway:
            for target in ("/healthz", "/v1/models", "/nope"):
                response = gateway.get(target)
                head = response.raw.decode("latin-1").lower()
                for banned in ("server:", "x-powered-by", "11434", "ollama"):
                    self.assertNotIn(banned, head, f"{target} leaked {banned}")

    def test_an_error_message_never_echoes_the_request(self) -> None:
        """A refusal is emitted before the request has been trusted for anything."""
        with Gateway() as gateway:
            marker = "CANARY-8f3a2b"
            response = gateway.get(f"/{marker}")
            self.assertEqual(404, response.status)
            self.assertNotIn(marker, response.body.decode("utf-8"))

            response = gateway.post_json(
                "/v1/responses", json.dumps({"model": marker})
            )
            self.assertEqual(404, response.status)
            self.assertNotIn(marker, response.body.decode("utf-8"))


class ErrorCatalogueTests(unittest.TestCase):
    """The catalogue in the assembly and the table in the contract agree."""

    def test_every_emitted_code_appears_in_the_contract(self) -> None:
        source = (ROOT / "src/http/http_response.asm").read_text(encoding="utf-8")
        contract = (ROOT / "docs/API_CONTRACT.md").read_text(encoding="utf-8")
        codes = set(re.findall(r'^e_\w+:\s+db "([a-z0-9_]+)"', source, re.MULTILINE))
        self.assertGreater(len(codes), 10, "the catalogue should not be nearly empty")
        for code in sorted(codes):
            with self.subTest(code=code):
                self.assertIn(
                    f"`{code}`", contract, f"{code} is emitted but not documented"
                )

    def test_every_status_the_catalogue_uses_has_a_reason_phrase(self) -> None:
        source = (ROOT / "src/http/http_response.asm").read_text(encoding="utf-8")
        table = source[
            source.index("af_http_error_table:") : source.index(
                "af_http_error_table_end:"
            )
        ]
        used = {int(m) for m in re.findall(r"^\s+dq (\d{3}),", table, re.MULTILINE)}
        listed = {int(m) for m in re.findall(r"^\s+dq (\d{3}), r_", source, re.MULTILINE)}
        self.assertTrue(
            used <= listed, f"no reason phrase for {sorted(used - listed)}"
        )


if __name__ == "__main__":
    unittest.main()
