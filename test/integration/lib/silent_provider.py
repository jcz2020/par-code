#!/usr/bin/env python3
"""A provider that accepts a request, sends SSE headers, then never writes a
byte. Used by silent_provider_test.sh to prove Esc cancels a stalled turn."""
import socket
import sys
import threading
import time


def handle(conn):
    try:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(65536)
            if not chunk:
                return
            data += chunk
        head, _, rest = data.partition(b"\r\n\r\n")
        length = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1].strip())
        while len(rest) < length:
            chunk = conn.recv(65536)
            if not chunk:
                return
            rest += chunk
        conn.sendall(
            b"HTTP/1.1 200 OK\r\n"
            b"Content-Type: text/event-stream\r\n"
            b"Transfer-Encoding: chunked\r\n"
            b"Connection: keep-alive\r\n\r\n"
        )
        # Hold the connection open without ever completing the stream.
        while True:
            time.sleep(5)
    except Exception:
        pass
    finally:
        try:
            conn.close()
        except Exception:
            pass


def main():
    port_file = sys.argv[1]
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(16)
    with open(port_file, "w") as f:
        f.write(str(srv.getsockname()[1]))
        f.flush()
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
