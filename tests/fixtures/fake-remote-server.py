#!/usr/bin/env python3
"""Stand in for the machine that shows the notifications.

Records what the remote backend POSTs where a test can read it back:

    requests      one "METHOD path" line per request, in order
    notify.json   the last POST /notify body, exactly as it arrived
    dismiss.json  the last POST /dismiss body, exactly as it arrived
    auth          the last Authorization header value (empty when absent)

Usage: fake-remote-server.py <directory> <port>

Like the fake backend, this needs no support in the production code:
pointing `@tama_remote_url` at any URL is a user feature, not a testing seam.
"""

import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIRECTORY = sys.argv[1]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def record(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length > 0 else b""
        with open(DIRECTORY + "/requests", "a") as handle:
            handle.write("POST %s\n" % self.path)
        name = self.path.split("?", 1)[0].strip("/").split("/")[-1]
        with open(DIRECTORY + "/" + name + ".json", "wb") as handle:
            handle.write(body)
        with open(DIRECTORY + "/auth", "w") as handle:
            handle.write(self.headers.get("Authorization") or "")

    def reply(self):
        body = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.record()
        self.reply()

    def do_GET(self):
        self.reply()


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
