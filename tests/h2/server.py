#!/usr/bin/env python3
"""HTTP/2 servers for the HTTP/2 tests of curl-vx, built on the h2 package (python-hyper).

    python3 tests/h2/server.py CERT_DIR PORT_FILE

It serves HTTP/2 over TLS (ALPN h2) and HTTP/2 over plain TCP (prior knowledge) on free ports
of 127.0.0.1, and writes them to PORT_FILE as "tls plain". The paths:

  /               "hello over h2"
  /big            1 MiB in many DATA frames, so that curl-vx must send WINDOW_UPDATE
  /echo           the length and a checksum of the request body, read with flow control
  /early          a 413 before reading the request body
  /trailers       a body and then trailers
  /padded         a DATA frame with padding
  /long-headers   a header block larger than a frame, so it needs CONTINUATION
  /reset          RST_STREAM with the error INTERNAL_ERROR
  /redirect       a 302 to /
  /cookie         a Set-Cookie header, and the Cookie header of the request in the body
  /headers        the request headers, one per line, in the body
  /small-frames   SETTINGS_MAX_FRAME_SIZE stays 16384, and the body comes in 100-byte frames
  /ping           a PING before the response
  /goaway         GOAWAY (last stream 1) after the response
  /endless-continuation  a header block whose CONTINUATION frames never end: 4 MiB of them,
                  and then the server waits
"""
import hashlib
import os
import socket
import ssl
import sys
import threading
import time

import h2.config
import h2.connection
import h2.events
import h2.settings

CERT_DIR, PORT_FILE = sys.argv[1], sys.argv[2]


def respond(conn, sock, stream, status, headers, body, end=True):
    conn.send_headers(stream, [(":status", str(status))] + headers)
    send_body(conn, sock, stream, body, end)


def send_body(conn, sock, stream, body, end=True, frame=16384):
    sock.sendall(conn.data_to_send())
    sent = 0
    while sent < len(body):
        window = conn.local_flow_control_window(stream)
        if window <= 0:
            wait_for_window(conn, sock)
            continue
        size = min(window, frame, len(body) - sent)
        conn.send_data(stream, body[sent:sent + size])
        sent += size
        sock.sendall(conn.data_to_send())
    if end:
        conn.end_stream(stream)
    sock.sendall(conn.data_to_send())


def wait_for_window(conn, sock):
    data = sock.recv(65536)
    if not data:
        raise ConnectionError("closed")
    for event in conn.receive_data(data):
        pass
    sock.sendall(conn.data_to_send())


def handle(sock):
    config = h2.config.H2Configuration(client_side=False, header_encoding="utf-8")
    conn = h2.connection.H2Connection(config=config)
    conn.initiate_connection()
    sock.sendall(conn.data_to_send())
    bodies = {}
    heads = {}
    try:
        while True:
            data = sock.recv(65536)
            if not data:
                return
            for event in conn.receive_data(data):
                if isinstance(event, h2.events.RequestReceived):
                    heads[event.stream_id] = dict(event.headers)
                    heads[event.stream_id]["_list"] = event.headers
                    bodies[event.stream_id] = b""
                    path = heads[event.stream_id][":path"]
                    if path == "/early":
                        respond(conn, sock, event.stream_id, 413, [("content-length", "9")],
                                b"too much\n")
                    if event.stream_ended:
                        serve(conn, sock, event.stream_id, heads[event.stream_id], b"")
                elif isinstance(event, h2.events.DataReceived):
                    bodies[event.stream_id] = bodies.get(event.stream_id, b"") + event.data
                    conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    if event.stream_ended:
                        serve(conn, sock, event.stream_id, heads[event.stream_id],
                              bodies[event.stream_id])
                elif isinstance(event, h2.events.StreamEnded):
                    pass
                elif isinstance(event, h2.events.ConnectionTerminated):
                    return
            sock.sendall(conn.data_to_send())
    except (ConnectionError, OSError, h2.exceptions.ProtocolError, h2.exceptions.StreamClosedError):
        return
    finally:
        sock.close()


