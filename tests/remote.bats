#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

# The remote backend, driven through `bin/tama` like everything else, with the
# computer that shows the banners replaced by a fixture HTTP server that records
# what it was POSTed.
#
# What that covers: the JSON payload (title, message, per-window group, terminal
# and click), the bearer token, the dismiss half naming the group raising used,
# and every misconfiguration degrading to silence rather than a failed agent
# turn. What it cannot cover is a banner on a real Mac — there is no Notification
# Center on a CI runner — so the receiver half is asserted against a fake
# `terminal-notifier` instead, and the whole path end to end through both.
setup() {
  command -v python3 >/dev/null 2>&1 || skip 'the remote backend tests need python3'
  command -v curl >/dev/null 2>&1 || skip 'the remote backend tests need curl'

  # Before the server boots: the backend is reached from tmux hooks too, and a
  # hook's `run-shell` inherits the environment the server was started with.
  export TAMA_REMOTE_DIR="$BATS_TEST_TMPDIR/remote"
  mkdir -p "$TAMA_REMOTE_DIR"
  : >"$TAMA_REMOTE_DIR/requests"

  tama_start_server
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
}

teardown() {
  [ -z "${TAMA_REMOTE_SERVER_PID:-}" ] || kill "$TAMA_REMOTE_SERVER_PID" 2>/dev/null || true
  TAMA_REMOTE_SERVER_PID=''
  tama_detach_client
  tmux_test_server_stop
}

# A port nothing else in this test owns. Bound and released, so a parallel test
# could in principle take it first — the wait below turns that into a slow test
# rather than a wrong one.
free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# The fixture server, and the plugin pointed at it — which is also how a user
# points at their own receiver, so this exercises that resolution.
start_fake_remote_server() {
  local port
  port="$(free_port)"
  TAMA_REMOTE_URL="http://127.0.0.1:$port"
  export TAMA_REMOTE_URL
  python3 "$PLUGIN_ROOT/tests/fixtures/fake-remote-server.py" "$TAMA_REMOTE_DIR" "$port" \
    >/dev/null 2>&1 &
  TAMA_REMOTE_SERVER_PID=$!

  local waited=0
  while ! curl -s -o /dev/null "$TAMA_REMOTE_URL/"; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'the fake receiver never answered on %s\n' "$TAMA_REMOTE_URL" >&2
      return 1
    fi
    sleep 0.05
  done

  tmux_test_server_run set -g @tama_backend remote
  tmux_test_server_run set -g @tama_remote_url "$TAMA_REMOTE_URL"
}

use_remote_backend_without_url() {
  tmux_test_server_run set -g @tama_backend remote
}

