#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  # This suite boots its server through the demo config rather than through the
  # helper, so it only reserves the socket name.
  tama_reserve_socket tamademo
}

teardown() {
  tama_kill_server
}

boot_demo() {
  run env "TAMA_DEMO_PLUGIN_DIR=$1" \
    tmux -L "$TAMA_SOCKET" -f "${2:-$PLUGIN_ROOT/examples/demo.tmux.conf}" \
    new-session -d -s demo
}

@test "the demo config boots a throwaway server with the plugin loaded" {
  boot_demo "$PLUGIN_ROOT"
  assert_success

  local bin
  bin="$(test_tmux show -gqv @tama_bin)"
  assert_equal "$bin" "$PLUGIN_ROOT/bin/tama"
  [ -x "$bin" ]
}

@test "the demo config finds the plugin when tmux is started from the clone" {
  cd "$PLUGIN_ROOT" || return 1
  boot_demo '' examples/demo.tmux.conf
  assert_success

  assert_equal "$(test_tmux show -gqv @tama_bin)" "$PLUGIN_ROOT/bin/tama"
}

@test "the demo status line contributes nothing for a window with no agent" {
  boot_demo "$PLUGIN_ROOT"
  assert_success

  # The demo interpolates the plugin's exported formats into the window status
  # line. With no agent pane they must expand to nothing at all — not even the
  # stray space that padding would leave.
  #
  # display-message does not run format jobs, so this sees the status line with
  # the icon command *not* run, which is exactly the case that has to leave no
  # trace either. What the command itself contributes is the test below.
  local rendered plain
  rendered="$(test_tmux display-message -p '#{E:window-status-format}')"
  plain="$(test_tmux display-message -p '#I:#W#{?window_flags,#{window_flags}, }')"
  assert_equal "$rendered" "$plain"

  tama_point_at_server
  assert_equal "$(tama_render_icons demo)" ''
}

@test "an agent reporting a state moves the icons in the demo status line" {
  boot_demo "$PLUGIN_ROOT"
  assert_success
  tama_point_at_server

  local pane
  pane="$(test_tmux list-panes -t demo -F '#{pane_id}' | head -1)"
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$pane"
  assert_success

  # The whole slice, through the config a user is told to copy: the state an
  # agent reported, drawn by the command the demo's status line runs.
  assert_equal "$(tama_render_icons demo)" ' ●'
}
