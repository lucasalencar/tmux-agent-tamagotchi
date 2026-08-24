#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

teardown() {
  tmux_test_server_stop
}

boot_demo() {
  local boot_status
  TAMA_DEMO_PLUGIN_DIR="$1"
  export TAMA_DEMO_PLUGIN_DIR
  tmux_test_server_start "${2:-$PLUGIN_ROOT/examples/demo.tmux.conf}" demo \
    tama_prepare_test_server_environment
  boot_status=$?
  unset TAMA_DEMO_PLUGIN_DIR
  # The demo config deliberately leaves `@tama_backend auto`, which on the developer's
  # own Mac resolves to their real notifier — and this suite reaches the dismissal path.
  # See tama_no_backend. Ignored when the boot was meant to fail.
  tama_no_backend 2>/dev/null || true
  return "$boot_status"
}

@test "the demo config boots a throwaway server with the plugin loaded" {
  boot_demo "$PLUGIN_ROOT" || return 1

  local bin
  bin="$(tmux_test_server_run show -gqv @tama_bin)"
  assert_equal "$bin" "$PLUGIN_ROOT/bin/tama"
  [ -x "$bin" ]
}

@test "the demo server records its pid for reliable teardown" {
  boot_demo "$PLUGIN_ROOT" || return 1

  [ -n "${TMUX_TEST_SERVER_PID:-}" ]
  kill -0 "$TMUX_TEST_SERVER_PID"
}

@test "the demo config finds the plugin when tmux is started from the clone" {
  cd "$PLUGIN_ROOT" || return 1
  boot_demo '' examples/demo.tmux.conf || return 1

  assert_equal "$(tmux_test_server_run show -gqv @tama_bin)" "$PLUGIN_ROOT/bin/tama"
}

@test "the demo status line contributes nothing for a window with no agent" {
  boot_demo "$PLUGIN_ROOT" || return 1

  # The demo interpolates the plugin's exported formats into the window status
  # line. With no agent pane they must expand to nothing at all — not even the
  # stray space that padding would leave.
  #
  # display-message does not run format jobs, so this sees the status line with
  # the icon command *not* run, which is exactly the case that has to leave no
  # trace either. What the command itself contributes is the test below.
  local rendered plain
  rendered="$(tmux_test_server_run display-message -p '#{E:window-status-format}')"
  plain="$(tmux_test_server_run display-message -p '#I:#W#{?window_flags,#{window_flags},}')"
  assert_equal "$rendered" "$plain"

  tama_point_at_server
  # By window id, which is what the exported format passes: naming the session would
  # let an index-based implementation pass too.
  assert_equal "$(tama_render_icons "$(tmux_test_server_run display-message -p -t demo '#{window_id}')")" ''
}

@test "an agent reporting a state moves the icons in the demo status line" {
  boot_demo "$PLUGIN_ROOT" || return 1
  tama_point_at_server

  local pane
  pane="$(tmux_test_server_run list-panes -t demo -F '#{pane_id}' | head -1)"
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$pane"
  assert_success

  # The whole slice, through the config a user is told to copy: the state an
  # agent reported, drawn by the command the demo's status line runs, for the window
  # id the format hands it.
  assert_equal "$(tama_render_icons "$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')")" ' ●'
}

@test "an agent that needs the user marks the window in the demo status line" {
  boot_demo "$PLUGIN_ROOT" || return 1
  tama_point_at_server

  local pane plain
  pane="$(tmux_test_server_run list-panes -t demo -F '#{pane_id}' | head -1)"
  # The window status line without anything of the plugin's in it, tmux's own zoom and
  # bell markers included — the same baseline the no-agent test above compares against.
  plain="$(tmux_test_server_run display-message -p -t "$pane" '#I:#W#{?window_flags,#{window_flags},}')"

  run "$PLUGIN_ROOT/bin/tama" state waiting Claude --pane "$pane"
  assert_success

  # Nobody is attached to this server, so nobody is looking at the window: the mark
  # belongs there. Read off the status line the demo config sets rather than off the
  # option, because the format doing the drawing is half of what this asserts. The
  # flag needs no job to expand, unlike the icons, so display-message does see it.
  local rendered
  rendered="$(tmux_test_server_run display-message -p -t "$pane" '#{E:window-status-format}')"
  assert_equal "$rendered" "$plain *"

  # And the user arriving clears it, which is the only thing that does.
  run "$PLUGIN_ROOT/bin/tama" on-select --window \
    "$(tmux_test_server_run display-message -p -t "$pane" '#{window_id}')"
  assert_success
  rendered="$(tmux_test_server_run display-message -p -t "$pane" '#{E:window-status-format}')"
  assert_equal "$rendered" "$plain"
}
