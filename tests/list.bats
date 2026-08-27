#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
}

teardown() {
  tmux_test_server_stop
}

set_pane_value() { # <pane> <option suffix> <value>
  tmux_test_server_run set -p -t "$1" "@tama_pane_$2" "$3"
}

record_for() { # <session target> <pane> <agent> <state> <label>
  local tab format
  tab="$(printf '\t')"
  format="#{session_name}${tab}#{session_id}${tab}#{window_index}${tab}#{window_name}${tab}#{window_id}${tab}#{pane_index}${tab}#{pane_id}${tab}$3${tab}$4${tab}$5"
  tmux_test_server_run display-message -p -t "$1.$2" "$format"
}

@test "list emits fixed records for every agent pane in deterministic server order" {
  tmux_test_server_run rename-session -t t zeta
  tmux_test_server_run rename-window -t zeta:0 'main window'
  local zeta_first zeta_second zeta_two zeta_ten alpha
  zeta_first="$(tama_pane_of zeta:0)"
  zeta_second="$(tmux_test_server_run split-window -d -P -F '#{pane_id}' -t zeta:0)"
  zeta_two="$(tmux_test_server_run new-window -d -P -F '#{pane_id}' -t zeta:2 -n two)"
  zeta_ten="$(tmux_test_server_run new-window -d -P -F '#{pane_id}' -t zeta:10 -n ten)"
  tmux_test_server_run new-session -d -s alpha -n 'unicode-ç'
  alpha="$(tama_pane_of alpha:0)"

  set_pane_value "$zeta_first" state_main waiting
  set_pane_value "$zeta_first" agent 'Claude Code'
  set_pane_value "$zeta_first" label 'api \\ v2'
  set_pane_value "$zeta_second" state_main idle
  set_pane_value "$zeta_second" subagents child
  set_pane_value "$alpha" state_main future-state
  set_pane_value "$alpha" agent 'Codex-β!'
  set_pane_value "$zeta_two" state_main running
  set_pane_value "$zeta_ten" state_main error

  local expected
  expected="$(printf '%s\n%s\n%s\n%s\n%s' \
    "$(record_for alpha:0 "$alpha" 'Codex-β!' future-state '')" \
    "$(record_for zeta:0 "$zeta_first" 'Claude Code' waiting 'api \\ v2')" \
    "$(record_for zeta:0 "$zeta_second" '' background '')" \
    "$(record_for zeta:2 "$zeta_two" '' running '')" \
    "$(record_for zeta:10 "$zeta_ten" '' error '')")"

  run "$PLUGIN_ROOT/bin/tama" list
  assert_success
  assert_equal "$output" "$expected"
}

@test "list filters by exact session name and id and missing sessions are empty" {
  tmux_test_server_run rename-session -t t exact
  local pane session_id expected
  pane="$(tama_pane_of exact:0)"
  session_id="$(tmux_test_server_run display-message -p -t exact:0 '#{session_id}')"
  set_pane_value "$pane" state_main running
  expected="$(record_for exact:0 "$pane" '' running '')"

  run "$PLUGIN_ROOT/bin/tama" list --session exact
  assert_success
  assert_equal "$output" "$expected"
  run "$PLUGIN_ROOT/bin/tama" list --session "$session_id"
  assert_success
  assert_equal "$output" "$expected"
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" list --session ex
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "list emits one record for each linked-window session linkage" {
  tmux_test_server_run rename-session -t t one
  local pane window_id
  pane="$(tama_pane_of one:0)"
  window_id="$(tama_window_id one:0)"
  set_pane_value "$pane" state_main idle
  tmux_test_server_run new-session -d -s two
  tmux_test_server_run link-window -s "$window_id" -t two:4

  run "$PLUGIN_ROOT/bin/tama" list
  assert_success
  assert_equal "$(printf '%s\n%s' \
    "$(record_for one:0 "$pane" '' idle '')" \
    "$(record_for two:4 "$pane" '' idle '')")" "$output"
}

@test "list does not embed control separators that older tmux versions escape" {
  local pane expected wrapper
  pane="$(tama_pane_of t:0)"
  set_pane_value "$pane" state_main running
  expected="$(record_for t:0 "$pane" '' running '')"
  wrapper="$BATS_TEST_TMPDIR/tmux-escaping-control-formats"
  sed \
    -e "s|@TMUX@|$(command -v tmux)|g" \
    "$PLUGIN_ROOT/tests/fixtures/tmux-escaping-control-formats" >"$wrapper"
  chmod +x "$wrapper"
  TAMA_TMUX="$wrapper"
  TAMA_TMUX_ARGS="-L $TMUX_TEST_SOCKET"

  run "$PLUGIN_ROOT/bin/tama" list
  assert_success
  assert_equal "$output" "$expected"
}

@test "list excludes ordinary panes and every auxiliary-only residue" {
  local suffix pane window_number=0
  for suffix in agent label cmd cwd subagents; do
    window_number=$((window_number + 1))
    pane="$(tmux_test_server_run new-window -d -P -F '#{pane_id}' -t "t:$window_number")"
    set_pane_value "$pane" "$suffix" residue
  done
  tmux_test_server_run set -w -t t:0 @tama_window_notification_pending residue

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" list
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "list is read-only, reports stale state, and a cleared pane disappears" {
  local pane before expected
  pane="$(tama_pane_of t:0)"
  set_pane_value "$pane" state_main error
  set_pane_value "$pane" cmd definitely-stale
  before="$(tmux_test_server_run show -p -t "$pane" -v @tama_pane_state_main)"
  expected="$(record_for t:0 "$pane" '' error '')"

  run "$PLUGIN_ROOT/bin/tama" list
  assert_success
  assert_equal "$output" "$expected"
  assert_equal "$(tmux_test_server_run show -p -t "$pane" -v @tama_pane_state_main)" "$before"

  tmux_test_server_run set -pu -t "$pane" @tama_pane_state_main
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" list
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "list rejects malformed, unknown, positional, and repeated arguments" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" list --session
  assert_usage_error '--session'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" list --session one --session two
  assert_usage_error '--session'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" list --session --unknown
  assert_usage_error '--session'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" list --unknown
  assert_usage_error '--unknown'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" list extra
  assert_usage_error 'extra'
}

@test "list discards records already collected when a later query fails" {
  tmux_test_server_run rename-session -t t first
  local first second
  first="$(tama_pane_of first:0)"
  set_pane_value "$first" state_main running
  tmux_test_server_run new-session -d -s second
  second="$(tama_pane_of second:0)"
  set_pane_value "$second" state_main waiting

  tama_use_tmux_fail_target "$(tama_window_id second:0)"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" list
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "list is byte-empty without tmux" {
  unset TMUX
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" list
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}