# The plugin backgrounds curl on purpose — the network must not cost an agent's
# turn — so every assertion about a request has to be an eventual one.
wait_for_remote_requests() { # <count>
  local waited=0
  while [ "$(wc -l <"$TAMA_REMOTE_DIR/requests")" -lt "$1" ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'the receiver was POSTed %s time(s), want %s; requests were:\n%s\n' \
        "$(wc -l <"$TAMA_REMOTE_DIR/requests")" "$1" "$(cat "$TAMA_REMOTE_DIR/requests")" >&2
      return 1
    fi
    sleep 0.05
  done
}

remote_request_count() {
  wc -l <"$TAMA_REMOTE_DIR/requests"
}

refute_remote_request() {
  # No waiting to do: this asserts the *absence* of a request, and the only honest
  # way to do that is to give a request that was going to happen the time to happen.
  sleep 0.5
  if [ "$(remote_request_count)" -ne 0 ]; then
    printf 'expected no request at all, got:\n%s\n' "$(cat "$TAMA_REMOTE_DIR/requests")" >&2
    return 1
  fi
}

assert_remote_request() { # <number> <method-path>
  local actual
  actual="$(sed -n "${1}p" "$TAMA_REMOTE_DIR/requests")"
  assert_equal "$actual" "$2"
}

# One field of the last POST to <path>, decoded from JSON: byte-exact, whatever an
# agent put in the message.
remote_json_value() { # <path> <field>
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' \
    "$TAMA_REMOTE_DIR/$1.json" "$2"
}

assert_remote_json_value() { # <path> <field> <expected>
  local actual
  actual="$(remote_json_value "$1" "$2")" || return 1
  assert_equal "$actual" "$3"
}

# An agent pane in a second window, so the user is somewhere else — the ordinary
# case for a notification. Prints the pane id.
agent_pane_elsewhere() {
  tmux_test_server_run new-window -t t: -d -P -F '#{pane_id}'
}

@test "a banner is forwarded with its title, message and per-window group" {
  start_fake_remote_server
  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' \
    --pane "$pane"
  assert_success
  [ -z "$stderr" ]

  wait_for_remote_requests 1
  assert_remote_request 1 'POST /notify'
  assert_contains "$(remote_json_value notify title)" 'claude-code - ' 'the title'
  assert_remote_json_value notify message 'permission needed'
  assert_remote_json_value notify group "tmux-window-$window"
  # The payload shape is a cross-machine contract: the receiver reads exactly
  # these keys, so a renamed or added one must update both sides at once.
  assert_equal "$(python3 -c 'import json, sys; print(" ".join(sorted(json.load(open(sys.argv[1])))))' \
    "$TAMA_REMOTE_DIR/notify.json")" 'activate click group message title'
}

@test "the terminal to activate and the click travel with the banner" {
  start_fake_remote_server
  tmux_test_server_run set -g @tama_terminal_bundle_id net.kovidgoyal.kitty
  local pane
  pane="$(agent_pane_elsewhere)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success

  wait_for_remote_requests 1
  assert_remote_json_value notify activate net.kovidgoyal.kitty
  # The click action the core composed, for the receiver to run back over SSH.
  assert_contains "$(remote_json_value notify click)" 'select-window' 'the click'
  assert_contains "$(remote_json_value notify click)" 'focus-window' 'the click'
}

@test "a message with quotes, backslashes and newlines arrives intact" {
  start_fake_remote_server
  local message
  message="don't \"quote\" \\ $(printf 'newline\nnewline') ❄ end"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code "$message" \
    --pane "$(agent_pane_elsewhere)"
  assert_success

  wait_for_remote_requests 1
  assert_remote_json_value notify message "$message"
}

@test "dismissing removes the group that raising used" {
  start_fake_remote_server
  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  wait_for_remote_requests 1
  local group
  group="$(remote_json_value notify group)"

  run "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  wait_for_remote_requests 2

  assert_remote_request 2 'POST /dismiss'
  assert_remote_json_value dismiss group "$group"
  assert_equal "$(python3 -c 'import json, sys; print(" ".join(sorted(json.load(open(sys.argv[1])))))' \
    "$TAMA_REMOTE_DIR/dismiss.json")" 'group'
}

@test "a group named ALL is shown but never removed" {
  start_fake_remote_server
  tmux_test_server_run set -g @tama_group_format ALL
  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  wait_for_remote_requests 1
  assert_remote_json_value notify group 'ALL'

  # The receiver removes with `terminal-notifier -remove`, where ALL would take down
  # notifications that do not belong to it — so dismissing one is a quiet nothing.
  run "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  sleep 0.5
  assert_equal "$(remote_request_count)" '1'
}

@test "an empty group dismisses nothing and forwards nothing" {
  start_fake_remote_server
  tmux_test_server_run set -g @tama_group_format ''

  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  wait_for_remote_requests 1
  assert_remote_json_value notify group ''

  # An ungrouped banner is nothing the receiver can take back, so dismissing one
  # is a quiet nothing rather than a pointless POST per arrival.
  run "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  sleep 0.5
  assert_equal "$(remote_request_count)" '1'
}

@test "an empty message forwards nothing" {
  start_fake_remote_server

  run env TAMA_PLUGIN_DIR="$PLUGIN_ROOT" \
    "$PLUGIN_ROOT/backends/remote/notify" 'a title' ''
  assert_success
  refute_remote_request
}

@test "no receiver URL is silence, not a failed turn" {
  use_remote_backend_without_url
  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  # The rest of the pipeline still ran: the window is marked even though nothing was
  # forwarded, which is the whole of "degrade quietly".
  assert_flagged "$window"
  refute_remote_request

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  [ -z "$stderr" ]
}

@test "a URL that is not http(s) is silence, not a failed turn" {
  start_fake_remote_server
  tmux_test_server_run set -g @tama_remote_url 'macbook.local:8765'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' \
    --pane "$(agent_pane_elsewhere)"
  assert_success
  [ -z "$stderr" ]
  refute_remote_request
}

@test "a URL with no host, or with a path the receiver never serves, is silence" {
  # The receiver is root-mounted: a path, query or fragment in the URL is a
  # configuration that can never deliver. Every case points at the live fake
  # server, so only validation silence — never a refused connection — passes.
  start_fake_remote_server
  local base="$TAMA_REMOTE_URL" url
  for url in 'http://' 'https://' 'http:///' "$base/prefix" "$base?x=1" "$base#frag"; do
    tmux_test_server_run set -g @tama_remote_url "$url"
    : >"$TAMA_REMOTE_DIR/requests"

    run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' \
      --pane "$(agent_pane_elsewhere)"
    assert_success || return 1
    [ -z "$stderr" ] || return 1
    refute_remote_request || return 1
  done
  # A whitespace host without any slash, so only the whitespace branch rejects it.
  tmux_test_server_run set -g @tama_remote_url 'http://exa mple:8765'
  : >"$TAMA_REMOTE_DIR/requests"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' \
    --pane "$(agent_pane_elsewhere)"
  assert_success
  [ -z "$stderr" ]
  refute_remote_request
}

@test "a curl that is not installed is silence, not a failed turn" {
  start_fake_remote_server
  tmux_test_server_run set -g @tama_remote_curl /nonexistent/curl

  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_flagged "$window"
  refute_remote_request
}

@test "the bearer token travels when configured and never otherwise" {
  start_fake_remote_server
  tmux_test_server_run set -g @tama_remote_token 's3cr3t-token'

  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  wait_for_remote_requests 1
  assert_equal "$(cat "$TAMA_REMOTE_DIR/auth")" 'Bearer s3cr3t-token'

  # Dismissal carries it too: without it a token-protected receiver answers 401
  # and banners are raised but never cleared.
  run "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  wait_for_remote_requests 2
  assert_equal "$(cat "$TAMA_REMOTE_DIR/auth")" 'Bearer s3cr3t-token'

  tmux_test_server_run set -g @tama_remote_token ''
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed again' \
    --pane "$(agent_pane_elsewhere)"
  assert_success
  wait_for_remote_requests 3
  assert_equal "$(cat "$TAMA_REMOTE_DIR/auth")" ''
}

@test "an invalid timeout falls back instead of failing" {
  start_fake_remote_server
  local invalid
  for invalid in 0 00 000 soon -3 ''; do
    tmux_test_server_run set -g @tama_remote_timeout "$invalid"
    : >"$TAMA_REMOTE_DIR/requests"

    run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' \
      --pane "$(agent_pane_elsewhere)"
    assert_success || return 1
    [ -z "$stderr" ] || return 1
    wait_for_remote_requests 1 || return 1
  done
}

@test "a trailing slash on the URL does not double the slash" {
  start_fake_remote_server
  tmux_test_server_run set -g @tama_remote_url "$TAMA_REMOTE_URL///"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$(agent_pane_elsewhere)"
  assert_success
  wait_for_remote_requests 1
  assert_remote_request 1 'POST /notify'
}

@test "the remote backend runs under the bash macOS ships" {
  # bash 3.2.57 is /bin/bash on every Mac, and the machine showing these banners is
  # one; the code that builds the JSON must parse and run there too.
  tama_use_bash_32_or_skip
  start_fake_remote_server

  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  local message
  message="$(printf "it's waiting\nsecond line\tend")"
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code "$message" \
    --pane "$pane"
  assert_success
  [ -z "$stderr" ]
  wait_for_remote_requests 1
  assert_remote_json_value notify message "$message"
  assert_flagged "$window"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  [ -z "$stderr" ]
  wait_for_remote_requests 2
  assert_remote_request 2 'POST /dismiss'
}

# --- doctor --------------------------------------------------------------------

healthy_remote_server() {
  tmux_test_server_run set -g window-status-format '#I:#{E:@tama_priority}#W#{E:@tama_icons}#{E:@tama_flag}'
  tmux_test_server_run set -g window-status-current-format '#I:#{E:@tama_priority}#W#{E:@tama_icons}#{E:@tama_flag}'
  tmux_test_server_run set -g @tama_backend remote
  tmux_test_server_run set -g @tama_remote_url 'http://macbook.local:8765'
  tmux_test_server_run set -g @tama_remote_token 's3cr3t-token'
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  cd "$BATS_TEST_TMPDIR" || return 1
}

@test "doctor reports the receiver, its capabilities and the token policy" {
  healthy_remote_server
  # The real receiver, so the probe observes the true steady state: 400 for the
  # messageless probe, and a named notifier on /health.
  start_real_receiver --token 's3cr3t-token'
  tmux_test_server_run set -g @tama_remote_url "$TAMA_RECEIVER_URL"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains "receiver: $TAMA_RECEIVER_URL"
  assert_output_contains 'capabilities: notify dismiss'
  assert_output_contains 'no focused: nothing is ever suppressed'
  assert_output_contains 'no focus: a click selects the window and the pane but does not'
  assert_output_contains '@tama_remote_token is configured'
  assert_output_contains '@tama_remote_timeout is 5s'
  assert_output_contains 'receiver answers at'
  assert_output_contains '(HTTP 400)'
  assert_output_contains 'no problems and no warnings'
}

@test "doctor warns when something that is not the receiver answers 200" {
  healthy_remote_server
  # The fixture answers 200 to every POST, which a real receiver never does for
  # the messageless probe — so 200 means an impostor, not health.
  start_fake_remote_server

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'answered HTTP 200'
  assert_output_contains 'a receiver answers 400'
}

# A stub answering fixed statuses, for the probe branches no real receiver takes.
start_fixed_status_server() { # <notify-status> <health-body>
  local port status="$1" body="$2"
  port="$(free_port)"
  TAMA_STUB_URL="http://127.0.0.1:$port"
  export TAMA_STUB_URL
  python3 -c '
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
status, body = int(sys.argv[1]), sys.argv[2].encode()
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def _reply(self, code, payload):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length: self.rfile.read(length)
        self._reply(status, b"{}")
    def do_GET(self):
        self._reply(200, body)
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[3])), Handler).serve_forever()
' "$status" "$body" "$port" >/dev/null 2>&1 &
  TAMA_REMOTE_SERVER_PID=$!

  local waited=0
  while ! curl -s -o /dev/null "$TAMA_STUB_URL/health"; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'the stub server never answered on %s\n' "$TAMA_STUB_URL" >&2
      return 1
    fi
    sleep 0.05
  done
}

