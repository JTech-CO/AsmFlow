#!/usr/bin/env python3
"""Small MCP stdio mock supporting modern discovery and a legacy mode."""
from __future__ import annotations

import argparse
import json
import sys


def send(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def modern_response(message: dict) -> dict:
    request_id = message.get("id")
    method = message.get("method")
    if method == "server/discover":
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "resultType": "complete",
                "supportedVersions": ["2026-07-28"],
                "capabilities": {"tools": {}},
                "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "asmflow-mock", "version": "0.1"}},
                "instructions": "Test server only.",
                "ttlMs": 60000,
                "cacheScope": "private",
            },
        }
    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "resultType": "complete",
                "tools": [{"name": "echo", "description": "Echo test input", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}],
                "ttlMs": 60000,
                "cacheScope": "private",
            },
        }
    if method == "tools/call":
        text = message.get("params", {}).get("arguments", {}).get("text", "")
        return {"jsonrpc": "2.0", "id": request_id, "result": {"resultType": "complete", "content": [{"type": "text", "text": text}], "isError": False}}
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}}


def legacy_response(message: dict) -> dict | None:
    request_id = message.get("id")
    method = message.get("method")
    if method == "server/discover":
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}}
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "asmflow-legacy-mock", "version": "0.1"}}}
    if method == "notifications/initialized":
        return None
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"tools": [{"name": "echo", "description": "Echo test input", "inputSchema": {"type": "object"}}]}}
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--legacy", action="store_true")
    parser.add_argument("--stdout-noise", action="store_true")
    parser.add_argument("--exit-after", type=int, default=0)
    args = parser.parse_args()
    count = 0
    for line in sys.stdin:
        if args.stdout_noise:
            sys.stdout.write("not-json\n")
            sys.stdout.flush()
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        response = legacy_response(message) if args.legacy else modern_response(message)
        if response is not None:
            send(response)
        count += 1
        if args.exit_after and count >= args.exit_after:
            return


if __name__ == "__main__":
    main()
