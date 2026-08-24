#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

# Doctor's exit status is part of its scriptable contract. Only `auto` resolution is
# platform-gated; explicit backends use fixtures on both CI platforms.

setup() {
  tama_start_server

  # Claude Code's settings are read from the environment and from $PWD, so both are
  # pointed somewhere this test owns. Without that the suite would read the developer's
  # own ~/.claude/settings.json and pass or fail on whatever they happen to have wired.
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  cd "$BATS_TEST_TMPDIR" || return 1
}

teardown() {
  tmux_test_server_stop
}

healthy_server() {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tmux_test_server_run set -g window-status-format '#I:#W#{E:@tama_icons}#{E:@tama_flag}'
  tmux_test_server_run set -g window-status-current-format '#I:#W#{E:@tama_icons}#{E:@tama_flag}'
  tama_use_fake_backend
}

require_darwin() {
  [ "$(uname -s)" = 'Darwin' ] || skip 'this is about what a Mac does'
}

refute_darwin() {
  [ "$(uname -s)" != 'Darwin' ] || skip 'this is about what a machine that is not a Mac does'
}

notifier_on_path() { # <name>
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cp "$PLUGIN_ROOT/tests/fixtures/fake-notifier" "$bin/$1"
  PATH="$bin:$PATH"
  export PATH
}

broken_jq_on_path() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  ln -sf /usr/bin/false "$bin/jq"
  PATH="$bin:$PATH"
  export PATH
}

# Everything the README's block wires, so a settings file can be written with one event
# left out on purpose.
CC_EVENTS='SessionStart UserPromptSubmit PostToolUse PostToolUseFailure PermissionRequest
Notification Stop StopFailure SubagentStart SubagentStop SessionEnd'

# Intentionally differs from the README formatting to model hand-merged settings.
cc_settings_without() { # <event…>
  cc_settings_into "$CLAUDE_CONFIG_DIR/settings.json" "$@"
}

cc_settings_into() { # <path> <event…>
  local target="$1" event skip_event skipped
  shift
  {
    printf '{\n  "hooks": {\n'
    for event in $CC_EVENTS; do
      skipped='no'
      for skip_event in "$@"; do
        [ "$event" != "$skip_event" ] || skipped='yes'
      done
      [ "$skipped" = 'no' ] || continue
      printf '    "%s": [{"hooks": [{"type": "command",' "$event"
      printf ' "command": "\\"$(tmux show -gqv @tama_bin 2>/dev/null)\\" hook claude-code %s >/dev/null 2>&1 || :"}]}],\n' \
        "$event"
    done
    printf '    "_": []\n  }\n}\n'
  } >"$target"
}

@test "doctor answers with no tmux server, where every other subcommand is a no-op" {
  local socket="tamadoctor-none-$$-$RANDOM"
  unset TMUX
  export TAMA_TMUX_ARGS="-L $socket"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'no tmux server is running'

  # And it did not boot one to find that out: a doctor that started a server would be
  # reporting on a server it created, and would leave the socket behind.
  [ ! -e "$(_tmux_test_server_socket_dir)/$socket" ]
}

@test "doctor says nothing is wrong when nothing is wrong, and exits 0" {
  healthy_server

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'no problems and no warnings'
  refute_output_contains 'switch-client'
}

@test "doctor reports that no label provider is configured" {
  healthy_server

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command is unset: window labels are not provided'
}

@test "doctor distinguishes an explicitly empty label provider" {
  healthy_server
  tmux_test_server_run set -g @tama_label_command ''

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command is empty: window labels are deliberately disabled'
}

@test "doctor reports an executable label provider without running it" {
  healthy_server
  local marker="$BATS_TEST_TMPDIR/provider-ran"
  local provider="$BATS_TEST_TMPDIR/label-provider"
  cat >"$provider" <<PROVIDER
#!/bin/sh
touch "$marker"
PROVIDER
  chmod +x "$provider"
  tmux_test_server_run set -g @tama_label_command "$provider"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains "@tama_label_command runs $provider"
  assert_output_contains "executable file: $provider"
  assert_output_contains "@tama_label_command runs $provider
       It runs synchronously inside the agent hook that asks for a label"
  assert_output_contains 'has no timeout'
  assert_output_contains 'no problems and no warnings'
  [ ! -e "$marker" ]
}

@test "doctor resolves the documented home-relative label provider without running it" {
  healthy_server
  export HOME="$BATS_TEST_TMPDIR/home"
  local marker="$BATS_TEST_TMPDIR/provider-ran"
  local provider="$HOME/bin/label-provider"
  mkdir -p "${provider%/*}"
  cat >"$provider" <<PROVIDER
#!/bin/sh
touch "$marker"
PROVIDER
  chmod +x "$provider"
  tmux_test_server_run set -g @tama_label_command '~/bin/label-provider'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command runs ~/bin/label-provider'
  assert_output_contains "executable file: $provider"
  [ ! -e "$marker" ]
}

