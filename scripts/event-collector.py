#!/usr/bin/env python3
"""Minimal HTTP event collector for temu integration tests.

Listens for POST requests from xatu-sidecar's HTTP output and writes a sentinel
file on first event received. Used by integration-test.sh to detect that the
xatu pipeline is working end-to-end.
"""
import argparse
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler


class Handler(BaseHTTPRequestHandler):
    sentinel_path = None
    sentinel_written = False

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        print(f"Received event ({length} bytes): {body[:500]}", file=sys.stderr, flush=True)
        self.send_response(200)
        self.end_headers()
        if not Handler.sentinel_written:
            Handler.sentinel_written = True
            with open(Handler.sentinel_path, "w") as f:
                f.write(body[:1000])
            print(f"Sentinel written to {Handler.sentinel_path}", file=sys.stderr, flush=True)

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, format, *args):
        pass  # suppress default access log noise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="HTTP event collector for integration tests")
    parser.add_argument("--port", type=int, default=8888, help="Port to listen on")
    parser.add_argument("--sentinel", required=True, help="Path to write sentinel file on first event")
    args = parser.parse_args()
    Handler.sentinel_path = args.sentinel
    server = HTTPServer(("0.0.0.0", args.port), Handler)
    print(f"Listening on 0.0.0.0:{args.port}", file=sys.stderr, flush=True)
    server.serve_forever()
