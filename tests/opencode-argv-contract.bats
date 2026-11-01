#!/usr/bin/env bats

# Cross-boundary contract between the OpenCode integration and the core CLI.
# These are the exact argv vectors integrations/opencode emits (mirrored from
# the "addresses per-agent effects at their own entry" test in
# integrations/opencode/test/effect-runner.test.ts), replayed here against the
# real `bin/tama`. The TS suite only asserts vectors against a mocked
# executor, and these bats tests only assert behavior for hand-written argv —
# if either side renames a flag, both suites stay green while production
# silently no-ops. Update both files together.

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

@test "integration argv vectors drive the real core" {
  # reconcile on an empty record is a quiet no-op, like a fresh restart.
  run "$PLUGIN_ROOT/bin/tama" state agent-reconcile --namespace opencode- --pane "$PANE" -- opencode-root-a opencode-root-b
  assert_success

  run "$PLUGIN_ROOT/bin/tama" state running OpenCode --agent opencode-root-a --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state subagent-start --agent opencode-root-a --pane "$PANE" -- child-a
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state idle OpenCode --agent opencode-root-b --pane "$PANE"
  assert_success

  assert_pane_option "$PANE" agents 'opencode-root-a=running/child-a;opencode-root-b=idle/'
  assert_equal "$(tama_icons "$WINDOW")" ' ●○'

  # Namespaced reconcile keeps survivors with state and subs, drops ghosts.
  run "$PLUGIN_ROOT/bin/tama" state agent-reconcile --namespace opencode- --pane "$PANE" -- opencode-root-a
  assert_success
  assert_pane_option "$PANE" agents 'opencode-root-a=running/child-a'

  # Per-agent notify records its own pending marker.
  run "$PLUGIN_ROOT/bin/tama" notify OpenCode done --agent opencode-root-a --pane "$PANE"
  assert_success
  run tmux_test_server_run show -wqv -t "$WINDOW" @tama_window_notification_pending_opencode-root-a
  assert_success
  assert_equal "$output" 'on'

  # Unregistering one entry leaves the record otherwise alone.
  run "$PLUGIN_ROOT/bin/tama" state clear --agent opencode-root-a --pane "$PANE"
  assert_success
  run tmux_test_server_run show -p -t "$PANE" -v @tama_pane_agents
  assert_status 1
  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "legacy argv vectors still work without any agent" {
  run "$PLUGIN_ROOT/bin/tama" state running OpenCode --pane "$PANE"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ●'

  run "$PLUGIN_ROOT/bin/tama" state subagent-start --pane "$PANE" -- child-b
  assert_success
  run tmux_test_server_run show -p -t "$PANE" -v @tama_pane_agents
  assert_status 1
  assert_pane_option "$PANE" subagents 'child-b'

  run "$PLUGIN_ROOT/bin/tama" state clear --keep-agents --pane "$PANE"
  assert_success
  run tmux_test_server_run show -p -t "$PANE" -v @tama_pane_state_main
  assert_status 1
}
