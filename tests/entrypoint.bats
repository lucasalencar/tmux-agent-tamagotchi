#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helper

setup() {
  tama_start_server
}

teardown() {
  tama_kill_server
}

@test "loading the plugin exports its bin path as server options" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  assert_equal "$(test_tmux show -gqv @tama_bin)" "$PLUGIN_ROOT/bin/tama"
  assert_equal "$(test_tmux show -gqv @tama_bin_dir)" "$PLUGIN_ROOT/bin"
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
  first="$(test_tmux show -g | grep '^@tama_')"

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  assert_equal "$(test_tmux show -g | grep '^@tama_')" "$first"
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

@test "below the minimum tmux version it warns and wires nothing" {
  tama_use_fake_tmux 'tmux 2.9'

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  assert_equal "$(test_tmux show -gqv @tama_bin)" ""
  assert_equal "$(test_tmux show -gqv @tama_bin_dir)" ""
  run grep -q 'display-message' "$TAMA_FAKE_TMUX_LOG"
  assert_success
  run grep -q '3\.1a' "$TAMA_FAKE_TMUX_LOG"
  assert_success
}

@test "below the minimum tmux version it sets no option at all" {
  tama_use_fake_tmux 'tmux 3.0a'

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  run grep -q '^set' "$TAMA_FAKE_TMUX_LOG"
  assert_status 1
}

@test "the minimum tmux version itself is supported" {
  tama_use_fake_tmux 'tmux 3.1a'

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
