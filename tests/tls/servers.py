#!/usr/bin/env python3
"""Servers for the TLS tests of securl.

    python3 tests/tls/servers.py CERT_DIR PORT_FILE PROXY_LOG

It starts six servers on free ports of 127.0.0.1 and writes their ports to PORT_FILE as
"https http proxy mute socks mtls":

- an HTTPS server with the certificate in CERT_DIR. `/` answers "hello over tls", and `/big`
  answers 1 MiB in chunks, so that TLS reads have to wait for more data.
- a plain HTTP server whose `/to-https` redirects to the HTTPS server.
- an HTTP proxy that only does CONNECT. It writes the first line of each request to PROXY_LOG.
- a server that accepts connections and never sends a byte, for the time limits of TLS.
- a SOCKS4, SOCKS4a, SOCKS5 and SOCKS5h proxy. It writes what each client asked for to
  PROXY_LOG, such as "SOCKS5 atyp=3 localhost:443 user=". For SOCKS5 it asks for a user name
  and a password when the client offers them, and takes only "user" and "secret". It refuses
  port 1 with the error code of the protocol.
- an HTTPS server that asks for a client certificate signed by client-ca.pem. `/whoami`
  answers with the common name of the certificate.

On both HTTP servers, `/stall` sends 10 of the 100 bytes of its body and then waits, for the
time limits of reads, and `/huge-chunk` sends a chunk size too large for 64 bits. The paths of
`ENDLESS` send a status line, a header, a chunk-size line or a trailer that never ends, and
`/chunk-junk` a chunk with no CRLF after its data.

It runs until it is killed.
"""
import http.server
import os
import socket
import socketserver
import ssl
import struct
import sys
import threading
import time

CERT_DIR, PORT_FILE, PROXY_LOG = sys.argv[1], sys.argv[2], sys.argv[3]


# The paths whose response never ends a line, and the bytes before the endless line.
ENDLESS = {
    "/endless-status": b"HTTP/1.1 200 ",
    "/endless-header": b"HTTP/1.1 200 OK\r\nX-Long: ",
    "/endless-chunk-line": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;",
    "/endless-trailer": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-T: ",
}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_body(self, body, content_type="text/plain"):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            self.send_body(b"hello over tls\n")
        elif self.path == "/whoami":
            cert = self.connection.getpeercert() or {}
            names = [v for rdn in cert.get("subject", ()) for k, v in rdn if k == "commonName"]
            self.send_body(("hello " + (names[0] if names else "nobody") + "\n").encode())
        elif self.path == "/big":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            chunk = bytes(range(256)) * 64
            for _ in range(64):
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        elif self.path == "/huge-chunk":
            # A chunk size of 2^63, which does not fit in a signed 64-bit number. Read as a
            # wrapped negative length, it would skip to the "0" line and end the body there.
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"8000000000000000\r\nhello\r\n0\r\n\r\n")
        elif self.path in ENDLESS:
            # A response that never ends a line: 4 MiB with no newline, and then the server
            # waits. securl must give up at its limit, not read on and wait.
            try:
                self.wfile.write(ENDLESS[self.path])
                for _ in range(64):
                    self.wfile.write(b"x" * 65536)
                self.wfile.flush()
                time.sleep(30)
            except ConnectionError:
                # securl hung up at its limit, as it should.
                pass
        elif self.path in ("/close-notify", "/close-cut", "/close-reset"):
            # A body that ends when the connection closes: no Content-Length, not chunked. The
            # three paths close in three ways: with the TLS close message (close_notify), with
            # a plain TCP close and no close message, and with a TCP reset.
            self.close_connection = True
            self.wfile.write(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nbody until close\n")
            self.wfile.flush()
            sock = self.connection
            if self.path == "/close-notify" and isinstance(sock, ssl.SSLSocket):
                sock.settimeout(2)
                try:
                    sock.unwrap()
                except (OSError, ssl.SSLError):
                    pass
            elif self.path == "/close-reset":
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            sock.close()
        elif self.path == "/chunk-junk":
            # A chunk whose data does not end with CRLF.
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"5\r\nhelloXY0\r\n\r\n")
        elif self.path == "/stall":
            self.send_response(200)
            self.send_header("Content-Length", "100")
            self.end_headers()
            self.wfile.write(b"0123456789")
            self.wfile.flush()
            time.sleep(10)
        elif self.path == "/to-https":
            https_port = self.server.https_port
            self.send_response(302)
            self.send_header("Location", f"https://localhost:{https_port}/")
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        try:
            b.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data = b""
        while b"\r\n\r\n" not in data:
            more = self.request.recv(4096)
            if not more:
                return
            data += more
        first = data.split(b"\r\n", 1)[0]
        with open(PROXY_LOG, "ab") as log:
            log.write(first + b"\n")
        parts = first.split()
        if len(parts) < 2 or parts[0] != b"CONNECT":
            self.request.sendall(b"HTTP/1.1 405 Only CONNECT\r\nContent-Length: 0\r\n\r\n")
            return
        host, port = parts[1].rsplit(b":", 1)
        upstream = socket.create_connection((host.decode(), int(port)))
        self.request.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        t = threading.Thread(target=pipe, args=(upstream, self.request), daemon=True)
        t.start()
        pipe(self.request, upstream)
        t.join()


