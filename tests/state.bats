#!/usr/bin/env bats

# What an agent pane reports about itself, observed the only way a status line
# could observe it: the tmux options on the pane.

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
  PANE="$(test_tmux list-panes -t t -F '#{pane_id}' | head -1)"
  WINDOW="$(test_tmux display-message -p -t "$PANE" '#{window_id}')"
}

teardown() {
  tama_kill_server
}

@test "reporting a state records it on the pane, with the snapshot around it" {
  # A pane whose command and directory are nothing like the caller's or the
  # session's active pane's, so a snapshot taken from the wrong pane cannot pass.
  local agent_pane='' agent_cwd
  # Resolved, because tmux reports the pane's real path and /tmp is a symlink on
  # macOS.
  agent_cwd="$(cd -P /tmp && pwd)"
  test_tmux new-window -d -t t -c "$agent_cwd" 'sleep 47'
  # Polled, because the pane reports the shell tmux started it with until the
  # command it was given has replaced it.
  local waited=0
  while [ -z "${agent_pane:-}" ] && [ "$waited" -lt 50 ]; do
    agent_pane="$(test_tmux list-panes -a -F '#{pane_id} #{pane_current_command}' |
      awk '$2 == "sleep" { print $1 }')"
    [ -n "$agent_pane" ] || sleep 0.1
    waited=$((waited + 1))
  done
  [ -n "${agent_pane:-}" ]

  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$agent_pane"
  assert_success

  assert_pane_option "$agent_pane" state_main running
  assert_pane_option "$agent_pane" agent Claude
  # The snapshot is what a later sweep compares against to notice the agent is
  # gone, so it has to be the pane's own command and path, not the caller's.
  assert_pane_option "$agent_pane" cmd sleep
  assert_pane_option "$agent_pane" cwd "$agent_cwd"
}

@test "with no --pane the state lands on the pane the hook is running in" {
  test_tmux split-window -d -t t
  local other
  other="$(test_tmux list-panes -t t -F '#{pane_id}' | tail -1)"

  TMUX_PANE="$other" run "$PLUGIN_ROOT/bin/tama" state running
  assert_success

  assert_pane_option "$other" state_main running
  assert_pane_option_unset "$PANE" state_main
}

@test "--pane overrides the pane the hook is running in" {
  test_tmux split-window -d -t t
  local other
  other="$(test_tmux list-panes -t t -F '#{pane_id}' | tail -1)"

  TMUX_PANE="$other" run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"
  assert_success

  assert_pane_option "$PANE" state_main running
  assert_pane_option_unset "$other" state_main
}

@test "a state reported for a pane that is gone exits 0 and writes nothing" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state running --pane %999
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  assert_pane_option_unset "$PANE" state_main

  # Not even attempted: a pane that is gone is noticed on the read, so nothing is
  # written at a target that no longer exists — and a subagent event does not spend
  # its retries finding that out.
  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane %999
  assert_success
  refute_tmux_command 'set'
  refute_tmux_command 'refresh-client'
}

@test "a tmux that cannot be reached is a silent no-op, not a retry storm" {
  # The server can go away between an agent's hook firing and this running. The
  # read notices, and the calls that would follow it — including the retries a
  # subagent event would otherwise spend — never happen.
  tama_log_tmux_calls
  export TAMA_FAKE_TMUX_FAIL_ALL=1
  export TAMA_FAKE_TMUX_COUNTER="$BATS_TEST_TMPDIR/calls"
  : >"$TAMA_FAKE_TMUX_COUNTER"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  assert_equal "$(wc -l <"$TAMA_FAKE_TMUX_COUNTER" | tr -d ' ')" 1
}

@test "each reported state is recorded as itself" {
  local reported
  for reported in running waiting idle error; do
    run "$PLUGIN_ROOT/bin/tama" state "$reported" --pane "$PANE"
    assert_success
    assert_pane_option "$PANE" state_main "$reported"
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
  # thing from finished, and it is never reported — only derived, from the pair of
  # things the pane does record.
  assert_pane_option "$PANE" state_main idle
  assert_pane_option "$PANE" subagents sub-1
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'

  run "$PLUGIN_ROOT/bin/tama" state subagent-stop sub-1 --pane "$PANE"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
  # The last one leaving takes the option with it, rather than leaving an empty
  # string behind that would read as a set option forever.
  assert_pane_option_unset "$PANE" subagents
}

@test "a subagent starting while the agent is idle turns it into background" {
  run "$PLUGIN_ROOT/bin/tama" state idle --pane "$PANE"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ○'

  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
}

