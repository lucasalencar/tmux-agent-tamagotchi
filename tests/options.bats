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
  tmux_test_server_stop
}

@test "tmux reports an unset user option as a failure" {
  run tmux_test_server_run show -gv @tama_never_set
  [ "$status" -ne 0 ]
}

@test "tmux reports a user option set to empty as success with no value" {
  tmux_test_server_run set -g @tama_deliberately_empty ''

  run tmux_test_server_run show -gv @tama_deliberately_empty
  assert_success
  assert_equal "$output" ''
}

@test "tmux reports a user option's value with its whitespace intact" {
  # The icon prefix and the flag text are single spaces, so a reader that
  # trimmed would silently change what the status line shows.
  tmux_test_server_run set -g @tama_configured ' * '

  run tmux_test_server_run show -gv @tama_configured
  assert_success
  assert_equal "$output" ' * '
}
