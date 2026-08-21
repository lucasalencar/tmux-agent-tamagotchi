#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

# The libnotify backend, driven through `bin/tama` like everything else, with
# `notify-send` replaced by a fixture that records the command line it was given.
#
# Almost everything here runs on **both** CI platforms, and that is the point: pointing
# `@tama_backend` at `libnotify` and `@tama_notify_send` at a fixture is a machine state
# any operating system can be put into, so the flags, the replace-per-window grouping and
# the degradations are asserted on the Mac leg too. Only the three tests about what `auto`
# resolves to are platform-gated, because that is the only claim a platform can change.
#
# What no fixture here can cover is the half only a freedesktop desktop can answer:
# whether a real notification daemon draws the banner, and whether it honours the
# replacement hint. What is asserted is the command line handed to `notify-send` — the
# hint among it — and not a banner anybody saw. There is no Linux desktop on this
# project's development machine and no notification daemon on a CI runner, so **the
# libnotify backend has never raised a banner anybody observed**; that is an open item
# for a user with a Linux desktop, not something this suite quietly claims.
#
# The two `auto` tests gated on not-a-Mac skip on the only machine this plugin is
# developed on, which is exactly the shape of test that passes for years while asserting
# nothing. They can be run from a Mac, and were: copy the plugin somewhere, change the
# `darwin*)` pattern in `tama_backend_is_darwin` to something no `$OSTYPE` matches, flip
# the two gates in this file, and run it. That found a real failure the Mac run hid — a
# mark asserted in a race with the sweep that a client attaching fires — so it is worth
# doing again after anything here or in tama_backend_auto moves.
setup() {
  # Before the server boots: the backend is reached from tmux hooks too — a window
  # selection dismissing a banner — and a hook's `run-shell` inherits the environment the
  # server was started with, not the one the test has now.
  export TAMA_NOTIFY_SEND_DIR="$BATS_TEST_TMPDIR/notify-send"
  mkdir -p "$TAMA_NOTIFY_SEND_DIR"
  : >"$TAMA_NOTIFY_SEND_DIR/calls"

  tama_start_server
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
}

teardown() {
  tama_detach_client
  tmux_test_server_stop
}

require_darwin() {
  [ "$(uname -s)" = 'Darwin' ] || skip 'this is about what a Mac does'
}

refute_darwin() {
  [ "$(uname -s)" != 'Darwin' ] || skip 'this is about what a machine that is not a Mac does'
}

# The backend under test, with `notify-send` named by absolute path — which is also how a
# user whose libnotify lives somewhere unusual says so.
use_libnotify_backend() {
  tmux_test_server_run set -g @tama_backend libnotify
  tmux_test_server_run set -g @tama_notify_send "$PLUGIN_ROOT/tests/fixtures/fake-notify-send"
}

# An unconfigured machine, for the tests about what `auto` resolves to. The helper turns
# the backend off on every test server precisely so that `auto` is never reached by
# accident; the tests that are *about* `auto` have to put it back.
use_no_configuration() {
  tmux_test_server_run set -gu @tama_backend
}

# A `notify-send` on PATH, the way a machine with libnotify installed has one — which is
# how `auto` has to find it, by name, with no option pointing at it.
notify_send_on_path() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cp "$PLUGIN_ROOT/tests/fixtures/fake-notify-send" "$bin/notify-send"
  PATH="$bin:$PATH"
  export PATH
}

