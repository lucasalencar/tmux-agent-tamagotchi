#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
  CLIENT_PIDS=''
  FIFO_PIDS=''
}

teardown() {
  local pid
  for pid in $CLIENT_PIDS $FIFO_PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  tmux_test_server_stop
}

attach_client() { # <session> <name>
  _tmux_test_server_require_isolated_socket || return 1
  local session="$1" name="$2" fifo="$BATS_TEST_TMPDIR/$2.fifo" waited=0 pid holder
  mkfifo "$fifo"
  sleep 300 >"$fifo" &
  holder=$!
  tmux_test_server_run -C -f /dev/null attach -t "$session" <"$fifo" >/dev/null 2>&1 &
  pid=$!
  CLIENT_PIDS="$CLIENT_PIDS $pid"
  FIFO_PIDS="$FIFO_PIDS $holder"
  while ! tmux_test_server_run list-clients -F '#{client_name} #{session_name}' | grep -q " $session\$"; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || return 1
    sleep 0.05
  done
  eval "$name=\$(tmux_test_server_run list-clients -F '#{client_name} #{session_name}' | awk '\$2 == \"'$session'\" { print \$1; exit }')"
}

session_id() {
  tmux_test_server_run display-message -p -t "$1" '#{session_id}'
}

arrange_stale_agent_pane() { # <pane>
  local pane="$1"
  tama_arrange_sleeping_pane "$pane" || return 1
  tmux_test_server_run set-option -g @tama_gc_shells sleep
  "$PLUGIN_ROOT/bin/tama" state waiting --pane "$pane"
  tmux_test_server_run set-option -p -t "$pane" @tama_pane_cmd definitely-stale
}

@test "state changes refresh linked current summaries and unrelated all summaries once" {
  local pane linked_client linked_current_client all_client current_client
  pane="$(tama_pane_of t:0)"
  tmux_test_server_run new-session -d -s linked
  tmux_test_server_run link-window -s t:0 -t linked:
  tmux_test_server_run new-session -d -s linked-current
  tmux_test_server_run link-window -s t:0 -t linked-current:
  tmux_test_server_run new-session -d -s all-view
  tmux_test_server_run new-session -d -s current-view
  tmux_test_server_run new-session -d -s detached-all
  tmux_test_server_run set-option -t all-view @tama_summary_scope all
  tmux_test_server_run set-option -t linked @tama_summary_scope all
  tmux_test_server_run set-option -t detached-all @tama_summary_scope all
  attach_client linked linked_client
  attach_client linked-current linked_current_client
  attach_client all-view all_client
  attach_client current-view current_client

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state running --pane "$pane"
  assert_success

  assert_equal "$(grep -cx refresh-client "$TAMA_FAKE_TMUX_LOG")" 3
  assert_equal "$(grep -cx -- "$linked_client" "$TAMA_FAKE_TMUX_LOG")" 1
  assert_equal "$(grep -cx -- "$linked_current_client" "$TAMA_FAKE_TMUX_LOG")" 1
  assert_equal "$(grep -cx -- "$all_client" "$TAMA_FAKE_TMUX_LOG")" 1
  assert_equal "$(grep -cx -- "$current_client" "$TAMA_FAKE_TMUX_LOG")" 0
  assert_equal "$("$PLUGIN_ROOT/bin/tama" summary "$(session_id linked-current)")" '● 1 ◐ 0 ○ 0'
  assert_equal "$("$PLUGIN_ROOT/bin/tama" summary "$(session_id all-view)")" '● 1 ◐ 0 ○ 0'
}

