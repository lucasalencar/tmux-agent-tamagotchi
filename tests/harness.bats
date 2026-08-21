#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/tmux" <<'FAKE_TMUX'
#!/bin/sh
case " $* " in
  *' new-session '*)
    printf 'server stdout stayed attached'
    printf 'server stderr stayed attached' >&2
    ;;
  *' kill-server '*)
    [ -z "${TAMA_FAKE_KILL_FAILURE:-}" ] || exit 1
    ;;
  *' has-session '*)
    [ -z "${TAMA_FAKE_SERVER_UNREACHABLE:-}" ] || exit 1
    ;;
  *' display-message '*'#{pid}'*)
    printf '%s' "${TAMA_FAKE_SERVER_PID:-}"
    ;;
esac
FAKE_TMUX
  chmod +x "$bin/tmux"
  PATH="$bin:$PATH"
  export PATH
}

@test "a test server cannot retain the suite output streams" {
  run --separate-stderr tama_start_server

  assert_success
  assert_equal "$output" ''
  assert_equal "$stderr" ''
}

@test "a failed kill leaves a live server's socket in place and reports it" {
  export TAMA_SOCKET=tamatest-survivor
  export TMUX_TMPDIR="$BATS_TEST_TMPDIR"
  export TAMA_FAKE_KILL_FAILURE=1
  mkdir -p "$(tama_socket_dir)"
  touch "$(tama_socket_dir)/$TAMA_SOCKET"

  run --separate-stderr tama_kill_server

  [ "$status" -ne 0 ]
  [ -e "$(tama_socket_dir)/$TAMA_SOCKET" ]
  assert_contains "$stderr" 'test tmux server survived kill-server' 'stderr'
}

@test "a successful kill that leaves the server alive is detected" {
  export TAMA_SOCKET=tamatest-survivor
  export TMUX_TMPDIR="$BATS_TEST_TMPDIR"
  mkdir -p "$(tama_socket_dir)"
  touch "$(tama_socket_dir)/$TAMA_SOCKET"

  run --separate-stderr tama_kill_server

  [ "$status" -ne 0 ]
  [ -e "$(tama_socket_dir)/$TAMA_SOCKET" ]
  assert_contains "$stderr" 'test tmux server survived kill-server' 'stderr'
}

@test "an unreachable server process must exit before its socket is removed" {
  export TAMA_SOCKET=tamatest-exiting
  export TMUX_TMPDIR="$BATS_TEST_TMPDIR"
  export TAMA_FAKE_SERVER_PID=$$
  export TAMA_FAKE_SERVER_UNREACHABLE=1
  mkdir -p "$(tama_socket_dir)"
  touch "$(tama_socket_dir)/$TAMA_SOCKET"

  run --separate-stderr tama_kill_server

  [ "$status" -ne 0 ]
  [ -e "$(tama_socket_dir)/$TAMA_SOCKET" ]
  assert_contains "$stderr" 'test tmux server survived kill-server' 'stderr'
}
