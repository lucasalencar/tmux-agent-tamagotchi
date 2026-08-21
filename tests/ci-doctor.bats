#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

@test "the CI doctor check fails when its isolated server cannot start" {
  run env TMUX_TMPDIR=/dev/null make -C "$PLUGIN_ROOT" doctor

  [ "$status" -ne 0 ]
}

@test "the CI doctor check fails and tears down when diagnosis fails" {
  local plugin="$BATS_TEST_TMPDIR/plugin"
  tama_copy_plugin "$plugin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$plugin/libexec/doctor"
  chmod +x "$plugin/libexec/doctor"

  export TMUX_TMPDIR="$BATS_TEST_TMPDIR/tmux"
  mkdir -p "$TMUX_TMPDIR"

  run make -C "$plugin" doctor

  [ "$status" -ne 0 ]
  [ -z "$(find "$TMUX_TMPDIR" -name 'tamatest-*' -print)" ]
}