@test "doctor resolves a label provider on PATH and redacts its arguments" {
  healthy_server
  local marker="$BATS_TEST_TMPDIR/provider-ran"
  local provider="$BATS_TEST_TMPDIR/bin/label-provider"
  mkdir -p "${provider%/*}"
  cat >"$provider" <<PROVIDER
#!/bin/sh
touch "$marker"
PROVIDER
  chmod +x "$provider"
  PATH="${provider%/*}:$PATH"
  export PATH
  tmux_test_server_run set -g @tama_label_command 'label-provider --token secret-value'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command runs label-provider'
  assert_output_contains "executable file: $provider"
  refute_output_contains '--token'
  refute_output_contains 'secret-value'
  [ ! -e "$marker" ]
}

@test "doctor leaves shell syntax unexecuted and does not expose its arguments" {
  healthy_server
  local marker="$BATS_TEST_TMPDIR/provider-ran"
  local provider="$BATS_TEST_TMPDIR/label provider"
  cat >"$provider" <<PROVIDER
#!/bin/sh
touch "$marker"
PROVIDER
  chmod +x "$provider"
  tmux_test_server_run set -g @tama_label_command "'$provider' --token secret-value"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command is set, but its executable cannot be checked without evaluating shell syntax'
  assert_output_contains 'has no timeout'
  refute_output_contains '--token'
  refute_output_contains 'secret-value'
  [ ! -e "$marker" ]
}

@test "doctor accepts a shell builtin as a label provider" {
  healthy_server
  tmux_test_server_run set -g @tama_label_command 'printf label'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command runs printf'
  assert_output_contains 'shell command: printf'
  assert_output_contains 'no problems and no warnings'
}

@test "doctor rejects a reserved shell word that cannot stand alone as a provider" {
  healthy_server
  tmux_test_server_run set -g @tama_label_command 'if'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains '@tama_label_command starts with if, which is not a complete shell command'
}

@test "doctor resolves builtins with the runtime shell rather than Bash" {
  sh -c 'command -v compgen >/dev/null 2>&1' &&
    skip 'this platform uses a runtime shell that also provides compgen'
  healthy_server
  tmux_test_server_run set -g @tama_label_command 'compgen'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains '@tama_label_command runs compgen, which does not resolve to an executable'
}

@test "doctor fails when a bare label provider is not on PATH" {
  healthy_server
  tmux_test_server_run set -g @tama_label_command 'tama-label-provider-that-does-not-exist'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains '@tama_label_command runs tama-label-provider-that-does-not-exist, which does not resolve to an executable'
}

@test "doctor does not guess through shell operators" {
  healthy_server
  tmux_test_server_run set -g @tama_label_command 'missing-provider || printf fallback'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command is set, but its executable cannot be checked without evaluating shell syntax'
}

@test "doctor does not guess through shell newlines" {
  healthy_server
  tmux_test_server_run set -g @tama_label_command $'missing-provider\nprintf fallback'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command is set, but its executable cannot be checked without evaluating shell syntax'
}

@test "doctor does not split control characters that the shell keeps in a word" {
  healthy_server
  tmux_test_server_run set -g @tama_label_command $'/bin/echo\rignored'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command is set, but its executable cannot be checked without evaluating shell syntax'
  refute_output_contains '@tama_label_command runs /bin/echo'
}

@test "doctor leaves environment assignments to the shell" {
  healthy_server
  tmux_test_server_run set -g @tama_label_command 'LABEL_STYLE=short label-provider'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command is set, but its executable cannot be checked without evaluating shell syntax'
  assert_output_contains 'has no timeout'
}

@test "doctor leaves relative provider paths to the hook working directory" {
  healthy_server
  local marker="$BATS_TEST_TMPDIR/provider-ran"
  local provider="$BATS_TEST_TMPDIR/label-provider"
  cat >"$provider" <<PROVIDER
#!/bin/sh
touch "$marker"
PROVIDER
  chmod +x "$provider"
  tmux_test_server_run set -g @tama_label_command './label-provider'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command runs ./label-provider, whose relative path depends on the hook working directory'
  assert_output_contains 'has no timeout'
  [ ! -e "$marker" ]
}

@test "doctor leaves providers found through a relative PATH entry to the hook working directory" {
  healthy_server
  local marker="$BATS_TEST_TMPDIR/provider-ran"
  local provider="$BATS_TEST_TMPDIR/bin/label-provider"
  mkdir -p "${provider%/*}"
  cat >"$provider" <<PROVIDER
#!/bin/sh
touch "$marker"
PROVIDER
  chmod +x "$provider"
  PATH="bin:$PATH"
  export PATH
  tmux_test_server_run set -g @tama_label_command 'label-provider'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command runs label-provider, but PATH resolved it relative to this working directory'
  [ ! -e "$marker" ]
}

@test "doctor keeps an absolute PATH match when a later entry is relative" {
  healthy_server
  local provider="$BATS_TEST_TMPDIR/absolute-bin/label-provider"
  mkdir -p "${provider%/*}" "$BATS_TEST_TMPDIR/relative-bin"
  printf '#!/bin/sh\n' >"$provider"
  chmod +x "$provider"
  PATH="${provider%/*}:relative-bin:$PATH"
  export PATH
  tmux_test_server_run set -g @tama_label_command 'label-provider'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command runs label-provider'
  assert_output_contains "executable file: $provider"
  refute_output_contains 'PATH resolved it relative'
}

