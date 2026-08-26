#!/usr/bin/env python3
"""Small standard-library OpenAI-compatible mock for integration tests."""
from __future__ import annotations

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    server_version = "AsmFlowMockProvider/0.1"

    def log_message(self, format: str, *args) -> None:
        return

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path in {"/healthz", "/v1/models", "/models"}:
            self._json(200, {"status": "ok", "data": []})
            return
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            request = json.loads(body)
        except json.JSONDecodeError:
            self._json(400, {"error": {"message": "invalid json"}})
            return

        delay_ms = int(self.headers.get("X-Mock-Delay-Ms", "0"))
        if delay_ms:
            time.sleep(delay_ms / 1000)
        forced = self.headers.get("X-Mock-Status")
        if forced:
            self._json(int(forced), {"error": {"message": "forced status"}})
            return

        if request.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            if self.path.endswith("/responses"):
                events = [
                    ("response.created", {"type": "response.created", "response": {"id": "resp_mock"}}),
                    ("response.output_text.delta", {"type": "response.output_text.delta", "delta": "hello"}),
                    ("response.completed", {"type": "response.completed", "response": {"id": "resp_mock"}}),
                ]
                for event, data in events:
                    self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
                    self.wfile.flush()
            else:
                chunks = [
                    {"id": "chatcmpl_mock", "choices": [{"index": 0, "delta": {"content": "hello"}, "finish_reason": None}]},
                    {"id": "chatcmpl_mock", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
                ]
                for chunk in chunks:
                    self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                    self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")
            return

        if self.path.endswith("/responses"):
            self._json(200, {"id": "resp_mock", "object": "response", "status": "completed", "output": []})
        elif self.path.endswith("/chat/completions"):
            self._json(200, {"id": "chatcmpl_mock", "object": "chat.completion", "choices": [{"index": 0, "message": {"role": "assistant", "content": "hello"}, "finish_reason": "stop"}]})
        else:
            self._json(404, {"error": {"message": "not found"}})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"mock provider listening on {args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
