#!/usr/bin/env python3
"""Small MCP stdio mock supporting modern discovery and a legacy mode."""
from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import tempfile
import time
from pathlib import Path


def send(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def emit_malformed_stdout(mode: str, oversized_bytes: int) -> None:
    """Write one deliberately invalid protocol frame without using text codecs."""
    if mode == "noise":
        payload = b"not-json\n"
    elif mode == "invalid-utf8":
        payload = b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"\xff\"}\n"
    elif mode == "oversized":
        payload = b"x" * oversized_bytes + b"\n"
    else:  # argparse constrains this, but keep the helper total.
        raise ValueError(f"unknown malformed stdout mode: {mode}")
    sys.stdout.buffer.write(payload)
    sys.stdout.buffer.flush()


def emit_stderr_flood(byte_count: int) -> None:
    """Fill stderr with one long line; the supervisor must drain and truncate it."""
    remaining = byte_count
    chunk = b"e" * 16384
    while remaining:
        piece = chunk[: min(remaining, len(chunk))]
        sys.stderr.buffer.write(piece)
        sys.stderr.buffer.flush()
        remaining -= len(piece)
    sys.stderr.buffer.write(b"\n")
    sys.stderr.buffer.flush()


def write_report(
    path: Path,
    methods: list[str | None],
    messages: list[dict],
    literal_args: list[str],
    selected_environment: list[str],
    lifecycle: dict,
) -> None:
    """Atomically publish process state without contaminating MCP stdout."""
    payload = {
        "pid": os.getpid(),
        "pgid": os.getpgrp(),
        "argv": list(sys.argv),
        "literal_args": list(literal_args),
        "cwd": os.getcwd(),
        "environment": {
            "keys": sorted(os.environ),
            "selected": {
                name: os.environ.get(name) for name in selected_environment
            },
        },
        "methods": list(methods),
        "messages": list(messages),
        "lifecycle": dict(lifecycle),
    }
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            json.dump(payload, temporary, separators=(",", ":"), sort_keys=True)
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_name, path)
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def modern_response(
    message: dict,
    invalid_modern_version: bool = False,
    tools_mode: str = "ok",
    tools_delay_ms: int = 0,
    resources_mode: str = "ok",
    prompts_mode: str = "ok",
    tool_call_delay_ms: int = 0,
    tool_call_timeout: bool = False,
) -> dict | None:
    request_id = message.get("id")
    method = message.get("method")
    if method == "server/discover":
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "resultType": "complete",
                "supportedVersions": [
                    "2099-01-01" if invalid_modern_version else "2026-07-28"
                ],
                "capabilities": {"tools": {}},
                "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "asmflow-mock", "version": "0.1"}},
                "instructions": "Test server only.",
                "ttlMs": 60000,
                "cacheScope": "private",
            },
        }
    if method == "tools/list":
        if tools_delay_ms:
            time.sleep(tools_delay_ms / 1000)
        if tools_mode == "timeout":
            return None
        if tools_mode == "error":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32001, "message": "injected tools failure"},
            }
        if tools_mode == "invalid":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"resultType": "complete", "notTools": []},
            }
        if tools_mode.startswith("invalid-element-"):
            invalid_tool = (
                42 if tools_mode == "invalid-element-scalar" else {}
            )
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "resultType": "complete",
                    "tools": [invalid_tool],
                    "ttlMs": 60000,
                    "cacheScope": "private",
                },
            }
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
    if method == "resources/list":
        if resources_mode == "timeout":
            return None
        if resources_mode == "error":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32002, "message": "injected resources failure"},
            }
        if resources_mode == "invalid":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"resultType": "complete", "notResources": []},
            }
        if resources_mode == "invalid-element":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "resultType": "complete",
                    "resources": [42],
                    "ttlMs": 60000,
                    "cacheScope": "private",
                },
            }
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "resultType": "complete",
                "resources": [],
                "ttlMs": 60000,
                "cacheScope": "private",
            },
        }
    if method == "prompts/list":
        if prompts_mode == "timeout":
            return None
        if prompts_mode == "error":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32003, "message": "injected prompts failure"},
            }
        if prompts_mode == "invalid":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"resultType": "complete", "notPrompts": []},
            }
        if prompts_mode == "invalid-element":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "resultType": "complete",
                    "prompts": [42],
                    "ttlMs": 60000,
                    "cacheScope": "private",
                },
            }
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "resultType": "complete",
                "prompts": [],
                "ttlMs": 60000,
                "cacheScope": "private",
            },
        }
    if method == "tools/call":
        if tool_call_timeout:
            return None
        if tool_call_delay_ms:
            time.sleep(tool_call_delay_ms / 1000)
        text = message.get("params", {}).get("arguments", {}).get("text", "")
        return {"jsonrpc": "2.0", "id": request_id, "result": {"resultType": "complete", "content": [{"type": "text", "text": text}], "isError": False}}
    if method == "notifications/cancelled":
        return None
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}}