@test "doctor warns on a 400 from something without the receiver contract" {
  healthy_remote_server
  # 400 alone is not proof: the verdict also needs /health to speak the
  # receiver's contract.
  start_fixed_status_server 400 '{"nope": true}'
  tmux_test_server_run set -g @tama_remote_url "$TAMA_STUB_URL"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'its /health is unexpected'
}

@test "doctor warns on an unexpected probe status" {
  healthy_remote_server
  start_fixed_status_server 500 '{"ok": true, "notifier": "terminal-notifier"}'
  tmux_test_server_run set -g @tama_remote_url "$TAMA_STUB_URL"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'answered HTTP 500'
  assert_output_contains 'expected 400'
}

@test "doctor warns when the receiver has nothing to draw with" {
  healthy_remote_server
  local empty="$BATS_TEST_TMPDIR/doctor-nothing"
  mkdir -p "$empty"
  local port
  port="$(free_port)"
  TAMA_RECEIVER_URL="http://127.0.0.1:$port"
  PATH="$empty:/bin" python3 "$PLUGIN_ROOT/backends/remote/receiver.py" \
    --host 127.0.0.1 --port "$port" --terminal-notifier "$BATS_TEST_TMPDIR/no-such-notifier" \
    >/dev/null 2>&1 &
  TAMA_REMOTE_SERVER_PID=$!
  local waited=0
  while ! curl -s -o /dev/null "$TAMA_RECEIVER_URL/health"; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || return 1
    sleep 0.05
  done
  tmux_test_server_run set -g @tama_remote_url "$TAMA_RECEIVER_URL"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'receiver has no notifier'
}

