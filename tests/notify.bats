#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

# The whole notification path against a backend that records instead of notifying.
# Nothing here reaches into a shell library: every test drives `bin/tama` and asserts
# on what a user could observe — the banner the backend was asked to raise, the tmux
# options a status line would draw, and what the click action does when it is run.
#
# The plugin is loaded in every test because the mark is half of what `notify` does,
# and the mark is only visible through the format the entrypoint exports.
setup() {
  # Before the server boots: the backend is reached from tmux hooks too, and a hook's
  # `run-shell` inherits the environment the server was started with.
  tama_fake_backend_env
  tama_start_server
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tama_use_fake_backend
}

teardown() {
  tama_detach_client
  tama_kill_server
}

# A second window in the session, so that a test can put the user somewhere other than
# the window the agent is in — which is the ordinary case for a notification.
arrange_two_windows() {
  test_tmux new-window -t t: -d
}

# An agent pane in a directory of a known name — which is what the default title is made
# of, so this is the fixture for every claim about it. Prints the pane id.
#
# Both of the things that title reads are arranged here, and neither is ceremony:
#
#   * tmux is asked for the pane's directory until it says this one. A pane can exist for
#     a few milliseconds before the shell in it does, and until then there is nothing to
#     read the directory from.
#   * the pane then reports a state, the way an agent does, which records the directory
#     as a pane option. That is the branch the default title falls back to, and it is
#     what makes this deterministic: tmux's live answer intermittently comes back empty
#     even for a pane that has been idle for minutes — 2 reads in 400 on macOS — so a
#     test that depended on it alone would fail about that often, and so would a banner.
agent_pane_in() { # <directory-name>
  local name="$1" dir="$BATS_TEST_TMPDIR/$1" pane waited=0
  mkdir -p "$dir"
  pane="$(test_tmux new-window -t t: -d -P -F '#{pane_id}' -c "$dir")"
  while [ "$(basename \
    "$(test_tmux display-message -p -t "$pane" '#{pane_current_path}')")" != "$name" ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'tmux never reported %s as the directory of %s\n' "$dir" "$pane" >&2
      return 1
    fi
    sleep 0.05
  done

  # Through the CLI, because that is the only seam a test uses, and repeated until the
  # snapshot is there: the write reads the same field tmux is unreliable about, so a
  # report that landed with nothing to record has to be made again.
  waited=0
  while [ "$(basename \
    "$(test_tmux show -p -t "$pane" -qv @tama_pane_cwd 2>/dev/null)")" != "$name" ]; do
    "$PLUGIN_ROOT/bin/tama" state running --pane "$pane"
    waited=$((waited + 1))
    if [ "$waited" -gt 20 ]; then
      printf 'the plugin never recorded %s as the directory of %s\n' "$dir" "$pane" >&2
      return 1
    fi
  done

  printf '%s' "$pane"
}

# The window a pane is in, by id.
window_of() { # <pane>
  test_tmux display-message -p -t "$1" '#{window_id}'
}

# Runs a click action the way the desktop runs it: in a process that has none of the
# environment the hook which raised the banner had. That is not a detail — everything the
# click needs has to be baked into the command line, the tmux server included, and a test
# that ran it with the suite's own environment would pass on a click that only worked
# because the environment was still there. It did.
#
# TAMA_TMUX is deliberately pointed at nothing rather than merely unset: if the command
# line ever stops carrying its own, every tmux call inside it fails instead of falling
# through to whichever server a bare `tmux` would reach — which on a developer's machine
# is their own. The click's own assignments override this one when they are there, which
# is the whole point.
run_click() { # <click command line>
  run --separate-stderr env -u TMUX -u TAMA_TMUX_ARGS TAMA_TMUX=/nonexistent/tmux \
    sh -c "$1"
}

@test "a banner says which agent and which project, with no configuration at all" {
  local pane
  pane="$(agent_pane_in the-api)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success

  assert_backend_called notify
  # Two arguments, and only two: the title and the message. Which agent, and which
  # project — expressed as a basename modifier on the pane's own path, with nothing
  # configured and no idea of a "project" anywhere in the plugin.
  assert_backend_value notify argc 2
  assert_backend_value notify argv1 'claude-code - the-api'
  assert_backend_value notify argv2 'permission needed'
}

@test "the backend is told which window, pane, session and agent it is about" {
  local pane window
  pane="$(tama_pane_of t:0)"
  window="$(tama_window_id t:0)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success

  # The window by id, never by index: a banner raised for `t:3` must still address the
  # same window after `renumber-windows` has moved it.
  assert_backend_value notify env.TAMA_WINDOW_ID "$window"
  assert_backend_value notify env.TAMA_PANE_ID "$pane"
  assert_backend_value notify env.TAMA_SESSION t
  assert_backend_value notify env.TAMA_AGENT claude-code
  assert_backend_value notify env.TAMA_GROUP "tmux-window-$window"
  # So a backend can call back into the plugin without knowing where it lives.
  assert_backend_value notify env.TAMA_BIN "$PLUGIN_ROOT/bin/tama"
}

@test "a banner marks its window too" {
  local pane window
  pane="$(tama_pane_of t:0)"
  window="$(tama_window_id t:0)"

  assert_not_flagged "$window"
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  assert_flagged "$window"
}

@test "no banner when tmux and the backend agree the user is looking at the window" {
  # The `AND` of ADR-0004 with both halves saying yes, which is the only combination
  # that drops a notification: the window is current in its own session, somebody is
  # attached to it, and the terminal really is in front.
  tama_attach_client t
  export TAMA_FAKE_FOCUSED=0

  local pane window
  pane="$(tama_pane_of t:0)"
  window="$(tama_window_id t:0)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success

  assert_backend_called focused
  refute_backend_called notify
  # A dropped notification leaves no trace at all, the mark included.
  assert_not_flagged "$window"
}

@test "a terminal behind a browser is notified anyway, and its window marked" {
  # The failure this plugin cannot afford: tmux says the user is on that window, and it
  # is wrong, because the terminal is minimized. The backend is the only thing that
  # knows, and its no is enough on its own.
  tama_attach_client t
  export TAMA_FAKE_FOCUSED=1

  local pane window
  pane="$(tama_pane_of t:0)"
  window="$(tama_window_id t:0)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success

  assert_backend_called focused
  assert_backend_called notify
  # And the mark belongs there: something did happen while nobody was looking, whatever
  # tmux thinks about which window is active.
  assert_flagged "$window"
}

@test "the expensive check is not made when the cheap one already said no" {
  # The ordering is the point of the ADR and not an optimization: nobody is attached
  # here, so there is nothing to ask the desktop about.
  export TAMA_FAKE_FOCUSED=0

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' \
    --pane "$(tama_pane_of t:0)"
  assert_success

  refute_backend_called focused
  assert_backend_called notify
}

@test "a backend that cannot tell whether the terminal is in front delivers" {
  # Which is what makes a backend without the capability — libnotify, none — usable at
  # all. Every way of not knowing lands on noise rather than on silence.
  test_tmux set -g @tama_backend "$(tama_fake_backend_without focused)"
  tama_attach_client t
  export TAMA_FAKE_FOCUSED=0

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' \
    --pane "$(tama_pane_of t:0)"
  assert_success

  assert_backend_called notify
}

@test "a failing focus check delivers" {
  tama_attach_client t
  export TAMA_FAKE_FOCUSED=3

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' \
    --pane "$(tama_pane_of t:0)"
  assert_success

  assert_backend_called focused
  assert_backend_called notify
}

@test "suppression can be turned off, and then nothing is asked or dropped" {
  test_tmux set -g @tama_suppress_when_focused off
  tama_attach_client t
  export TAMA_FAKE_FOCUSED=0

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' \
    --pane "$(tama_pane_of t:0)"
  assert_success

  refute_backend_called focused
  assert_backend_called notify
}

@test "notifications can be turned off entirely while the icons keep working" {
  test_tmux set -g @tama_notifications off

  local pane window
  pane="$(tama_pane_of t:0)"
  window="$(tama_window_id t:0)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  refute_backend_called notify
  assert_not_flagged "$window"

  # The other half of the claim: everything inside tmux is untouched. The icons still
  # move, and a state that needs the user still marks the window — going heads-down is
  # about the OS interrupting, not about the status line going blank.
  run "$PLUGIN_ROOT/bin/tama" state waiting claude-code --pane "$pane"
  assert_success
  assert_equal "$(tama_icons "$window")" ' ◐'
  assert_flagged "$window"
}

@test "the title is a real tmux format, expanded against the pane that spoke" {
  # No template engine of the plugin's own, and no idea of a "project": whatever tmux
  # can express, including things the plugin has never heard of.
  test_tmux set -g @tama_title_format '#{session_name}:#{window_index} #{pane_id}'
  local pane
  pane="$(tama_pane_of t:0)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  assert_backend_value notify argv1 "t:0 $pane"
}

@test "the title comes from the pane's own directory, not the caller's" {
  # The bug this replaces: the project name came from the hook process's working
  # directory, which is right until an agent is started from somewhere else. This suite
  # runs from neither of these, so a title naming the caller's directory fails here.
  local one two
  one="$(agent_pane_in the-api)"
  two="$(agent_pane_in the-website)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$one"
  assert_success
  assert_backend_value notify argv1 'claude-code - the-api'

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$two"
  assert_success
  assert_backend_value notify argv1 'claude-code - the-website'
}

@test "no label provider means nothing is run and nothing is stored" {
  local pane
  pane="$(agent_pane_in the-api)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success

  # Not an empty label: no label. The default title asks whether there is one at all,
  # and an option set to "" would answer yes and draw an empty pair of brackets.
  assert_pane_option_unset "$pane" label
  assert_backend_value notify argv1 'claude-code - the-api'
}

@test "a configured label provider is given the window id and reaches the title" {
  local provider="$BATS_TEST_TMPDIR/label"
  cat >"$provider" <<'PROVIDER'
#!/bin/sh
printf 'the %s window\n' "$1"
PROVIDER
  chmod +x "$provider"
  test_tmux set -g @tama_label_command "$provider"

  local pane window
  pane="$(agent_pane_in the-api)"
  window="$(window_of "$pane")"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success

  # Exposed as a pane option, which is how a format the user writes can reach it.
  assert_pane_option "$pane" label "the $window window"
  assert_backend_value notify argv1 "claude-code - the-api (the $window window)"
}

@test "a label provider that says nothing useful leaves the title alone" {
  local provider="$BATS_TEST_TMPDIR/label"
  cat >"$provider" <<'PROVIDER'
#!/bin/sh
exit 1
PROVIDER
  chmod +x "$provider"
  test_tmux set -g @tama_label_command "$provider"

  local pane
  pane="$(agent_pane_in the-api)"
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  assert_pane_option_unset "$pane" label
  assert_backend_value notify argv1 'claude-code - the-api'
}

@test "a label the plugin cannot store is no label" {
  # A value with a control character in it comes back from a tmux option changed or
  # escaped depending on the version and the locale, so the title would be nonsense
  # rather than what the user's tooling meant.
  local provider="$BATS_TEST_TMPDIR/label"
  cat >"$provider" <<'PROVIDER'
#!/bin/sh
printf 'one\ttwo\n'
PROVIDER
  chmod +x "$provider"
  test_tmux set -g @tama_label_command "$provider"

  local pane
  pane="$(tama_pane_of t:0)"
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  assert_pane_option_unset "$pane" label
}

@test "a stale label does not survive on a pane whose agent has gone" {
  # The label is a pane option the plugin wrote, so it is one of the things `clear`
  # takes away. A pane that kept one would be a pane a later read can still tell from
  # one that never ran an agent.
  local provider="$BATS_TEST_TMPDIR/label"
  cat >"$provider" <<'PROVIDER'
#!/bin/sh
printf 'a label\n'
PROVIDER
  chmod +x "$provider"
  test_tmux set -g @tama_label_command "$provider"

  local pane
  pane="$(tama_pane_of t:0)"
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  assert_pane_option "$pane" label 'a label'

  run "$PLUGIN_ROOT/bin/tama" state clear --pane "$pane"
  assert_success
  assert_pane_option_unset "$pane" label
  assert_equal "$(test_tmux show -p -t "$pane" | grep -c '^@tama_' || true)" '0'
}

@test "raising and dismissing name the same banner" {
  local pane window
  pane="$(tama_pane_of t:0)"
  window="$(tama_window_id t:0)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  local group
  group="$(tama_backend_value notify env.TAMA_GROUP)"

  run "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  assert_backend_called dismiss
  assert_backend_value dismiss argv1 "$group"
  assert_backend_value dismiss env.TAMA_GROUP "$group"
}

@test "a group format of the user's own is followed by both halves" {
  # One configurable format, read in one place, precisely so that these two cannot
  # drift apart: a dismissal naming a different group than the banner leaves the banner
  # on screen with nothing to say why.
  test_tmux set -g @tama_group_format 'agent-#{session_name}-#{window_id}'

  local pane window
  pane="$(tama_pane_of t:0)"
  window="$(tama_window_id t:0)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  assert_backend_value notify env.TAMA_GROUP "agent-t-$window"

  run "$PLUGIN_ROOT/bin/tama" dismiss --pane "$pane"
  assert_success
  assert_backend_value dismiss argv1 "agent-t-$window"
}

@test "arriving at the window takes its banner down" {
  # Through the hook the entrypoint wired, not by calling on-select: the user selects
  # the window and both the mark and the banner go.
  arrange_two_windows
  tama_attach_client t
  test_tmux select-window -t t:0

  local pane window
  pane="$(tama_pane_of t:1)"
  window="$(tama_window_id t:1)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  assert_flagged "$window"
  local group
  group="$(tama_backend_value notify env.TAMA_GROUP)"

  test_tmux select-window -t t:1
  wait_until_not_flagged "$window"
  wait_until_backend_called dismiss
  assert_backend_value dismiss argv1 "$group"
}

@test "a window selection with no mark on it starts no notifier at all" {
  # A window selection happens every time the user presses a key. A window with no mark
  # has no banner of ours pending, because a delivered banner always leaves one, so
  # there is nothing to ask the desktop about — and asking would mean a notifier
  # process per keystroke.
  arrange_two_windows
  tama_attach_client t

  test_tmux select-window -t t:1
  test_tmux select-window -t t:0
  # Nothing to wait for, so wait for the sweep that runs on the same event to have had
  # its chance, then assert on the absence.
  sleep 0.5
  refute_backend_called dismiss
}

@test "dismiss is a no-op with notifications off" {
  test_tmux set -g @tama_notifications off
  run "$PLUGIN_ROOT/bin/tama" dismiss "$(tama_window_id t:0)"
  assert_success
  refute_backend_called dismiss
}

@test "clicking the banner lands the cursor on the pane that spoke" {
  arrange_two_windows
  test_tmux split-window -t t:1 -d

  # The second pane of the other window: a click has to find the pane, not just the
  # window, and not just the pane that happened to be active.
  local pane window
  pane="$(test_tmux list-panes -t t:1 -F '#{pane_id}' | tail -1)"
  window="$(tama_window_id t:1)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success

  test_tmux select-window -t t:0
  assert_equal "$(test_tmux display-message -p -t "$window" '#{window_active}')" '0'

  # The click, run the way the desktop would run it: one command line, no environment
  # of the plugin's left.
  local click
  click="$(tama_backend_value notify env.TAMA_CLICK)"
  run_click "$click"
  assert_success

  assert_equal "$(test_tmux display-message -p -t "$window" '#{window_active}')" '1'
  assert_equal "$(test_tmux display-message -p -t "$window" '#{pane_id}')" "$pane"
  # And the terminal itself comes forward, which is the step tmux cannot do.
  assert_backend_called focus
  assert_backend_value focus argv1 t
}

@test "clicking a banner whose pane has gone still brings the terminal forward" {
  arrange_two_windows
  test_tmux split-window -t t:1 -d

  local pane window
  pane="$(test_tmux list-panes -t t:1 -F '#{pane_id}' | tail -1)"
  window="$(tama_window_id t:1)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  local click
  click="$(tama_backend_value notify env.TAMA_CLICK)"

  test_tmux select-window -t t:0
  test_tmux kill-pane -t "$pane"

  run_click "$click"
  assert_success
  # The steps are chained so that each happens whatever the one before it did: the
  # window is still selected, and the terminal is still brought forward.
  assert_equal "$(test_tmux display-message -p -t "$window" '#{window_active}')" '1'
  assert_backend_called focus
}

@test "clicking a banner whose window has gone still brings the terminal forward" {
  # The click a user makes minutes later, on a window they have since closed. Doing
  # nothing at all is the one outcome that makes the banner feel broken.
  arrange_two_windows

  local pane window
  pane="$(tama_pane_of t:1)"
  window="$(tama_window_id t:1)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  local click
  click="$(tama_backend_value notify env.TAMA_CLICK)"

  test_tmux kill-window -t "$window"

  run_click "$click"
  assert_success
  assert_backend_called focus
  assert_backend_value focus argv1 t
}

@test "focus-window works where a click arrives: outside tmux" {
  # Every other command is a quiet no-op with no \$TMUX, and this one must not be: a
  # click arrives in a process the desktop started, which has none of the environment
  # the hook that raised the banner had.
  run --separate-stderr env -u TMUX "$PLUGIN_ROOT/bin/tama" focus-window t
  assert_success
  [ -z "$output" ]
  assert_backend_called focus
  assert_backend_value focus argv1 t
  assert_backend_value focus env.TAMA_SESSION t
}

@test "a session name a shell would act on survives the click" {
  # The one command line this plugin composes out of values it did not choose. A
  # session called this is legal in tmux, and every part of the click has to arrive as
  # one word whatever is in it.
  local session="my 'project'; touch $BATS_TEST_TMPDIR/pwned"
  test_tmux -f /dev/null new-session -d -s "$session"

  local pane
  pane="$(test_tmux list-panes -t "$session" -F '#{pane_id}' | head -1)"
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success

  local click
  click="$(tama_backend_value notify env.TAMA_CLICK)"
  run_click "$click"
  assert_success

  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  assert_backend_value focus argv1 "$session"
}

@test "the message arrives as one argument, whatever an agent put in it" {
  # This is what #12 hands over: text a human or a model wrote, with no promises about
  # it. It is never expanded as a tmux format, never read as shell, and never stored in
  # an option — so nothing in it needs escaping and nothing in it can act.
  local message
  message="don't #{window_id} \$(touch $BATS_TEST_TMPDIR/pwned) \`id\` \"quoted\" 'both'"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code "$message" \
    --pane "$(tama_pane_of t:0)"
  assert_success

  assert_backend_value notify argc 2
  assert_backend_value notify argv2 "$message"
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "a message with a newline in it is still one argument" {
  local message
  message="$(printf 'the first line\nthe second line')"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code "$message" \
    --pane "$(tama_pane_of t:0)"
  assert_success
  assert_backend_value notify argc 2
  assert_backend_value notify argv2 "$message"
}

@test "a message that begins with a dash is a message, after --" {
  # Anything a model wrote can begin with a dash, and a sentence quite reasonably does.
  # Without `--` it is an option, and a wrong one is loud, as everywhere else.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code '--not-an-option' \
    --pane "$(tama_pane_of t:0)"
  assert_usage_error 'unknown option'

  run "$PLUGIN_ROOT/bin/tama" notify --pane "$(tama_pane_of t:0)" -- \
    claude-code '--not-an-option'
  assert_success
  assert_backend_value notify argv2 '--not-an-option'
}

@test "one capability can be replaced without replacing the backend" {
  local own="$BATS_TEST_TMPDIR/my-notifier"
  cat >"$own" <<'NOTIFIER'
#!/bin/sh
printf '%s' "$#" >"$TAMA_TEST_LOG.own.argc"
printf '%s' "$1" >"$TAMA_TEST_LOG.own.argv1"
printf '%s' "$3" >"$TAMA_TEST_LOG.own.argv3"
NOTIFIER
  chmod +x "$own"
  # A command line, not a path, so it can carry its own flags — and the title and the
  # message are still appended as arguments rather than pasted into it.
  test_tmux set -g @tama_notify_command "$own --loud"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' \
    --pane "$(tama_pane_of t:0)"
  assert_success

  refute_backend_called notify
  # The user's own flag first, then the two the contract promises.
  assert_equal "$(cat "$TAMA_TEST_LOG.own.argc")" '3'
  assert_equal "$(cat "$TAMA_TEST_LOG.own.argv1")" '--loud'
  assert_equal "$(cat "$TAMA_TEST_LOG.own.argv3")" 'permission needed'
}

@test "the no-op backend that ships is silent, and does not suppress anything" {
  # Where `auto` lands on a machine with no notifier. It ships no `focused`, on
  # purpose: one that exited 0 would mean "the user is looking", and every notification
  # on the machine would be dropped.
  test_tmux set -g @tama_backend none
  tama_attach_client t
  export TAMA_FAKE_FOCUSED=0

  local pane window
  pane="$(tama_pane_of t:0)"
  window="$(tama_window_id t:0)"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  # Nothing was suppressed, which is the only thing observable about a backend that
  # does nothing: the pipeline ran all the way to the end.
  assert_flagged "$window"
}

@test "a missing backend, capability or notifier never fails an agent's turn" {
  local pane
  pane="$(tama_pane_of t:0)"

  # A backend that is not there.
  test_tmux set -g @tama_backend not-a-backend
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  # A name that would reach out of the plugin's own backends directory.
  test_tmux set -g @tama_backend '../../etc'
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$stderr" ]

  # Backends off entirely.
  test_tmux set -g @tama_backend ''
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$stderr" ]

  # A backend with no notify capability.
  test_tmux set -g @tama_backend "$(tama_fake_backend_without notify)"
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$stderr" ]

  # A notifier that failed, and one that was noisy about it.
  local broken="$BATS_TEST_TMPDIR/broken-backend"
  mkdir -p "$broken"
  cat >"$broken/notify" <<'BROKEN'
#!/bin/sh
printf 'terminal-notifier: no such thing\n' >&2
printf 'and something on stdout\n'
exit 4
BROKEN
  chmod +x "$broken/notify"
  test_tmux set -g @tama_backend "$broken"
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  # And the same for the other two commands.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" dismiss "$(tama_window_id t:0)"
  assert_success
  [ -z "$stderr" ]
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" focus-window t
  assert_success
  [ -z "$stderr" ]
}

@test "the notification commands are quiet no-ops outside tmux" {
  local window
  window="$(tama_window_id t:0)"

  run --separate-stderr env -u TMUX "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed'
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  refute_backend_called notify

  run --separate-stderr env -u TMUX "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  [ -z "$output" ]
  refute_backend_called dismiss
}

@test "a pane or a window that is gone is not an error" {
  arrange_two_windows
  local doomed_pane doomed_window
  doomed_pane="$(tama_pane_of t:1)"
  doomed_window="$(tama_window_id t:1)"
  test_tmux kill-window -t "$doomed_window"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' \
    --pane "$doomed_pane"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  refute_backend_called notify

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" dismiss "$doomed_window"
  assert_success
  [ -z "$stderr" ]
  refute_backend_called dismiss
}

@test "notify with no pane at all does nothing, quietly" {
  # No \$TMUX_PANE — a wrapper lost it — and no --pane. There is nothing to notify
  # about and an agent's turn must not fail over it.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed'
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  refute_backend_called notify
}

@test "the notification commands reject a wrong invocation loudly" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify
  assert_usage_error 'agent name'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code
  assert_usage_error 'message'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify '' 'needed'
  assert_usage_error 'agent name'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code ''
  assert_usage_error 'message'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify a b c
  assert_usage_error 'two arguments'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify --nope a b
  assert_usage_error 'unknown option'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify --pane
  assert_usage_error '--pane needs a pane id'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify "$(printf 'two\nlines')" 'needed'
  assert_usage_error 'agent name'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" dismiss @1 @2
  assert_usage_error 'at most one target'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" dismiss ''
  assert_usage_error 'needs a window target'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" focus-window
  assert_usage_error 'needs a session'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" focus-window one two
  assert_usage_error 'one session'

  # focus-window is loud outside tmux as well as inside it, because outside tmux is
  # where it is meant to run. The other two are the quiet no-op there, which is the
  # dispatcher's rule for every command that needs a server and not this one's to bend.
  run --separate-stderr env -u TMUX "$PLUGIN_ROOT/bin/tama" focus-window
  assert_usage_error 'needs a session'
}

@test "a wrong invocation is refused before any of it happens" {
  # The argument check comes before the configuration and before the environment, so
  # that a hook whose author has made a mistake hears about it even on a machine where
  # notifications are off.
  test_tmux set -g @tama_notifications off
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code
  assert_usage_error 'message'
}

@test "the notification path runs under the bash macOS ships" {
  # bash 3.2 is /bin/bash on every macOS and differs from bash 5 at runtime as well as
  # at parse time. A diagnostic on stderr would be a broken plugin even with the right
  # result, which is why every claim here is also about stderr.
  tama_use_bash_32_or_skip

  local pane window
  pane="$(tama_pane_of t:0)"
  window="$(tama_window_id t:0)"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code "it's waiting" \
    --pane "$pane"
  assert_success
  [ -z "$stderr" ]
  assert_backend_called notify
  assert_backend_value notify argv2 "it's waiting"
  assert_flagged "$window"

  local click
  click="$(tama_backend_value notify env.TAMA_CLICK)"
  run_click "$click"
  assert_success
  [ -z "$stderr" ]
  assert_backend_called focus

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  [ -z "$stderr" ]
  assert_backend_called dismiss
}
