#!/usr/bin/env bats

# The option reader has no subcommand to read options for yet, and no test may
# reach into a shell library, so what is pinned here is the tmux behaviour
# lib/options.sh is built on: `show -gv` fails for an option that was never set,
# and succeeds with empty output for one deliberately set to the empty string.
# That distinction is the whole reason the reader does not use -q, and it is a
# property of tmux rather than of this plugin — exactly the kind of assumption
# that breaks quietly across versions.

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
}

teardown() {
  tama_kill_server
}

@test "tmux reports an unset user option as a failure" {
  run test_tmux show -gv @tama_never_set
  [ "$status" -ne 0 ]
}

@test "tmux reports a user option set to empty as success with no value" {
  test_tmux set -g @tama_deliberately_empty ''

  run test_tmux show -gv @tama_deliberately_empty
  assert_success
  assert_equal "$output" ''
}

@test "tmux reports a user option's value verbatim" {
  test_tmux set -g @tama_configured ' * '

  run test_tmux show -gv @tama_configured
  assert_success
  assert_equal "$output" ' * '
}
