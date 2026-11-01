#!/usr/bin/env bats

# One banner per agent: notify --agent groups by (window, agent) instead of
# replacing the window's banner, and dismiss --agent takes down only its own.
# Legacy notify/dismiss without --agent behave exactly as before, and a plain
# dismiss clears every pending banner on the window.

bats_require_minimum_version 1.7.0

load helper

setup() {
  # Tolerance for the async hook path only: hooks run via `run-shell -b`, so
  # a loaded CI runner may observe a call as started before its argv files
  # land. Narrow on purpose: retries anywhere else would mask real isolation
  # failures. Needs bats >= 1.8; older installs ignore the variable.
  export BATS_TEST_RETRIES=2
  # Before the server boots: the backend is reached from tmux hooks and a hook's
  # `run-shell` inherits the environment the server was started with.
  tama_fake_backend_env
  tama_start_server
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tama_use_fake_backend
}

teardown() {
  tama_detach_client
  tmux_test_server_stop
}

@test "per-agent banners keep their own groups" {
  local pane window
  pane="$(tmux_test_server_run new-window -t t: -d -P -F '#{pane_id}' -c "$BATS_TEST_TMPDIR")"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run "$PLUGIN_ROOT/bin/tama" notify test-agent 'first needs you' --agent ses_A --pane "$pane"
  assert_success
  local group_a
  group_a="$(tama_backend_value notify env.TAMA_GROUP)"

  run "$PLUGIN_ROOT/bin/tama" notify test-agent 'second needs you' --agent ses_B --pane "$pane"
  assert_success
  local group_b
  group_b="$(tama_backend_value notify env.TAMA_GROUP)"

  [ -n "$group_a" ]
  [ -n "$group_b" ]
  [ "$group_a" != "$group_b" ]
}

@test "dismiss --agent takes down only its own banner" {
  local pane
  pane="$(tmux_test_server_run new-window -t t: -d -P -F '#{pane_id}' -c "$BATS_TEST_TMPDIR")"

  run "$PLUGIN_ROOT/bin/tama" notify test-agent 'first needs you' --agent ses_A --pane "$pane"
  assert_success
  local group_a
  group_a="$(tama_backend_value notify env.TAMA_GROUP)"
  run "$PLUGIN_ROOT/bin/tama" notify test-agent 'second needs you' --agent ses_B --pane "$pane"
  assert_success
  [ "$(tama_backend_calls notify)" -eq 2 ]

  run "$PLUGIN_ROOT/bin/tama" dismiss --agent ses_A --pane "$pane"
  assert_success
  [ "$(tama_backend_calls dismiss)" -eq 1 ]
  assert_backend_value dismiss argv1 "$group_a"

  # The other agent's pending banner survives its sibling's dismissal.
  run "$PLUGIN_ROOT/bin/tama" dismiss --agent ses_B --pane "$pane"
  assert_success
  [ "$(tama_backend_calls dismiss)" -eq 2 ]
}

@test "a plain dismiss clears every agent banner on the window" {
  local pane
  pane="$(tmux_test_server_run new-window -t t: -d -P -F '#{pane_id}' -c "$BATS_TEST_TMPDIR")"

  run "$PLUGIN_ROOT/bin/tama" notify test-agent 'first needs you' --agent ses_A --pane "$pane"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" notify test-agent 'second needs you' --agent ses_B --pane "$pane"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" dismiss --pane "$pane"
  assert_success
  [ "$(tama_backend_calls dismiss)" -eq 3 ]

  # Nothing pending anywhere on the window: no silent re-dismissals later.
  run "$PLUGIN_ROOT/bin/tama" dismiss --pane "$pane"
  assert_success
  [ "$(tama_backend_calls dismiss)" -eq 4 ]
}

@test "a per-agent notify still raises the window flag" {
  local pane window
  pane="$(tmux_test_server_run new-window -t t: -d -P -F '#{pane_id}' -c "$BATS_TEST_TMPDIR")"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"
  assert_not_flagged "$window"

  run "$PLUGIN_ROOT/bin/tama" notify test-agent 'needs you' --agent ses_A --pane "$pane"
  assert_success
  assert_flagged "$window"
}

@test "an invalid agent id on notify is a usage error" {
  local pane
  pane="$(tmux_test_server_run new-window -t t: -d -P -F '#{pane_id}' -c "$BATS_TEST_TMPDIR")"

  run "$PLUGIN_ROOT/bin/tama" notify test-agent 'needs you' --agent 'has space' --pane "$pane"
  assert_status 2
}

@test "legacy notify without --agent still replaces the window banner" {
  local pane group_first group_second
  pane="$(tmux_test_server_run new-window -t t: -d -P -F '#{pane_id}' -c "$BATS_TEST_TMPDIR")"

  run "$PLUGIN_ROOT/bin/tama" notify test-agent first --pane "$pane"
  assert_success
  group_first="$(tama_backend_value notify env.TAMA_GROUP)"

  run "$PLUGIN_ROOT/bin/tama" notify test-agent second --pane "$pane"
  assert_success
  group_second="$(tama_backend_value notify env.TAMA_GROUP)"

  assert_equal "$group_first" "$group_second"
}