@test "doctor never prints the token" {
  healthy_remote_server
  tmux_test_server_run set -g @tama_remote_token 's3cr3t-token-value'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  refute_output_contains 's3cr3t'
}

@test "doctor fails when the receiver has no URL" {
  healthy_remote_server
  tmux_test_server_run set -g @tama_remote_url ''

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains '@tama_remote_url is unset'
}

@test "doctor fails on a URL that is not the receiver's http(s) address" {
  healthy_remote_server
  tmux_test_server_run set -g @tama_remote_url 'macbook.local:8765'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains "expected the receiver's http(s):// URL"
}

@test "doctor fails when the token does not match the receiver's" {
  # The likeliest two-machine misconfiguration: banners forwarded but never drawn,
  # silent in both directions without this probe.
  start_real_receiver --token 'receiver-token'
  tmux_test_server_run set -g @tama_backend remote
  tmux_test_server_run set -g @tama_remote_url "$TAMA_RECEIVER_URL"
  tmux_test_server_run set -g @tama_remote_token 'other-token'
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'rejected this token (HTTP 401)'
  refute_output_contains 'other-token'
}

@test "doctor warns when the receiver cannot be reached" {
  healthy_remote_server
  # A port nobody listens on: refused fast, without touching the network.
  tmux_test_server_run set -g @tama_remote_url http://127.0.0.1:9

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'receiver not reached at http://127.0.0.1:9/notify'
}

