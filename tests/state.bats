#!/usr/bin/env bats

# What an agent pane reports about itself, observed the only way a status line
# could observe it: the tmux options on the pane.

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
  PANE="$(test_tmux list-panes -t t -F '#{pane_id}' | head -1)"
}

teardown() {
  tama_kill_server
}

@test "reporting a state records it on the pane, with the snapshot around it" {
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success

  assert_pane_option "$PANE" state_main running
  assert_pane_option "$PANE" state running
  assert_pane_option "$PANE" agent Claude
  # The snapshot is what a later sweep compares against to notice the agent is
  # gone, so it has to be the pane's own command and path, not the caller's.
  assert_pane_option "$PANE" cmd "$(test_tmux display-message -p -t "$PANE" '#{pane_current_command}')"
  assert_pane_option "$PANE" cwd "$(test_tmux display-message -p -t "$PANE" '#{pane_current_path}')"
}

@test "with no --pane the state lands on the pane the hook is running in" {
  test_tmux split-window -d -t t
  local other
  other="$(test_tmux list-panes -t t -F '#{pane_id}' | tail -1)"

  TMUX_PANE="$other" run "$PLUGIN_ROOT/bin/tama" state running
  assert_success

  assert_pane_option "$other" state running
  assert_pane_option_unset "$PANE" state
}

@test "--pane overrides the pane the hook is running in" {
  test_tmux split-window -d -t t
  local other
  other="$(test_tmux list-panes -t t -F '#{pane_id}' | tail -1)"

  TMUX_PANE="$other" run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"
  assert_success

  assert_pane_option "$PANE" state running
  assert_pane_option_unset "$other" state
}

@test "a state reported for a pane that is gone exits 0 and writes nothing" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state running --pane %999
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  assert_pane_option_unset "$PANE" state
}

@test "each reported state is recorded as itself" {
  local reported
  for reported in running waiting idle error; do
    run "$PLUGIN_ROOT/bin/tama" state "$reported" --pane "$PANE"
    assert_success
    assert_pane_option "$PANE" state_main "$reported"
    assert_pane_option "$PANE" state "$reported"
  done
}

@test "the agent name is remembered when a later state does not repeat it" {
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state idle --pane "$PANE"
  assert_success

  assert_pane_option "$PANE" agent Claude
}

@test "idle with a live subagent is background, and idle again once it stops" {
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state idle --pane "$PANE"
  assert_success

  # The agent's own turn is done, but its children are not: that is a different
  # thing from finished, and it is never reported — only derived.
  assert_pane_option "$PANE" state_main idle
  assert_pane_option "$PANE" state background

  run "$PLUGIN_ROOT/bin/tama" state subagent-stop sub-1 --pane "$PANE"
  assert_success
  assert_pane_option "$PANE" state idle
  # The last one leaving takes the option with it, rather than leaving an empty
  # string behind that would read as a set option forever.
  assert_pane_option_unset "$PANE" subagents
}

@test "a subagent starting while the agent is idle turns it into background" {
  run "$PLUGIN_ROOT/bin/tama" state idle --pane "$PANE"
  assert_success
  assert_pane_option "$PANE" state idle

  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success
  assert_pane_option "$PANE" state background
}

@test "background is never reported directly" {
  run "$PLUGIN_ROOT/bin/tama" state background --pane "$PANE"
  assert_success

  assert_pane_option_unset "$PANE" state
  assert_pane_option_unset "$PANE" state_main
}

@test "a subagent does not change a state that is not idle" {
  run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success

  assert_pane_option "$PANE" state running
  assert_pane_option "$PANE" subagents sub-1
}

@test "a duplicate subagent start is idempotent" {
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success

  assert_pane_option "$PANE" subagents sub-1
}

