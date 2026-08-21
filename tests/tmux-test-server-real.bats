#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

teardown() {
  tmux_test_server_stop
}

@test "the test server interface owns one complete server lifecycle" {
  tmux_test_server_start /dev/null module

  run tmux_test_server_run display-message -p '#{session_name}'
  assert_success
  assert_equal "$output" module

  tmux_test_server_stop

  run tmux_test_server_run has-session
  [ "$status" -ne 0 ]
}

@test "stopping a real test server removes its socket and process" {
  tmux_test_server_start
  local socket="$(_tmux_test_server_socket_dir)/$TMUX_TEST_SOCKET"
  local server_pid="$TMUX_TEST_SERVER_PID"
  [ -S "$socket" ]

  tmux_test_server_stop

  [ ! -e "$socket" ]
  ! kill -0 "$server_pid" 2>/dev/null
}

@test "teardown can recover the server pid from tmux" {
  tmux_test_server_start
  local socket="$(_tmux_test_server_socket_dir)/$TMUX_TEST_SOCKET"
  local server_pid="$TMUX_TEST_SERVER_PID"
  unset TMUX_TEST_SERVER_PID

  tmux_test_server_stop

  [ ! -e "$socket" ]
  ! kill -0 "$server_pid" 2>/dev/null
}