@test "doctor warns without a token rather than failing" {
  healthy_remote_server
  tmux_test_server_run set -g @tama_remote_token ''

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_remote_token is empty'
  assert_output_contains 'may raise banners'
}

@test "doctor warns on a timeout that falls back" {
  healthy_remote_server
  tmux_test_server_run set -g @tama_remote_timeout 'soon'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains "@tama_remote_timeout is 'soon'; using 5s instead"
}

@test "doctor clamps a timeout no forward should wait" {
  healthy_remote_server
  tmux_test_server_run set -g @tama_remote_timeout '60000'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains "@tama_remote_timeout is '60000'; using 300s instead"
}

@test "doctor fails when curl is missing while any capability still needs it" {
  healthy_remote_server
  tmux_test_server_run set -g @tama_remote_curl "$BATS_TEST_TMPDIR/no-such-curl"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'named the remote backend and its curl is missing'
}

@test "a remote backend every capability of which is replaced is not broken" {
  # The backend ships notify and dismiss and nothing else, so two overrides really
  # do cover everything it can do — the same grading the other backends get.
  healthy_remote_server
  tmux_test_server_run set -g @tama_remote_curl "$BATS_TEST_TMPDIR/no-such-curl"
  tmux_test_server_run set -g @tama_notify_command '/bin/echo'
  tmux_test_server_run set -g @tama_dismiss_command '/bin/echo'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'named the remote backend and its curl is missing'
  assert_output_contains 'every capability this backend ships is replaced'
}

@test "a fully replaced backend is not failed over its unused URL either" {
  healthy_remote_server
  tmux_test_server_run set -g @tama_notify_command '/bin/echo'
  tmux_test_server_run set -g @tama_dismiss_command '/bin/echo'

  local url
  for url in '' 'macbook.local:8765'; do
    tmux_test_server_run set -g @tama_remote_url "$url"

    run "$PLUGIN_ROOT/bin/tama" doctor
    assert_success || return 1
    assert_output_contains 'every capability this backend ships is replaced' || return 1
    refute_output_contains 'something here is broken' || return 1
  done
}

# --- the receiver ---------------------------------------------------------------

# The real receiver, with the notifier replaced by the fixture that records the
# command line — the whole showing half, without a banner appearing anywhere.
start_real_receiver() { # [extra args…]
  export TAMA_NOTIFIER_DIR="$BATS_TEST_TMPDIR/notifier"
  mkdir -p "$TAMA_NOTIFIER_DIR"
  : >"$TAMA_NOTIFIER_DIR/calls"
  local port
  port="$(free_port)"
  TAMA_RECEIVER_URL="http://127.0.0.1:$port"
  export TAMA_RECEIVER_URL
  python3 "$PLUGIN_ROOT/backends/remote/receiver.py" --host 127.0.0.1 --port "$port" \
    --terminal-notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier" "$@" \
    >/dev/null 2>&1 &
  TAMA_REMOTE_SERVER_PID=$!

  local waited=0
  while ! curl -s -o /dev/null "$TAMA_RECEIVER_URL/health"; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'the receiver never answered on %s\n' "$TAMA_RECEIVER_URL" >&2
      return 1
    fi
    sleep 0.05
  done
}

notifier_flag() { # <flag>
  local file="$TAMA_NOTIFIER_DIR/$1"
  if [ ! -e "$file" ]; then
    printf 'the notifier was given no -%s\n' "$1" >&2
    return 1
  fi
  cat "$file"
}

assert_notifier_flag() { # <flag> <expected>
  local actual
  actual="$(notifier_flag "$1")" || return 1
  assert_equal "$actual" "$2"
}

@test "the receiver draws what it is sent, natively" {
  start_real_receiver
  local payload
  payload='{"title":"claude-code - api","message":"permission needed","group":"tmux-window-@7","activate":"com.mitchellh.ghostty"}'

  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/notify" \
    --data-binary "$payload"
  assert_success
  assert_equal "$output" '200'

  local waited=0
  while [ "$(wc -l <"$TAMA_NOTIFIER_DIR/calls")" -eq 0 ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'the notifier was never started\n' >&2
      return 1
    }
    sleep 0.05
  done
  assert_notifier_flag title 'claude-code - api'
  assert_notifier_flag message 'permission needed'
  assert_notifier_flag group 'tmux-window-@7'
  assert_notifier_flag activate 'com.mitchellh.ghostty'

  # The health contract the doctor probe and monitoring rely on.
  local health
  health="$(curl -s "$TAMA_RECEIVER_URL/health")"
  assert_equal "$(python3 -c 'import json, sys; print(json.load(sys.stdin)["ok"])' <<<"$health")" 'True'
  assert_equal "$(python3 -c 'import json, sys; print(json.load(sys.stdin)["notifier"])' <<<"$health")" 'terminal-notifier'
}

