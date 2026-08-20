#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
  EXTRA_CLIENT_PID=''
  EXTRA_FIFO_HOLDER_PID=''
  UNRELATED_CLIENT_PID=''
  UNRELATED_FIFO_HOLDER_PID=''
}

teardown() {
  [ -z "$EXTRA_CLIENT_PID" ] || kill "$EXTRA_CLIENT_PID" 2>/dev/null || true
  [ -z "$EXTRA_FIFO_HOLDER_PID" ] || kill "$EXTRA_FIFO_HOLDER_PID" 2>/dev/null || true
  [ -z "$UNRELATED_CLIENT_PID" ] || kill "$UNRELATED_CLIENT_PID" 2>/dev/null || true
  [ -z "$UNRELATED_FIFO_HOLDER_PID" ] || kill "$UNRELATED_FIFO_HOLDER_PID" 2>/dev/null || true
  tama_detach_client
  tama_kill_server
}

session_id() {
  test_tmux display-message -p -t "$1" '#{session_id}'
}

session_scope() {
  test_tmux show-options -qv -t "$1" @tama_summary_scope
}

attach_extra_client() { # <session>
  local fifo="$BATS_TEST_TMPDIR/attach-extra.fifo" waited=0
  mkfifo "$fifo"
  sleep 300 >"$fifo" &
  EXTRA_FIFO_HOLDER_PID=$!
  tmux -L "$TAMA_SOCKET" -C attach -t "$1" <"$fifo" >/dev/null 2>&1 &
  EXTRA_CLIENT_PID=$!
  while [ "$(test_tmux list-clients -t "$1" -F '#{client_name}' | wc -l | tr -d ' ')" -lt 2 ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || return 1
    sleep 0.05
  done
}

attach_unrelated_client() { # <session>
  local fifo="$BATS_TEST_TMPDIR/attach-unrelated.fifo" waited=0
  mkfifo "$fifo"
  sleep 300 >"$fifo" &
  UNRELATED_FIFO_HOLDER_PID=$!
  tmux -L "$TAMA_SOCKET" -C attach -t "$1" <"$fifo" >/dev/null 2>&1 &
  UNRELATED_CLIENT_PID=$!
  while [ "$(test_tmux display-message -p -t "$1" '#{session_attached}')" = '0' ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || return 1
    sleep 0.05
  done
}

@test "summary-scope selects and toggles scope on the explicitly targeted session" {
  local first second
  first="$(session_id t)"
  test_tmux new-session -d -s other
  second="$(session_id other)"

  run "$PLUGIN_ROOT/bin/tama" summary-scope --session "$first" all
  assert_success
  assert_equal "$(session_scope "$first")" all
  [ -z "$(session_scope "$second")" ]

  run "$PLUGIN_ROOT/bin/tama" summary-scope --session "$first" toggle
  assert_success
  assert_equal "$(session_scope "$first")" current

  run "$PLUGIN_ROOT/bin/tama" summary-scope --session "$second" current
  assert_success
  assert_equal "$(session_scope "$second")" current
  assert_equal "$(session_scope "$first")" current
}

@test "summary-scope treats an invalid stored value as current when toggling" {
  local target
  target="$(session_id t)"
  test_tmux set-option -t "$target" @tama_summary_scope invalid

  run "$PLUGIN_ROOT/bin/tama" summary-scope --session "$target" toggle
  assert_success
  assert_equal "$(session_scope "$target")" all
}

@test "summary-scope refreshes every client displaying only the targeted session" {
  local target target_clients unrelated_client client
  target="$(session_id t)"
  test_tmux new-session -d -s unrelated
  tama_attach_client "$target"
  attach_extra_client "$target"
  attach_unrelated_client unrelated
  target_clients="$(test_tmux list-clients -t "$target" -F '#{client_name}')"
  unrelated_client="$(test_tmux list-clients -t unrelated -F '#{client_name}')"

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" summary-scope --session "$target" all
  assert_success

  assert_equal "$(grep -cx refresh-client "$TAMA_FAKE_TMUX_LOG")" 2
  assert_equal "$(grep -cx -- -S "$TAMA_FAKE_TMUX_LOG")" 2
  while IFS= read -r client; do
    assert_equal "$(grep -cx -- "$client" "$TAMA_FAKE_TMUX_LOG")" 1
  done <<EOF
$target_clients
EOF
  assert_equal "$(grep -cx -- "$unrelated_client" "$TAMA_FAKE_TMUX_LOG")" 0
  assert_equal "$(session_scope unrelated)" ''
}

@test "multiple clients do not multiply all-sessions pane counts" {
  local target pane
  target="$(session_id t)"
  pane="$(tama_pane_of t:0)"
  test_tmux set-option -p -t "$pane" @tama_pane_state_main running
  test_tmux set-option -t "$target" @tama_summary_scope all
  tama_attach_client "$target"
  attach_extra_client "$target"

  run "$PLUGIN_ROOT/bin/tama" summary "$target"
  assert_success
  assert_equal "$output" '● 1 ◐ 0 ○ 0'
}

@test "summary-scope rejects incomplete, reordered, extra, and invalid arguments" {
  local target
  target="$(session_id t)"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary-scope
  assert_usage_error '--session'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary-scope --session
  assert_usage_error 'session id'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary-scope all --session "$target"
  assert_usage_error '--session'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary-scope --session "$target" all extra
  assert_usage_error 'exactly one scope'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary-scope --session "$target" invalid
  assert_usage_error 'current, all, or toggle'
}

@test "summary-scope is byte-empty without tmux" {
  unset TMUX
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary-scope --session '\$0' all
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "all-sessions selection and rendering run under the bash macOS ships" {
  tama_use_bash_32_or_skip
  local target pane
  target="$(session_id t)"
  pane="$(tama_pane_of t:0)"
  test_tmux set-option -p -t "$pane" @tama_pane_state_main running

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary-scope --session "$target" all
  assert_success
  [ -z "$stderr" ]
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary "$target"
  assert_success
  [ -z "$stderr" ]
  assert_equal "$output" '● 1 ◐ 0 ○ 0'
}