@test "doctor recognizes a bare result selected through an empty PATH entry" {
  healthy_server
  local provider="$BATS_TEST_TMPDIR/label-provider"
  printf '#!/bin/sh\n' >"$provider"
  chmod +x "$provider"
  PATH=":$PATH"
  export PATH
  [ "$(sh -c 'command -v "$1"' _ label-provider)" = 'label-provider' ] ||
    skip 'this shell reports an absolute path for empty PATH entries'
  tmux_test_server_run set -g @tama_label_command 'label-provider'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command runs label-provider, but PATH resolved it relative to this working directory'
}

@test "doctor does not reject a home-relative provider when HOME is unavailable" {
  healthy_server
  tmux_test_server_run set -g @tama_label_command '~/bin/label-provider'
  unset HOME

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_label_command runs ~/bin/label-provider, but this shell has no HOME to resolve it'
  assert_output_contains 'has no timeout'
}

@test "doctor fails when the configured label provider does not exist" {
  healthy_server
  local provider="$BATS_TEST_TMPDIR/missing-label-provider"
  tmux_test_server_run set -g @tama_label_command "$provider"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains "@tama_label_command runs $provider, which does not resolve to an executable"
  assert_output_contains '1 problem'
}

@test "doctor fails when the configured label provider is not executable" {
  healthy_server
  local provider="$BATS_TEST_TMPDIR/label-provider"
  printf '#!/bin/sh\n' >"$provider"
  chmod -x "$provider"
  tmux_test_server_run set -g @tama_label_command "$provider"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains "@tama_label_command runs $provider, which is not an executable file"
  assert_output_contains '1 problem'
}

@test "doctor fails when the configured label provider is a directory" {
  healthy_server
  local provider="$BATS_TEST_TMPDIR/label-provider"
  mkdir "$provider"
  tmux_test_server_run set -g @tama_label_command "$provider"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains "@tama_label_command runs $provider, which is not an executable file"
}

@test "doctor warns about an invalid session summary scope and uses current fallback" {
  healthy_server
  local target
  target="$(tmux_test_server_run display-message -p -t t '#{session_id}')"
  tmux_test_server_run set-option -t "$target" @tama_summary_scope everywhere

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_summary_scope'
  assert_output_contains 'everywhere'
  assert_output_contains 'current'
  assert_output_contains 'no problems and 1 warning'
}

@test "doctor warns successfully about every invalid summary bucket policy and its fallback" {
  healthy_server
  tmux_test_server_run set -g @tama_summary_show_running sometimes
  tmux_test_server_run set -g @tama_summary_show_waiting sometimes
  tmux_test_server_run set -g @tama_summary_show_idle sometimes
  tmux_test_server_run set -g @tama_summary_show_background sometimes
  tmux_test_server_run set -g @tama_summary_show_error sometimes
  tmux_test_server_run set -g @tama_summary_show_unknown sometimes

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_summary_show_running'
  assert_output_contains '@tama_summary_show_waiting'
  assert_output_contains '@tama_summary_show_idle'
  assert_output_contains '@tama_summary_show_background'
  assert_output_contains '@tama_summary_show_error'
  assert_output_contains '@tama_summary_show_unknown'
  assert_output_contains "'sometimes'"
  assert_output_contains 'always'
  assert_output_contains 'nonzero'
  assert_output_contains 'no problems and 6 warnings'
}

@test "a tmux older than the minimum is broken and exits non-zero" {
  healthy_server
  tama_use_fake_tmux '3.0'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'tmux 3.0 is older than the minimum'
  assert_output_contains 'something here is broken'
}

@test "a tmux that cannot say its version at all is broken" {
  healthy_server
  tama_use_fake_tmux '3.7'
  export TAMA_FAKE_TMUX_FAIL_VERSION=1

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'no tmux'
}

@test "a server the plugin was never loaded into is broken" {
  # A bare test server: tamagotchi.tmux has not run, so @tama_bin is unset and every
  # hook recipe and the icon format have nothing to find the plugin by.
  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains '@tama_bin is not set'
}

@test "a status line that never asks for the icons is a warning, not a failure" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tama_use_fake_backend

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'window-status-format mentions neither @tama_icons nor @tama_flag'
  assert_output_contains 'window-status-current-format mentions neither'
}

@test "a status line carrying only the flag's text is not a status line drawing the flag" {
  # `@tama_flag_text` is the text *inside* the flag, and it draws on every window
  # unconditionally; `@tama_flag` is the option gated on the mark. A substring search
  # for the shorter name found the longer one and reported the flag as correctly drawn,
  # which is a false ok on one of the two commonest "nothing appears" symptoms — and it
  # sends the user looking anywhere but at their status line.
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tama_use_fake_backend
  tmux_test_server_run set -g window-status-format '#I:#W#{E:@tama_icons}#{E:@tama_flag_text}'
  tmux_test_server_run set -g window-status-current-format '#I:#W#{E:@tama_icons}#{E:@tama_flag}'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'window-status-format does not mention @tama_flag'
  refute_output_contains 'window-status-format draws both'
  # And the format that really does draw it is still recognised, so the boundary did not
  # simply stop matching everything.
  assert_output_contains 'window-status-current-format draws both'
}

