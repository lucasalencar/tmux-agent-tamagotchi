#!/usr/bin/env bats

# What the status line shows for a window: one glyph per agent pane, in pane
# order. Asserted both on the command's own output and on the format the plugin
# exports for the user to interpolate, since that is what actually runs.

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
  WINDOW="$(test_tmux display-message -p -t t '#{window_id}')"
  PANE="$(test_tmux list-panes -t t -F '#{pane_id}' | head -1)"
}

teardown() {
  tama_kill_server
}

# Reports a state on a pane the way an agent hook would.
report() {
  local pane="$1"
  shift
  run "$PLUGIN_ROOT/bin/tama" state "$@" --pane "$pane"
  assert_success
}

@test "each state has its own glyph" {
  report "$PANE" running
  assert_equal "$(tama_icons "$WINDOW")" ' ●'

  report "$PANE" waiting
  assert_equal "$(tama_icons "$WINDOW")" ' ◐'

  report "$PANE" idle
  assert_equal "$(tama_icons "$WINDOW")" ' ○'

  report "$PANE" error
  assert_equal "$(tama_icons "$WINDOW")" ' ✕'
}

@test "an idle agent with a live subagent shows the background glyph" {
  report "$PANE" subagent-start sub-1
  report "$PANE" idle

  # Not the idle glyph, which would read as finished, and not the running one.
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
}

@test "a window with two agent panes shows two glyphs, in pane order" {
  test_tmux split-window -d -t t
  local first second
  first="$(test_tmux list-panes -t t -F '#{pane_id}' | head -1)"
  second="$(test_tmux list-panes -t t -F '#{pane_id}' | tail -1)"

  report "$first" waiting
  report "$second" running
  assert_equal "$(tama_icons "$WINDOW")" ' ◐●'

  # Reversing the states reverses the glyphs, which is what makes this pane
  # order rather than an accident of the option values.
  report "$first" running
  report "$second" waiting
  assert_equal "$(tama_icons "$WINDOW")" ' ●◐'
}

@test "a pane with no agent in it contributes nothing" {
  test_tmux split-window -d -t t
  local second
  second="$(test_tmux list-panes -t t -F '#{pane_id}' | tail -1)"

  report "$second" running
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
}

@test "the icons are the window's own, not the whole server's" {
  test_tmux new-window -d -t t
  local other_window other_pane
  other_window="$(test_tmux list-windows -t t -F '#{window_id}' | tail -1)"
  other_pane="$(test_tmux list-panes -t "$other_window" -F '#{pane_id}')"

  report "$PANE" running
  report "$other_pane" waiting

  assert_equal "$(tama_icons "$WINDOW")" ' ●'
  assert_equal "$(tama_icons "$other_window")" ' ◐'
}

@test "the exported format names the window by identity, not by index" {
  # A window index is only unique within its session, and moves under
  # renumber-windows; the command also runs some moments after the format naming
  # the window was expanded. So an index would draw one session's icons onto
  # another session's window.
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  test_tmux new-session -d -s other
  local other_window other_pane
  other_window="$(test_tmux display-message -p -t other '#{window_id}')"
  other_pane="$(test_tmux list-panes -t other -F '#{pane_id}')"
  # Both are window 0 — of different sessions.
  assert_equal "$(test_tmux display-message -p -t "$WINDOW" '#{window_index}')" \
    "$(test_tmux display-message -p -t "$other_window" '#{window_index}')"

  report "$PANE" running
  report "$other_pane" waiting

  # Whichever window a bare index happened to resolve to, it cannot be both.
  assert_equal "$(tama_render_icons "$WINDOW")" ' ●'
  assert_equal "$(tama_render_icons "$other_window")" ' ◐'
}

@test "a cleared pane contributes no icon, like a pane that never ran an agent" {
  report "$PANE" running
  report "$PANE" clear

  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "a window with no agent pane contributes nothing at all, not even a space" {
  run "$PLUGIN_ROOT/bin/tama" icons "$WINDOW"
  assert_success
  assert_equal "$output" ''
  # Byte for byte, because a stray space would pad every ordinary window in the
  # status line.
  assert_equal "$("$PLUGIN_ROOT/bin/tama" icons "$WINDOW" | wc -c | tr -d ' ')" '0'
}

@test "icons for a window that is gone says nothing and exits 0" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" icons @999
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "icons rejects invocations a status line author has to fix" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" icons
  assert_usage_error

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" icons "$WINDOW" extra
  assert_usage_error
}

@test "the exported format renders the icons the way a status line would" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  report "$PANE" running

  # Not the command the test calls, but the one tmux runs: the plugin path as
  # the plugin published it, the window id substituted by tmux, and a shell
  # doing the parsing.
  assert_equal "$(tama_render_icons "$WINDOW")" ' ●'
}

@test "the exported format survives a plugin path with characters tmux eats" {
  # `#` opens a format, `%` is a strftime conversion, a space splits a word in the
  # shell tmux runs the command with, and `)` would end the job early — tmux finds
  # that paren before it expands anything, so a path inside the job cannot contain
  # one at all.
  local plugin="$BATS_TEST_TMPDIR/od#d p%th (1) qu'ote/tamagotchi"
  mkdir -p "$(dirname "$plugin")"
  tama_copy_plugin "$plugin"
  plugin="$(cd -P "$plugin" && pwd)"

  run "$plugin/tamagotchi.tmux"
  assert_success
  report "$PANE" running

  assert_equal "$(tama_render_icons "$WINDOW")" ' ●'
}

@test "the icons render under the bash macOS ships" {
  # bash 3.2 is /bin/bash on every macOS, and tmux runs this command in a shell of
  # its own — so an incompatibility here is invisible until the status line is
  # simply blank on somebody's machine.
  tama_use_bash_32_or_skip

  report "$PANE" subagent-start sub-1
  report "$PANE" idle

  # Including on stderr: a 3.2-only diagnostic would otherwise be printed into
  # the status line on every tick, on machines whose suite is green.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" icons "$WINDOW"
  assert_success
  assert_equal "$output" ' ⚙'
  [ -z "$stderr" ]
}
