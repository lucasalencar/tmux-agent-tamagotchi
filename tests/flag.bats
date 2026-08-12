#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

# The plugin is loaded in every test here, because the flag is only half a feature
# without the format that draws it: these tests ask what the status line would show,
# not what an option holds.
setup() {
  tama_start_server
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
}

teardown() {
  tama_detach_client
  tama_kill_server
}

# A second session with two windows, so that "same index, different session" — the
# bug this feature exists to fix — can be arranged at all. The server starts with
# session `t` holding window 0; this gives `t` a window 1 too, and `other` windows
# 0 and 1, at matching indexes on purpose.
arrange_two_sessions() {
  test_tmux new-window -t t: -d
  test_tmux -f /dev/null new-session -d -s other
  test_tmux new-window -t other: -d
}

@test "waiting raises the flag on a window nobody is looking at" {
  local window pane
  window="$(tama_window_id t:0)"
  pane="$(tama_pane_of t:0)"

  assert_not_flagged "$window"
  run "$PLUGIN_ROOT/bin/tama" state waiting --pane "$pane"
  assert_success
  assert_flagged "$window"
}

@test "error raises the flag too" {
  local window pane
  window="$(tama_window_id t:0)"
  pane="$(tama_pane_of t:0)"

  run "$PLUGIN_ROOT/bin/tama" state error --pane "$pane"
  assert_success
  assert_flagged "$window"
}

@test "the states that are not asking for anything raise no flag" {
  local window pane
  window="$(tama_window_id t:0)"
  pane="$(tama_pane_of t:0)"

  run "$PLUGIN_ROOT/bin/tama" state running --pane "$pane"
  assert_success
  assert_not_flagged "$window"

  run "$PLUGIN_ROOT/bin/tama" state idle --pane "$pane"
  assert_success
  assert_not_flagged "$window"
}

@test "an agent moving on to another state does not clear the flag" {
  local window pane
  window="$(tama_window_id t:0)"
  pane="$(tama_pane_of t:0)"

  run "$PLUGIN_ROOT/bin/tama" state waiting --pane "$pane"
  assert_success
  assert_flagged "$window"

  # The whole asymmetry: the agent going back to work does not un-happen the thing
  # the user missed. Every state it could move to, including a clear.
  run "$PLUGIN_ROOT/bin/tama" state running --pane "$pane"
  assert_success
  assert_flagged "$window"

  run "$PLUGIN_ROOT/bin/tama" state idle --pane "$pane"
  assert_success
  assert_flagged "$window"

  run "$PLUGIN_ROOT/bin/tama" state clear --pane "$pane"
  assert_success
  assert_flagged "$window"
}

@test "the window the user is actually looking at is not flagged" {
  tama_attach_client t

  local window pane
  window="$(tama_window_id t:0)"
  pane="$(tama_pane_of t:0)"

  run "$PLUGIN_ROOT/bin/tama" state waiting --pane "$pane"
  assert_success
  assert_not_flagged "$window"
}

@test "a window at the same index in another session is flagged" {
  # The bug being fixed. The old system compared the target window's *index* against
  # the index of whatever window the ambient client was showing: both are 1 here, so
  # an agent asking a question in `other:1` was silently never flagged while the user
  # sat in `t:1`.
  arrange_two_sessions
  tama_attach_client t
  test_tmux select-window -t t:1

  local target pane
  target="$(tama_window_id other:1)"
  pane="$(tama_pane_of other:1)"

  # Same index as the window the user is looking at, and a different session.
  assert_equal "$(test_tmux display-message -p -t other:1 '#{window_index}')" \
    "$(test_tmux display-message -p -t t:1 '#{window_index}')"

  run "$PLUGIN_ROOT/bin/tama" state waiting --pane "$pane"
  assert_success
  assert_flagged "$target"
}

@test "a window that is active in its own unattached session is still flagged" {
  # The other half of "is the user looking at this": `other:0` is the active window
  # of its session and shares an index with the window the user is on, so the only
  # thing left to notice is that nobody is attached to that session at all. An agent
  # working in a detached session is exactly who most needs the flag waiting for them.
  arrange_two_sessions
  tama_attach_client t

  local target pane
  target="$(tama_window_id other:0)"
  pane="$(tama_pane_of other:0)"

  assert_equal "$(test_tmux display-message -p -t "$target" '#{window_active}')" '1'
  assert_equal "$(test_tmux display-message -p -t "$target" '#{session_attached}')" '0'

  run "$PLUGIN_ROOT/bin/tama" state waiting --pane "$pane"
  assert_success
  assert_flagged "$target"
}