@test "a status line set on the session is read, not the global one it overrides" {
  # Both formats are inherited: a value on the session — or on one window — is what tmux
  # draws that window from, and `show -gv` never sees it. Reading only the global table
  # told a user who configures them per session that their status line "mentions neither
  # @tama_icons nor @tama_flag" while the icons were on the screen in front of them.
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tama_use_fake_backend
  tmux_test_server_run set -g window-status-format '#I:#W'
  tmux_test_server_run set -g window-status-current-format '#I:#W'
  tmux_test_server_run set -t t window-status-format '#I:#W#{E:@tama_icons}#{E:@tama_flag}'
  tmux_test_server_run set -t t window-status-current-format '#I:#W#{E:@tama_icons}#{E:@tama_flag}'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'window-status-format draws both'
  assert_output_contains 'window-status-current-format draws both'
  refute_output_contains 'mentions neither'
  # And it says the value it read is not the global one, because the setup section below
  # tells the user to paste `set -g` lines that this server would then override.
  assert_output_contains 'That is the value in force on t:'
  assert_output_contains '`set -g window-status-format` holds something else'
}

@test "a status line with the icons on only one of the two formats says which one" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tama_use_fake_backend
  tmux_test_server_run set -g window-status-format '#I:#W#{E:@tama_icons}#{E:@tama_flag}'
  tmux_test_server_run set -g window-status-current-format '#I:#W'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'window-status-format draws both'
  assert_output_contains 'window-status-current-format mentions neither'
}

@test "a hook carrying only a stale recipe is not a hook that is wired" {
  # doctor decided the question by looking for the option name `@tama_bin` anywhere in
  # `show-hooks -g`, while the entrypoint decides it by the whole recipe. So a server
  # carrying a recipe from an earlier version of this plugin — same option, a command
  # since renamed or given different arguments — was reported as "the plugin's tmux hooks
  # are wired in this server" while those hooks did something else or nothing.
  healthy_server
  local event
  for event in after-select-window after-select-pane client-focus-in client-session-changed client-attached; do
    tmux_test_server_run set-hook -gu "$event" 2>/dev/null || true
    tmux_test_server_run set-hook -ga "$event" "run-shell -b '#{q:@tama_bin} sweep --everything'"
  done

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'name @tama_bin but not what this version runs'
  refute_output_contains "the plugin's tmux hooks are wired in this server"
}

@test "hooks wired for some events and not others say which are missing" {
  healthy_server
  tmux_test_server_run set-hook -gu client-session-changed 2>/dev/null || true

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'only partly wired: client-session-changed'
  refute_output_contains "the plugin's tmux hooks are wired in this server"
}

@test "an empty @tama_backend is a configuration and not a fault" {
  healthy_server
  tmux_test_server_run set -g @tama_backend ''

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'every capability is off, deliberately'
}

@test "a backend the user named that is not there is broken" {
  healthy_server
  tmux_test_server_run set -g @tama_backend "$BATS_TEST_TMPDIR/no-such-backend"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'which is not a directory'
}

@test "a backend name that would reach outside backends/ is broken" {
  healthy_server
  tmux_test_server_run set -g @tama_backend '../../etc'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'cannot name a backend'
}

@test "naming the macos backend without its notifier is broken, where auto would not have been" {
  healthy_server
  tmux_test_server_run set -g @tama_backend macos
  tmux_test_server_run set -g @tama_terminal_notifier "$BATS_TEST_TMPDIR/no-such-notifier"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'named the macos backend and its notifier is missing'
  assert_output_contains 'used as given or not at all'
}

@test "a clone path with glob characters in it still gets the shipped-backend checks" {
  # The two checks a shipped backend gets — its binary, and for libnotify the session bus
  # — are reached through a `case` whose patterns are built from $TAMA_PLUGIN_DIR. A
  # `case` pattern is a glob, so a clone at a path holding `[`, `*` or `?` reads like one
  # that would silently skip both: not fail them, not run them.
  #
  # It does not, because those patterns are wholly double-quoted and quoting makes a
  # pattern literal. This test is here so that stays true: unquoting them, or rebuilding
  # them with an interpolation that is not quoted, turns a diagnosis into a silence, and a
  # silence is exactly what nobody notices.
  healthy_server
  local plugin="$BATS_TEST_TMPDIR/clo[n]e*?/plugin"
  mkdir -p "$(dirname "$plugin")"
  tama_copy_plugin "$plugin"
  plugin="$(cd -P "$plugin" && pwd)"

  run "$plugin/tamagotchi.tmux"
  assert_success
  tmux_test_server_run set -g @tama_backend libnotify
  tmux_test_server_run set -g @tama_notify_send "$BATS_TEST_TMPDIR/no-such-notify-send"
  unset DBUS_SESSION_BUS_ADDRESS

  run "$plugin/bin/tama" doctor
  assert_status 1
  assert_output_contains 'named the libnotify backend and its binary is missing'
  assert_output_contains 'DBUS_SESSION_BUS_ADDRESS is not set'
}

@test "the resolved notifier is reported with the path it came from: an option" {
  healthy_server
  tmux_test_server_run set -g @tama_backend macos
  tmux_test_server_run set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_output_contains "terminal-notifier: $PLUGIN_ROOT/tests/fixtures/fake-notifier"
  assert_output_contains 'named outright by @tama_terminal_notifier'
}

