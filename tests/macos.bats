#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

# The macOS backend, driven through `bin/tama` like everything else, with the notifier
# replaced by a fixture that records the command line it was given.
#
# What that covers, and it is most of the backend: which flags `terminal-notifier` is
# handed, that the group `notify` raises is the group `dismiss` removes, that the click
# action survives being pasted into `-execute` — the whole notification path, without a
# banner appearing on the machine running the suite.
#
# What it cannot cover is the two answers that only a desktop can give: a terminal that
# really is frontmost showing this session, and a window really coming forward. Both are
# `osascript` talking to System Events about the user's own terminal, and there is no
# fixture for a Mac with somebody looking at it. The negative halves are here — a
# terminal application that does not exist, a session no window is showing — because
# those are the ones the plugin must get right for a user to be told anything at all.
# The positive halves are verified by hand.
#
# Nothing in this file lets the real `focus` capability run against a short session name.
# It matches terminal window titles, so a session named `t` could match a real window of
# the developer's own terminal called `notes` and raise it. Every test here either
# replaces the capability or uses a session name no real window could be called.
setup() {
  # Before the server boots: the notifier is reached from tmux hooks too, and a hook's
  # `run-shell` inherits the environment the server was started with.
  export TAMA_NOTIFIER_DIR="$BATS_TEST_TMPDIR/notifier"
  mkdir -p "$TAMA_NOTIFIER_DIR"
  : >"$TAMA_NOTIFIER_DIR/calls"

  tama_start_server
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
}

teardown() {
  tama_detach_client
  tama_kill_server
}

require_darwin() {
  [ "$(uname -s)" = 'Darwin' ] || skip 'the macOS backend needs a Mac'
}

# An unconfigured machine, for the tests about what `auto` resolves to. The helper turns
# the backend off on every test server precisely so that `auto` is never reached by
# accident; the three tests that are *about* `auto` have to put it back.
use_no_configuration() {
  test_tmux set -gu @tama_backend
}

refute_darwin() {
  [ "$(uname -s)" != 'Darwin' ] || skip 'this is about what a machine that is not a Mac does'
}

# The backend under test, with the notifier named by absolute path — which is also how a
# user with their own build of it says so.
use_macos_backend() {
  test_tmux set -g @tama_backend macos
  test_tmux set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"
}

