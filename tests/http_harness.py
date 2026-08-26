"""A raw HTTP client and a gateway under test, shared by the M5 suites.

Everything here speaks bytes. The point of the M5 tests is what the daemon does
with a specific sequence of octets — a duplicated framing header, a request
delivered one byte at a time, a connection that stops mid-header — and an HTTP
client library would normalise away exactly the thing under test.
"""
from __future__ import annotations

import contextlib
import errno
import socket
import time
from dataclasses import dataclass, field

from tests.test_control_protocol import DaemonUnderTest

CRLF = b"\r\n"


def free_port() -> int:
    """A port nothing is listening on.

    Racy in principle. In practice the daemon binds it within milliseconds, and
    the alternative — a fixed port — turns two concurrent test runs into a
    confusing failure rather than a rare one.
    """
    probe = socket.socket()
    try:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]
    finally:
        probe.close()


@dataclass
class Response:
    status: int
    reason: str
    headers: dict = field(default_factory=dict)
    body: bytes = b""
    raw: bytes = b""

    def header(self, name: str, default=None):
        return self.headers.get(name.lower(), default)

    def json(self):
        import json

        return json.loads(self.body.decode("utf-8"))


def parse_responses(raw: bytes) -> list:
    """Split a byte stream into responses.

    Written out rather than delegated so that a wrong Content-Length is a test
    failure here instead of something a tolerant parser papers over.
    """
    out = []
    rest = raw
    while rest:
        split = rest.find(CRLF + CRLF)
        if split < 0:
            break
        head, rest = rest[:split], rest[split + 4 :]
        lines = head.split(CRLF)
        status_line = lines[0].decode("latin-1")
        parts = status_line.split(" ", 2)
        if len(parts) < 2 or not parts[0].startswith("HTTP/"):
            raise AssertionError(f"not a status line: {status_line!r}")
        headers = {}
        for line in lines[1:]:
            name, _, value = line.decode("latin-1").partition(":")
            headers[name.strip().lower()] = value.strip()
        length = int(headers.get("content-length", 0))
        body, rest = rest[:length], rest[length:]
        out.append(
            Response(
                status=int(parts[1]),
                reason=parts[2] if len(parts) > 2 else "",
                headers=headers,
                body=body,
                raw=head,
            )
        )
    return out


def send_raw(port: int, payload: bytes, timeout: float = 5.0, host: str = "127.0.0.1") -> bytes:
    """One connection, one write, read until the peer closes or falls silent."""
    sock = socket.create_connection((host, port), timeout=timeout)
    try:
        sock.sendall(payload)
        return read_until_quiet(sock, timeout)
    finally:
        with contextlib.suppress(OSError):
            sock.close()


def read_until_quiet(sock: socket.socket, timeout: float = 5.0) -> bytes:
    sock.settimeout(timeout)
    chunks = []
    while True:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            break
        except OSError as exc:
            if exc.errno in (errno.ECONNRESET, errno.EPIPE):
                break
            raise
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def request_bytes(
    method: str = "GET",
    target: str = "/healthz",
    headers=None,
    body: bytes = b"",
    version: str = "HTTP/1.1",
    host: str = "127.0.0.1",
    close: bool = True,
) -> bytes:
    """Build a request from parts, adding nothing that was not asked for."""
    lines = [f"{method} {target} {version}".encode("latin-1")]
    supplied = {name.lower() for name, _ in (headers or [])}
    if "host" not in supplied:
        lines.append(f"Host: {host}".encode("latin-1"))
    if close and "connection" not in supplied:
        lines.append(b"Connection: close")
    for name, value in headers or []:
        if isinstance(value, bytes):
            lines.append(name.encode("latin-1") + b": " + value)
        else:
            lines.append(f"{name}: {value}".encode("latin-1"))
    return CRLF.join(lines) + CRLF + CRLF + body


def get(port: int, target: str, connect_host: str = "127.0.0.1", **kwargs) -> Response:
    raw = send_raw(port, request_bytes(target=target, **kwargs), host=connect_host)
    responses = parse_responses(raw)
    assert responses, f"no response to GET {target}: {raw!r}"
    return responses[0]


def post_json(
    port: int, target: str, payload: str, connect_host: str = "127.0.0.1", **kwargs
) -> Response:
    body = payload.encode("utf-8")
    headers = list(kwargs.pop("headers", []))
    if not any(name.lower() == "content-type" for name, _ in headers):
        headers.append(("Content-Type", "application/json"))
    headers.append(("Content-Length", str(len(body))))
    raw = send_raw(
        port,
        request_bytes(method="POST", target=target, headers=headers, body=body, **kwargs),
        host=connect_host,
    )
    responses = parse_responses(raw)
    assert responses, f"no response to POST {target}: {raw!r}"
    return responses[0]


class Gateway:
    """A daemon with its data-plane listener on a port this test owns."""

    def __init__(self, mutate=None, extra_env=None, connect_host=None, **listener) -> None:
        self.port = free_port()
        self.host = connect_host or listener.get("host", "127.0.0.1")

        def configure(document):
            document["listener"]["host"] = listener.pop("host", "127.0.0.1")
            document["listener"]["port"] = self.port
            document["listener"].update(listener)
            if mutate is not None:
                mutate(document)

        self.daemon = DaemonUnderTest(mutate=configure, extra_env=extra_env)
        self._wait_for_listener()

    def _wait_for_listener(self, timeout: float = 15.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.daemon.process.poll() is not None:
                out, err = self.daemon.process.communicate()
                raise RuntimeError(
                    "the daemon exited before its listener was up:\n"
                    + out.decode()
                    + err.decode()
                )
            try:
                probe = socket.create_connection((self.host, self.port), timeout=1.0)
                probe.close()
                return
            except OSError:
                time.sleep(0.02)
        raise RuntimeError("the gateway listener never became connectable")

    def connect(self, timeout: float = 5.0) -> socket.socket:
        return socket.create_connection((self.host, self.port), timeout=timeout)

    def get(self, target: str, **kwargs) -> Response:
        return get(self.port, target, connect_host=self.host, **kwargs)

    def post_json(self, target: str, payload: str, **kwargs) -> Response:
        return post_json(self.port, target, payload, connect_host=self.host, **kwargs)

    def send_raw(self, payload: bytes, timeout: float = 5.0) -> bytes:
        return send_raw(self.port, payload, timeout, host=self.host)

    @property
    def process(self):
        return self.daemon.process

    def alive(self) -> bool:
        return self.daemon.process.poll() is None

    def descriptor_count(self) -> int:
        import os

        return len(os.listdir(f"/proc/{self.daemon.process.pid}/fd"))

    def close(self) -> None:
        self.daemon.close()

    def __enter__(self) -> "Gateway":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
