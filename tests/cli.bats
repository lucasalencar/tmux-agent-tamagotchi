#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
}

teardown() {
  tama_kill_server
}

# Sets $PLUGIN to a copy of the plugin that has one dispatchable subcommand.
plugin_with_stub() {
  PLUGIN="$BATS_TEST_TMPDIR/plugin"
  tama_copy_plugin "$PLUGIN"
  tama_add_stub_subcommand "$PLUGIN"
}

@test "version prints the plugin version on stdout" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" version
  assert_success
  [ -z "$stderr" ]
  [[ "$output" =~ ^tama\ [0-9] ]]
}

@test "--version is the same as version" {
  run "$PLUGIN_ROOT/bin/tama" version
  assert_success
  local expected="$output"
  run "$PLUGIN_ROOT/bin/tama" --version
  assert_success
  assert_equal "$output" "$expected"
}

@test "--help prints usage on stdout" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" --help
  assert_success
  [ -z "$stderr" ]
  assert_output_contains "Usage: tama"
}

@test "--help stands on its own: what the plugin does and how hooks call it" {
  run "$PLUGIN_ROOT/bin/tama" --help
  assert_success
  assert_output_contains "tmux"
  assert_output_contains "agent"
  # The three things a hook author cannot find out anywhere else.
  assert_output_contains "exit"
  assert_output_contains "TMUX"
  assert_output_contains "@tama_bin"
}

@test "help and -h are the same as --help" {
  run "$PLUGIN_ROOT/bin/tama" --help
  assert_success
  local expected="$output"
  run "$PLUGIN_ROOT/bin/tama" help
  assert_success
  assert_equal "$output" "$expected"
  run "$PLUGIN_ROOT/bin/tama" -h
  assert_success
  assert_equal "$output" "$expected"
}

@test "the hook recipe --help prints stays quiet when the plugin is not loaded" {
  run "$PLUGIN_ROOT/bin/tama" --help
  assert_success

  # A hook runs on machines where the plugin is absent, or on a tmux too old for
  # it to have wired anything, so the recipe must read the option with -gqv and
  # bail when it is empty instead of trying to run an empty path.
  assert_output_contains 'show -gqv @tama_bin'
  assert_output_contains '[ -n "$tama" ] || exit 0'

  # And the shape it prescribes has to actually behave that way.
  test_tmux set -gu @tama_bin
  run --separate-stderr sh -c '
    [ -n "$TMUX" ] || exit 0
    tama="$(tmux $TAMA_TMUX_ARGS show -gqv @tama_bin)"
    [ -n "$tama" ] || exit 0
    "$tama" version
  '
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "an unknown subcommand exits 2 with a message on stderr" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" not-a-subcommand
  assert_usage_error 'not-a-subcommand'
}

@test "the usage hint points at a path that is actually runnable" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" not-a-subcommand
  assert_usage_error "$PLUGIN_ROOT/bin/tama --help"

  # The hint is only useful if that command works.
  run "$PLUGIN_ROOT/bin/tama" --help
  assert_success
}

@test "no subcommand at all exits 2 with a message on stderr" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama"
  assert_usage_error
}

@test "a malformed option exits 2 with a message on stderr" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" --bogus
  assert_usage_error '--bogus'
}

@test "a subcommand name that reaches outside libexec exits 2" {
  plugin_with_stub

  run --separate-stderr "$PLUGIN/bin/tama" ../bin/tama version
  assert_usage_error
  run --separate-stderr "$PLUGIN/bin/tama" /bin/echo hi
  assert_usage_error
  run --separate-stderr "$PLUGIN/bin/tama" ..
  assert_usage_error
}

@test "a dotfile in libexec is not a subcommand" {
  plugin_with_stub
  cp "$PLUGIN/libexec/stub" "$PLUGIN/libexec/.hidden"

  run --separate-stderr "$PLUGIN/bin/tama" .hidden
  assert_usage_error '.hidden'
}

@test "an empty subcommand exits 2 rather than dispatching to libexec itself" {
  plugin_with_stub

  run --separate-stderr "$PLUGIN/bin/tama" ""
  assert_usage_error
}

@test "a subcommand name that is a directory exits 2" {
  plugin_with_stub
  mkdir -p "$PLUGIN/libexec/helpers"

  run --separate-stderr "$PLUGIN/bin/tama" helpers
  assert_usage_error 'helpers'
}

@test "a libexec file that is not executable exits 2" {
  plugin_with_stub
  chmod -x "$PLUGIN/libexec/stub"

  run --separate-stderr "$PLUGIN/bin/tama" stub
  assert_usage_error 'stub'
}

@test "an unknown subcommand exits 2 even outside tmux" {
  unset TMUX
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" not-a-subcommand
  assert_usage_error 'not-a-subcommand'
}

@test "a subcommand is dispatched with its arguments intact" {
  plugin_with_stub

  run "$PLUGIN/bin/tama" stub --pane %9 "two words"
  assert_success
  assert_output_contains "argc: 3"
  assert_output_contains "arg: two words"
}

@test "a subcommand is told where the plugin is" {
  plugin_with_stub

  run "$PLUGIN/bin/tama" stub
  assert_success
  assert_output_contains "plugin_dir: $(cd -P "$PLUGIN" && pwd)"
}

@test "a subcommand run with no \$TMUX exits 0 silently" {
  plugin_with_stub

  unset TMUX
  run --separate-stderr "$PLUGIN/bin/tama" stub
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "version and --help work outside tmux" {
  unset TMUX

  run "$PLUGIN_ROOT/bin/tama" version
  assert_success
  [ -n "$output" ]

  run "$PLUGIN_ROOT/bin/tama" --help
  assert_success
  [ -n "$output" ]
}

@test "a plugin directory without its libraries says so and exits non-zero" {
  local broken="$BATS_TEST_TMPDIR/broken"
  mkdir -p "$broken/bin"
  cp "$PLUGIN_ROOT/bin/tama" "$broken/bin/"

  run --separate-stderr "$broken/bin/tama" version
  [ "$status" -ne 0 ]
  assert_stderr_contains 'lib/'
}

@test "the entry points parse under the bash macOS ships" {
  # bash 3.2 is /bin/bash on every macOS, and it cannot parse constructs that
  # bash 5 accepts — a whole-plugin failure that no amount of behavioural
  # testing under a modern bash can see. Only runs where such a bash exists,
  # which is why the macOS CI leg matters.
  [ -x /bin/bash ] || skip 'no /bin/bash on this machine'
  case "$(/bin/bash --version | head -1)" in
    *'version 3.'*) ;;
    *) skip '/bin/bash is not 3.x here' ;;
  esac

  run /bin/bash "$PLUGIN_ROOT/bin/tama" version
  assert_success
  run /bin/bash "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_plugin_wired
}

@test "the dispatcher works when reached through a symlink to itself" {
  local link="$BATS_TEST_TMPDIR/tama-link"
  ln -s "$PLUGIN_ROOT/bin/tama" "$link"

  run "$link" version
  assert_success
  [[ "$output" =~ ^tama\ [0-9] ]]
}
