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
        if headers.get("transfer-encoding", "").lower() == "chunked":
            body, rest = decode_chunked(rest)
        else:
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


class Incomplete(Exception):
    """Not enough bytes yet — meaningful only while a connection is open."""


def decode_chunked(data: bytes, partial_ok: bool = False):
    """Decode a chunked body, returning it and whatever followed.

    Written out for the same reason the rest of this parser is: a streamed
    response is framed by AsmFlow, and a decoder that tolerated a malformed
    chunk size or a missing terminator would hide the thing under test.

    Whether a short body is a defect depends on the caller. Reading until the
    peer closes, it is: a stream that ended without its terminating chunk lost
    data, and that is exactly the fault the slow-reader test found. Reading one
    response off a connection that stays open, it just means more is coming, so
    `partial_ok` raises Incomplete instead.
    """
    body = b""
    rest = data
    while True:
        split = rest.find(CRLF)
        if split < 0:
            if partial_ok:
                raise Incomplete()
            raise AssertionError(f"chunked body ended mid-header: {rest[:64]!r}")
        header = rest[:split]
        # A chunk extension is legal but AsmFlow emits none, so seeing one
        # means something other than AsmFlow framed this response.
        assert b";" not in header, f"unexpected chunk extension: {header!r}"
        size = int(header, 16)
        rest = rest[split + 2 :]
        if size == 0:
            if len(rest) < 2:
                if partial_ok:
                    raise Incomplete()
                raise AssertionError(f"missing final CRLF: {rest[:16]!r}")
            assert rest.startswith(CRLF), f"missing final CRLF: {rest[:16]!r}"
            return body, rest[2:]
        if len(rest) < size + 2:
            if partial_ok:
                raise Incomplete()
            raise AssertionError("chunked body is truncated")
        body += rest[:size]
        assert rest[size : size + 2] == CRLF, "chunk not terminated by CRLF"
        rest = rest[size + 2 :]


def parse_prefix(raw: bytes, partial_ok: bool = True):
    """One response off the front of `raw`, and the rest.

    Returns (None, raw) when the response is not complete yet.
    """
    split = raw.find(CRLF + CRLF)
    if split < 0:
        if partial_ok:
            return None, raw
        raise AssertionError(f"no header terminator in {raw[:120]!r}")
    head, rest = raw[:split], raw[split + 4 :]
    lines = head.split(CRLF)
    status_line = lines[0].decode("latin-1")
    parts = status_line.split(" ", 2)
    if len(parts) < 2 or not parts[0].startswith("HTTP/"):
        raise AssertionError(f"not a status line: {status_line!r}")
    headers = {}
    for line in lines[1:]:
        name, _, value = line.decode("latin-1").partition(":")
        headers[name.strip().lower()] = value.strip()

    if headers.get("transfer-encoding", "").lower() == "chunked":
        try:
            body, rest = decode_chunked(rest, partial_ok=partial_ok)
        except Incomplete:
            return None, raw
    else:
        length = int(headers.get("content-length", 0))
        if len(rest) < length:
            if partial_ok:
                return None, raw
            raise AssertionError("body is shorter than Content-Length")
        body, rest = rest[:length], rest[length:]

    return (
        Response(
            status=int(parts[1]),
            reason=parts[2] if len(parts) > 2 else "",
            headers=headers,
            body=body,
            raw=head,
        ),
        rest,
    )


class ResponseStream:
    """Responses read one at a time from a connection that stays open.

    `read_until_quiet` cannot be used on a keep-alive connection: there is no
    close to stop at, so it would wait out the timeout for every request and a
    pipelining test would take minutes. The leftover bytes live here rather
    than on the socket, which has no room for an attribute.
    """

    def __init__(self, sock, timeout: float = 20.0) -> None:
        self.sock = sock
        self.sock.settimeout(timeout)
        self.buffered = b""

    def next(self) -> Response:
        while True:
            response, rest = parse_prefix(self.buffered)
            if response is not None:
                self.buffered = rest
                return response
            piece = self.sock.recv(65536)
            if not piece:
                raise AssertionError(
                    "the connection closed with a partial response: "
                    f"{self.buffered[:200]!r}"
                )
            self.buffered += piece


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
