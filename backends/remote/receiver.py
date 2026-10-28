#!/usr/bin/env python3
"""tama-remote-receiver — draw tmux-agent-tamagotchi banners on this computer.

Runs on the computer that shows the notifications (for example your MacBook)
and receives what the `remote` backend forwards from the computer that runs
tmux (for example a Linux VM)::

    python3 receiver.py --port 8765 --token s3cr3t

Then, on the tmux side::

    set -g @tama_backend remote
    set -g @tama_remote_url 'http://macbook.local:8765'
    set -g @tama_remote_token 's3cr3t'

Only the standard library is used, so any Python 3.7 or newer runs this with
nothing to install.

Endpoints:

    POST /notify   {"title", "message", "group", "activate", "click"}
    POST /dismiss  {"group"}
    GET  /health   {"ok", "notifier"}

A banner is drawn with `terminal-notifier` when it is installed and with
`display notification` via `osascript` otherwise, which has no grouping and no
click action. `terminal-notifier -remove` dismisses; anything else is a no-op.

Clicking a banner runs nothing by default besides activating the terminal: the
click action names tmux paths on the *sending* machine, where this computer
cannot reach them. Pass `--ssh-target user@vm` and the click is run back over
SSH instead, so a click lands on the pane that spoke — provided this computer
can SSH there without a passphrase prompt.
"""

import argparse
import hmac
import json
import os
import shlex
import shutil
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NOTIFIER_NAME = "terminal-notifier"
NOTIFIER_DIRS = ("/opt/homebrew/bin", "/usr/local/bin")
MAX_BODY_BYTES = 1024 * 1024


def find_notifier(explicit=None):
    """The terminal-notifier to draw with, or None."""
    if explicit:
        if os.path.isfile(explicit) and os.access(explicit, os.X_OK):
            return explicit
        return None
    found = shutil.which(NOTIFIER_NAME)
    if found:
        return found
    for directory in NOTIFIER_DIRS:
        candidate = directory + "/" + NOTIFIER_NAME
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def applescript_escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def draw_banner(notifier, osascript, title, message, group, activate, execute):
    """Draw one banner. Returns True when something was asked to draw it."""
    if notifier is not None:
        argv = [notifier, "-title", title, "-message", message]
        if group and group != "ALL":
            argv += ["-group", group]
        if activate:
            argv += ["-activate", activate]
        if execute:
            argv += ["-execute", execute]
        try:
            subprocess.run(
                argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=30, check=False,
            )
            return True
        except (OSError, subprocess.SubprocessError):
            pass
    if osascript is not None:
        script = 'display notification "%s" with title "%s"' % (
            applescript_escape(message), applescript_escape(title))
        try:
            subprocess.run(
                [osascript, "-e", script],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=30, check=False,
            )
            return True
        except (OSError, subprocess.SubprocessError):
            pass
    return False