@test "a still-open question raises the flag again after the user walked away" {
  # `state` writes nothing when nothing changed, and the flag must not be behind that
  # short-circuit: the agent is still waiting, the user glanced at the window and
  # left, and asking again has to put the mark back.
  local window pane
  window="$(tama_window_id t:0)"
  pane="$(tama_pane_of t:0)"

  run "$PLUGIN_ROOT/bin/tama" state waiting --pane "$pane"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" unflag "$window"
  assert_success
  assert_not_flagged "$window"

  # The same state as before, so the pane record does not change at all.
  run "$PLUGIN_ROOT/bin/tama" state waiting --pane "$pane"
  assert_success
  assert_flagged "$window"
}

@test "flag and unflag act directly on a window" {
  local window
  window="$(tama_window_id t:0)"

  run "$PLUGIN_ROOT/bin/tama" flag "$window"
  assert_success
  assert_flagged "$window"

  run "$PLUGIN_ROOT/bin/tama" unflag "$window"
  assert_success
  assert_not_flagged "$window"
}

@test "flag takes the window of a pane, and does not flag one the user is looking at" {
  tama_attach_client t
  arrange_two_sessions

  run "$PLUGIN_ROOT/bin/tama" flag --pane "$(tama_pane_of t:0)"
  assert_success
  assert_not_flagged "$(tama_window_id t:0)"

  run "$PLUGIN_ROOT/bin/tama" flag --pane "$(tama_pane_of other:0)"
  assert_success
  assert_flagged "$(tama_window_id other:0)"
}

@test "clearing the flag unsets the option rather than emptying it" {
  # A flag that is set to "" is still a flag that is set. `#{?@tama_window_flag,…}`
  # would read it as false today, but every other clear in the plugin unsets, and a
  # window that was never flagged and one that has been seen must not be told apart.
  local window
  window="$(tama_window_id t:0)"

  run "$PLUGIN_ROOT/bin/tama" flag "$window"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" unflag "$window"
  assert_success

  assert_window_option_unset "$window" window_flag
}

@test "on-select clears the flag of the window it was called for" {
  local window
  window="$(tama_window_id t:0)"

  run "$PLUGIN_ROOT/bin/tama" flag "$window"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" on-select --pane "$(tama_pane_of t:0)"
  assert_success
  assert_not_flagged "$window"
}

@test "selecting a window clears its flag with no manual step" {
  # The claim the feature rests on, through the hook the entrypoint wired rather than
  # by calling on-select: the user selects the window and the mark goes.
  arrange_two_sessions
  tama_attach_client t
  test_tmux select-window -t t:0

  local window
  window="$(tama_window_id t:1)"
  run "$PLUGIN_ROOT/bin/tama" flag "$window"
  assert_success
  assert_flagged "$window"

  test_tmux select-window -t t:1
  wait_until_not_flagged "$window"
}

@test "selecting a window clears only that window's flag" {
  # The hook has to name the window it fired for. It cannot be left to work that out
  # from $TMUX_PANE: tmux sets that, inside a hook's run-shell, to a pane id that does
  # not exist, so the flag was cleared nowhere at all — and a command that fell back to
  # some *other* real pane would clear the wrong window instead.
  arrange_two_sessions
  tama_attach_client t
  test_tmux select-window -t t:0

  local selected other
  selected="$(tama_window_id t:1)"
  other="$(tama_window_id other:1)"
  run "$PLUGIN_ROOT/bin/tama" flag "$selected"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" flag "$other"
  assert_success

  test_tmux select-window -t t:1
  wait_until_not_flagged "$selected"
  # The window nobody selected keeps its mark.
  assert_flagged "$other"
}

@test "on-select ignores the phantom pane tmux hands a hook" {
  # Pinning the trap itself, since the recipe is the only thing protecting against it:
  # a pane id that resolves to nothing must clear nothing, quietly, rather than pick a
  # window for itself.
  local window
  window="$(tama_window_id t:0)"
  run "$PLUGIN_ROOT/bin/tama" flag "$window"
  assert_success

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" on-select --pane '%101'
  assert_success
  [ -z "$output" ]
  assert_flagged "$window"
}