# The plugin backgrounds notify-send on purpose — a daemon that is slow to answer must
# not cost an agent's turn — so every assertion about it has to be an eventual one or it
# is timing noise.
wait_for_notify_send() {
  local waited=0
  while [ "$(wc -l <"$TAMA_NOTIFY_SEND_DIR/calls")" -eq 0 ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'notify-send was never started\n' >&2
      return 1
    fi
    sleep 0.05
  done
}

refute_notify_send_started() {
  # No waiting to do: this asserts the *absence* of a call, and the only honest way to do
  # that is to give a call that was going to happen the time to happen.
  sleep 0.5
  if [ "$(wc -l <"$TAMA_NOTIFY_SEND_DIR/calls")" -ne 0 ]; then
    printf 'expected no notify-send at all, got %s call(s):\n%s\n' \
      "$(wc -l <"$TAMA_NOTIFY_SEND_DIR/calls")" \
      "$(cat "$TAMA_NOTIFY_SEND_DIR/argv" 2>/dev/null)" >&2
    return 1
  fi
}

# One value notify-send was given: `title`, `message`, or `hint.<name>`.
notify_send_value() { # <what>
  local file="$TAMA_NOTIFY_SEND_DIR/$1"
  if [ ! -e "$file" ]; then
    printf 'notify-send was given no %s; its argv was:\n%s\n' "$1" \
      "$(cat "$TAMA_NOTIFY_SEND_DIR/argv" 2>/dev/null)" >&2
    return 1
  fi
  cat "$file"
}

assert_notify_send_value() { # <what> <expected>
  local actual
  actual="$(notify_send_value "$1")" || return 1
  assert_equal "$actual" "$2"
}

# An agent pane in a second window, so the user is somewhere else — the ordinary case
# for a notification. Prints the pane id.
agent_pane_elsewhere() {
  tmux_test_server_run new-window -t t: -d -P -F '#{pane_id}'
}

@test "a banner is handed to notify-send with its title, message and replace hint" {
  use_libnotify_backend
  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' \
    --pane "$pane"
  assert_success
  [ -z "$stderr" ]

  wait_for_notify_send
  assert_notify_send_value message 'permission needed'
  # The title is the core's, expanded by tmux against the pane; all the backend owes it
  # is to pass it through as one argument. What it is made of belongs to notify.bats.
  assert_contains "$(notify_send_value title)" 'claude-code - ' 'the title'
  # The hint that makes a newer banner replace the older one instead of stacking, and it
  # carries the core's per-window group — so "one banner per window" is the same promise
  # here as on a Mac.
  assert_notify_send_value hint.x-canonical-private-synchronous "tmux-window-$window"
}

@test "banners replace per window: same window, same hint; another window, another" {
  use_libnotify_backend
  local first second first_hint
  first="$(agent_pane_elsewhere)"
  second="$(agent_pane_elsewhere)"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'first' --pane "$first"
  assert_success
  wait_for_notify_send
  first_hint="$(notify_send_value hint.x-canonical-private-synchronous)"

  # The same window again — a chatty agent, which is what the grouping is for.
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'again' --pane "$first"
  assert_success
  local waited=0
  while [ "$(notify_send_value message)" != 'again' ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'the second banner never reached notify-send\n' >&2
      return 1
    }
    sleep 0.05
  done
  assert_notify_send_value hint.x-canonical-private-synchronous "$first_hint"

  # A different window is a different banner, or one agent would silently take the
  # other's off the screen.
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'elsewhere' --pane "$second"
  assert_success
  waited=0
  while [ "$(notify_send_value message)" != 'elsewhere' ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'the third banner never reached notify-send\n' >&2
      return 1
    }
    sleep 0.05
  done
  if [ "$(notify_send_value hint.x-canonical-private-synchronous)" = "$first_hint" ]; then
    printf 'two windows shared a group: %s\n' "$first_hint" >&2
    return 1
  fi
}

@test "a message that begins with a dash is a message, not a flag of notify-send's" {
  use_libnotify_backend

  run "$PLUGIN_ROOT/bin/tama" notify --pane "$(agent_pane_elsewhere)" -- \
    claude-code '--urgency=critical'
  assert_success

  wait_for_notify_send
  assert_notify_send_value message '--urgency=critical'
}

@test "the libnotify backend never asks whether the user is looking" {
  use_libnotify_backend
  # tmux's half of the AND says the user is looking: they are attached, at this window.
  # There is no `focused` capability here — a desktop that can say which window is in
  # front of which is not something libnotify offers — and a missing capability means
  # deliver, never suppress. Noise, never silence (ADR-0004).
  tama_attach_client t

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' \
    --pane "$(tama_pane_of t:0)"
  assert_success
  [ -z "$stderr" ]

  wait_for_notify_send
  assert_notify_send_value message 'needed'
  # Deliberately no claim about the mark here, and not because there is none: attaching
  # a client fires `client-attached`, whose sweep clears the mark on the window the user
  # is now looking at, asynchronously and therefore in a race with the mark this notify
  # raises. Which of the two wins is timing — it was observed both ways — and the mark's
  # own behaviour is asserted where nothing is racing it, in notify.bats and below.
}

@test "the focus action of a click is a no-op that says nothing at all" {
  use_libnotify_backend

  # Bringing a terminal window forward is a window manager's business and there is no
  # portable way to ask one, so this backend ships no `focus`. The contract makes that
  # "unsupported" rather than an error, which is what the click's last step degrades to:
  # `@tama_focus_command` is where a user with wmctrl, xdotool or swaymsg wires theirs.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" focus-window t
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  refute_notify_send_started
}

@test "a banner nobody can take down still lets the mark clear on arrival" {
  use_libnotify_backend
  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  wait_for_notify_send
  assert_flagged "$window"

  # This backend ships no `dismiss` either: `notify-send` cannot take a banner back, and
  # the daemon retires it on its own timeout. So dismissing has to be a quiet nothing
  # rather than an error — and the mark, which lives in tmux and not on the desktop,
  # still comes off the moment the user arrives.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  tmux_test_server_run select-window -t "$window"
  wait_until_not_flagged "$window"
}

@test "a notify-send that is not installed is silence, not a failed turn" {
  use_libnotify_backend
  tmux_test_server_run set -g @tama_notify_send /nonexistent/notify-send

  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  # The rest of the pipeline still ran: the window is marked even though nothing on the
  # desktop said so, which is the whole of "degrade quietly".
  assert_flagged "$window"
}

@test "the libnotify backend runs under the bash macOS ships" {
  # A claim about bash 3.2 and nothing else, so it skips wherever there is no 3.2 —
  # which is every Linux runner. Everything this backend actually promises is asserted
  # by the tests above, and those run on both legs; this one is here because every script
  # in the plugin is written for the oldest bash it can meet, and a `local` or a `set --`
  # that only bash 5 accepts would otherwise be found by a user rather than by CI.
  tama_use_bash_32_or_skip
  use_libnotify_backend

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code "it's waiting" \
    --pane "$(agent_pane_elsewhere)"
  assert_success
  [ -z "$stderr" ]

  wait_for_notify_send
  assert_notify_send_value message "it's waiting"
}

@test "auto picks libnotify off a Mac where notify-send is installed" {
  refute_darwin
  # No @tama_backend at all: this is what a Linux user gets with no configuration. And no
  # @tama_notify_send either — the binary is found the way it will be found on a real
  # machine, by name, on PATH.
  use_no_configuration
  notify_send_on_path

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$(agent_pane_elsewhere)"
  assert_success

  wait_for_notify_send
  assert_notify_send_value message 'needed'
}

@test "auto picks no backend at all where notify-send is not installed" {
  refute_darwin
  # A headless box, a container, a CI runner: nothing to draw a banner with. Picking
  # `libnotify` here would mean every notification an agent reports is a process started
  # to fail, and a user with no idea why.
  use_no_configuration
  tmux_test_server_run set -g @tama_notify_send /nonexistent/notify-send

  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$stderr" ]
  refute_notify_send_started
  assert_flagged "$window"
}

@test "auto never picks libnotify on a Mac, even with notify-send installed" {
  require_darwin
  # Homebrew's glib ships a notify-send, and a Mac has no freedesktop notification daemon
  # for it to talk to. So a Mac with no terminal-notifier is silent — never a banner sent
  # into nothing, which is a failure with nowhere to look for it.
  use_no_configuration
  tmux_test_server_run set -g @tama_terminal_notifier /nonexistent/terminal-notifier
  notify_send_on_path

  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$stderr" ]
  refute_notify_send_started
  assert_flagged "$window"
}