@test "background is never reported directly" {
  run "$PLUGIN_ROOT/bin/tama" state background --pane "$PANE"
  assert_success

  assert_pane_option_unset "$PANE" state_main
  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "a subagent does not change a state that is not idle" {
  run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success

  assert_pane_option "$PANE" state_main running
  assert_pane_option "$PANE" subagents sub-1
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
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
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
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
  #
  # Asked of the pane rather than of a list of names, so an option this plugin
  # learns to write but forgets to clear fails here without anybody remembering
  # to add it.
  local remaining
  remaining="$(test_tmux show -p -t "$PANE" | grep -c '^@tama_' || true)"
  assert_equal "$remaining" 0
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
  assert_pane_option_unset "$PANE" state_main
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
  assert_pane_option "$PANE" state_main waiting
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

  # Including on stderr: a 3.2-only diagnostic on every hook call is a broken
  # plugin even when the options come out right.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state subagent-start sub-1 --pane "$PANE"
  assert_success
  [ -z "$stderr" ]
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state idle Claude --pane "$PANE"
  assert_success
  [ -z "$stderr" ]
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'

  # Including the no-op paths, where nothing is staged at all.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state idle Claude --pane "$PANE"
  assert_success
  [ -z "$stderr" ]

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state clear --pane "$PANE"
  assert_success
  [ -z "$stderr" ]
  assert_pane_option_unset "$PANE" state_main
}

@test "a change nothing can see writes, but refreshes no client" {
  # Waking every client redraws every status line, which re-runs the icon command
  # once per window on the server. A new agent name on an unchanged state is worth
  # storing and not worth that.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state running Codex --pane "$PANE"
  assert_success

  assert_tmux_command 'set'
  refute_tmux_command 'refresh-client'
  assert_pane_option "$PANE" agent Codex
}

@test "a subagent start whose write is overwritten is retried until it holds" {
  # tmux has no atomic read-modify-write, so this is the case the optimistic loop
  # exists for. Losing a start is the failure that matters: a pane with a live
  # subagent would look finished.
  #
  # The race is driven rather than raced for, and by events rather than by clocks,
  # so a slow machine cannot turn it into two calls that never overlap. Both calls
  # read the empty list; `b` writes first; `a`'s write waits for that and lands on
  # top of it, dropping it; and `b`'s read-back waits for *that*, so it is `b` that
  # has to notice its id is gone and put it back.
  tama_log_tmux_calls
  local wrote_a="$BATS_TEST_TMPDIR/a-wrote" wrote_b="$BATS_TEST_TMPDIR/b-wrote"

  TAMA_FAKE_TMUX_COUNTER="$BATS_TEST_TMPDIR/calls-a" \
    TAMA_FAKE_TMUX_WAIT_BEFORE=2 TAMA_FAKE_TMUX_WAIT_FOR="$wrote_b" \
    TAMA_FAKE_TMUX_TOUCH_AFTER=2 TAMA_FAKE_TMUX_TOUCH="$wrote_a" \
    "$PLUGIN_ROOT/bin/tama" state subagent-start sub-a --pane "$PANE" &
  TAMA_FAKE_TMUX_COUNTER="$BATS_TEST_TMPDIR/calls-b" \
    TAMA_FAKE_TMUX_TOUCH_AFTER=2 TAMA_FAKE_TMUX_TOUCH="$wrote_b" \
    TAMA_FAKE_TMUX_WAIT_BEFORE=3 TAMA_FAKE_TMUX_WAIT_FOR="$wrote_a" \
    "$PLUGIN_ROOT/bin/tama" state subagent-start sub-b --pane "$PANE" &
  wait

  # The race really happened: both wrote, and somebody had to write again. Without
  # that third write this test would be asserting nothing.
  [ -e "$wrote_a" ]
  [ -e "$wrote_b" ]
  [ "$(grep -cx set "$TAMA_FAKE_TMUX_LOG")" -ge 3 ]

  local list
  list="$(test_tmux show -p -t "$PANE" -v @tama_pane_subagents)"
  assert_contains "$list" sub-a 'the subagent list'
  assert_contains "$list" sub-b 'the subagent list'
}

@test "a subagent start whose write loses to a clear does not put the state back" {
  # The retry loop cannot tell a `state clear` from a lost race by looking at the
  # list — either way its id is gone — and retrying past a clear is the one direction
  # that is not benign: it leaves an option on a pane that has to be
  # indistinguishable from one that never ran an agent, and no later clear cleans it
  # up, because clear is what lost.
  #
  # Driven by events, in this order: the start reads, the start writes, the clear
  # reads, the clear writes, the start reads back and finds its id gone.
  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-a --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state idle Claude --pane "$PANE"
  assert_success

  local started="$BATS_TEST_TMPDIR/started" cleared="$BATS_TEST_TMPDIR/cleared"

  TAMA_FAKE_TMUX_COUNTER="$BATS_TEST_TMPDIR/calls-start" \
    TAMA_FAKE_TMUX_TOUCH_AFTER=2 TAMA_FAKE_TMUX_TOUCH="$started" \
    TAMA_FAKE_TMUX_WAIT_BEFORE=3 TAMA_FAKE_TMUX_WAIT_FOR="$cleared" \
    "$PLUGIN_ROOT/bin/tama" state subagent-start sub-b --pane "$PANE" &
  TAMA_FAKE_TMUX_COUNTER="$BATS_TEST_TMPDIR/calls-clear" \
    TAMA_FAKE_TMUX_WAIT_BEFORE=1 TAMA_FAKE_TMUX_WAIT_FOR="$started" \
    TAMA_FAKE_TMUX_TOUCH_AFTER=2 TAMA_FAKE_TMUX_TOUCH="$cleared" \
    "$PLUGIN_ROOT/bin/tama" state clear --pane "$PANE" &
  wait

  # The interleaving really happened: without both writes this asserts nothing.
  [ -e "$started" ]
  [ -e "$cleared" ]

  local remaining
  remaining="$(test_tmux show -p -t "$PANE" | grep -c '^@tama_' || true)"
  assert_equal "$remaining" 0

  # And the consequence a user would have seen: the next agent in this pane
  # reporting `idle` draws the finished glyph, not `background` from a dead id.
  run "$PLUGIN_ROOT/bin/tama" state idle Claude --pane "$PANE"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "a subagent start that lands after a clear takes its own residue back off" {
  # The same hole without the retry loop: the write arrives after `clear` read the
  # pane, so clear does not know to unset it and the start's own read-back is the
  # only thing left that can see the pane is no longer an agent pane.
  #
  # In this order: the start reads, the clear reads, the clear writes, the start
  # writes, the start reads back and finds its id there but the pane cleared.
  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-a --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state idle Claude --pane "$PANE"
  assert_success

  local cleared="$BATS_TEST_TMPDIR/cleared"

  TAMA_FAKE_TMUX_COUNTER="$BATS_TEST_TMPDIR/calls-start" \
    TAMA_FAKE_TMUX_WAIT_BEFORE=2 TAMA_FAKE_TMUX_WAIT_FOR="$cleared" \
    "$PLUGIN_ROOT/bin/tama" state subagent-start sub-b --pane "$PANE" &
  TAMA_FAKE_TMUX_COUNTER="$BATS_TEST_TMPDIR/calls-clear" \
    TAMA_FAKE_TMUX_TOUCH_AFTER=2 TAMA_FAKE_TMUX_TOUCH="$cleared" \
    "$PLUGIN_ROOT/bin/tama" state clear --pane "$PANE" &
  wait

  [ -e "$cleared" ]

  local remaining
  remaining="$(test_tmux show -p -t "$PANE" | grep -c '^@tama_' || true)"
  assert_equal "$remaining" 0
}

@test "an id that begins with a dash can be given after --" {
  # Ids are opaque and the agent chooses them, so some of them will look like
  # options; without a way to say "this is a value" they would be unusable.
  run "$PLUGIN_ROOT/bin/tama" state --pane "$PANE" -- subagent-start -dash-id
  assert_success
  assert_pane_option "$PANE" subagents -dash-id

  run "$PLUGIN_ROOT/bin/tama" state --pane "$PANE" -- subagent-stop -dash-id
  assert_success
  assert_pane_option_unset "$PANE" subagents
}

@test "a value that tmux would read as a command separator survives intact" {
  # tmux takes an argument ending in `;` as the end of a command, and would both
  # store the name without it and abandon the rest of the batch.
  run "$PLUGIN_ROOT/bin/tama" state running 'Claude;' --pane "$PANE"
  assert_success

  assert_pane_option "$PANE" agent 'Claude;'
  assert_pane_option "$PANE" cwd "$(test_tmux display-message -p -t "$PANE" '#{pane_current_path}')"

  # And the pane still recognises itself, so the hot path stays short-circuited.
  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" state running 'Claude;' --pane "$PANE"
  assert_success
  refute_tmux_command 'set'
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

  # A newline would end the record the whole pane is read as, so everything after
  # it would come back empty on every later read.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state running "$(printf 'Cla\nude')" --pane "$PANE"
  assert_usage_error 'newline'
  assert_pane_option_unset "$PANE" state_main

  # And the separator the record is packed with, which would shift every field
  # after it and leave the pane unable to recognise itself.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state running "$(printf 'Cla\037ude')" --pane "$PANE"
  assert_usage_error
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state subagent-start "$(printf 'su\037b')" --pane "$PANE"
  assert_usage_error
  assert_pane_option_unset "$PANE" state_main

  # A hook that failed to interpolate its variable, rather than a state from a
  # version that does not exist yet.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state '' --pane "$PANE"
  assert_usage_error
}