@test "subagent and clear events refresh summaries only when their rendered state changes" {
  local pane client
  pane="$(tama_pane_of t:0)"
  attach_client t client
  run "$PLUGIN_ROOT/bin/tama" state idle --pane "$pane"
  assert_success

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state subagent-start child --pane "$pane"
  assert_success
  assert_equal "$(grep -cx refresh-client "$TAMA_FAKE_TMUX_LOG")" 1
  assert_equal "$("$PLUGIN_ROOT/bin/tama" summary "$(session_id t)")" '● 0 ◐ 0 ○ 0 ⚙ 1'

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state subagent-start child --pane "$pane"
  assert_success
  refute_tmux_command refresh-client

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state subagent-stop child --pane "$pane"
  assert_success
  assert_equal "$(grep -cx refresh-client "$TAMA_FAKE_TMUX_LOG")" 1
  assert_equal "$("$PLUGIN_ROOT/bin/tama" summary "$(session_id t)")" '● 0 ◐ 0 ○ 1'

  run "$PLUGIN_ROOT/bin/tama" state subagent-start child --pane "$pane"
  assert_success
  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state clear --pane "$pane"
  assert_success
  assert_equal "$(grep -cx refresh-client "$TAMA_FAKE_TMUX_LOG")" 1
  assert_equal "$("$PLUGIN_ROOT/bin/tama" summary "$(session_id t)")" '● 0 ◐ 0 ○ 0'
}

@test "gc refreshes each affected window once when clearing multiple panes" {
  local first second third first_client other_client
  first="$(tama_pane_of t:0)"
  tmux_test_server_run split-window -d -t t:0
  second="$(tmux_test_server_run list-panes -t t:0 -F '#{pane_id}' | tail -n 1)"
  tmux_test_server_run new-session -d -s other
  third="$(tama_pane_of other:0)"
  attach_client t first_client
  attach_client other other_client
  arrange_stale_agent_pane "$first"
  arrange_stale_agent_pane "$second"
  arrange_stale_agent_pane "$third"

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" gc --all
  assert_success

  assert_equal "$(grep -cx refresh-client "$TAMA_FAKE_TMUX_LOG")" 2
  assert_equal "$(grep -cx -- "$first_client" "$TAMA_FAKE_TMUX_LOG")" 1
  assert_equal "$(grep -cx -- "$other_client" "$TAMA_FAKE_TMUX_LOG")" 1
  assert_equal "$("$PLUGIN_ROOT/bin/tama" summary "$(session_id t)")" '● 0 ◐ 0 ○ 0'
}

@test "gc refreshes linked current summaries and unrelated all summaries" {
  local pane window linked_client all_client current_client
  pane="$(tama_pane_of t:0)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"
  tmux_test_server_run new-session -d -s linked
  tmux_test_server_run link-window -s t:0 -t linked:
  tmux_test_server_run new-session -d -s all-view
  tmux_test_server_run new-session -d -s current-view
  tmux_test_server_run set-option -t all-view @tama_summary_scope all
  attach_client linked linked_client
  attach_client all-view all_client
  attach_client current-view current_client
  arrange_stale_agent_pane "$pane"

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" gc --window "$window"
  assert_success

  assert_equal "$(grep -cx refresh-client "$TAMA_FAKE_TMUX_LOG")" 2
  assert_equal "$(grep -cx -- "$linked_client" "$TAMA_FAKE_TMUX_LOG")" 1
  assert_equal "$(grep -cx -- "$all_client" "$TAMA_FAKE_TMUX_LOG")" 1
  assert_equal "$(grep -cx -- "$current_client" "$TAMA_FAKE_TMUX_LOG")" 0
}

@test "refresh discovery and redraw failures cannot fail a state hook" {
  local pane
  pane="$(tama_pane_of t:0)"
  attach_client t unused
  tama_log_tmux_calls
  export TAMA_FAKE_TMUX_FAIL_COMMAND=list-windows

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state running --pane "$pane"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_pane_option "$pane" state_main running

  export TAMA_FAKE_TMUX_FAIL_COMMAND=list-clients
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state waiting --pane "$pane"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_pane_option "$pane" state_main waiting

  export TAMA_FAKE_TMUX_FAIL_COMMAND=refresh-client
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state idle --pane "$pane"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_pane_option "$pane" state_main idle
}