def legacy_response(
    message: dict,
    *,
    invalid_modern_version: bool = False,
    invalid_legacy_version: bool = False,
    tools_mode: str = "ok",
    tools_delay_ms: int = 0,
    resources_mode: str = "ok",
    prompts_mode: str = "ok",
    tool_call_delay_ms: int = 0,
    tool_call_timeout: bool = False,
) -> dict | None:
    request_id = message.get("id")
    method = message.get("method")
    if method == "server/discover":
        if invalid_modern_version:
            return modern_response(message, invalid_modern_version=True)
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}}
    if method == "initialize":
        version = "2099-01-01" if invalid_legacy_version else "2025-11-25"
        return {"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": version, "capabilities": {"tools": {}}, "serverInfo": {"name": "asmflow-legacy-mock", "version": "0.1"}}}
    if method == "notifications/initialized":
        return None
    if method == "tools/list":
        if tools_delay_ms:
            time.sleep(tools_delay_ms / 1000)
        if tools_mode == "timeout":
            return None
        if tools_mode == "error":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32001, "message": "injected tools failure"},
            }
        if tools_mode == "invalid":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"notTools": []},
            }
        if tools_mode.startswith("invalid-element-"):
            invalid_tool = (
                42 if tools_mode == "invalid-element-scalar" else {}
            )
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"tools": [invalid_tool]},
            }
        return {"jsonrpc": "2.0", "id": request_id, "result": {"tools": [{"name": "echo", "description": "Echo test input", "inputSchema": {"type": "object"}}]}}
    if method == "resources/list":
        if resources_mode == "timeout":
            return None
        if resources_mode == "error":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32002, "message": "injected resources failure"},
            }
        if resources_mode == "invalid":
            return {"jsonrpc": "2.0", "id": request_id, "result": {"notResources": []}}
        if resources_mode == "invalid-element":
            return {"jsonrpc": "2.0", "id": request_id, "result": {"resources": [42]}}
        return {"jsonrpc": "2.0", "id": request_id, "result": {"resources": []}}
    if method == "prompts/list":
        if prompts_mode == "timeout":
            return None
        if prompts_mode == "error":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32003, "message": "injected prompts failure"},
            }
        if prompts_mode == "invalid":
            return {"jsonrpc": "2.0", "id": request_id, "result": {"notPrompts": []}}
        if prompts_mode == "invalid-element":
            return {"jsonrpc": "2.0", "id": request_id, "result": {"prompts": [42]}}
        return {"jsonrpc": "2.0", "id": request_id, "result": {"prompts": []}}
    if method == "tools/call":
        if tool_call_timeout:
            return None
        if tool_call_delay_ms:
            time.sleep(tool_call_delay_ms / 1000)
        text = message.get("params", {}).get("arguments", {}).get("text", "")
        return {"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": text}], "isError": False}}
    if method == "notifications/cancelled":
        return None
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--legacy", action="store_true")
    parser.add_argument("--stdout-noise", action="store_true")
    parser.add_argument(
        "--stdout-malformed",
        choices=("noise", "invalid-utf8", "oversized"),
    )
    parser.add_argument("--malformed-first-process-only", action="store_true")
    parser.add_argument("--oversized-bytes", type=int, default=8192)
    parser.add_argument("--stderr-bytes", type=int, default=0)
    parser.add_argument("--exit-after", type=int, default=0)
    parser.add_argument("--exit-code", type=int, default=1)
    parser.add_argument("--exit-delay-ms", type=int, default=0)
    parser.add_argument("--exit-first-process-only", action="store_true")
    parser.add_argument("--resist-shutdown", action="store_true")
    parser.add_argument("--stdout-eof-after", type=int, default=0)
    parser.add_argument("--close-stderr-at-start", action="store_true")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--report-env", action="append", default=[], metavar="NAME")
    parser.add_argument("--invalid-modern-version", action="store_true")
    parser.add_argument("--invalid-legacy-version", action="store_true")
    tools_failures = parser.add_mutually_exclusive_group()
    tools_failures.add_argument("--tools-timeout", action="store_true")
    tools_failures.add_argument("--tools-error", action="store_true")
    tools_failures.add_argument("--tools-invalid-shape", action="store_true")
    tools_failures.add_argument(
        "--tools-invalid-element",
        choices=("scalar", "object"),
    )
    parser.add_argument("--tools-invalid-on", type=int, default=0, metavar="N")
    parser.add_argument("--tools-delay-ms", type=int, default=0)
    parser.add_argument("--tool-call-delay-ms", type=int, default=0)
    parser.add_argument("--tool-call-timeout", action="store_true")
    parser.add_argument("--server-request-after-inventory", action="store_true")
    parser.add_argument("--discover-timeout-first-process", action="store_true")
    parser.add_argument("--fork-helper", action="store_true")
    parser.add_argument("--resources-error", action="store_true")
    parser.add_argument("--resources-invalid-shape", action="store_true")
    parser.add_argument("--resources-invalid-element", action="store_true")
    parser.add_argument("--prompts-error", action="store_true")
    parser.add_argument("--prompts-invalid-shape", action="store_true")
    parser.add_argument("--prompts-invalid-element", action="store_true")
    parser.add_argument("literal_args", nargs="*")
    args = parser.parse_args()
    if not 0 <= args.exit_code <= 255:
        parser.error("--exit-code must be between 0 and 255")
    tools_mode = "ok"
    if args.tools_timeout:
        tools_mode = "timeout"
    elif args.tools_error:
        tools_mode = "error"
    elif args.tools_invalid_shape:
        tools_mode = "invalid"
    elif args.tools_invalid_element:
        tools_mode = f"invalid-element-{args.tools_invalid_element}"
    resources_mode = "ok"
    if args.resources_error:
        resources_mode = "error"
    elif args.resources_invalid_shape:
        resources_mode = "invalid"
    elif args.resources_invalid_element:
        resources_mode = "invalid-element"
    prompts_mode = "ok"
    if args.prompts_error:
        prompts_mode = "error"
    elif args.prompts_invalid_shape:
        prompts_mode = "invalid"
    elif args.prompts_invalid_element:
        prompts_mode = "invalid-element"
    if args.resist_shutdown:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    count = 0
    tools_count = 0
    methods: list[str | None] = []
    messages: list[dict] = []
    lifecycle = {
        "start_history_monotonic_ns": [],
        "exit_history_monotonic_ns": [],
        "server_request_history_monotonic_ns": [],
        "process_pid_history": [],
        "discover_pid_history": [],
        "initialize_pid_history": [],
        "cancel_pid_history": [],
        "helper_pid_history": [],
        "helper_pgid_history": [],
    }
    if args.report is not None:
        try:
            previous = json.loads(args.report.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            previous = {}
        previous_lifecycle = previous.get("lifecycle", {})
        for key in lifecycle:
            values = previous_lifecycle.get(key, [])
            if isinstance(values, list) and all(
                isinstance(value, int) for value in values
            ):
                lifecycle[key] = list(values)
    lifecycle["start_history_monotonic_ns"].append(time.monotonic_ns())
    lifecycle["process_pid_history"].append(os.getpid())
    first_process = len(lifecycle["process_pid_history"]) == 1
    if args.fork_helper:
        helper_pid = os.fork()
        if helper_pid == 0:
            for descriptor in (sys.stdin, sys.stdout, sys.stderr):
                try:
                    os.close(descriptor.fileno())
                except OSError:
                    pass
            while True:
                signal.pause()
        lifecycle["helper_pid_history"].append(helper_pid)
        lifecycle["helper_pgid_history"].append(os.getpgid(helper_pid))
    if args.report is not None:
        write_report(
            args.report,
            methods,
            messages,
            args.literal_args,
            args.report_env,
            lifecycle,
        )
    if args.stderr_bytes:
        emit_stderr_flood(args.stderr_bytes)
    if args.close_stderr_at_start:
        os.close(sys.stderr.fileno())
    malformed_sent = False
    server_request_sent = False
    stdout_closed = False
    for line in sys.stdin:
        if args.stdout_noise and not stdout_closed:
            sys.stdout.write("not-json\n")
            sys.stdout.flush()
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        methods.append(message.get("method"))
        messages.append(message)
        if message.get("method") == "server/discover":
            lifecycle["discover_pid_history"].append(os.getpid())
        elif message.get("method") == "initialize":
            lifecycle["initialize_pid_history"].append(os.getpid())
        elif message.get("method") == "notifications/cancelled":
            lifecycle["cancel_pid_history"].append(os.getpid())
        if args.report is not None:
            write_report(
                args.report,
                methods,
                messages,
                args.literal_args,
                args.report_env,
                lifecycle,
            )
        malformed_this_process = (
            not args.malformed_first_process_only or first_process
        )
        if (
            args.stdout_malformed is not None
            and not malformed_sent
            and malformed_this_process
        ):
            emit_malformed_stdout(args.stdout_malformed, args.oversized_bytes)
            malformed_sent = True
        message_tools_mode = tools_mode
        if message.get("method") == "tools/list":
            tools_count += 1
            if args.tools_invalid_on == tools_count:
                message_tools_mode = "invalid"
        discover_timeout = (
            args.discover_timeout_first_process
            and first_process
            and message.get("method") == "server/discover"
        )
        response = None
        if not discover_timeout:
            response = (
                legacy_response(
                    message,
                    invalid_modern_version=args.invalid_modern_version,
                    invalid_legacy_version=args.invalid_legacy_version,
                    tools_mode=message_tools_mode,
                    tools_delay_ms=args.tools_delay_ms,
                    resources_mode=resources_mode,
                    prompts_mode=prompts_mode,
                    tool_call_delay_ms=args.tool_call_delay_ms,
                    tool_call_timeout=args.tool_call_timeout,
                )
                if args.legacy
                else modern_response(
                    message,
                    invalid_modern_version=args.invalid_modern_version,
                    tools_mode=message_tools_mode,
                    tools_delay_ms=args.tools_delay_ms,
                    resources_mode=resources_mode,
                    prompts_mode=prompts_mode,
                    tool_call_delay_ms=args.tool_call_delay_ms,
                    tool_call_timeout=args.tool_call_timeout,
                )
            )
        if response is not None and not stdout_closed:
            send(response)
        if (
            args.server_request_after_inventory
            and message.get("method") == "prompts/list"
            and not server_request_sent
            and not stdout_closed
        ):
            send(
                {
                    "jsonrpc": "2.0",
                    "id": 9001,
                    "method": "sampling/createMessage",
                    "params": {"messages": [], "maxTokens": 1},
                }
            )
            server_request_sent = True
            lifecycle["server_request_history_monotonic_ns"].append(
                time.monotonic_ns()
            )
            if args.report is not None:
                write_report(
                    args.report,
                    methods,
                    messages,
                    args.literal_args,
                    args.report_env,
                    lifecycle,
                )
        count += 1
        if (
            args.stdout_eof_after
            and count >= args.stdout_eof_after
            and not stdout_closed
        ):
            os.close(sys.stdout.fileno())
            stdout_closed = True
        exit_this_process = (
            not args.exit_first_process_only
            or len(lifecycle["start_history_monotonic_ns"]) == 1
        )
        if args.exit_after and count >= args.exit_after and exit_this_process:
            if args.exit_delay_ms:
                time.sleep(args.exit_delay_ms / 1000)
            lifecycle["exit_history_monotonic_ns"].append(time.monotonic_ns())
            if args.report is not None:
                write_report(
                    args.report,
                    methods,
                    messages,
                    args.literal_args,
                    args.report_env,
                    lifecycle,
                )
            raise SystemExit(args.exit_code)
    if args.resist_shutdown:
        while True:
            signal.pause()


if __name__ == "__main__":
    main()