def serve(conn, sock, stream, head, body):
    path = head[":path"]
    if path == "/":
        respond(conn, sock, stream, 200, [("content-type", "text/plain")], b"hello over h2\n")
    elif path == "/big":
        chunk = bytes(range(256)) * 64
        respond(conn, sock, stream, 200, [("content-length", str(1 << 20))], chunk * 64)
    elif path == "/echo":
        text = "%d %s\n" % (len(body), hashlib.sha256(body).hexdigest()[:16])
        respond(conn, sock, stream, 200, [], text.encode())
    elif path == "/early":
        pass
    elif path == "/trailers":
        conn.send_headers(stream, [(":status", "200")])
        send_body(conn, sock, stream, b"body before trailers\n", end=False)
        conn.send_headers(stream, [("x-checksum", "abc123"), ("x-done", "yes")], end_stream=True)
    elif path == "/padded":
        conn.send_headers(stream, [(":status", "200"), ("x-padded", "yes")])
        sock.sendall(conn.data_to_send())
        conn.send_data(stream, b"padded data\n", pad_length=20, end_stream=True)
    elif path == "/long-headers":
        headers = [(":status", "200")] + [("x-long-%d" % i, "v" * 200) for i in range(120)]
        conn.send_headers(stream, headers)
        send_body(conn, sock, stream, b"after a long head\n")
    elif path == "/reset":
        conn.send_headers(stream, [(":status", "200")])
        conn.reset_stream(stream, error_code=2)
    elif path == "/redirect":
        respond(conn, sock, stream, 302, [("location", "/"), ("content-length", "0")], b"")
    elif path == "/cookie":
        cookie = head.get("cookie", "none")
        respond(conn, sock, stream, 200, [("set-cookie", "h2=yes; path=/")],
                ("cookie: %s\n" % cookie).encode())
    elif path == "/headers":
        text = "".join("%s: %s\n" % (k, v) for k, v in head["_list"])
        respond(conn, sock, stream, 200, [], text.encode())
    elif path == "/small-frames":
        conn.send_headers(stream, [(":status", "200")])
        send_body(conn, sock, stream, b"x" * 5000, frame=100)
    elif path == "/ping":
        conn.ping(b"12345678")
        respond(conn, sock, stream, 200, [], b"after a ping\n")
    elif path == "/endless-continuation":
        # Raw frames, past the state machine of h2: HEADERS with ":status: 200" (index 8 of
        # the static table) and no END_HEADERS, then CONTINUATION frames with no END_HEADERS.
        def frame(kind, payload):
            return (len(payload).to_bytes(3, "big") + bytes([kind, 0])
                    + stream.to_bytes(4, "big") + payload)
        sock.sendall(conn.data_to_send())
        sock.sendall(frame(1, b"\x88"))
        try:
            for _ in range(256):
                sock.sendall(frame(9, b"\x00" * 16384))
            time.sleep(30)
        except OSError:
            # curl-vx hung up at its limit, as it should.
            pass
        return
    elif path == "/goaway":
        respond(conn, sock, stream, 200, [], b"then goaway\n")
        conn.close_connection(last_stream_id=1)
    else:
        respond(conn, sock, stream, 404, [("content-length", "0")], b"")
    sock.sendall(conn.data_to_send())


def listen(wrap):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(16)

    def loop():
        while True:
            c, _ = s.accept()
            try:
                c = wrap(c)
            except (ssl.SSLError, OSError):
                c.close()
                continue
            threading.Thread(target=handle, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()
    return s.getsockname()[1]


def main():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(CERT_DIR, "server.pem"), os.path.join(CERT_DIR, "server.key"))
    context.set_alpn_protocols(["h2"])
    tls_port = listen(lambda c: context.wrap_socket(c, server_side=True))
    plain_port = listen(lambda c: c)
    with open(PORT_FILE + ".tmp", "w") as f:
        f.write("%d %d\n" % (tls_port, plain_port))
    os.replace(PORT_FILE + ".tmp", PORT_FILE)
    threading.Event().wait()


if __name__ == "__main__":
    main()