@test "the resolved notifier is reported with the path it came from: PATH" {
  healthy_server
  tmux_test_server_run set -g @tama_backend macos
  notifier_on_path terminal-notifier

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_output_contains "terminal-notifier: $BATS_TEST_TMPDIR/bin/terminal-notifier"
  assert_output_contains 'found on $PATH'
}

@test "the capabilities a backend ships are reported, and so is what each absence costs" {
  healthy_server
  tmux_test_server_run set -g @tama_backend "$(tama_fake_backend_without focused)"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'capabilities: notify dismiss focus'
  assert_output_contains 'no focused: nothing is ever suppressed'
}

@test "a capability replaced by the user's own command says the backend is not consulted" {
  healthy_server
  tmux_test_server_run set -g @tama_notify_command '/bin/echo'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_notify_command replaces the notify capability'
  assert_output_contains 'The backend is not consulted for those'
}

@test "an override's arguments are not printed, because this output is for pasting" {
  # These options are complete command lines for talking to a notification service, and
  # a `curl` at a Pushover or a Slack webhook carries its token inline. The whole point
  # of this command's output is that it gets pasted into a bug report, so printing the
  # value verbatim put a credential in it. The program is enough to notice that the
  # backend diagnosis above is beside the point, and to notice a hijacked option.
  healthy_server
  tmux_test_server_run set -g @tama_notify_command \
    'curl -s -F token=s3cr3t-app-token -F user=s3cr3t-user https://api.pushover.net/1/messages.json -F message'
  tmux_test_server_run set -g @tama_dismiss_command '/usr/bin/env SLACK_TOKEN=xoxb-s3cr3t /bin/true'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  # Nothing after the program name.
  refute_output_contains 's3cr3t'
  refute_output_contains 'xoxb-'
  refute_output_contains 'api.pushover.net'
  # And the program name itself, so the check still does the job it is here for.
  assert_output_contains 'runs curl'
  assert_output_contains 'runs /usr/bin/env'
  assert_output_contains 'usually has a'
}

@test "a named backend whose binary is missing is broken while any capability still needs it" {
  # The macOS backend ships all four capabilities, so replacing `notify` leaves dismiss,
  # focused and focus still starting a process that is not there. That is a promise this
  # configuration cannot keep, and ADR-0007 calls it broken.
  healthy_server
  tmux_test_server_run set -g @tama_backend macos
  tmux_test_server_run set -g @tama_terminal_notifier "$BATS_TEST_TMPDIR/no-such-notifier"
  tmux_test_server_run set -g @tama_notify_command '/bin/echo'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'named the macos backend and its notifier is missing'
  assert_output_contains 'is not replaced by a @tama_…_command below is a process'
}

@test "a named backend every capability of which is replaced is not broken, and exits 0" {
  # The defect this is here for: `@tama_notify_command` is the documented way to replace
  # the notifier wholesale, and lib/backend.sh answers it without consulting the backend
  # at all. doctor failed anyway, so a working, supported configuration made
  # `tama doctor` exit 1 — which is precisely the "usable as a CI check" criterion
  # ADR-0007 gives for the exit status, failing on its own terms.
  #
  # The libnotify backend ships `notify` and nothing else, so one override really does
  # cover everything it can do.
  healthy_server
  tmux_test_server_run set -g @tama_backend libnotify
  tmux_test_server_run set -g @tama_notify_send "$BATS_TEST_TMPDIR/no-such-notify-send"
  tmux_test_server_run set -g @tama_notify_command '/bin/echo'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  # Still said out loud — the user wants to know the shipped backend is unusable — but as
  # something worth knowing rather than as something broken.
  assert_output_contains 'named the libnotify backend and its binary is missing'
  assert_output_contains 'every capability this backend ships is replaced'
  refute_output_contains 'something here is broken'
}

@test "that same backend without the override is broken, so the check is still there" {
  # The other direction of the test above. Without it, a fix that simply stopped failing
  # on a missing binary would pass both.
  healthy_server
  tmux_test_server_run set -g @tama_backend libnotify
  tmux_test_server_run set -g @tama_notify_send "$BATS_TEST_TMPDIR/no-such-notify-send"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'named the libnotify backend and its binary is missing'
  assert_output_contains 'something here is broken'
}

# --- what `auto` chose, and why ---------------------------------------------------

@test "auto on a Mac with no notifier says so, and how to fix it" {
  require_darwin
  healthy_server
  tmux_test_server_run set -gu @tama_backend
  # A name that is on no PATH and in neither Homebrew prefix, which is the same machine
  # state as not having installed it — and one this suite can produce on a developer's
  # Mac, where the real notifier is installed.
  tmux_test_server_run set -g @tama_terminal_notifier 'terminal-notifier-absent'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'backend: none'
  assert_output_contains "This is a Mac, so 'auto' wants the macos backend"
  assert_output_contains 'not on $PATH and not in /opt/homebrew/bin /usr/local/bin'
}

@test "auto on a Mac that does have notify-send says why it was not picked" {
  require_darwin
  healthy_server
  tmux_test_server_run set -gu @tama_backend
  tmux_test_server_run set -g @tama_terminal_notifier 'terminal-notifier-absent'
  notifier_on_path notify-send

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'You do have notify-send here'
  assert_output_contains 'macOS has no freedesktop notification daemon'
  assert_output_contains 'This is not a bug'
}

