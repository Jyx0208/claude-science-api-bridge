#!/usr/bin/env python3
"""Tiny TCP forwarder: 127.0.0.1:443 → 127.0.0.1:9877

Requires sudo because port 443 is privileged.
The TLS/HTTPS is handled by the proxy on 9877, this just forwards raw bytes.
"""
import socket
import sys
import threading

SRC_HOST = "127.0.0.1"
SRC_PORT = 443
DST_HOST = "127.0.0.1"
DST_PORT = 9877


def forward(src, dst_host, dst_port):
    """Bidirectional raw TCP forwarding between src socket and destination."""
    dst = None
    try:
        dst = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        dst.settimeout(30)
        dst.connect((dst_host, dst_port))
        src.settimeout(30)
        dst.settimeout(30)

        def pipe(a, b):
            try:
                while True:
                    data = a.recv(65536)
                    if not data:
                        break
                    b.sendall(data)
            except Exception:
                pass

        t1 = threading.Thread(target=pipe, args=(src, dst), daemon=True)
        t2 = threading.Thread(target=pipe, args=(dst, src), daemon=True)
        t1.start()
        t2.start()
        t1.join(timeout=300)
        t2.join(timeout=300)
    except Exception as e:
        print(f"[forward-443] connection error: {e}", file=sys.stderr)
    finally:
        try:
            src.close()
        except Exception:
            pass
        try:
            dst.close()
        except Exception:
            pass


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Allow quick restart without TIME_WAIT
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1) if hasattr(socket, 'SO_REUSEPORT') else None

    try:
        server.bind((SRC_HOST, SRC_PORT))
    except PermissionError:
        print(f"[forward-443] ERROR: Need root to bind port {SRC_PORT}. Run with sudo.",
              file=sys.stderr)
        sys.exit(1)

    server.listen(32)
    print(f"[forward-443] Listening on {SRC_HOST}:{SRC_PORT} → {DST_HOST}:{DST_PORT}")

    while True:
        try:
            client, addr = server.accept()
            t = threading.Thread(target=forward, args=(client, DST_HOST, DST_PORT), daemon=True)
            t.start()
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"[forward-443] accept error: {e}", file=sys.stderr)

    server.close()
    print("[forward-443] Shutdown")


if __name__ == "__main__":
    main()