def remove_banner(notifier, group):
    """Take down the banners raised under group. A no-op without a notifier."""
    if notifier is None:
        return True
    if not group or group == "ALL":
        return True
    try:
        subprocess.run(
            [notifier, "-remove", group],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=30, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        pass
    return True


class ReceiverHandler(BaseHTTPRequestHandler):
    server_version = "tama-remote-receiver/1"

    def log_message(self, fmt, *args):  # noqa: N802 (BaseHTTPRequestHandler API)
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None, self.send_json(400, {"error": "bad Content-Length"})
        if length <= 0 or length > MAX_BODY_BYTES:
            self.send_json(413 if length > 0 else 400, {"error": "bad body size"})
            return None, None
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self.send_json(400, {"error": "malformed JSON"})
            return None, None
        if not isinstance(payload, dict):
            self.send_json(400, {"error": "JSON object expected"})
            return None, None
        return payload, None

    def authorized(self):
        expected = self.server.shared_token
        if not expected:
            return True
        presented = self.headers.get("Authorization") or ""
        if hmac.compare_digest(presented, "Bearer " + expected):
            return True
        self.send_json(401, {"error": "bad token"})
        return False

    def do_GET(self):  # noqa: N802 (BaseHTTPRequestHandler API)
        if self.path.split("?", 1)[0] != "/health":
            self.send_json(404, {"error": "unknown path"})
            return
        notifier = self.server.notifier
        self.send_json(200, {
            "ok": True,
            "notifier": NOTIFIER_NAME if notifier else (
                "osascript" if self.server.osascript else "none"),
        })

    def do_POST(self):  # noqa: N802 (BaseHTTPRequestHandler API)
        path = self.path.split("?", 1)[0]
        if path not in ("/notify", "/dismiss"):
            self.send_json(404, {"error": "unknown path"})
            return
        if not self.authorized():
            return
        payload, _ = self.read_json()
        if payload is None:
            return

        def text(name):
            value = payload.get(name) or ""
            return value if isinstance(value, str) else str(value)

        if path == "/dismiss":
            remove_banner(self.server.notifier, text("group"))
            self.send_json(200, {})
            return

        message = text("message")
        if not message:
            self.send_json(400, {"error": "message is required"})
            return
        execute = ""
        click = text("click")
        if click and self.server.ssh_target:
            execute = "%s %s %s" % (
                shlex.quote(self.server.ssh_binary),
                shlex.quote(self.server.ssh_target),
                shlex.quote(click),
            )
        shown = draw_banner(
            self.server.notifier, self.server.osascript,
            text("title"), message, text("group"), text("activate"), execute)
        if shown:
            self.send_json(200, {})
        else:
            self.send_json(500, {"error": "no notifier available"})


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Draw tmux-agent-tamagotchi banners forwarded by the "
                    "remote backend as native notifications on this computer.")
    parser.add_argument("--host", default="0.0.0.0",
                        help="interface to listen on (default: %(default)s; "
                             "use 127.0.0.1 to accept only local forwards)")
    parser.add_argument("--port", type=int, default=8765,
                        help="port to listen on (default: %(default)s)")
    parser.add_argument("--token", default=None,
                        help="shared secret the sender must present as a "
                             "bearer token (default: $TAMA_REMOTE_TOKEN, else "
                             "anyone who can reach this port may raise banners)")
    parser.add_argument("--ssh-target", default="",
                        help="optional SSH destination (user@host) back to the "
                             "tmux machine, enabling click-to-pane; without it "
                             "a click only activates the terminal")
    parser.add_argument("--terminal-notifier", default=None, metavar="PATH",
                        help="terminal-notifier binary to draw with "
                             "(default: found on PATH, then Homebrew prefixes)")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    token = args.token if args.token is not None else os.environ.get("TAMA_REMOTE_TOKEN", "")

    notifier = find_notifier(args.terminal_notifier)
    if args.terminal_notifier and notifier is None:
        sys.stderr.write("WARNING: terminal-notifier not executable, "
                         "falling back: %s\n" % args.terminal_notifier)
    osascript = shutil.which("osascript")
    ssh_binary = shutil.which("ssh") or "ssh"

    server = ThreadingHTTPServer((args.host, args.port), ReceiverHandler)
    server.shared_token = token
    server.notifier = notifier
    server.osascript = osascript
    server.ssh_target = args.ssh_target
    server.ssh_binary = ssh_binary

    print("tama-remote-receiver listening on http://%s:%d" % (args.host, args.port))
    if notifier is not None:
        print("drawing with %s" % notifier)
    elif osascript is not None:
        print("drawing with osascript (no grouping, no click action)")
    else:
        print("WARNING: neither terminal-notifier nor osascript found; "
              "/notify will answer 500 until one is installed")
    if not token:
        print("WARNING: no token configured; anyone who can reach this port "
              "may raise banners here")
    if args.ssh_target:
        print("clicks run back over SSH to %s" % args.ssh_target)
    else:
        print("clicks only activate the terminal "
              "(pass --ssh-target for click-to-pane)")
    sys.stdout.flush()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