@test "auto off a Mac with no notify-send says which binary it wanted and where it looked" {
  refute_darwin
  healthy_server
  tmux_test_server_run set -gu @tama_backend
  tmux_test_server_run set -g @tama_notify_send 'notify-send-absent'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'backend: none'
  assert_output_contains "This is not a Mac, so 'auto' asks about notify-send"
  assert_output_contains 'not on $PATH and not in /usr/bin /usr/local/bin'
}

@test "a notifier option naming a path that is not there is never searched for by name" {
  # The fourth way `auto` reaches `none`, and the one that surprises: a path the user
  # gave is used as given or not at all, so a typo in it is silence rather than a
  # fallback to the perfectly good binary on PATH. Both options are set, so this is the
  # same assertion on either platform.
  healthy_server
  tmux_test_server_run set -gu @tama_backend
  notifier_on_path terminal-notifier
  notifier_on_path notify-send
  tmux_test_server_run set -g @tama_terminal_notifier "$BATS_TEST_TMPDIR/nowhere/terminal-notifier"
  tmux_test_server_run set -g @tama_notify_send "$BATS_TEST_TMPDIR/nowhere/notify-send"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'backend: none'
  assert_output_contains 'which is not an executable file'
  assert_output_contains 'used as given or not at all'
}

# --- focus -------------------------------------------------------------------------

@test "the focus diagnosis does not claim a bundle id controls the click" {
  healthy_server
  tmux_test_server_run set -g @tama_backend macos
  tmux_test_server_run set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"
  tmux_test_server_run set -g @tama_terminal_app Ghostty
  tmux_test_server_run set -g @tama_terminal_bundle_id net.kovidgoyal.kitty

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'terminal: Ghostty (@tama_terminal_app)'
  refute_output_contains 'bundle id'
}

@test "a title configuration the focus check cannot match warns, and says it fails toward noise" {
  healthy_server
  tmux_test_server_run set -g @tama_backend macos
  tmux_test_server_run set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"
  tmux_test_server_run set -g set-titles off

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'set-titles is'
  assert_output_contains 'extra banners, never missing ones'
  assert_output_contains 'terminal window cannot be raised for the session'
  assert_output_contains "set -g set-titles-string '#S'"
}

@test "a set-titles-string that merely contains the session name is not enough" {
  healthy_server
  tmux_test_server_run set -g @tama_backend macos
  tmux_test_server_run set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"
  tmux_test_server_run set -g set-titles on
  tmux_test_server_run set -g set-titles-string '#S:#I:#W'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'which is not the session name alone'
  assert_output_contains 'for equality, not containment'
}

@test "the title configuration the backend needs is accepted" {
  healthy_server
  tmux_test_server_run set -g @tama_backend macos
  tmux_test_server_run set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"
  tmux_test_server_run set -g set-titles on
  tmux_test_server_run set -g set-titles-string '#S'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains "set-titles is on and set-titles-string is '#S'"
}

@test "the macOS focus diagnosis explains the fallback it cannot predict" {
  healthy_server
  tmux_test_server_run set -g @tama_backend macos
  tmux_test_server_run set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"
  tmux_test_server_run set -g set-titles on
  tmux_test_server_run set -g set-titles-string '#S'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'terminal window cannot be raised for the session'
  assert_output_contains 'no title'
  assert_output_contains 'macOS automation fails'
  assert_output_contains 'switch-client'
  assert_output_contains 'if one exists'
  assert_output_contains 'an arbitrary client attached to another session'
  assert_output_contains 'cannot predict which client a future click would choose'
}

@test "auto-selected macOS focus gets the fallback diagnosis" {
  require_darwin
  healthy_server
  tmux_test_server_run set -gu @tama_backend
  notifier_on_path terminal-notifier

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'backend: macos'
  assert_output_contains 'the focus action'
  assert_output_contains 'terminal window cannot be raised for the session'
}

@test "a focus override does not inherit the macOS backend fallback diagnosis" {
  healthy_server
  tmux_test_server_run set -g @tama_backend macos
  tmux_test_server_run set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"
  tmux_test_server_run set -g @tama_focus_command '/bin/true'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_focus_command replaces the focus capability'
  refute_output_contains 'terminal window cannot be raised for the session'
  refute_output_contains 'switch-client'
}

@test "a non-executable macOS focus capability has no fallback to diagnose" {
  healthy_server
  local plugin="$BATS_TEST_TMPDIR/plugin"
  tama_copy_plugin "$plugin"
  chmod -x "$plugin/backends/macos/focus"
  run "$plugin/tamagotchi.tmux"
  assert_success
  tmux_test_server_run set -g @tama_backend macos
  tmux_test_server_run set -g @tama_terminal_notifier "$plugin/tests/fixtures/fake-notifier"

  run "$plugin/bin/tama" doctor
  assert_success
  assert_output_contains 'no focus: a click selects the window and the pane but does not'
  refute_output_contains 'terminal window cannot be raised for the session'
  refute_output_contains 'switch-client'
}

