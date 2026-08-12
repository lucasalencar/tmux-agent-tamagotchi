#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
}

teardown() {
  tama_kill_server
}

@test "loading the plugin exports its bin path as tmux options" {
  run --separate-stderr "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  assert_plugin_wired "$PLUGIN_ROOT"
}

@test "loading the plugin changes nothing else about the server" {
  local before
  before="$(tama_server_state)"

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # Only its own options may differ: the plugin must not touch the status line,
  # the hooks or the key bindings the user configured. Where the exported formats
  # go in the status line is the user's decision, not the plugin's.
  local after
  after="$(tama_server_state | grep -v '^@tama_')"
  assert_equal "$after" "$(printf '%s\n' "$before" | grep -v '^@tama_')"
}

@test "loading the plugin exports the icon format for the user to interpolate" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # A format the user puts where they want it, that runs the icon command for the
  # window being drawn. Rendered rather than compared as a string, because what
  # matters is that tmux and the shell agree on what it means.
  test_tmux set -p @tama_pane_state running
  assert_equal "$(tama_render_icons t)" ' ●'
}

@test "the exported options are reachable from a tmux format" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # This is how the status line and every hook recipe will reach them, so it is
  # the observation that matters, not the scope they happen to be stored in.
  assert_equal "$(test_tmux display-message -p '#{@tama_bin}')" "$PLUGIN_ROOT/bin/tama"
}

@test "the exported bin option is a runnable absolute path" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  local bin
  bin="$(test_tmux show -gqv @tama_bin)"
  [ -x "$bin" ]
  run "$bin" version
  assert_success
}

@test "loading is idempotent across repeated source-file" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  local first
  first="$(tama_server_state)"

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  assert_equal "$(tama_server_state)" "$first"
}

@test "loading works from a clone reached through a symlink" {
  local link="$BATS_TEST_TMPDIR/linked-plugin"
  ln -s "$PLUGIN_ROOT" "$link"

  run "$link/tamagotchi.tmux"
  assert_success

  assert_plugin_wired "$PLUGIN_ROOT"
  local bin
  bin="$(test_tmux show -gqv @tama_bin)"
  [ -x "$bin" ]
}

@test "loading works from a clone at any other path" {
  local plugin="$BATS_TEST_TMPDIR/elsewhere/plugin"
  mkdir -p "$(dirname "$plugin")"
  tama_copy_plugin "$plugin"
  # The plugin reports its resolved location, and $TMPDIR is itself a symlink
  # on macOS.
  plugin="$(cd -P "$plugin" && pwd)"

  run "$plugin/tamagotchi.tmux"
  assert_success

  assert_plugin_wired "$plugin"
}

@test "an incomplete plugin directory says so and wires nothing" {
  local broken="$BATS_TEST_TMPDIR/broken"
  mkdir -p "$broken"
  cp "$PLUGIN_ROOT/tamagotchi.tmux" "$broken/"

  run --separate-stderr "$broken/tamagotchi.tmux"
  [ "$status" -ne 0 ]
  assert_stderr_contains 'not a complete plugin directory'
  assert_plugin_not_wired
}

@test "a clone whose bin/tama cannot be run wires nothing" {
  # Otherwise every hook on the machine would fail on a path that is published
  # but not runnable — an archive download or a lost mode bit.
  local plugin="$BATS_TEST_TMPDIR/no-exec"
  tama_copy_plugin "$plugin"
  chmod -x "$plugin/bin/tama"

  run --separate-stderr "$plugin/tamagotchi.tmux"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
  assert_plugin_not_wired
}

@test "below the minimum tmux version it warns, naming both versions" {
  tama_use_fake_tmux 'tmux 2.9'

  run --separate-stderr "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # The warning has to reach the user whether or not a client is attached, so it
  # goes to stderr as well as to tmux.
  assert_stderr_contains '2.9'
  assert_stderr_contains '3.1a'
  run grep -q 'too old' "$TAMA_FAKE_TMUX_LOG"
  assert_success
}

@test "the warning cannot smuggle a tmux format out of the version string" {
  # display-message expands its argument as a format, and a format can run a
  # command, so nothing derived from `tmux -V` may keep its `#`.
  tama_use_fake_tmux 'tmux 2.9#(touch "$TAMA_FAKE_TMUX_LOG.pwned")'

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  [ ! -e "$TAMA_FAKE_TMUX_LOG.pwned" ]
  run grep -q '#' "$TAMA_FAKE_TMUX_LOG"
  assert_status 1
}

@test "below the minimum tmux version it wires nothing at all" {
  local before
  before="$(tama_server_state)"

  tama_use_fake_tmux 'tmux 3.0a'
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  assert_plugin_not_wired
  assert_equal "$(tama_server_state)" "$before"
}

@test "the minimum tmux version itself is supported, and warns about nothing" {
  tama_use_fake_tmux 'tmux 3.1a'

  run --separate-stderr "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  [ -z "$stderr" ]
  assert_plugin_wired "$PLUGIN_ROOT"
  run grep -q 'display-message' "$TAMA_FAKE_TMUX_LOG"
  assert_status 1
}

@test "a version without the bugfix letter is older than one with it" {
  assert_version_rejected 'tmux 3.1'
}

@test "a later bugfix release of the minimum version is supported" {
  assert_version_supported 'tmux 3.1b'
}

@test "a two-digit minor version is compared numerically, not lexically" {
  assert_version_supported 'tmux 3.10'
}

@test "a newer major version is supported" {
  assert_version_supported 'tmux 4.0'
}

@test "an older major version is rejected" {
  assert_version_rejected 'tmux 2.8'
}

@test "a distro build with a third version component is supported" {
  assert_version_supported 'tmux 3.1.2'
}

@test "a release candidate of an old version is still rejected" {
  # The suffix must not be mistaken for a build prefix and strip the version.
  assert_version_rejected 'tmux 2.9-rc'
}

@test "a development build of a supported version is supported" {
  assert_version_supported 'tmux next-3.4'
}

@test "an unparseable tmux version is given the benefit of the doubt" {
  assert_version_supported 'tmux master'
}

@test "a tmux that cannot report its version is given the benefit of the doubt" {
  tama_use_fake_tmux ''
  export TAMA_FAKE_TMUX_FAIL_VERSION=1

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_plugin_wired "$PLUGIN_ROOT"
}
