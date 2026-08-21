#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

@test "the CI doctor check fails when its isolated server cannot start" {
  run env -u TMUX TMUX_TMPDIR=/dev/null make -C "$PLUGIN_ROOT" doctor

  [ "$status" -ne 0 ]
}

@test "the CI doctor check fails and tears down when diagnosis fails" {
  local plugin="$BATS_TEST_TMPDIR/plugin"
  tama_copy_plugin "$plugin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'tmux -L "$TMUX_TEST_SOCKET" display-message -p "#{pid}" >"$TAMA_CI_SERVER_PID"' \
    ': >"$TAMA_CI_DOCTOR_MARKER"' 'exit 1' \
    >"$plugin/libexec/doctor"
  chmod +x "$plugin/libexec/doctor"

  export TAMA_CI_DOCTOR_MARKER="$BATS_TEST_TMPDIR/doctor-ran"
  export TAMA_CI_SERVER_PID="$BATS_TEST_TMPDIR/server-pid"
  export TMUX_TMPDIR
  TMUX_TMPDIR="$(mktemp -d /tmp/tama-ci-doctor.XXXXXX)"

  run env -u TMUX make -C "$plugin" doctor

  [ "$status" -ne 0 ]
  [ -e "$TAMA_CI_DOCTOR_MARKER" ]
  ! kill -0 "$(cat "$TAMA_CI_SERVER_PID")" 2>/dev/null
  [ -z "$(find "$TMUX_TMPDIR" ! -type d -print)" ]
  rmdir "$(_tmux_test_server_socket_dir)" "$TMUX_TMPDIR"
}