@test "the flag follows the window, not its index" {
  # Indexes move: `renumber-windows` closes a gap and every window after it shifts.
  # A flag that had been recorded against an index would be on the wrong window here,
  # or on none.
  arrange_two_sessions
  test_tmux new-window -t t: -d
  test_tmux set -g renumber-windows on

  local window before
  window="$(tama_window_id t:2)"
  before="$(test_tmux display-message -p -t "$window" '#{window_index}')"
  run "$PLUGIN_ROOT/bin/tama" flag "$window"
  assert_success

  test_tmux kill-window -t t:1
  # The window really did move, or this test proves nothing.
  [ "$(test_tmux display-message -p -t "$window" '#{window_index}')" != "$before" ]
  assert_flagged "$window"
}

@test "the exported flag format draws the configured text" {
  local window
  window="$(tama_window_id t:0)"
  run "$PLUGIN_ROOT/bin/tama" flag "$window"
  assert_success

  # The default, which the entrypoint seeds because a format cannot carry one.
  assert_equal "$(test_tmux display-message -p -t "$window" '#{E:@tama_flag}')" ' *'

  # Read at expansion time, so a reconfiguration needs no reload — and expanded a
  # second time, so it can carry colour.
  test_tmux set -g @tama_flag_text '#[fg=red]!'
  assert_equal "$(test_tmux display-message -p -t "$window" '#{E:@tama_flag}')" '#[fg=red]!'
}

@test "flag text the user emptied stays empty across a reload" {
  test_tmux set -g @tama_flag_text ''
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_equal "$(test_tmux show -gv @tama_flag_text)" ''
}

@test "the flag commands are quiet no-ops outside tmux" {
  local window
  window="$(tama_window_id t:0)"

  run --separate-stderr env -u TMUX "$PLUGIN_ROOT/bin/tama" flag "$window"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_not_flagged "$window"

  run --separate-stderr env -u TMUX "$PLUGIN_ROOT/bin/tama" unflag "$window"
  assert_success
  [ -z "$output" ]

  run --separate-stderr env -u TMUX "$PLUGIN_ROOT/bin/tama" on-select
  assert_success
  [ -z "$output" ]
}

@test "a flag command with no pane and no target does nothing, quietly" {
  # No $TMUX_PANE — a wrapper lost it — and nothing on the command line. There is no
  # window to mark and an agent's turn must not fail over it.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" flag
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" on-select
  assert_success
  [ -z "$output" ]
}

@test "a window that is gone is not an error" {
  local window
  window="$(tama_window_id t:0)"
  test_tmux new-window -t t: -d
  local doomed
  doomed="$(tama_window_id t:1)"
  test_tmux kill-window -t "$doomed"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" flag "$doomed"
  assert_success
  [ -z "$output" ]

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" unflag "$doomed"
  assert_success
  [ -z "$output" ]

  # And the surviving window was not marked instead.
  assert_not_flagged "$window"
}

@test "the flag path runs under the bash macOS ships" {
  # bash 3.2 is /bin/bash on every macOS and differs from bash 5 at runtime as well as
  # at parse time, so the only way to know these paths work there is to run them. The
  # window record is taken apart with `set --` rather than an array for exactly this
  # reason; a diagnostic on stderr would be a broken plugin even with the right result.
  tama_use_bash_32_or_skip

  local window pane
  window="$(tama_window_id t:0)"
  pane="$(tama_pane_of t:0)"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" state waiting --pane "$pane"
  assert_success
  [ -z "$stderr" ]
  assert_flagged "$window"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" on-select --window "$window"
  assert_success
  [ -z "$stderr" ]
  assert_not_flagged "$window"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" flag "$window"
  assert_success
  [ -z "$stderr" ]
  assert_flagged "$window"
}

@test "the flag commands reject a wrong invocation loudly" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" flag --nope
  assert_usage_error 'unknown option'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" flag @1 @2
  assert_usage_error 'at most one target'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" flag --pane
  assert_usage_error '--pane needs a pane id'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" flag ''
  assert_usage_error 'needs a window target'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" unflag --nope
  assert_usage_error 'unknown option'

  # on-select is about what the user just did, so there is no window to name.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" on-select @1
  assert_usage_error 'takes no arguments'
}
