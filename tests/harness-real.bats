#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

teardown() {
  tama_kill_server
}

@test "a real test server leaves no socket after teardown" {
  tama_start_server
  local socket="$(tama_socket_dir)/$TAMA_SOCKET"
  [ -S "$socket" ]

  tama_kill_server

  [ ! -e "$socket" ]
  TAMA_SOCKET=''
}
