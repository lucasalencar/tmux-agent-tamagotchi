#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

@test "the test tmux helper refuses the default socket" {
  local shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  ln -s /usr/bin/true "$shim/tmux"
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
  ln -s /usr/bin/true "$shim/tmux"
  PATH="$shim:$PATH"
  export PATH
  export TMUX_TMPDIR="$BATS_TEST_TMPDIR"
  TAMA_SOCKET=default

  run --separate-stderr tama_kill_server

  [ "$status" -ne 0 ]
  assert_equal "$output" ''
  assert_equal "$stderr" 'refusing to use the default tmux socket in tests'
}

@test "the test client helper refuses the default socket before attaching" {
  TAMA_SOCKET=default

  run --separate-stderr tama_attach_client t

  [ "$status" -ne 0 ]
  assert_equal "$output" ''
  assert_equal "$stderr" 'refusing to use the default tmux socket in tests'
}

@test "the fake tmux refuses an invocation without an explicit server" {
  run --separate-stderr env TAMA_FAKE_TMUX_VERSION='tmux 3.4' \
    "$PLUGIN_ROOT/tests/fixtures/fake-tmux" -u -V

  [ "$status" -ne 0 ]
  assert_equal "$output" ''
  assert_equal "$stderr" 'fake tmux refused an invocation without an explicit server'
}

@test "the fake tmux setup refuses the default socket" {
  TAMA_SOCKET=default

  run --separate-stderr tama_use_fake_tmux 'tmux 3.4'

  [ "$status" -ne 0 ]
  assert_equal "$output" ''
  assert_equal "$stderr" 'refusing to use the default tmux socket in tests'
}

@test "the fake tmux executable refuses an explicit default server" {
  run --separate-stderr env TAMA_FAKE_TMUX_VERSION='tmux 3.4' \
    "$PLUGIN_ROOT/tests/fixtures/fake-tmux" -u -L default -V

  [ "$status" -ne 0 ]
  assert_equal "$output" ''
  assert_equal "$stderr" 'fake tmux refused the default server'
}