@test "suppression turned off is reported as the deliberate thing it is" {
  healthy_server
  tmux_test_server_run set -g @tama_backend macos
  tmux_test_server_run set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"
  tmux_test_server_run set -g @tama_suppress_when_focused off
  tmux_test_server_run set -g set-titles off

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'every banner is delivered'
  assert_output_contains 'terminal window cannot be raised for the session'
  assert_output_contains 'terminal: ghostty (@tama_terminal_app)'
  assert_output_contains "set-titles is 'off', so focus cannot reliably find the session's window"
  assert_output_contains 'may therefore reach the switch-client fallback described above'
  assert_output_contains "set -g set-titles-string '#S'"
}

@test "doctor reads a flag option the way the rest of the plugin reads it" {
  # doctor's job is to say what the plugin *would* do, so it must not have a second
  # opinion about what a value means. It used to: three sites here compared against
  # `on` by hand, so `@tama_manage_hooks no` reported hooks as managed while the
  # entrypoint wired them — and `@tama_notifications false` reported banners as on
  # while lib/notify.sh agreed, which is the same defect pointing the other way.
  local spelling
  for spelling in $TAMA_OFF_SPELLINGS; do
    healthy_server
    tmux_test_server_run set -g @tama_notifications "$spelling"
    tmux_test_server_run set -g @tama_suppress_when_focused "$spelling"
    tmux_test_server_run set -g @tama_manage_hooks "$spelling"

    run "$PLUGIN_ROOT/bin/tama" doctor
    assert_success || return 1
    assert_output_contains '@tama_notifications is off' || return 1
    assert_output_contains 'every banner is delivered' || return 1
    assert_output_contains '@tama_manage_hooks is off' || return 1
  done
}

@test "doctor does not report a flag option as off when it is on" {
  local spelling
  for spelling in $TAMA_ON_SPELLINGS; do
    healthy_server
    tmux_test_server_run set -g @tama_notifications "$spelling"
    tmux_test_server_run set -g @tama_suppress_when_focused "$spelling"
    tmux_test_server_run set -g @tama_manage_hooks "$spelling"

    run "$PLUGIN_ROOT/bin/tama" doctor
    assert_success || return 1
    assert_output_contains '@tama_notifications is on' || return 1
    refute_output_contains 'every banner is delivered' || return 1
    refute_output_contains '@tama_manage_hooks is off' || return 1
  done
}

@test "libnotify diagnoses its session bus without macOS focus guidance" {
  healthy_server
  tmux_test_server_run set -g @tama_backend libnotify
  tmux_test_server_run set -g @tama_notify_send "$PLUGIN_ROOT/tests/fixtures/fake-notify-send"
  unset DBUS_SESSION_BUS_ADDRESS

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'DBUS_SESSION_BUS_ADDRESS is not set'
  assert_output_contains 'every banner fails silently'
  refute_output_contains 'terminal:'
  refute_output_contains 'bundle id'
  refute_output_contains 'The macOS backend identifies the application'
}

# --- Claude Code -------------------------------------------------------------------

@test "settings that drop the Notification event are called out by name" {
  healthy_server
  cc_settings_without Notification

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'the Notification event is NOT wired'
  assert_output_contains 'total loss of banners'
  # And what the symptom looks like, which is the whole reason it is checked by name: a
  # permission prompt that moves the icon and never says anything.
  assert_output_contains 'moves the icon and marks the window and never says a word'
}

@test "settings that wire every event say nothing is missing" {
  healthy_server
  cc_settings_without

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'the Notification event is wired'
  assert_output_contains 'no problems and no warnings'
}

@test "wired Claude Code hooks require a working jq" {
  healthy_server
  cc_settings_without
  broken_jq_on_path

  run "$PLUGIN_ROOT/bin/tama" doctor

  assert_status 1
  assert_output_contains 'jq is not available'
  assert_output_contains 'brew install jq'
  assert_output_contains 'apt-get install jq'
  assert_output_contains 'something here is broken'
}

@test "an event is wired only by the canonical command" {
  healthy_server
  mkdir -p "$CLAUDE_CONFIG_DIR"
  local canonical
  canonical='\"$(tmux show -gqv @tama_bin 2>/dev/null)\" hook claude-code Notification >/dev/null 2>&1 || :'

  local command
  for command in \
    'tama hook claude-code Notification' \
    "prefix $canonical" \
    "$canonical; false"; do
    printf '{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' \
      "$command" >"$CLAUDE_CONFIG_DIR/settings.json"

    run "$PLUGIN_ROOT/bin/tama" doctor
    assert_success
    assert_output_contains 'the Notification event is NOT wired'
  done
}

@test "a missing event other than Notification says what it costs" {
  healthy_server
  cc_settings_without Stop SubagentStop

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'the Stop event is not wired: no banner when a turn ends'
  assert_output_contains 'the SubagentStop event is not wired: no background icon'
}

@test "one event name being a prefix of another does not confuse either" {
  # The trap in the direction that costs a user something: with PostToolUse dropped and
  # PostToolUseFailure kept, a check that searched for the bare name would find it
  # inside the longer one and report a hook as wired that is not. Silence about a real
  # gap is worse than either message.
  healthy_server
  cc_settings_without PostToolUse

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_output_contains 'the PostToolUse event is not wired'
  refute_output_contains 'the PostToolUseFailure event is not wired'

  # And the other way round, which is the one that would report a gap twice.
  cc_settings_without PostToolUseFailure
  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_output_contains 'the PostToolUseFailure event is not wired'
  refute_output_contains 'the PostToolUse event is not wired'
}

