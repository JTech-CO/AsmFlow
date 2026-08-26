"""A minimal NDJSON control client, used by the integration tests.

Standard library only, like every other test helper here: the control protocol
is a contract, and a client that needed a package to speak it would be evidence
the contract is more complicated than it claims.
"""
from __future__ import annotations

import json
import socket
from typing import Any


class ControlError(RuntimeError):
    def __init__(self, payload: dict) -> None:
        error = payload.get("error", {})
        super().__init__(f"{error.get('code')}: {error.get('message')}")
        self.payload = payload
        self.code = error.get("code")
        self.field = error.get("field")


class ControlClient:
    """One connection. Requests are correlated by an incrementing id."""

    def __init__(self, socket_path: str, timeout: float = 10.0) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(socket_path)
        self._buffer = b""
        self._next_id = 1

    def __enter__(self) -> "ControlClient":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def send_raw(self, payload: bytes) -> None:
        self.sock.sendall(payload)

    def read_frame(self) -> dict:
        while b"\n" not in self._buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("the daemon closed the connection")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        return json.loads(line.decode("utf-8"))

    def call(self, method: str, params: dict | None = None,
             request_id: str | None = None) -> Any:
        """Send one request and return its `result`, raising on an error frame."""
        if request_id is None:
            request_id = f"ctl-{self._next_id}"
            self._next_id += 1
        frame = {"id": request_id, "method": method}
        if params is not None:
            frame["params"] = params
        self.send_raw(json.dumps(frame).encode("utf-8") + b"\n")
        response = self.read_frame()
        if response.get("id") != request_id:
            raise RuntimeError(
                f"response id {response.get('id')!r} does not match "
                f"request id {request_id!r}"
            )
        if not response.get("ok"):
            raise ControlError(response)
        return response.get("result")

    def call_expect_error(self, method: str, params: dict | None = None,
                          request_id: str | None = None) -> dict:
        try:
            result = self.call(method, params, request_id)
        except ControlError as error:
            return error.payload
        raise AssertionError(f"{method} unexpectedly succeeded: {result!r}")
