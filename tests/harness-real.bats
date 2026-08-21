#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

teardown() {
  tama_kill_server
}

@test "stopping a real test server removes its socket and process" {
  tama_start_server
  local socket="$(tama_socket_dir)/$TAMA_SOCKET"
  local server_pid="$TAMA_SERVER_PID"
  [ -S "$socket" ]

  tama_kill_server

  [ ! -e "$socket" ]
  ! kill -0 "$server_pid" 2>/dev/null
}
