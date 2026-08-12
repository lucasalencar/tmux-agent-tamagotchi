#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

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

  assert_equal "$(test_tmux show -gqv @tama_bin)" "$PLUGIN_ROOT/bin/tama"
  assert_equal "$(test_tmux show -gqv @tama_bin_dir)" "$PLUGIN_ROOT/bin"
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

  local bin
  bin="$(test_tmux show -gqv @tama_bin)"
  [ -x "$bin" ]
  run "$bin" version
  assert_success
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

  assert_equal "$(test_tmux show -gqv @tama_bin)" "$plugin/bin/tama"
  assert_equal "$(test_tmux show -gqv @tama_bin_dir)" "$plugin/bin"
}

@test "below the minimum tmux version it warns, naming both versions" {
  tama_use_fake_tmux 'tmux 2.9'

  run --separate-stderr "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # The warning has to reach the user whether or not a client is attached, so it
  # goes to stderr as well as to tmux.
  case "$stderr" in
    *'2.9'*'3.1a'*) ;;
    *) printf 'expected a warning naming both versions, got: %s\n' "$stderr" >&2; return 1 ;;
  esac
  run grep -q 'display-message.*2\.9.*3\.1a' "$TAMA_FAKE_TMUX_LOG"
  assert_success
}

@test "below the minimum tmux version it wires nothing at all" {
  tama_use_fake_tmux 'tmux 3.0a'

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  assert_equal "$(test_tmux show -gqv @tama_bin)" ""
  assert_equal "$(test_tmux show -gqv @tama_bin_dir)" ""
  run grep -q '^set' "$TAMA_FAKE_TMUX_LOG"
  assert_status 1
}

@test "the minimum tmux version itself is supported, and warns about nothing" {
  tama_use_fake_tmux 'tmux 3.1a'

  run --separate-stderr "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  [ -z "$stderr" ]
  assert_equal "$(test_tmux show -gqv @tama_bin)" "$PLUGIN_ROOT/bin/tama"
  run grep -q 'display-message' "$TAMA_FAKE_TMUX_LOG"
  assert_status 1
}

@test "a version without the bugfix letter is older than one with it" {
  tama_use_fake_tmux 'tmux 3.1'

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_equal "$(test_tmux show -gqv @tama_bin)" ""
}

@test "a later bugfix release of the minimum version is supported" {
  tama_use_fake_tmux 'tmux 3.1b'

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_equal "$(test_tmux show -gqv @tama_bin)" "$PLUGIN_ROOT/bin/tama"
}

@test "a two-digit minor version is compared numerically, not lexically" {
  tama_use_fake_tmux 'tmux 3.10'

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_equal "$(test_tmux show -gqv @tama_bin)" "$PLUGIN_ROOT/bin/tama"
}

@test "a distro build with a third version component is supported" {
  tama_use_fake_tmux 'tmux 3.1.2'

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_equal "$(test_tmux show -gqv @tama_bin)" "$PLUGIN_ROOT/bin/tama"
}

@test "a development build of a supported version is supported" {
  tama_use_fake_tmux 'tmux next-3.4'

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_equal "$(test_tmux show -gqv @tama_bin)" "$PLUGIN_ROOT/bin/tama"
}

@test "an unparseable tmux version is given the benefit of the doubt" {
  tama_use_fake_tmux 'tmux master'

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_equal "$(test_tmux show -gqv @tama_bin)" "$PLUGIN_ROOT/bin/tama"
}
