"""Deterministic NDJSON control-plane server for M10 client tests.

This is deliberately a wire fixture, not a Python implementation of AsmFlow
policy.  It records the exact request sent by a console client and returns a
scripted response envelope.  TUI layout, selection, confirmation, and table
formatting remain product responsibilities.
"""
from __future__ import annotations

import copy
import json
import socket
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable


class ScriptedControlServer:
    """A small Unix-socket server backed by a JSON-compatible scenario.

    ``scenario["methods"][name]`` is either ``{"reply": envelope}`` or
    ``{"sequence": [envelope, ...]}``.  The request id is copied into every
    ordinary reply.  Three test-only keys may appear in an envelope:

    * ``_response_id`` overrides correlation (for protocol-failure tests),
    * ``_raw`` sends the supplied UTF-8 bytes verbatim,
    * ``_close`` closes the connection without replying.
    """

    def __init__(
        self,
        scenario: dict[str, Any],
        *,
        socket_path: str | Path | None = None,
    ) -> None:
        self.scenario = copy.deepcopy(scenario)
        self._tmp: tempfile.TemporaryDirectory[str] | None = None
        if socket_path is None:
            self._tmp = tempfile.TemporaryDirectory(prefix="asmflow-m10-")
            socket_path = Path(self._tmp.name) / "control.sock"
        self.socket_path = str(socket_path)
        self.requests: list[dict[str, Any]] = []
        self.raw_requests: list[bytes] = []
        self.raw_responses: list[bytes] = []
        self._method_counts: dict[str, int] = {}
        self._condition = threading.Condition()
        self._stop = threading.Event()
        self._listener: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._clients: set[socket.socket] = set()
        self._client_threads: set[threading.Thread] = set()

    @classmethod
    def from_path(cls, path: str | Path) -> "ScriptedControlServer":
        document = json.loads(Path(path).read_text(encoding="utf-8"))
        return cls(document)

    def __enter__(self) -> "ScriptedControlServer":
        self.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def start(self) -> None:
        if not hasattr(socket, "AF_UNIX"):
            raise RuntimeError("Unix-domain sockets are required for control tests")
        path = Path(self.socket_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.socket_path)
        listener.listen(8)
        listener.settimeout(0.1)
        self._listener = listener
        self._thread = threading.Thread(
            target=self._serve,
            name="asmflow-mock-control",
            daemon=True,
        )
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        listener, self._listener = self._listener, None
        if listener is not None:
            try:
                listener.close()
            except OSError:
                pass
        self.disconnect_clients()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        for thread in tuple(self._client_threads):
            thread.join(timeout=1.0)
        try:
            Path(self.socket_path).unlink()
        except FileNotFoundError:
            pass
        if self._tmp is not None:
            self._tmp.cleanup()
            self._tmp = None

    def disconnect_clients(self) -> None:
        """Simulate a daemon-side disconnect for every live console."""
        with self._condition:
            clients = tuple(self._clients)
        for client in clients:
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                client.close()
            except OSError:
                pass

    def send_event(self, event: dict[str, Any]) -> None:
        """Send one server event to all connected clients."""
        payload = json.dumps(
            event, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8") + b"\n"
        with self._condition:
            clients = tuple(self._clients)
        for client in clients:
            try:
                client.sendall(payload)
            except OSError:
                pass

    def request_count(self, method: str) -> int:
        with self._condition:
            return sum(1 for request in self.requests if request.get("method") == method)

    def wait_for_request(
        self,
        method: str,
        *,
        count: int = 1,
        timeout: float = 5.0,
        predicate: Callable[[dict[str, Any]], bool] | None = None,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        with self._condition:
            while True:
                matching = [
                    request
                    for request in self.requests
                    if request.get("method") == method
                    and (predicate is None or predicate(request))
                ]
                if len(matching) >= count:
                    return matching[count - 1]
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(
                        f"control method {method!r} was requested "
                        f"{len(matching)} times, expected at least {count}; "
                        f"all requests={self.requests!r}"
                    )
                self._condition.wait(remaining)

    def _serve(self) -> None:
        assert self._listener is not None
        while not self._stop.is_set():
            try:
                client, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            client.settimeout(0.1)
            with self._condition:
                self._clients.add(client)
                self._condition.notify_all()
            thread = threading.Thread(
                target=self._handle_client,
                args=(client,),
                name="asmflow-mock-control-client",
                daemon=True,
            )
            self._client_threads.add(thread)
            thread.start()

    def _handle_client(self, client: socket.socket) -> None:
        buffer = bytearray()
        try:
            while not self._stop.is_set():
                try:
                    chunk = client.recv(65536)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not chunk:
                    break
                buffer.extend(chunk)
                if len(buffer) > 1024 * 1024:
                    break
                while b"\n" in buffer:
                    raw, _, remainder = bytes(buffer).partition(b"\n")
                    buffer[:] = remainder
                    if not raw:
                        continue
                    if not self._dispatch(client, raw):
                        return
        finally:
            with self._condition:
                self._clients.discard(client)
                self._condition.notify_all()
            try:
                client.close()
            except OSError:
                pass
            self._client_threads.discard(threading.current_thread())

    def _dispatch(self, client: socket.socket, raw: bytes) -> bool:
        try:
            request = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            request = {"id": None, "method": "<invalid>"}
        with self._condition:
            self.raw_requests.append(raw + b"\n")
            self.requests.append(request)
            self._condition.notify_all()

        reply = self._reply_for(request)
        if reply.pop("_close", False):
            return False
        if "_raw" in reply:
            payload = str(reply["_raw"]).encode("utf-8")
            if not payload.endswith(b"\n"):
                payload += b"\n"
        else:
            response_id = reply.pop("_response_id", request.get("id"))
            reply["id"] = response_id
            payload = json.dumps(
                reply, ensure_ascii=False, separators=(",", ":")
            ).encode("utf-8") + b"\n"
        self.raw_responses.append(payload)
        try:
            client.sendall(payload)
        except OSError:
            return False
        return True

    def _reply_for(self, request: dict[str, Any]) -> dict[str, Any]:
        method = request.get("method")
        specification = self.scenario.get("methods", {}).get(method)
        if specification is None:
            return {
                "ok": False,
                "error": {
                    "code": "unknown_method",
                    "message": f"Unknown control method: {method}",
                    "field": "method",
                },
            }
        count = self._method_counts.get(str(method), 0)
        self._method_counts[str(method)] = count + 1
        if "sequence" in specification:
            sequence = specification["sequence"]
            if not sequence:
                raise AssertionError(f"empty mock sequence for {method}")
            reply = sequence[min(count, len(sequence) - 1)]
        else:
            reply = specification.get("reply", specification)
        return copy.deepcopy(reply)


def load_scenario(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))