@test "a machine with no Claude Code settings at all is not a broken machine" {
  healthy_server
  broken_jq_on_path

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'no Claude Code settings file found'
  refute_output_contains 'jq is not available'
}

@test "a project's settings are found from a subdirectory of it, not only from its root" {
  # Claude Code reads a project's `.claude/settings.local.json` at the root of the git
  # repository, "resolved through worktrees to the main checkout, so one file covers
  # sessions started in any subdirectory or worktree of the repository"
  # (code.claude.com/docs/en/settings). Reading only $PWD/.claude therefore reported a
  # fully wired project as having nothing wired, for anybody who ran this from a
  # subdirectory — which is most of the time.
  healthy_server

  # The physical path, because git answers with one and the assertion compares strings:
  # on a Mac $BATS_TEST_TMPDIR lives under a symlinked /var.
  local project
  project="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/project"
  mkdir -p "$project/.claude" "$project/src/deep"
  git -C "$project" init -q
  cc_settings_into "$project/.claude/settings.local.json"
  cd "$project/src/deep" || return 1

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains "read: $project/.claude/settings.local.json"
  assert_output_contains 'the Notification event is wired'
  refute_output_contains 'no Claude Code settings file found'
}

@test "a directory that is no git repository is still read for its own settings" {
  # The other side of the rule above: outside a repository Claude Code keeps the file in
  # the directory the session started in, so $PWD stays part of the answer.
  healthy_server

  local project
  project="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/loose"
  mkdir -p "$project/.claude"
  cc_settings_into "$project/.claude/settings.json"
  cd "$project" || return 1

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains "read: $project/.claude/settings.json"
}

@test "with no HOME there is no /.claude, in what it looked at or in what it hands over" {
  # $HOME unset is rare and real — a launchd agent, a `su` without `-`, a container — and
  # `${HOME:-}/.claude` printed a confident `/.claude` in both the line saying where
  # doctor looked and the recipe it tells the user to paste. A wrong path costs more than
  # a missing one, especially in a recipe.
  healthy_server

  run env -u HOME -u CLAUDE_CONFIG_DIR "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  refute_output_contains ' /.claude'
  assert_output_contains '$HOME is not set in this shell'
  assert_output_contains '$HOME/.claude/settings.json'
}

# --- the setup recipe ---------------------------------------------------------------

@test "the recipe carries the real absolute path of this clone" {
  healthy_server

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_output_contains "run-shell '$PLUGIN_ROOT/tamagotchi.tmux'"
  assert_output_contains "$PLUGIN_ROOT/integrations/claude-code/README.md"
}

@test "every tmux line the recipe prints is one tmux accepts" {
  healthy_server

  # Sourced the way a user would paste it into tmux.conf, rather than eyeballed: a
  # snippet tmux refuses is a recipe that costs somebody an afternoon.
  local conf="$BATS_TEST_TMPDIR/recipe.conf"
  "$PLUGIN_ROOT/bin/tama" doctor | sed -n 's/^ *\(set -g .*\)$/\1/p' >"$conf"
  [ -s "$conf" ]

  run tmux_test_server_run source-file "$conf"
  assert_success

  # And what it told the user to paste is what the entrypoint really exports.
  assert_contains "$(tmux_test_server_run show -gv window-status-format)" '@tama_icons' 'the snippet'
  assert_contains "$(tmux_test_server_run show -gv window-status-current-format)" '@tama_flag' 'the snippet'
  assert_equal "$(tmux_test_server_run show -gv set-titles-string)" '#S'
}

@test "the hook block doctor prints is the block the README documents" {
  healthy_server

  # Every hook line doctor prints has to appear verbatim in the README, and the README
  # must wire no event doctor does not. Two lists of Claude Code events drifting apart
  # would mean the command that tells you what is missing is checking for something the
  # documentation never told you to add.
  local readme="$PLUGIN_ROOT/integrations/claude-code/README.md" line
  while IFS= read -r line; do
    grep -qF -- "$line" "$readme" || {
      printf 'doctor printed a hook line the README does not have:\n%s\n' "$line" >&2
      return 1
    }
  done < <("$PLUGIN_ROOT/bin/tama" doctor | grep -F '"type": "command"')

  local printed documented
  printed="$("$PLUGIN_ROOT/bin/tama" doctor |
    sed -n 's/.*hook claude-code \([A-Za-z]*\) >\/dev\/null.*/\1/p' | sort -u)"
  documented="$(sed -n 's/.*hook claude-code \([A-Za-z]*\) >\/dev\/null.*/\1/p' \
    "$readme" | sort -u)"
  [ -n "$printed" ]
  assert_equal "$printed" "$documented"
}

# --- the contract ------------------------------------------------------------------

@test "doctor takes no arguments" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" doctor --verbose
  assert_usage_error '--verbose'
}

@test "doctor parses and runs under the bash macOS ships" {
  healthy_server
  tama_use_bash_32_or_skip

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'no problems and no warnings'
}
