"""End-to-end loopback checks for the built ztunnel executable.

Run after `zig build`: python3 tests/test_proxy.py
"""

import socket
import subprocess
import threading
import time
from pathlib import Path

EXECUTABLE = Path(__file__).resolve().parent.parent / "zig-out/bin/ztunnel"


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def request_status(proxy_port, request, expected):
    with socket.create_connection(("127.0.0.1", proxy_port), timeout=8) as sock:
        sock.settimeout(8)
        sock.sendall(request)
        if not request.endswith(b"\r\n\r\n"):
            sock.shutdown(socket.SHUT_WR)
        reply = bytearray()
        while chunk := sock.recv(4096):
            reply.extend(chunk)
        assert reply.startswith(expected), (expected, reply)
        assert reply.endswith(b"\r\n\r\n"), reply


def target_server(listener):
    try:
        for _ in range(2):
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(8)
                data = bytearray()
                while chunk := connection.recv(4096):
                    data.extend(chunk)
                connection.sendall(b"REPLY:" + data)
    finally:
        listener.close()


def test_tunnel(proxy_port, target_port, host):
    payload = bytes(index % 256 for index in range(9000))
    with socket.create_connection(("127.0.0.1", proxy_port), timeout=8) as sock:
        sock.settimeout(8)
        # The first tunnel bytes arrive alongside the CONNECT headers.
        sock.sendall(f"CONNECT {host}:{target_port} HTTP/1.1\r\n\r\n".encode() + b"ABC")
        headers = bytearray()
        while not headers.endswith(b"\r\n\r\n"):
            byte = sock.recv(1)
            assert byte, f"proxy closed before 200: {headers!r}"
            headers.extend(byte)
        assert headers == b"HTTP/1.1 200 Connection Established\r\n\r\n", headers

        sock.sendall(payload)
        sock.shutdown(socket.SHUT_WR)
        reply = bytearray()
        while chunk := sock.recv(4096):
            reply.extend(chunk)
        assert reply == b"REPLY:ABC" + payload, (host, len(reply))


def main():
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(2)
    listener.settimeout(10)
    target_port = listener.getsockname()[1]
    worker = threading.Thread(target=target_server, args=(listener,), daemon=True)
    worker.start()

    proxy_port = unused_port()
    proxy = subprocess.Popen(
        [str(EXECUTABLE), "--listen", f"127.0.0.1:{proxy_port}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        for _ in range(100):
            if proxy.poll() is not None:
                raise AssertionError(
                    f"proxy exited early: {proxy.stderr.read().decode()}"
                )
            try:
                with socket.create_connection(("127.0.0.1", proxy_port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.03)
        else:
            raise AssertionError("proxy did not start")

        request_status(
            proxy_port, b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", b"HTTP/1.1 405"
        )
        request_status(proxy_port, b"CONNECT :9000 HTTP/1.1\r\n\r\n", b"HTTP/1.1 400")
        request_status(
            proxy_port, b"CONNECT 127.0.0.1:9000 HTTP/1.1\r\n", b"HTTP/1.1 400"
        )
        request_status(proxy_port, b"x" * 8192, b"HTTP/1.1 400")
        request_status(
            proxy_port,
            f"CONNECT 127.0.0.1:{unused_port()} HTTP/1.1\r\n\r\n".encode(),
            b"HTTP/1.1 502",
        )
        test_tunnel(proxy_port, target_port, "127.0.0.1")
        test_tunnel(proxy_port, target_port, "localhost")
        worker.join(3)
        assert not worker.is_alive(), "target server did not finish"
        assert proxy.poll() is None, "proxy should still accept new clients"
        print("PASS: 400, 405, 502, IPv4/DNS 200, 9-KiB relay and half-closes")
    finally:
        proxy.terminate()
        try:
            proxy.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proxy.kill()
            proxy.communicate()
        listener.close()


if __name__ == "__main__":
    main()
