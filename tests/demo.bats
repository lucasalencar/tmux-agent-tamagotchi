#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helper

setup() {
  # This suite boots its server through the demo config rather than through the
  # helper, so it only reserves the socket name.
  tama_reserve_socket tamademo
}

teardown() {
  tama_kill_server
}

@test "the demo config boots a throwaway server with the plugin loaded" {
  TAMA_PLUGIN_DIR="$PLUGIN_ROOT" \
    run test_tmux -f "$PLUGIN_ROOT/examples/demo.tmux.conf" new-session -d -s demo
  assert_success

  local bin
  bin="$(test_tmux show -gqv @tama_bin)"
  assert_equal "$bin" "$PLUGIN_ROOT/bin/tama"
  [ -x "$bin" ]
}

@test "the demo config finds the plugin when tmux is started from the clone" {
  cd "$PLUGIN_ROOT" || return 1
  TAMA_PLUGIN_DIR= \
    run test_tmux -f examples/demo.tmux.conf new-session -d -s demo
  assert_success

  assert_equal "$(test_tmux show -gqv @tama_bin)" "$PLUGIN_ROOT/bin/tama"
}

@test "the demo config puts the exported formats in the window status line" {
  TAMA_PLUGIN_DIR="$PLUGIN_ROOT" \
    run test_tmux -f "$PLUGIN_ROOT/examples/demo.tmux.conf" new-session -d -s demo
  assert_success

  local format
  format="$(test_tmux show -gqv window-status-format)"
  case "$format" in
    *@tama_icons*@tama_flag*) ;;
    *)
      printf 'expected the icons and flag formats, got: %s\n' "$format" >&2
      return 1
      ;;
  esac
}