@test "the receiver guards dismissal like the backend does" {
  start_real_receiver

  # Neither ALL nor an empty group may reach `terminal-notifier -remove`: the first
  # would take down notifications that do not belong to it, the second removes
  # nothing and only costs a process.
  local group
  for group in ALL ''; do
    run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/dismiss" \
      --data-binary "{\"group\":\"$group\"}"
    assert_success || return 1
    assert_equal "$output" '200' || return 1
  done
  sleep 0.5
  [ ! -e "$TAMA_NOTIFIER_DIR/remove" ]
}

@test "the receiver never groups a banner it must not" {
  start_real_receiver

  # The notify half of the same rule: ALL or empty must draw ungrouped, never as
  # `-group ALL` (addressing unrelated banners together) or `-group ''`.
  local group
  for group in ALL ''; do
    : >"$TAMA_NOTIFIER_DIR/calls"
    rm -f "$TAMA_NOTIFIER_DIR/group"
    run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/notify" \
      --data-binary "{\"title\":\"t\",\"message\":\"m\",\"group\":\"$group\"}"
    assert_success || return 1
    assert_equal "$output" '200' || return 1
    local waited=0
    while [ "$(wc -l <"$TAMA_NOTIFIER_DIR/calls")" -eq 0 ]; do
      waited=$((waited + 1))
      [ "$waited" -le 200 ] || {
        printf 'the notifier was never started\n' >&2
        return 1
      }
      sleep 0.05
    done
    if [ -e "$TAMA_NOTIFIER_DIR/group" ]; then
      printf 'expected no -group for %s, got: %s\n' "$group" "$(cat "$TAMA_NOTIFIER_DIR/group")" >&2
      return 1
    fi
  done
}

@test "a messageless payload is the probe contract, not a banner" {
  start_real_receiver

  run curl -s -o "$BATS_TEST_TMPDIR/probe-body" -w '%{http_code}' \
    -X POST "$TAMA_RECEIVER_URL/notify" --data-binary '{}'
  assert_success
  assert_equal "$output" '400'
  assert_contains "$(cat "$BATS_TEST_TMPDIR/probe-body")" 'message is required' 'the error'
  # And no banner was drawn for it: every doctor run probes, so a draw here
  # would pop a banner on the showing computer on each one.
  [ "$(wc -l <"$TAMA_NOTIFIER_DIR/calls")" -eq 0 ]
}

@test "the receiver removes the group raising used" {
  start_real_receiver

  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/dismiss" \
    --data-binary '{"group":"tmux-window-@7"}'
  assert_success
  assert_equal "$output" '200'

  local waited=0
  while [ ! -e "$TAMA_NOTIFIER_DIR/remove" ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'the notifier was never asked to remove anything\n' >&2
      return 1
    }
    sleep 0.05
  done
  assert_notifier_flag remove 'tmux-window-@7'
}

@test "the receiver refuses without the token it was started with" {
  start_real_receiver --token 's3cr3t-token'

  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/notify" \
    --data-binary '{"title":"t","message":"m"}'
  assert_success
  assert_equal "$output" '401'

  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/notify" \
    -H 'Authorization: Bearer wrong' --data-binary '{"title":"t","message":"m"}'
  assert_success
  assert_equal "$output" '401'

  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/notify" \
    -H 'Authorization: Bearer s3cr3t-token' --data-binary '{"title":"t","message":"m"}'
  assert_success
  assert_equal "$output" '200'

  # Dismissal is gated the same way: an ungated one lets anyone on the network
  # clear banners.
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/dismiss" \
    --data-binary '{"group":"tmux-window-@7"}'
  assert_success
  assert_equal "$output" '401'

  # And health stays open: monitoring must not need the token.
  run curl -s -o /dev/null -w '%{http_code}' "$TAMA_RECEIVER_URL/health"
  assert_success
  assert_equal "$output" '200'
}

@test "a click without an SSH target only activates the terminal" {
  start_real_receiver

  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/notify" \
    --data-binary '{"title":"t","message":"m","click":"tmux select-window"}'
  assert_success
  assert_equal "$output" '200'

  local waited=0
  while [ "$(wc -l <"$TAMA_NOTIFIER_DIR/calls")" -eq 0 ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'the notifier was never started\n' >&2
      return 1
    }
    sleep 0.05
  done
  # No -execute: the click names tmux paths on the sending machine, where this
  # computer cannot reach them, so running it would only fail.
  if [ -e "$TAMA_NOTIFIER_DIR/execute" ]; then
    printf 'expected no click action, got: %s\n' "$(cat "$TAMA_NOTIFIER_DIR/execute")" >&2
    return 1
  fi
}

@test "a click with an SSH target runs back over SSH" {
  start_real_receiver --token 's3cr3t-token' --ssh-target 'user@vm'

  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/notify" \
    -H 'Authorization: Bearer s3cr3t-token' \
    --data-binary '{"title":"t","message":"m","click":"tmux select-window -t X"}'
  assert_success
  assert_equal "$output" '200'

  local waited=0
  while [ ! -e "$TAMA_NOTIFIER_DIR/execute" ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'the notifier was never given a click action\n' >&2
      return 1
    }
    sleep 0.05
  done
  # The exact command: quoting is the safety of this payload, and substrings
  # would stay green while it broke.
  assert_equal "$(notifier_flag execute)" \
    "$(python3 -c 'import shlex, shutil; print(shlex.quote(shutil.which("ssh") or "ssh"), shlex.quote("user@vm"), shlex.quote("tmux select-window -t X"))')"
}

@test "the receiver refuses an SSH target without a token" {
  local port
  port="$(free_port)"

  run --separate-stderr python3 "$PLUGIN_ROOT/backends/remote/receiver.py" --host 127.0.0.1 \
    --port "$port" --ssh-target 'user@vm'
  assert_status 2
  assert_stderr_contains '--ssh-target'
  assert_stderr_contains '--token'
}

@test "the receiver accepts a non-ASCII token" {
  start_real_receiver --token 'tokén-s3cr3t'

  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/notify" \
    -H 'Authorization: Bearer tokén-s3cr3t' --data-binary '{"title":"t","message":"m"}'
  assert_success
  assert_equal "$output" '200'
}

@test "the receiver falls back to osascript without terminal-notifier" {
  export TAMA_OSASCRIPT_DIR="$BATS_TEST_TMPDIR/osascript"
  mkdir -p "$TAMA_OSASCRIPT_DIR"
  : >"$TAMA_OSASCRIPT_DIR/calls"
  local bin="$BATS_TEST_TMPDIR/osabin"
  mkdir -p "$bin"
  cp "$PLUGIN_ROOT/tests/fixtures/fake-osascript" "$bin/osascript"

  local port
  port="$(free_port)"
  TAMA_RECEIVER_URL="http://127.0.0.1:$port"
  # A notifier path that is not there forces the fallback deterministically, on any
  # machine — including a developer Mac that really has terminal-notifier.
  PATH="$bin:/usr/bin:/bin" python3 "$PLUGIN_ROOT/backends/remote/receiver.py" \
    --host 127.0.0.1 --port "$port" --terminal-notifier "$BATS_TEST_TMPDIR/no-such-notifier" \
    >/dev/null 2>&1 &
  TAMA_REMOTE_SERVER_PID=$!
  local waited=0
  while ! curl -s -o /dev/null "$TAMA_RECEIVER_URL/health"; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || return 1
    sleep 0.05
  done

  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/notify" \
    --data-binary '{"title":"t","message":"say \"hi\"\nsecond line"}'
  assert_success
  assert_equal "$output" '200'

  waited=0
  while [ "$(wc -l <"$TAMA_OSASCRIPT_DIR/calls")" -eq 0 ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'osascript was never started\n' >&2
      return 1
    }
    sleep 0.05
  done
  assert_contains "$(cat "$TAMA_OSASCRIPT_DIR/script")" 'display notification' 'the script'
  assert_contains "$(cat "$TAMA_OSASCRIPT_DIR/script")" 'say \"hi\"' 'the escaped message'
  # One line: a literal newline would end the AppleScript string early and the
  # banner would never draw.
  assert_equal "$(wc -l <"$TAMA_OSASCRIPT_DIR/script")" '0'
}

@test "a failing terminal-notifier falls back to osascript" {
  export TAMA_OSASCRIPT_DIR="$BATS_TEST_TMPDIR/osascript-fallback"
  mkdir -p "$TAMA_OSASCRIPT_DIR"
  : >"$TAMA_OSASCRIPT_DIR/calls"
  local bin="$BATS_TEST_TMPDIR/fallbackbin"
  mkdir -p "$bin"
  cp "$PLUGIN_ROOT/tests/fixtures/fake-osascript" "$bin/osascript"
  cat >"$bin/terminal-notifier" <<'NOTIFIER'
#!/bin/sh
exit 1
NOTIFIER
  chmod +x "$bin/terminal-notifier"

  local port
  port="$(free_port)"
  TAMA_RECEIVER_URL="http://127.0.0.1:$port"
  PATH="$bin:/usr/bin:/bin" python3 "$PLUGIN_ROOT/backends/remote/receiver.py" \
    --host 127.0.0.1 --port "$port" >/dev/null 2>&1 &
  TAMA_REMOTE_SERVER_PID=$!
  local waited=0
  while ! curl -s -o /dev/null "$TAMA_RECEIVER_URL/health"; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || return 1
    sleep 0.05
  done

  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/notify" \
    --data-binary '{"title":"t","message":"m"}'
  assert_success
  assert_equal "$output" '200'

  waited=0
  while [ "$(wc -l <"$TAMA_OSASCRIPT_DIR/calls")" -eq 0 ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'the fallback never drew the banner\n' >&2
      return 1
    }
    sleep 0.05
  done
}

@test "with no notifier at all the receiver says so" {
  local empty="$BATS_TEST_TMPDIR/nothinghere"
  mkdir -p "$empty"

  local port
  port="$(free_port)"
  TAMA_RECEIVER_URL="http://127.0.0.1:$port"
  PATH="$empty:/bin" python3 "$PLUGIN_ROOT/backends/remote/receiver.py" \
    --host 127.0.0.1 --port "$port" --terminal-notifier "$BATS_TEST_TMPDIR/no-such-notifier" \
    >/dev/null 2>&1 &
  TAMA_REMOTE_SERVER_PID=$!
  local waited=0
  while ! curl -s -o /dev/null "$TAMA_RECEIVER_URL/health"; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || return 1
    sleep 0.05
  done

  run curl -s "$TAMA_RECEIVER_URL/health"
  assert_success
  assert_equal "$(python3 -c 'import json, sys; print(json.load(sys.stdin)["notifier"])' <<<"$output")" 'none'

  run curl -s -o /dev/null -w '%{http_code}' -X POST "$TAMA_RECEIVER_URL/notify" \
    --data-binary '{"title":"t","message":"m"}'
  assert_success
  assert_equal "$output" '500'
}

@test "tama notify through the real receiver draws the banner end to end" {
  # The objective itself: a notification raised on this machine, forwarded by the
  # backend, drawn natively on the other side — then taken down on arrival.
  start_real_receiver
  tmux_test_server_run set -g @tama_backend remote
  tmux_test_server_run set -g @tama_remote_url "$TAMA_RECEIVER_URL"

  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success

  local waited=0
  while [ "$(wc -l <"$TAMA_NOTIFIER_DIR/calls")" -eq 0 ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'the banner never reached the other computer\n' >&2
      return 1
    }
    sleep 0.05
  done
  assert_notifier_flag message 'permission needed'
  assert_notifier_flag group "tmux-window-$window"

  run "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  waited=0
  while [ ! -e "$TAMA_NOTIFIER_DIR/remove" ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'the dismissal never reached the other computer\n' >&2
      return 1
    }
    sleep 0.05
  done
  assert_notifier_flag remove "tmux-window-$window"
}

@test "tama notify through a token-protected receiver draws end to end" {
  # Both halves with the same token: the header the sender puts on must be the
  # one the receiver checks, or production 401s while each half passes alone.
  start_real_receiver --token 'shared-secret'
  tmux_test_server_run set -g @tama_backend remote
  tmux_test_server_run set -g @tama_remote_url "$TAMA_RECEIVER_URL"
  tmux_test_server_run set -g @tama_remote_token 'shared-secret'

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' \
    --pane "$(agent_pane_elsewhere)"
  assert_success

  local waited=0
  while [ "$(wc -l <"$TAMA_NOTIFIER_DIR/calls")" -eq 0 ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'the banner never reached the other computer\n' >&2
      return 1
    }
    sleep 0.05
  done
  assert_notifier_flag message 'permission needed'
}

@test "tama notify with the wrong token draws nothing and fails nothing" {
  start_real_receiver --token 'receiver-secret'
  tmux_test_server_run set -g @tama_backend remote
  tmux_test_server_run set -g @tama_remote_url "$TAMA_RECEIVER_URL"
  tmux_test_server_run set -g @tama_remote_token 'other-secret'

  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  # Still silence rather than a failed turn: hooks must never fail over this.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$stderr" ]
  assert_flagged "$window"

  sleep 0.5
  [ "$(wc -l <"$TAMA_NOTIFIER_DIR/calls")" -eq 0 ]
}
