#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
}

teardown() {
  tmux_test_server_stop
}

@test "toggle-priority requires an explicit window target" {
  local expected
  expected="tama: toggle-priority needs --window <target>"$'\n'"Try '$PLUGIN_ROOT/bin/tama --help'."
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" toggle-priority

  assert_status 2
  assert_equal "$stderr" "$expected"
}

@test "toggle-priority quietly toggles the targeted tmux window" {
  local window
  window="$(tama_window_id t:0)"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$window"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_equal "$(tmux_test_server_run show -wqv -t "$window" @tama_window_priority)" on

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$window"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  run tmux_test_server_run show -wv -t "$window" @tama_window_priority
  [ "$status" -ne 0 ]
}

@test "the default limit rejects a second Priority among two tmux windows" {
  tmux_test_server_run new-window -d -t t:
  local first second
  first="$(tama_window_id t:0)"
  second="$(tama_window_id t:1)"

  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$first"
  assert_success

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$second"
  assert_status 1
  assert_equal "$stderr" \
    "tama: cannot prioritize $second: 2 of 2 tmux windows would be Priority; limit is 80% (1 permitted). If everything is priority, nothing is priority."
  assert_equal "$(tmux_test_server_run show -wqv -t "$first" @tama_window_priority)" on
  assert_equal "$(tmux_test_server_run show -wqv -t "$second" @tama_window_priority)" ''
}

@test "Priority marker follows the preset and supports explicit and empty overrides" {
  local window
  window="$(tama_window_id t:0)"
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$window"
  assert_success

  assert_equal "$(tmux_test_server_run display-message -p -t "$window" '#{E:@tama_priority}')" ' ★'

  tmux_test_server_run set -g @tama_icon_set pets
  assert_equal "$(tmux_test_server_run display-message -p -t "$window" '#{E:@tama_priority}')" ' ⭐'

  tmux_test_server_run set -g @tama_icon_set ascii
  assert_equal "$(tmux_test_server_run display-message -p -t "$window" '#{E:@tama_priority}')" ' *'

  tmux_test_server_run set -g @tama_priority_icon '#[fg=red] P'
  assert_equal "$(tmux_test_server_run display-message -p -t "$window" '#{E:@tama_priority}')" '#[fg=red] P'

  tmux_test_server_run set -g @tama_priority_icon ''
  assert_equal "$(tmux_test_server_run display-message -p -t "$window" '#{E:@tama_priority}')" ''
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_equal "$(tmux_test_server_run show -gqv @tama_priority_icon)" ''
}

@test "ambient policy flags a secondary event but suppresses its Notification" {
  tama_fake_backend_env
  tama_use_fake_backend
  tmux_test_server_run new-window -d -t t:
  local primary secondary pane
  primary="$(tama_window_id t:0)"
  secondary="$(tama_window_id t:1)"
  pane="$(tama_pane_of "$secondary")"
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$primary"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" notify Codex done --pane "$pane"
  assert_success

  assert_flagged "$secondary"
  refute_backend_called notify
}

@test "selective policy suppresses both channels for a secondary event" {
  tama_fake_backend_env
  tama_use_fake_backend
  tmux_test_server_run set -g @tama_flag_policy selective
  tmux_test_server_run new-window -d -t t:
  local primary secondary pane
  primary="$(tama_window_id t:0)"
  secondary="$(tama_window_id t:1)"
  pane="$(tama_pane_of "$secondary")"
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$primary"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" notify Codex done --pane "$pane"
  assert_success

  assert_not_flagged "$secondary"
  refute_backend_called notify
}

@test "Notifications-off leaves an eligible automatic Flag enabled" {
  tama_fake_backend_env
  tama_use_fake_backend
  tmux_test_server_run set -g @tama_notifications off
  local window pane
  window="$(tama_window_id t:0)"
  pane="$(tama_pane_of "$window")"
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$window"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" notify Codex done --pane "$pane"
  assert_success

  assert_flagged "$window"
  refute_backend_called notify
}

@test "the direct flag command bypasses selective Priority policy" {
  tmux_test_server_run set -g @tama_flag_policy selective
  tmux_test_server_run new-window -d -t t:
  local primary secondary
  primary="$(tama_window_id t:0)"
  secondary="$(tama_window_id t:1)"
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$primary"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" flag "$secondary"
  assert_success
  assert_flagged "$secondary"
}

@test "ordinary tmux window targets resolve to one shared linked-window Priority" {
  tmux_test_server_run rename-window -t t:0 api
  tmux_test_server_run -f /dev/null new-session -d -s other
  tmux_test_server_run link-window -s t:api -t other:
  local window
  window="$(tama_window_id t:api)"

  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:api
  assert_success
  assert_equal "$(tmux_test_server_run show -wqv -t "$window" @tama_window_priority)" on
  assert_equal "$(tmux_test_server_run display-message -p -t other:1 '#{E:@tama_priority}')" ' ★'

  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window api
  assert_success
  assert_equal "$(tmux_test_server_run show -wqv -t "$window" @tama_window_priority)" ''
}

