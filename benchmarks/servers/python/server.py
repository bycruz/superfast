"""Python stdlib empty-200 HTTP/1.1 server.

Equivalent to `python3 -m http.server` (ThreadingHTTPServer since Python 3.7)
but returns an empty 200 with Content-Length: 0 and keep-alive so it is
comparable to the other benchmark servers.

Spawned by the benchmarks package: python3 server.py  (PORT env overrides).
"""
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8094"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive by default

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_HEAD = do_GET

    def log_message(self, *args):
        pass  # silence per-request logging during benchmarks


ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
