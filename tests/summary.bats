#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
}

teardown() {
  tama_kill_server
}

set_pane_state() { # <pane> <state> [subagents]
  test_tmux set -p -t "$1" @tama_pane_state_main "$2"
  [ "$#" -lt 3 ] || test_tmux set -p -t "$1" @tama_pane_subagents "$3"
}

session_id() {
  test_tmux display-message -p -t "$1" '#{session_id}'
}

@test "summary renders every supported state in order for one session" {
  local running waiting idle background error
  running="$(tama_pane_of t:0)"
  waiting="$(test_tmux split-window -d -P -F '#{pane_id}' -t t:0)"
  idle="$(test_tmux split-window -d -P -F '#{pane_id}' -t t:0)"
  background="$(test_tmux split-window -d -P -F '#{pane_id}' -t t:0)"
  error="$(test_tmux split-window -d -P -F '#{pane_id}' -t t:0)"

  set_pane_state "$running" running
  set_pane_state "$waiting" waiting
  set_pane_state "$idle" idle
  set_pane_state "$background" idle child
  set_pane_state "$error" error

  run "$PLUGIN_ROOT/bin/tama" summary "$(session_id t:0)"
  assert_success
  assert_equal "$output" '● 1 ◐ 1 ○ 1 ⚙ 1 ✕ 1'
}

@test "summary keeps baseline zero buckets and omits zero situational buckets" {
  run "$PLUGIN_ROOT/bin/tama" summary "$(session_id t)"
  assert_success
  assert_equal "$output" '● 0 ◐ 0 ○ 0'
}

@test "summary counts only agent panes in the requested session" {
  local stale cleared ordinary elsewhere
  stale="$(tama_pane_of t:0)"
  cleared="$(test_tmux split-window -d -P -F '#{pane_id}' -t t:0)"
  ordinary="$(test_tmux split-window -d -P -F '#{pane_id}' -t t:0)"
  test_tmux new-session -d -s elsewhere
  elsewhere="$(tama_pane_of elsewhere:0)"

  set_pane_state "$stale" waiting
  test_tmux set -p -t "$stale" @tama_pane_cmd definitely-stale
  set_pane_state "$cleared" running
  test_tmux set -pu -t "$cleared" @tama_pane_state_main
  test_tmux set -p -t "$ordinary" @tama_pane_agent residue
  set_pane_state "$elsewhere" error

  run "$PLUGIN_ROOT/bin/tama" summary "$(session_id t:0)"
  assert_success
  assert_equal "$output" '● 0 ◐ 1 ○ 0'
  assert_pane_option "$stale" state_main waiting
}

@test "all-sessions summary includes detached sessions and deduplicates linked windows" {
  local local_pane remote_pane target
  local_pane="$(tama_pane_of t:0)"
  set_pane_state "$local_pane" running
  target="$(session_id t)"

  test_tmux new-session -d -s detached
  remote_pane="$(tama_pane_of detached:0)"
  set_pane_state "$remote_pane" waiting
  test_tmux new-session -d -s linked
  test_tmux link-window -k -s detached:0 -t linked:0

  test_tmux set -t "$target" @tama_summary_scope all

  run "$PLUGIN_ROOT/bin/tama" summary "$target"
  assert_success
  assert_equal "$output" '● 1 ◐ 1 ○ 0'
}

@test "summary scope is isolated per session and invalid values fall back to current" {
  local first first_pane second second_pane
  first="$(session_id t)"
  first_pane="$(tama_pane_of t:0)"
  set_pane_state "$first_pane" running
  test_tmux new-session -d -s other
  second="$(session_id other)"
  second_pane="$(tama_pane_of other:0)"
  set_pane_state "$second_pane" waiting

  test_tmux set-option -t "$first" @tama_summary_scope all
  test_tmux set-option -t "$second" @tama_summary_scope invalid

  run "$PLUGIN_ROOT/bin/tama" summary "$first"
  assert_success
  assert_equal "$output" '● 1 ◐ 1 ○ 0'

  run "$PLUGIN_ROOT/bin/tama" summary "$second"
  assert_success
  assert_equal "$output" '● 0 ◐ 1 ○ 0'
}

@test "summary reuses configured state icons" {
  local running background
  running="$(tama_pane_of t:0)"
  background="$(test_tmux split-window -d -P -F '#{pane_id}' -t t:0)"
  set_pane_state "$running" running
  set_pane_state "$background" idle child
  test_tmux set -g @tama_icon_running R
  test_tmux set -g @tama_icon_waiting W
  test_tmux set -g @tama_icon_idle I
  test_tmux set -g @tama_icon_background B

  run "$PLUGIN_ROOT/bin/tama" summary "$(session_id t)"
  assert_success
  assert_equal "$output" 'R 1 W 0 I 0 B 1'
}

@test "summary discards counts when a later inventory query fails" {
  local first second wrapper
  first="$(tama_pane_of t:0)"
  set_pane_state "$first" running
  second="$(test_tmux new-window -d -P -F '#{pane_id}' -t t:1)"
  set_pane_state "$second" waiting

  wrapper="$BATS_TEST_TMPDIR/tmux-fail-target"
  sed \
    -e "s|@TMUX@|$(command -v tmux)|g" \
    -e "s|@SOCKET@|$TAMA_SOCKET|g" \
    "$PLUGIN_ROOT/tests/fixtures/tmux-fail-target" >"$wrapper"
  chmod +x "$wrapper"
  export TAMA_FAIL_TARGET="$(tama_window_id t:1)"
  TAMA_TMUX="$wrapper"
  TAMA_TMUX_ARGS=''

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary "$(session_id t)"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "all-sessions summary discards counts when a later session query fails" {
  local first second target wrapper
  target="$(session_id t)"
  first="$(tama_pane_of t:0)"
  set_pane_state "$first" running
  test_tmux new-session -d -s later
  second="$(tama_pane_of later:0)"
  set_pane_state "$second" waiting
  test_tmux set-option -t "$target" @tama_summary_scope all

  wrapper="$BATS_TEST_TMPDIR/tmux-fail-target"
  sed \
    -e "s|@TMUX@|$(command -v tmux)|g" \
    -e "s|@SOCKET@|$TAMA_SOCKET|g" \
    "$PLUGIN_ROOT/tests/fixtures/tmux-fail-target" >"$wrapper"
  chmod +x "$wrapper"
  export TAMA_FAIL_TARGET="$(tama_window_id later:0)"
  TAMA_TMUX="$wrapper"
  TAMA_TMUX_ARGS=''

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary "$target"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "summary is byte-empty without tmux" {
  unset TMUX
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary '\$0'
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "summary rejects missing, empty, extra, and option-like session ids" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary
  assert_usage_error 'session id'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary ''
  assert_usage_error 'session id'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary --bad
  assert_usage_error 'session id'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" summary one two
  assert_usage_error 'exactly one'
}