@test "custom limits are read at runtime and linked tmux windows count once" {
  tmux_test_server_run new-window -d -t t:
  tmux_test_server_run new-window -d -t t:
  tmux_test_server_run -f /dev/null new-session -d -s linked -t t
  tmux_test_server_run set -g @tama_priority_max_percent 50

  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:0
  assert_success
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:1
  assert_status 1

  tmux_test_server_run set -g @tama_priority_max_percent 100
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:1
  assert_success
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:2
  assert_success
}

@test "maximum percentages with leading zeros are decimal" {
  tmux_test_server_run set -g @tama_priority_max_percent 08

  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:0

  assert_success
  assert_equal "$(tmux_test_server_run show -wqv -t t:0 @tama_window_priority)" on
}

@test "invalid and empty maximum percentages fail open" {
  tmux_test_server_run new-window -d -t t:
  local configured
  for configured in '' 0 101 half; do
    tmux_test_server_run set -g @tama_priority_max_percent "$configured"
    run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:0
    assert_success || return 1
    run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:1
    assert_success || return 1
    run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:0
    assert_success || return 1
    run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:1
    assert_success || return 1
  done
}

@test "removing Priority is allowed after a lower runtime limit" {
  tmux_test_server_run new-window -d -t t:
  tmux_test_server_run set -g @tama_priority_max_percent 100
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:0
  assert_success
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:1
  assert_success

  tmux_test_server_run set -g @tama_priority_max_percent 1
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window t:1
  assert_success
  assert_equal "$(tmux_test_server_run show -wqv -t t:0 @tama_window_priority)" on
  assert_equal "$(tmux_test_server_run show -wqv -t t:1 @tama_window_priority)" ''
}

@test "missing and ambiguous targets are visible operational failures" {
  tmux_test_server_run rename-window -t t:0 same
  tmux_test_server_run -f /dev/null new-session -d -s other -n same

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" toggle-priority --window missing
  assert_status 1
  assert_equal "$stderr" 'tama: no unique tmux window matches: missing'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" toggle-priority --window same
  assert_status 1
  assert_equal "$stderr" 'tama: no unique tmux window matches: same'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" toggle-priority --window sam
  assert_status 1
  assert_equal "$stderr" 'tama: no unique tmux window matches: sam'
}

@test "state waiting follows selective policy without changing State visibility" {
  tmux_test_server_run set -g @tama_flag_policy selective
  tmux_test_server_run new-window -d -t t:
  local primary secondary pane
  primary="$(tama_window_id t:0)"
  secondary="$(tama_window_id t:1)"
  pane="$(tama_pane_of "$secondary")"
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$primary"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" state waiting Codex --pane "$pane"
  assert_success
  assert_not_flagged "$secondary"
  assert_equal "$(tama_icons "$secondary")" ' ◐'
}

@test "closing the last Priority tmux window restores normal Notification eligibility" {
  tama_fake_backend_env
  tama_use_fake_backend
  tmux_test_server_run new-window -d -t t:
  local primary secondary pane
  primary="$(tama_window_id t:0)"
  secondary="$(tama_window_id t:1)"
  pane="$(tama_pane_of "$secondary")"
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$primary"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" notify Codex first --pane "$pane"
  assert_success
  refute_backend_called notify

  tmux_test_server_run kill-window -t "$primary"
  run "$PLUGIN_ROOT/bin/tama" notify Codex second --pane "$pane"
  assert_success
  assert_backend_called notify
}

@test "a Priority tmux window remains eligible for both selective attention channels" {
  tama_fake_backend_env
  tama_use_fake_backend
  tmux_test_server_run set -g @tama_flag_policy selective
  tmux_test_server_run new-window -d -t t:
  local primary pane
  primary="$(tama_window_id t:0)"
  pane="$(tama_pane_of "$primary")"
  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$primary"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" notify Codex done --pane "$pane"
  assert_success

  assert_flagged "$primary"
  assert_backend_called notify
}

@test "Priority mode leaves stable list records and status summaries unchanged" {
  tmux_test_server_run set -g automatic-rename off
  tmux_test_server_run rename-window -t t:0 primary
  tmux_test_server_run new-window -d -t t:
  tmux_test_server_run rename-window -t t:1 secondary
  local primary secondary pane before_list before_summary
  primary="$(tama_window_id t:0)"
  secondary="$(tama_window_id t:1)"
  pane="$(tama_pane_of "$secondary")"
  run "$PLUGIN_ROOT/bin/tama" state running Codex --pane "$pane"
  assert_success
  before_list="$("$PLUGIN_ROOT/bin/tama" list)"
  before_summary="$("$PLUGIN_ROOT/bin/tama" summary "$(tmux_test_server_run display-message -p -t t '#{session_id}')")"

  run "$PLUGIN_ROOT/bin/tama" toggle-priority --window "$primary"
  assert_success

  assert_equal "$("$PLUGIN_ROOT/bin/tama" list)" "$before_list"
  assert_equal "$("$PLUGIN_ROOT/bin/tama" summary "$(tmux_test_server_run display-message -p -t t '#{session_id}')")" "$before_summary"
}
