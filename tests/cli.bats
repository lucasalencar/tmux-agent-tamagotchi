#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
}

teardown() {
  tmux_test_server_stop
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

@test "a tag on this commit is the version the plugin announces" {
  # The release failure this catches is tagging v0.1.0 on a tree that still says
  # 0.1.0-dev, which nobody notices until a bug report carries the wrong version.
  #
  # It is deliberately conditional, and it is worth knowing where it does and does not
  # fire. A working tree between releases *should* say -dev, so there is nothing to assert
  # until a tag points at HEAD — which is exactly the moment a release runs the suite
  # again before pushing the tag. On CI it skips, since the checkout carries no tags, and
  # from a tarball it skips for want of git. So this is a check on the person cutting the
  # release, not a check CI performs for them.
  local tag version
  command -v git >/dev/null 2>&1 || skip 'no git'
  tag="$(git -C "$PLUGIN_ROOT" tag --points-at HEAD 2>/dev/null | grep '^v' | head -n 1)"
  [ -n "$tag" ] || skip 'no release tag points at this commit'

  run "$PLUGIN_ROOT/bin/tama" version
  assert_success
  version="${tag#v}"
  assert_equal "$output" "tama $version"
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

@test "--help stands on its own: what a hook author cannot find out elsewhere" {
  run "$PLUGIN_ROOT/bin/tama" --help
  assert_success
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

# The hook recipe as --help prints it, so what gets tested is the text users
# paste rather than a paraphrase of it.
extract_hook_recipe() {
  "$PLUGIN_ROOT/bin/tama" --help |
    sed -n '/^  \[ -n "\$TMUX" \]/,/^$/p'
}

@test "the hook recipe --help prints runs the plugin when it is loaded" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tama_shim_tmux_on_path

  run --separate-stderr sh -c "$(extract_hook_recipe)"
  assert_success
  [[ "$output" =~ ^tama\ [0-9] ]]
  [ -z "$stderr" ]
}

@test "the hook recipe --help prints stays quiet when the plugin is not loaded" {
  # A hook runs on machines where the plugin is absent, and on a tmux too old for
  # the entrypoint to have wired anything, so the recipe must not fail the
  # agent's turn there.
  tmux_test_server_run set -gu @tama_bin
  tama_shim_tmux_on_path

  run --separate-stderr sh -c "$(extract_hook_recipe)"
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

@test "a subcommand's exit status reaches the caller" {
  plugin_with_stub

  TAMA_STUB_EXIT=3 run "$PLUGIN/bin/tama" stub
  assert_status 3
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

  # An exported but empty TMUX is the same condition.
  TMUX='' run --separate-stderr "$PLUGIN/bin/tama" stub
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

@test "setup delegates to an integration helper outside tmux" {
  local config="$BATS_TEST_TMPDIR/opencode.json"
  unset TMUX

  run "$PLUGIN_ROOT/bin/tama" setup opencode "$config"
  assert_success

  run jq -e --arg plugin "$PLUGIN_ROOT/integrations/opencode/index.ts" \
    '.plugin == [$plugin]' "$config"
  assert_success
}

@test "setup rejects missing and unsafe integration names" {
  unset TMUX

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" setup
  assert_usage_error 'integration name'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" setup ../opencode
  assert_usage_error 'invalid integration name'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" setup unknown
  assert_usage_error 'no setup helper'
}

@test "a plugin directory without its libraries says so and exits non-zero" {
  local broken="$BATS_TEST_TMPDIR/broken"
  mkdir -p "$broken/bin"
  cp "$PLUGIN_ROOT/bin/tama" "$broken/bin/"

  run --separate-stderr "$broken/bin/tama" version
  [ "$status" -ne 0 ]
  assert_stderr_contains 'lib/'

  # Same for a lib/ that is there but missing a file the rest depends on.
  local partial="$BATS_TEST_TMPDIR/partial"
  tama_copy_plugin "$partial"
  rm "$partial/lib/options.sh"

  run --separate-stderr "$partial/bin/tama" version
  [ "$status" -ne 0 ]
  assert_stderr_contains 'options.sh'
}

@test "version and --help reject arguments they cannot honour" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" version --pane %1
  assert_usage_error
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" --help extra
  assert_usage_error
}

@test "the entry points parse under the bash macOS ships" {
  # bash 3.2 is /bin/bash on every macOS, and it cannot parse constructs that
  # bash 5 accepts — a whole-plugin failure that no amount of behavioural
  # testing under a modern bash can see. Only runs where such a bash exists,
  # which is why the macOS CI leg matters.
  tama_use_bash_32_or_skip

  run "$PLUGIN_ROOT/bin/tama" version
  assert_success
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_plugin_wired "$PLUGIN_ROOT"
}

@test "the dispatcher works when reached through a symlink to itself" {
  local link="$BATS_TEST_TMPDIR/tama-link"
  ln -s "$PLUGIN_ROOT/bin/tama" "$link"

  run "$link" version
  assert_success
  [[ "$output" =~ ^tama\ [0-9] ]]
}

@test "the dispatcher works through a chain of relative symlinks" {
  mkdir -p "$BATS_TEST_TMPDIR/nest"
  ln -s "$PLUGIN_ROOT/bin/tama" "$BATS_TEST_TMPDIR/first"
  # A relative target, resolved against the directory holding the link.
  ln -s ../first "$BATS_TEST_TMPDIR/nest/second"

  run "$BATS_TEST_TMPDIR/nest/second" version
  assert_success
  [[ "$output" =~ ^tama\ [0-9] ]]
}

@test "the dispatcher works from a clone whose path contains a space" {
  local plugin="$BATS_TEST_TMPDIR/my plugins/tamagotchi"
  mkdir -p "$BATS_TEST_TMPDIR/my plugins"
  tama_copy_plugin "$plugin"
  plugin="$(cd -P "$plugin" && pwd)"

  run "$plugin/bin/tama" version
  assert_success

  run "$plugin/tamagotchi.tmux"
  assert_success
  assert_plugin_wired "$plugin"

  # And the path it published is runnable as published.
  run "$(tmux_test_server_run show -gqv @tama_bin)" version
  assert_success
}
