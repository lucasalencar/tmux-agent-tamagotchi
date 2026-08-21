#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
}

teardown() {
  tmux_test_server_stop
}

set_pane_state() { # <pane> <state> [subagents]
  tmux_test_server_run set -p -t "$1" @tama_pane_state_main "$2"
  [ "$#" -lt 3 ] || tmux_test_server_run set -p -t "$1" @tama_pane_subagents "$3"
}

session_id() {
  tmux_test_server_run display-message -p -t "$1" '#{session_id}'
}

@test "summary renders every supported state in order for one session" {
  local running waiting idle background error
  running="$(tama_pane_of t:0)"
  waiting="$(tmux_test_server_run split-window -d -P -F '#{pane_id}' -t t:0)"
  idle="$(tmux_test_server_run split-window -d -P -F '#{pane_id}' -t t:0)"
  background="$(tmux_test_server_run split-window -d -P -F '#{pane_id}' -t t:0)"
  error="$(tmux_test_server_run split-window -d -P -F '#{pane_id}' -t t:0)"

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

@test "summary renders unsupported nonempty reported states in the unknown bucket" {
  local unknown ordinary
  unknown="$(tama_pane_of t:0)"
  ordinary="$(tmux_test_server_run split-window -d -P -F '#{pane_id}' -t t:0)"
  set_pane_state "$unknown" surprised
  tmux_test_server_run set -p -t "$ordinary" @tama_pane_state_main ''

  run "$PLUGIN_ROOT/bin/tama" summary "$(session_id t)"
  assert_success
  assert_equal "$output" '● 0 ◐ 0 ○ 0 ? 1'
}

@test "summary uses the configured unknown icon literally" {
  local unknown
  unknown="$(tama_pane_of t:0)"
  set_pane_state "$unknown" surprised
  tmux_test_server_run set -g @tama_icon_unknown '#[fg=magenta]U'

  run "$PLUGIN_ROOT/bin/tama" summary "$(session_id t)"
  assert_success
  assert_equal "$output" '● 0 ◐ 0 ○ 0 ##[fg=magenta]U 1'
}

@test "summary applies always nonzero and never independently to every bucket" {
  local waiting
  waiting="$(tama_pane_of t:0)"
  set_pane_state "$waiting" waiting
  tmux_test_server_run set -g @tama_summary_show_running never
  tmux_test_server_run set -g @tama_summary_show_waiting nonzero
  tmux_test_server_run set -g @tama_summary_show_idle never
  tmux_test_server_run set -g @tama_summary_show_background always
  tmux_test_server_run set -g @tama_summary_show_error always
  tmux_test_server_run set -g @tama_summary_show_unknown always

  run "$PLUGIN_ROOT/bin/tama" summary "$(session_id t)"
  assert_success
  assert_equal "$output" '◐ 1 ⚙ 0 ✕ 0 ? 0'
}

@test "summary composes configured prefix separator and suffix around literal styled icons" {
  local running
  running="$(tama_pane_of t:0)"
  set_pane_state "$running" running
  tmux_test_server_run set -g @tama_icon_running '#[fg=green]R'
  tmux_test_server_run set -g @tama_icon_waiting '#[fg=yellow]W'
  tmux_test_server_run set -g @tama_icon_idle '#[fg=white]I'
  tmux_test_server_run set -g @tama_icon_background '#[fg=cyan]B'
  tmux_test_server_run set -g @tama_icon_error '#[fg=red]E'
  tmux_test_server_run set -g @tama_summary_show_background always
  tmux_test_server_run set -g @tama_summary_show_error always
  tmux_test_server_run set -g @tama_summary_prefix '#[bold]<'
  tmux_test_server_run set -g @tama_summary_separator '#[default]|'
  tmux_test_server_run set -g @tama_summary_suffix '>#[nobold]'

  run "$PLUGIN_ROOT/bin/tama" summary "$(session_id t)"
  assert_success
  assert_equal "$output" '##[bold]<##[fg=green]R 1##[default]|##[fg=yellow]W 0##[default]|##[fg=white]I 0##[default]|##[fg=cyan]B 0##[default]|##[fg=red]E 0>##[nobold]'
}

@test "summary falls back independently from invalid bucket policies" {
  tmux_test_server_run set -g @tama_summary_show_running sometimes
  tmux_test_server_run set -g @tama_summary_show_waiting sometimes
  tmux_test_server_run set -g @tama_summary_show_idle sometimes
  tmux_test_server_run set -g @tama_summary_show_background sometimes
  tmux_test_server_run set -g @tama_summary_show_error sometimes
  tmux_test_server_run set -g @tama_summary_show_unknown sometimes

  run "$PLUGIN_ROOT/bin/tama" summary "$(session_id t)"
  assert_success
  assert_equal "$output" '● 0 ◐ 0 ○ 0'
}

@test "summary counts only agent panes in the requested session" {
  local stale cleared ordinary elsewhere
  stale="$(tama_pane_of t:0)"
  cleared="$(tmux_test_server_run split-window -d -P -F '#{pane_id}' -t t:0)"
  ordinary="$(tmux_test_server_run split-window -d -P -F '#{pane_id}' -t t:0)"
  tmux_test_server_run new-session -d -s elsewhere
  elsewhere="$(tama_pane_of elsewhere:0)"

  set_pane_state "$stale" waiting
  tmux_test_server_run set -p -t "$stale" @tama_pane_cmd definitely-stale
  set_pane_state "$cleared" running
  tmux_test_server_run set -pu -t "$cleared" @tama_pane_state_main
  tmux_test_server_run set -p -t "$ordinary" @tama_pane_agent residue
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

  tmux_test_server_run new-session -d -s detached
  remote_pane="$(tama_pane_of detached:0)"
  set_pane_state "$remote_pane" waiting
  tmux_test_server_run new-session -d -s linked
  tmux_test_server_run link-window -k -s detached:0 -t linked:0

  tmux_test_server_run set -t "$target" @tama_summary_scope all

  run "$PLUGIN_ROOT/bin/tama" summary "$target"
  assert_success
  assert_equal "$output" '● 1 ◐ 1 ○ 0'
}

@test "summary scope is isolated per session and invalid values fall back to current" {
  local first first_pane second second_pane
  first="$(session_id t)"
  first_pane="$(tama_pane_of t:0)"
  set_pane_state "$first_pane" running
  tmux_test_server_run new-session -d -s other
  second="$(session_id other)"
  second_pane="$(tama_pane_of other:0)"
  set_pane_state "$second_pane" waiting

  tmux_test_server_run set-option -t "$first" @tama_summary_scope all
  tmux_test_server_run set-option -t "$second" @tama_summary_scope invalid

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
  background="$(tmux_test_server_run split-window -d -P -F '#{pane_id}' -t t:0)"
  set_pane_state "$running" running
  set_pane_state "$background" idle child
  tmux_test_server_run set -g @tama_icon_running R
  tmux_test_server_run set -g @tama_icon_waiting W
  tmux_test_server_run set -g @tama_icon_idle I
  tmux_test_server_run set -g @tama_icon_background B

  run "$PLUGIN_ROOT/bin/tama" summary "$(session_id t)"
  assert_success
  assert_equal "$output" 'R 1 W 0 I 0 B 1'
}

@test "summary discards counts when a later inventory query fails" {
  local first second wrapper
  first="$(tama_pane_of t:0)"
  set_pane_state "$first" running
  second="$(tmux_test_server_run new-window -d -P -F '#{pane_id}' -t t:1)"
  set_pane_state "$second" waiting

  wrapper="$BATS_TEST_TMPDIR/tmux-fail-target"
  sed \
    -e "s|@TMUX@|$(command -v tmux)|g" \
    "$PLUGIN_ROOT/tests/fixtures/tmux-fail-target" >"$wrapper"
  chmod +x "$wrapper"
  export TAMA_FAIL_TARGET="$(tama_window_id t:1)"
  TAMA_TMUX="$wrapper"
  TAMA_TMUX_ARGS="-L $TMUX_TEST_SOCKET"

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
  tmux_test_server_run new-session -d -s later
  second="$(tama_pane_of later:0)"
  set_pane_state "$second" waiting
  tmux_test_server_run set-option -t "$target" @tama_summary_scope all

  wrapper="$BATS_TEST_TMPDIR/tmux-fail-target"
  sed \
    -e "s|@TMUX@|$(command -v tmux)|g" \
    "$PLUGIN_ROOT/tests/fixtures/tmux-fail-target" >"$wrapper"
  chmod +x "$wrapper"
  export TAMA_FAIL_TARGET="$(tama_window_id later:0)"
  TAMA_TMUX="$wrapper"
  TAMA_TMUX_ARGS="-L $TMUX_TEST_SOCKET"

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