# The plugin backgrounds the notifier on purpose — it must not cost an agent's turn — so
# every assertion about it has to be an eventual one or it is timing noise.
wait_for_notifier() {
  local waited=0
  while [ "$(wc -l <"$TAMA_NOTIFIER_DIR/calls")" -eq 0 ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'the notifier was never started\n' >&2
      return 1
    fi
    sleep 0.05
  done
}

refute_notifier_started() {
  # No waiting to do: this asserts the *absence* of a call, and the only honest way to
  # do that is to give a call that was going to happen the time to happen.
  sleep 0.5
  if [ "$(wc -l <"$TAMA_NOTIFIER_DIR/calls")" -ne 0 ]; then
    printf 'expected no notifier at all, got %s call(s)\n' \
      "$(wc -l <"$TAMA_NOTIFIER_DIR/calls")" >&2
    return 1
  fi
}

# The value the notifier was given after -<flag>.
notifier_flag() { # <flag>
  local file="$TAMA_NOTIFIER_DIR/$1"
  if [ ! -e "$file" ]; then
    printf 'the notifier was given no -%s\n' "$1" >&2
    return 1
  fi
  cat "$file"
}

assert_notifier_flag() { # <flag> <expected>
  local actual
  actual="$(notifier_flag "$1")" || return 1
  assert_equal "$actual" "$2"
}

# An agent pane in a second window, so the user is somewhere else — the ordinary case
# for a notification. Prints the pane id.
agent_pane_elsewhere() {
  test_tmux new-window -t t: -d -P -F '#{pane_id}'
}

# Runs a click action the way the desktop runs it: with none of the environment the hook
# that raised the banner had. See notify.bats — everything the click needs has to be
# baked into the command line.
run_click() { # <click command line>
  run --separate-stderr env -u TMUX -u TAMA_TMUX_ARGS TAMA_TMUX=/nonexistent/tmux \
    sh -c "$1"
}

@test "a banner is handed to terminal-notifier with its title, message and group" {
  use_macos_backend
  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(test_tmux display-message -p -t "$pane" '#{window_id}')"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' \
    --pane "$pane"
  assert_success
  [ -z "$stderr" ]

  wait_for_notifier
  assert_notifier_flag message 'permission needed'
  # The title is the core's, expanded by tmux against the pane; all the backend owes it
  # is to pass it through as one argument. What it is made of belongs to notify.bats.
  assert_contains "$(notifier_flag title)" 'claude-code - ' 'the title'
  # Grouped per window, which is what makes a second banner replace the first instead of
  # burying the screen, and what lets it be dismissed later.
  assert_notifier_flag group "tmux-window-$window"
  # And the terminal comes forward on click even if the command line does not run.
  assert_notifier_flag activate com.mitchellh.ghostty
}

@test "the macOS backend runs under the bash macOS ships" {
  # bash 3.2.57 is /bin/bash on every Mac, and a Mac is the only machine this backend
  # exists for: whatever else this claim is worth elsewhere in the suite, here it is the
  # only bash that matters. A diagnostic on stderr would be a broken backend even with
  # the right result, so this is a claim about stderr as much as about the banner.
  tama_use_bash_32_or_skip
  use_macos_backend

  local pane
  pane="$(agent_pane_elsewhere)"
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code "it's waiting" \
    --pane "$pane"
  assert_success
  [ -z "$stderr" ]

  wait_for_notifier
  assert_notifier_flag message "it's waiting"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" dismiss \
    "$(test_tmux display-message -p -t "$pane" '#{window_id}')"
  assert_success
  [ -z "$stderr" ]
}

@test "the terminal a banner activates is configuration, not a hardcoded app" {
  use_macos_backend
  test_tmux set -g @tama_terminal_bundle_id net.kovidgoyal.kitty

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$(agent_pane_elsewhere)"
  assert_success

  wait_for_notifier
  assert_notifier_flag activate net.kovidgoyal.kitty
}

@test "clicking the banner runs the click action the core composed" {
  use_macos_backend
  # The real `focus` capability is replaced for this test and only for this test: it
  # raises terminal windows by title, and this session is called `t`. Everything else
  # about the click is the real thing — the command line the core composed, pasted into
  # -execute by the backend, run with none of this suite's environment.
  local focused="$BATS_TEST_TMPDIR/focused-session"
  cat >"$BATS_TEST_TMPDIR/fake-focus" <<FOCUS
#!/bin/sh
printf '%s' "\$1" >"$focused"
FOCUS
  chmod +x "$BATS_TEST_TMPDIR/fake-focus"
  test_tmux set -g @tama_focus_command "$BATS_TEST_TMPDIR/fake-focus"

  local pane window
  pane="$(agent_pane_elsewhere)"
  test_tmux split-window -t "$pane" -d
  window="$(test_tmux display-message -p -t "$pane" '#{window_id}')"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  wait_for_notifier

  test_tmux select-window -t t:0
  assert_equal "$(test_tmux display-message -p -t "$window" '#{window_active}')" '0'

  # Exactly what terminal-notifier will run when the banner is clicked, with a PATH the
  # backend adds because launchd gives one that cannot find bash.
  run_click "$(notifier_flag execute)"
  assert_success
  [ -z "$stderr" ]

  assert_equal "$(test_tmux display-message -p -t "$window" '#{window_active}')" '1'
  assert_equal "$(test_tmux display-message -p -t "$window" '#{pane_id}')" "$pane"
  assert_equal "$(cat "$focused")" 't'
}

@test "the banner a window raised is the banner dismissing it removes" {
  use_macos_backend
  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(test_tmux display-message -p -t "$pane" '#{window_id}')"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  wait_for_notifier
  local group
  group="$(notifier_flag group)"

  run "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success

  local waited=0
  while [ ! -e "$TAMA_NOTIFIER_DIR/remove" ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || {
      printf 'the notifier was never asked to remove anything\n' >&2
      return 1
    }
    sleep 0.05
  done
  assert_notifier_flag remove "$group"
}

@test "a group named ALL never removes every notification" {
  use_macos_backend
  test_tmux set -g @tama_group_format ALL
  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(test_tmux display-message -p -t "$pane" '#{window_id}')"

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$pane"
  assert_success
  wait_for_notifier

  run "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success

  # The backend backgrounds terminal-notifier, so give a regressed invocation time to
  # reach the fixture before asserting that no global removal was requested.
  sleep 0.2
  [ ! -e "$TAMA_NOTIFIER_DIR/remove" ]
}

@test "a notifier that is not installed is silence, not a failed turn" {
  use_macos_backend
  test_tmux set -g @tama_terminal_notifier /nonexistent/terminal-notifier

  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(test_tmux display-message -p -t "$pane" '#{window_id}')"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  # The rest of the pipeline still ran: the window is marked even though nothing on the
  # desktop said so, which is the whole of "degrade quietly".
  assert_flagged "$window"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" dismiss "$window"
  assert_success
  [ -z "$stderr" ]
}

@test "auto picks the macOS backend on a Mac with a notifier on PATH" {
  require_darwin
  # No @tama_backend at all: this is what a Mac user gets with no configuration. And no
  # @tama_terminal_notifier either — the notifier is found the way it will be found on a
  # real machine, by name, on PATH.
  use_no_configuration
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cp "$PLUGIN_ROOT/tests/fixtures/fake-notifier" "$bin/terminal-notifier"
  PATH="$bin:$PATH"
  export PATH

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$(agent_pane_elsewhere)"
  assert_success

  wait_for_notifier
  assert_notifier_flag message 'needed'
}

@test "auto does not pick the macOS backend when the notifier is not installed" {
  require_darwin
  # The machine `auto` has to be right about: a Mac with no terminal-notifier. Picking
  # `macos` here would mean every capability is a process started to fail, and a user
  # with no idea why.
  use_no_configuration
  test_tmux set -g @tama_terminal_notifier /nonexistent/terminal-notifier

  local pane window
  pane="$(agent_pane_elsewhere)"
  window="$(test_tmux display-message -p -t "$pane" '#{window_id}')"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$pane"
  assert_success
  [ -z "$stderr" ]
  refute_notifier_started
  assert_flagged "$window"
}

@test "auto never picks the macOS backend off a Mac" {
  refute_darwin
  use_no_configuration
  # Off a Mac `auto` goes on to ask about `notify-send`, and this test's machine is a
  # Linux runner that may well have one. Pointed at nothing, so that what runs here is
  # the resolution and not somebody's notification daemon: `auto` landing on `libnotify`
  # is tests/linux.bats's claim to make, and it makes it against a fixture.
  test_tmux set -g @tama_notify_send /nonexistent/notify-send
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cp "$PLUGIN_ROOT/tests/fixtures/fake-notifier" "$bin/terminal-notifier"
  PATH="$bin:$PATH"
  export PATH

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$(agent_pane_elsewhere)"
  assert_success
  refute_notifier_started
}

@test "a terminal application that is not running is not a terminal you are looking at" {
  require_darwin
  use_macos_backend
  # tmux's half of the AND says the user is looking: they are attached, at this window.
  # This test is about focus suppression, so leave client-attached to its coverage in
  # gc.bats; its asynchronous on-select would race the mark asserted below.
  test_tmux set-hook -gu client-attached
  tama_attach_client t
  local window
  window="$(tama_window_id t:0)"

  # The desktop's half cannot agree, because there is no such application. Every way of
  # not knowing means deliver — that is the whole failure direction of ADR-0004, and it
  # is why this is the half worth testing without a desktop.
  test_tmux set -g @tama_terminal_app 'tama-no-such-application'

  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'needed' --pane "$(tama_pane_of t:0)"
  assert_success

  wait_for_notifier
  assert_notifier_flag message 'needed'
  assert_flagged "$window"
}

@test "focus steals a client from another session when no window is showing this one" {
  require_darwin
  use_macos_backend

  # Session names no terminal window on this machine could be called, because the real
  # `focus` capability runs here and matches window titles.
  local target="tamafocus-target-$$-$BATS_TEST_NUMBER-$RANDOM"
  local other="tamafocus-other-$$-$BATS_TEST_NUMBER-$RANDOM"
  test_tmux new-session -d -s "$target"
  test_tmux new-session -d -s "$other"
  tama_attach_client "$other"

  # No terminal window is showing the target session — nothing is showing anything, this
  # is a headless server — so level 1 finds nothing and level 2 repurposes the one
  # client there is. That it takes the window away from another session is the intended
  # behaviour: the user clicked a banner about this one.
  run "$PLUGIN_ROOT/bin/tama" focus-window "$target"
  assert_success

  local waited=0
  while [ "$(test_tmux display-message -p -t "$target" '#{session_attached}')" = '0' ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'the client was never switched to %s; clients:\n%s\n' "$target" \
        "$(test_tmux list-clients -F '#{client_tty} #{client_session}')" >&2
      return 1
    fi
    sleep 0.05
  done
  assert_equal "$(test_tmux display-message -p -t "$other" '#{session_attached}')" '0'
}