def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        more = sock.recv(n - len(data))
        if not more:
            raise ConnectionError("closed")
        data += more
    return data


def recv_until_nul(sock):
    data = b""
    while True:
        b = recv_exact(sock, 1)
        if b == b"\0":
            return data
        data += b


class SocksHandler(socketserver.BaseRequestHandler):
    def log(self, text):
        with open(PROXY_LOG, "a") as log:
            log.write(text + "\n")

    def handle(self):
        try:
            version = recv_exact(self.request, 1)[0]
            if version == 4:
                self.socks4()
            elif version == 5:
                self.socks5()
        except (ConnectionError, OSError):
            pass

    def connect_and_pipe(self, host, port):
        upstream = socket.create_connection((host, port), timeout=5)
        upstream.settimeout(None)
        t = threading.Thread(target=pipe, args=(upstream, self.request), daemon=True)
        t.start()
        pipe(self.request, upstream)
        t.join()

    def socks4(self):
        command, port = struct.unpack("!BH", recv_exact(self.request, 3))
        ip = recv_exact(self.request, 4)
        user = recv_until_nul(self.request).decode()
        if ip[:3] == b"\0\0\0" and ip[3] != 0:
            host = recv_until_nul(self.request).decode()
            self.log(f"SOCKS4a {host}:{port} user={user}")
        else:
            host = socket.inet_ntoa(ip)
            self.log(f"SOCKS4 {host}:{port} user={user}")
        reply = struct.pack("!BBH", 0, 91 if port == 1 else 90, port) + ip
        if port == 1:
            self.request.sendall(reply)
            return
        try:
            upstream_ok = socket.create_connection((host, port), timeout=5)
            upstream_ok.close()
        except OSError:
            self.request.sendall(struct.pack("!BBH", 0, 91, port) + ip)
            return
        self.request.sendall(reply)
        self.connect_and_pipe(host, port)

    def socks5(self):
        count = recv_exact(self.request, 1)[0]
        methods = recv_exact(self.request, count)
        user = ""
        if 2 in methods:
            self.request.sendall(b"\x05\x02")
            recv_exact(self.request, 1)
            user = recv_exact(self.request, recv_exact(self.request, 1)[0]).decode()
            password = recv_exact(self.request, recv_exact(self.request, 1)[0]).decode()
            if (user, password) != ("user", "secret"):
                self.log(f"SOCKS5 rejected user={user}")
                self.request.sendall(b"\x01\x01")
                return
            self.request.sendall(b"\x01\x00")
        else:
            self.request.sendall(b"\x05\x00")
        _ver, _cmd, _rsv, atyp = recv_exact(self.request, 4)
        if atyp == 1:
            host = socket.inet_ntoa(recv_exact(self.request, 4))
        elif atyp == 4:
            host = socket.inet_ntop(socket.AF_INET6, recv_exact(self.request, 16))
        else:
            host = recv_exact(self.request, recv_exact(self.request, 1)[0]).decode()
        port = struct.unpack("!H", recv_exact(self.request, 2))[0]
        self.log(f"SOCKS5 atyp={atyp} {host}:{port} user={user}")
        bound = b"\x01\x7f\x00\x00\x01\x00\x00"
        if port == 1:
            # 2: connection not allowed by ruleset.
            self.request.sendall(b"\x05\x02\x00" + bound)
            return
        try:
            upstream_ok = socket.create_connection((host, port), timeout=5)
            upstream_ok.close()
        except OSError:
            # 5: connection refused.
            self.request.sendall(b"\x05\x05\x00" + bound)
            return
        self.request.sendall(b"\x05\x00\x00" + bound)
        self.connect_and_pipe(host, port)


class Proxy(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


class MuteHandler(socketserver.BaseRequestHandler):
    def handle(self):
        time.sleep(10)


def main():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(CERT_DIR, "server.pem"),
                            os.path.join(CERT_DIR, "server.key"))
    https = Server(("127.0.0.1", 0), Handler)
    https.socket = context.wrap_socket(https.socket, server_side=True)
    plain = Server(("127.0.0.1", 0), Handler)
    plain.https_port = https.server_address[1]
    proxy = Proxy(("127.0.0.1", 0), ProxyHandler)
    mute = Proxy(("127.0.0.1", 0), MuteHandler)
    socks = Proxy(("127.0.0.1", 0), SocksHandler)
    mtls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    mtls_context.load_cert_chain(os.path.join(CERT_DIR, "server.pem"),
                                 os.path.join(CERT_DIR, "server.key"))
    mtls_context.verify_mode = ssl.CERT_REQUIRED
    mtls_context.load_verify_locations(os.path.join(CERT_DIR, "client-ca.pem"))
    mtls = Server(("127.0.0.1", 0), Handler)
    mtls.socket = mtls_context.wrap_socket(mtls.socket, server_side=True)
    for server in (https, plain, proxy, mute, socks, mtls):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    with open(PORT_FILE + ".tmp", "w") as f:
        f.write(f"{https.server_address[1]} {plain.server_address[1]} {proxy.server_address[1]} "
                f"{mute.server_address[1]} {socks.server_address[1]} "
                f"{mtls.server_address[1]}\n")
    os.replace(PORT_FILE + ".tmp", PORT_FILE)
    threading.Event().wait()


if __name__ == "__main__":
    main()
