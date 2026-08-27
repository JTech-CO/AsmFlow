"""A provider that does exactly what a test tells it to, byte for byte.

The M6 suites are about what AsmFlow does with a provider's bytes: an event
split across two packets, a stream that stops mid-event, a response that never
starts. None of that is expressible against a real provider, and very little of
it is expressible against a library HTTP server either — `http.server` decides
its own framing, buffers what it likes, and closes when it likes.

So this speaks the socket directly. A handler receives the parsed request and a
`Writer` that can emit a status line, headers, and body bytes in whatever sizes
and at whatever times the test asks for. Nothing here is clever; the point is
that the wire is under the test's control rather than under a library's.

The server also records what it received, which is how the parity tests check
that `model` was rewritten and that everything else survived the trip.
"""
from __future__ import annotations

import json
import select
import socket
import threading
import time
from dataclasses import dataclass, field

CRLF = b"\r\n"


@dataclass
class RecordedRequest:
    method: str = ""
    target: str = ""
    headers: dict = field(default_factory=dict)
    body: bytes = b""
    disconnected: bool = False

    def json(self):
        return json.loads(self.body.decode("utf-8"))

    def header(self, name, default=None):
        return self.headers.get(name.lower(), default)


class Writer:
    """The response side of one connection, with no framing opinions."""

    def __init__(self, conn: socket.socket) -> None:
        self.conn = conn
        self.peer_gone = False

    def closed_by_peer(self) -> bool:
        """True once the gateway has closed this connection.

        A handler that only ever writes learns about a cancellation from the
        write failing. A handler that is deliberately silent — the one that
        makes a request time out, or the one holding a request open while the
        client walks away — never writes, so it needs to be able to ask. A
        zero-length peek is the answer: readable and empty means FIN.
        """
        if self.peer_gone:
            return True
        try:
            ready, _, _ = select.select([self.conn], [], [], 0)
            if not ready:
                return False
            if self.conn.recv(1, socket.MSG_PEEK) == b"":
                self.peer_gone = True
                return True
        except OSError:
            self.peer_gone = True
            return True
        return False

    def wait_for_disconnect(self, seconds: float) -> bool:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self.closed_by_peer():
                return True
            time.sleep(0.02)
        return False

    def raw(self, data: bytes) -> bool:
        """Send bytes. False once the peer has stopped reading."""
        if self.peer_gone:
            return False
        try:
            self.conn.sendall(data)
            return True
        except OSError:
            # The gateway closed the connection: on this side a cancelled
            # transfer looks like EPIPE or ECONNRESET on the next write, which
            # is what the cancellation test asserts.
            self.peer_gone = True
            return False

    def head(self, status=200, headers=None, reason="OK") -> bool:
        lines = [f"HTTP/1.1 {status} {reason}".encode()]
        for name, value in (headers or {}).items():
            lines.append(f"{name}: {value}".encode())
        lines.append(b"")
        lines.append(b"")
        return self.raw(CRLF.join(lines))

    def json_response(self, payload, status=200) -> bool:
        body = json.dumps(payload).encode()
        return self.head(
            status,
            {"Content-Type": "application/json", "Content-Length": str(len(body))},
        ) and self.raw(body)

    def sse_head(self) -> bool:
        return self.head(
            200,
            {
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "close",
            },
        )

    def chunks(self, data: bytes, size: int = 0, delay: float = 0.0) -> bool:
        """Send `data` in `size`-byte pieces; size 0 means all at once."""
        if size <= 0:
            return self.raw(data)
        for offset in range(0, len(data), size):
            if not self.raw(data[offset : offset + size]):
                return False
            if delay:
                time.sleep(delay)
        return True


class MockProvider:
    """A provider under the test's control, on a port the test owns."""

    def __init__(self, handler) -> None:
        self.handler = handler
        self.requests: list[RecordedRequest] = []
        self.lock = threading.Lock()
        self._listener = socket.socket()
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(64)
        self.port = self._listener.getsockname()[1]
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._accept_thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._accept_thread.start()

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}/v1"

    def _accept_loop(self) -> None:
        self._listener.settimeout(0.2)
        while not self._stop.is_set():
            try:
                conn, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            thread = threading.Thread(target=self._serve, args=(conn,), daemon=True)
            thread.start()
            self._threads.append(thread)

    def _serve(self, conn: socket.socket) -> None:
        record = RecordedRequest()
        try:
            conn.settimeout(30.0)
            raw = b""
            while CRLF + CRLF not in raw:
                piece = conn.recv(65536)
                if not piece:
                    return
                raw += piece
            head, _, rest = raw.partition(CRLF + CRLF)
            lines = head.decode("latin-1").split("\r\n")
            parts = lines[0].split(" ")
            record.method = parts[0] if parts else ""
            record.target = parts[1] if len(parts) > 1 else ""
            for line in lines[1:]:
                name, _, value = line.partition(":")
                record.headers[name.strip().lower()] = value.strip()

            length = int(record.header("content-length", "0") or 0)
            body = rest
            while len(body) < length:
                piece = conn.recv(65536)
                if not piece:
                    break
                body += piece
            record.body = body
            with self.lock:
                self.requests.append(record)

            writer = Writer(conn)
            self.handler(record, writer)
            record.disconnected = writer.peer_gone
        except (OSError, ValueError):
            record.disconnected = True
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def close(self) -> None:
        self._stop.set()
        try:
            self._listener.close()
        except OSError:
            pass

    def __enter__(self) -> "MockProvider":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


# --- handlers the suites reuse ---------------------------------------------


def json_handler(payload, status=200):
    """Answer every request with the same JSON document."""

    def handler(request, writer):
        writer.json_response(payload, status=status)

    return handler


def echo_handler(status=200):
    """Answer with the request body, so a test can see what was forwarded."""

    def handler(request, writer):
        writer.raw(
            b"HTTP/1.1 %d OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n"
            % (status, len(request.body))
        )
        writer.raw(request.body)

    return handler


def sse_handler(events, chunk_size=0, delay=0.0, terminate=True):
    """Stream `events` as SSE, in pieces of `chunk_size` bytes.

    `chunk_size=1` is the fragment corpus: every byte its own write, so a
    boundary falls between every pair of characters including inside a
    multi-byte one.
    """

    def handler(request, writer):
        writer.sse_head()
        payload = b"".join(events)
        writer.chunks(payload, size=chunk_size, delay=delay)
        if terminate:
            # The provider closing is what ends an SSE stream.
            try:
                writer.conn.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    return handler


def hang_handler(seconds=30.0):
    """Accept the request and answer nothing, until the client gives up."""

    def handler(request, writer):
        writer.wait_for_disconnect(seconds)

    return handler


def truncating_handler(prefix, after_bytes=None):
    """Start a response and cut the connection partway through it."""

    def handler(request, writer):
        body = prefix if isinstance(prefix, bytes) else prefix.encode()
        writer.head(
            200,
            {"Content-Type": "application/json", "Content-Length": str(len(body) + 64)},
        )
        writer.raw(body if after_bytes is None else body[:after_bytes])
        try:
            writer.conn.close()
        except OSError:
            pass

    return handler


def sse_event(data: str, name: str | None = None, newline: str = "\n") -> bytes:
    """One SSE event with a chosen line terminator."""
    lines = []
    if name is not None:
        lines.append(f"event: {name}")
    lines.append(f"data: {data}")
    return (newline.join(lines) + newline + newline).encode("utf-8")