@test "stopping a subagent that was never started is a no-op" {
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state subagent-stop who --pane "$PANE"
  assert_success

  assert_pane_option "$PANE" subagents sub-1

  # And on a pane that never tracked one at all.
  test_tmux split-window -d -t t
  local other
  other="$(test_tmux list-panes -t t -F '#{pane_id}' | tail -1)"
  run "$PLUGIN_ROOT/bin/tama" state subagent-stop who --pane "$other"
  assert_success
  assert_pane_option_unset "$other" subagents
}

@test "several subagents are tracked, and one stopping leaves the others" {
  local id
  for id in sub-1 sub-2 sub-3; do
    run "$PLUGIN_ROOT/bin/tama" state subagent-start "$id" --pane "$PANE"
    assert_success
  done
  run "$PLUGIN_ROOT/bin/tama" state idle --pane "$PANE"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" state subagent-stop sub-2 --pane "$PANE"
  assert_success
  assert_pane_option "$PANE" subagents 'sub-1 sub-3'
  # Still somebody working, so still background.
  assert_pane_option "$PANE" state background
}

@test "clear unsets every pane option rather than emptying it" {
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" state clear --pane "$PANE"
  assert_success

  # tmux tells an unset option from one set to the empty string, and so does
  # everything that reads them: a cleared pane must be indistinguishable from a
  # pane that never ran an agent.
  local option
  for option in state_main subagents state cmd agent cwd; do
    assert_pane_option_unset "$PANE" "$option"
  done
}

@test "clearing a pane that never ran an agent is a silent no-op" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state clear --pane "$PANE"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "an unknown state is ignored, quietly" {
  # Agents grow event types, and a hook wired for a newer plugin has to stay
  # quiet on an older one rather than fail the turn it is reporting on.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state thinking --pane "$PANE"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_pane_option_unset "$PANE" state
}

@test "a state reported outside tmux is a silent no-op" {
  unset TMUX
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "repeating a state writes nothing and refreshes no client" {
  # `running` is reported on every tool call of every agent, so this is the hot
  # path: what it must not do is write six options and wake every client up to
  # tell them nothing changed.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success

  # It still looked — it has to, to find out — and then wrote nothing.
  assert_tmux_command 'display-message'
  refute_tmux_command 'set'
  refute_tmux_command 'refresh-client'
}

@test "a state that is different does write, and does refresh" {
  # The control for the test above: without this, "wrote nothing" would also pass
  # for a command that never writes anything at all.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state waiting Claude --pane "$PANE"
  assert_success

  assert_tmux_command 'set'
  assert_tmux_command 'refresh-client'
  assert_pane_option "$PANE" state waiting
}

@test "a duplicate subagent start writes nothing" {
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success

  refute_tmux_command 'set'
  refute_tmux_command 'refresh-client'
}

@test "the whole state model runs under the bash macOS ships" {
  # bash 3.2 is /bin/bash on every macOS, and it differs from bash 5 at *runtime*
  # as well as at parse time — expanding an empty array under `nounset` is an
  # error there, and this command writes through one. Parsing the entry points is
  # not enough to catch that; only running the paths that write is.
  tama_use_bash_32_or_skip

  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state idle Claude --pane "$PANE"
  assert_success
  assert_pane_option "$PANE" state background

  # Including the no-op paths, where nothing is staged at all.
  run "$PLUGIN_ROOT/bin/tama" state idle Claude --pane "$PANE"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" state clear --pane "$PANE"
  assert_success
  assert_pane_option_unset "$PANE" state
}

@test "state rejects invocations a hook author has to fix" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state
  assert_usage_error

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state running Claude extra
  assert_usage_error 'extra'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state running --bogus
  assert_usage_error '--bogus'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state running --pane
  assert_usage_error '--pane'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state subagent-start
  assert_usage_error 'subagent-start'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state subagent-stop
  assert_usage_error 'subagent-stop'

  # An id travels in a space-separated list; one with whitespace in it would
  # silently become several.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state subagent-start 'two ids'
  assert_usage_error 'whitespace'
}
