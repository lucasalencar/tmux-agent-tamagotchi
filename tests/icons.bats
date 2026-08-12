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
  # `#` opens a format, `%` is a strftime conversion, and a space splits a word
  # in the shell tmux runs the command with. Whoever interpolates a path into a
  # format owns all three.
  local plugin="$BATS_TEST_TMPDIR/od#d p%th/tamagotchi"
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
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
}
