from __future__ import annotations

import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


class ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.minimal = load_json(ROOT / "examples/asmflow.minimal.json")
        self.full = load_json(ROOT / "examples/asmflow.full.json")

    def test_examples_have_schema_version(self) -> None:
        self.assertEqual(1, self.minimal["schema_version"])
        self.assertEqual(1, self.full["schema_version"])

    def test_ids_are_unique_and_routes_resolve(self) -> None:
        for config in (self.minimal, self.full):
            provider_ids = [item["id"] for item in config["providers"]]
            route_ids = [item["id"] for item in config["routes"]]
            mcp_ids = [item["id"] for item in config["mcp_servers"]]
            self.assertEqual(len(provider_ids), len(set(provider_ids)))
            self.assertEqual(len(route_ids), len(set(route_ids)))
            self.assertEqual(len(mcp_ids), len(set(mcp_ids)))
            for route in config["routes"]:
                self.assertGreaterEqual(len(route["targets"]), 1)
                self.assertLessEqual(route["fallback"]["max_attempts"], len(route["targets"]))
                for target in route["targets"]:
                    self.assertIn(target["provider_id"], provider_ids)

    def test_loopback_listener_can_use_no_auth(self) -> None:
        listener = self.minimal["listener"]
        self.assertEqual("127.0.0.1", listener["host"])
        self.assertEqual("none", listener["auth"]["type"])

    def test_full_example_uses_secret_references(self) -> None:
        self.assertEqual("bearer_env", self.full["listener"]["auth"]["type"])
        for node in walk(self.full):
            if "auth" in node and isinstance(node["auth"], dict):
                auth = node["auth"]
                self.assertNotIn("token", auth)
                self.assertNotIn("api_key", auth)
                self.assertNotIn("authorization", auth)
                if auth.get("type") == "bearer_env":
                    self.assertRegex(auth["env"], r"^[A-Z_][A-Z0-9_]*$")
            if "env" in node and isinstance(node["env"], dict):
                for secret_ref in node["env"].values():
                    if isinstance(secret_ref, dict) and "source" in secret_ref:
                        self.assertEqual("env", secret_ref["source"])
                        self.assertIn("name", secret_ref)

    def test_modern_mcp_fixture_has_per_request_metadata(self) -> None:
        fixture = load_json(ROOT / "tests/fixtures/mcp/discover_request_2026-07-28.json")
        meta = fixture["params"]["_meta"]
        self.assertEqual("2026-07-28", meta["io.modelcontextprotocol/protocolVersion"])
        self.assertIn("io.modelcontextprotocol/clientInfo", meta)
        self.assertIn("io.modelcontextprotocol/clientCapabilities", meta)

    def test_openai_json_fixtures_parse(self) -> None:
        fixture_paths = [
            ROOT / "tests/fixtures/openai/chat_request.json",
            ROOT / "tests/fixtures/openai/chat_response.json",
            ROOT / "tests/fixtures/openai/responses_request.json",
        ]
        for path in fixture_paths:
            self.assertIsInstance(load_json(path), dict)

    def test_sse_fixture_data_is_json_or_done(self) -> None:
        for name in ("chat_stream.sse", "responses_stream.sse"):
            path = ROOT / "tests/fixtures/openai" / name
            for raw_line in path.read_text(encoding="utf-8").splitlines():
                if not raw_line.startswith("data:"):
                    continue
                data = raw_line[5:].strip()
                if data == "[DONE]" or not data:
                    continue
                parsed = json.loads(data)
                self.assertIsInstance(parsed, dict)

    def test_invalid_plaintext_secret_fixture_is_detectable(self) -> None:
        invalid = load_json(ROOT / "tests/fixtures/config/invalid_plaintext_secret.json")
        provider = invalid["providers"][0]
        self.assertIn("api_key", provider)

    def test_schema_file_is_draft_2020_12(self) -> None:
        schema = load_json(ROOT / "config/asmflow.schema.json")
        self.assertEqual("https://json-schema.org/draft/2020-12/schema", schema["$schema"])
        self.assertFalse(schema["additionalProperties"])


if __name__ == "__main__":
    unittest.main()
