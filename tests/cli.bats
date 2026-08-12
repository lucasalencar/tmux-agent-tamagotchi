#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helper

setup() {
  tama_start_server
}

teardown() {
  tama_kill_server
}

@test "version prints the plugin version on stdout" {
  run "$PLUGIN_ROOT/bin/tama" version
  assert_success
  assert_output_contains "tama"
  [ -n "$output" ]
}

@test "--help prints usage on stdout" {
  run "$PLUGIN_ROOT/bin/tama" --help
  assert_success
  assert_output_contains "Usage: tama"
}

@test "--help explains what the plugin does without pointing at the README" {
  run "$PLUGIN_ROOT/bin/tama" --help
  assert_success
  assert_output_contains "tmux"
  assert_output_contains "agent"
}

@test "help and -h are the same as --help" {
  run "$PLUGIN_ROOT/bin/tama" --help
  local expected="$output"
  run "$PLUGIN_ROOT/bin/tama" help
  assert_equal "$output" "$expected"
  run "$PLUGIN_ROOT/bin/tama" -h
  assert_equal "$output" "$expected"
}

@test "an unknown subcommand exits 2 with a message on stderr" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" not-a-subcommand
  assert_status 2
  [ -z "$output" ]
  case "$stderr" in
    *not-a-subcommand*) ;;
    *) printf 'expected stderr to name the bad subcommand, got: %s\n' "$stderr" >&2; return 1 ;;
  esac
}

@test "no subcommand at all exits 2 with a message on stderr" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama"
  assert_status 2
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "an unknown subcommand exits 2 even outside tmux" {
  TMUX= run --separate-stderr "$PLUGIN_ROOT/bin/tama" not-a-subcommand
  assert_status 2
  [ -n "$stderr" ]
}

@test "a subcommand is dispatched with its arguments" {
  local plugin="$BATS_TEST_TMPDIR/plugin"
  tama_copy_plugin "$plugin"
  tama_add_stub_subcommand "$plugin"

  run "$plugin/bin/tama" stub --pane %9 hello
  assert_success
  assert_output_contains "stub ran: --pane %9 hello"
}

@test "a subcommand run with no \$TMUX exits 0 silently" {
  local plugin="$BATS_TEST_TMPDIR/plugin"
  tama_copy_plugin "$plugin"
  tama_add_stub_subcommand "$plugin"

  TMUX= run --separate-stderr "$plugin/bin/tama" stub
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "version and --help work outside tmux" {
  TMUX= run "$PLUGIN_ROOT/bin/tama" version
  assert_success
  [ -n "$output" ]

  TMUX= run "$PLUGIN_ROOT/bin/tama" --help
  assert_success
  [ -n "$output" ]
}
