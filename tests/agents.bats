#!/usr/bin/env bats

# Independent per-agent reports inside one pane: each entry keeps its own
# state and subagents, and the pane draws one icon per entry. The legacy
# single-state path is untouched — every assertion here that omits --agent
# behaves exactly as before.

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
  WINDOW="$(tmux_test_server_run display-message -p -t t '#{window_id}')"
  PANE="$(tmux_test_server_run list-panes -t t -F '#{pane_id}' | head -1)"
}

teardown() {
  tmux_test_server_stop
}

# Reports a state the way an agent hook would, optionally for one entry.
areport() {
  local pane="$1"
  shift
  run "$PLUGIN_ROOT/bin/tama" state "$@" --pane "$pane"
  assert_success
}

@test "one pane with two agents draws two glyphs, in registration order" {
  areport "$PANE" running --agent ses_A
  areport "$PANE" idle --agent ses_B
  assert_equal "$(tama_icons "$WINDOW")" ' ●○'
}

@test "an unknown agent id is a usage error, not a stored entry" {
  run "$PLUGIN_ROOT/bin/tama" state running --agent 'has space' --pane "$PANE"
  assert_status 2
  run "$PLUGIN_ROOT/bin/tama" state running --agent 'has/slash' --pane "$PANE"
  assert_status 2
  run "$PLUGIN_ROOT/bin/tama" state running --agent 'ses=A' --pane "$PANE"
  assert_status 2
  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "an unknown state with --agent stays silent like the legacy path" {
  run "$PLUGIN_ROOT/bin/tama" state newer-state --agent ses_A --pane "$PANE"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "clearing one agent keeps the others" {
  areport "$PANE" running --agent ses_A
  areport "$PANE" waiting --agent ses_B
  areport "$PANE" clear --agent ses_A
  assert_equal "$(tama_icons "$WINDOW")" ' ◐'
}

@test "a full clear takes the agent record with it" {
  areport "$PANE" running --agent ses_A
  areport "$PANE" clear --pane "$PANE"
  assert_equal "$(tama_icons "$WINDOW")" ''
  run tmux_test_server_run show -p -t "$PANE" -v @tama_pane_agents
  assert_status 1
}

@test "agent entries win over the legacy state without touching it" {
  areport "$PANE" idle
  areport "$PANE" running --agent ses_A
  # One agent icon, not the legacy idle one beside it.
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
  # The legacy state is still stored where list and friends read it.
  assert_pane_option "$PANE" state_main idle
  areport "$PANE" clear --agent ses_A
  # With no agents left, the legacy state draws again.
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "subagents of one agent derive background without touching the other" {
  areport "$PANE" idle --agent ses_A
  areport "$PANE" idle --agent ses_B
  run "$PLUGIN_ROOT/bin/tama" state subagent-start --agent ses_A --pane "$PANE" -- sub_1
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙○'
  run "$PLUGIN_ROOT/bin/tama" state subagent-stop --agent ses_A --pane "$PANE" -- sub_1
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ○○'
}

@test "stopping an unknown subagent id of a known agent is a no-op" {
  areport "$PANE" running --agent ses_A
  areport "$PANE" subagent-stop --agent ses_A never_there
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
}

@test "subagent tracking starts before the first state report" {
  run "$PLUGIN_ROOT/bin/tama" state subagent-start --agent ses_A --pane "$PANE" -- sub_1
  assert_success
  # Stateless entries draw nothing, like a pane with no main state.
  assert_equal "$(tama_icons "$WINDOW")" ''
  areport "$PANE" idle --agent ses_A
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
}

@test "agent-reconcile drops ghosts and preserves survivors" {
  areport "$PANE" running --agent ses_keep
  run "$PLUGIN_ROOT/bin/tama" state subagent-start --agent ses_keep --pane "$PANE" -- sub_1
  assert_success
  areport "$PANE" error --agent ses_ghost
  run "$PLUGIN_ROOT/bin/tama" state agent-reconcile ses_keep --pane "$PANE"
  assert_success
  # Ghost gone with its error; survivor kept state and subagents.
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
  assert_pane_option "$PANE" agents 'ses_keep=running/sub_1'
}

@test "agent-reconcile with no ids empties the record" {
  areport "$PANE" running --agent ses_A
  run "$PLUGIN_ROOT/bin/tama" state agent-reconcile --pane "$PANE"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "subagent reconcile replaces one entry's set" {
  areport "$PANE" idle --agent ses_A
  run "$PLUGIN_ROOT/bin/tama" state subagent-start --agent ses_A --pane "$PANE" -- old_1
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state subagent-start --agent ses_A --pane "$PANE" -- old_2
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state subagent-reconcile --agent ses_A --pane "$PANE" -- new_9
  assert_success
  assert_pane_option "$PANE" agents 'ses_A=idle/new_9'
}

@test "malformed agent records draw nothing and never clear a live pane" {
  tmux_test_server_run set -p -t "$PANE" '@tama_pane_agents' 'ses_A=running'
  assert_equal "$(tama_icons "$WINDOW")" ''
  # A pane whose record cannot be parsed keeps no icon but is not cleared.
  run "$PLUGIN_ROOT/bin/tama" state clear --agent ses_A --pane "$PANE"
  assert_success
}

@test "agents lists one row per entry with derived state and subagent count" {
  areport "$PANE" running --agent ses_A
  areport "$PANE" idle --agent ses_B
  run "$PLUGIN_ROOT/bin/tama" state subagent-start --agent ses_A --pane "$PANE" -- sub_1
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state subagent-start --agent ses_A --pane "$PANE" -- sub_2
  assert_success

  local session_id
  session_id="$(tmux_test_server_run display-message -p -t "$PANE" '#{session_id}')"
  local window_index window_id window_name
  window_index="$(tmux_test_server_run display-message -p -t "$PANE" '#{window_index}')"
  window_name="$(tmux_test_server_run display-message -p -t "$PANE" '#{window_name}')"
  window_id="$(tmux_test_server_run display-message -p -t "$PANE" '#{window_id}')"
  local pane_index
  pane_index="$(tmux_test_server_run display-message -p -t "$PANE" '#{pane_index}')"
  run "$PLUGIN_ROOT/bin/tama" agents
  assert_success
  assert_equal "$output" "t	$session_id	$window_index	$window_name	$window_id	$pane_index	$PANE	ses_A	running	2
t	$session_id	$window_index	$window_name	$window_id	$pane_index	$PANE	ses_B	idle	0"
}

@test "agents skips stateless entries and malformed records" {
  run "$PLUGIN_ROOT/bin/tama" state subagent-start --agent ses_quiet --pane "$PANE" -- sub_1
  assert_success
  run "$PLUGIN_ROOT/bin/tama" agents
  assert_success
  assert_equal "$output" ''
  tmux_test_server_run set -p -t "$PANE" '@tama_pane_agents' 'not a record at all'
  run "$PLUGIN_ROOT/bin/tama" agents
  assert_success
  assert_equal "$output" ''
}

@test "summary counts one line per agent, not per pane" {
  areport "$PANE" running --agent ses_A
  areport "$PANE" idle --agent ses_B
  local session
  session="$(tmux_test_server_run display-message -p -t "$PANE" '#{session_id}')"
  run "$PLUGIN_ROOT/bin/tama" summary "$session"
  assert_success
  assert_equal "$output" '● 1 ◐ 0 ○ 1'
}

@test "summary keeps counting legacy panes without agent entries" {
  areport "$PANE" running --agent ses_A
  tmux_test_server_run split-window -d -t t
  local other
  other="$(tmux_test_server_run list-panes -t t -F '#{pane_id}' | tail -1)"
  areport "$other" waiting
  local session
  session="$(tmux_test_server_run display-message -p -t "$PANE" '#{session_id}')"
  run "$PLUGIN_ROOT/bin/tama" summary "$session"
  assert_success
  assert_equal "$output" '● 1 ◐ 1 ○ 0'
}

@test "an agent-only pane stays out of the legacy list" {
  areport "$PANE" running --agent ses_A
  run "$PLUGIN_ROOT/bin/tama" list
  assert_success
  assert_equal "$output" ''
}
