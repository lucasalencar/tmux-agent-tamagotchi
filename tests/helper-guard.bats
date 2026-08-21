#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

@test "the test tmux helper refuses the default socket" {
  local shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  ln -s /usr/bin/false "$shim/tmux"
  PATH="$shim:$PATH"
  export PATH
  TAMA_SOCKET=default

  run --separate-stderr test_tmux display-message -p '#{session_name}'

  [ "$status" -ne 0 ]
  assert_equal "$output" ''
  assert_equal "$stderr" 'refusing to use the default tmux socket in tests'
}

@test "the test teardown refuses the default socket" {
  local shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  ln -s /usr/bin/false "$shim/tmux"
  PATH="$shim:$PATH"
  export PATH
  export TMUX_TMPDIR="$BATS_TEST_TMPDIR"
  TAMA_SOCKET=default

  run --separate-stderr tama_kill_server

  [ "$status" -ne 0 ]
  assert_equal "$output" ''
  assert_equal "$stderr" 'refusing to use the default tmux socket in tests'
}
