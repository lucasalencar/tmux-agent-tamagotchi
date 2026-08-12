#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

# `tama doctor`, driven through `bin/tama` against an isolated tmux server like
# everything else here.
#
# Two things make this suite different from its neighbours. It is the only one where
# the *exit status* is a promised behaviour rather than "0, always": doctor is meant to
# be droppable into a script, so what counts as broken and what counts as merely worth
# knowing is asserted here and not left to the prose. And most of it is
# platform-independent on purpose — pointing `@tama_backend` at `macos` and
# `@tama_terminal_notifier` at a fixture is a machine state any operating system can be
# put into, so the title warning, the "which binary and from where" reporting and the
# named-backend failures are all asserted on both CI legs.
#
# What stays platform-gated is only what a platform can really change: what `auto`
# resolves to. Those tests skip on the other platform, which is the shape of test that
# quietly asserts nothing for years, so each one says in its name which machine it is
# about.
#
# Nothing here ever lets a real notifier run. doctor never invokes a capability — it
# only resolves and inspects paths — and the suite still points every notifier option
# at a fixture where it points it anywhere at all.

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
  tama_kill_server
}

# The plugin loaded and a status line that asks for both formats: a machine with
# nothing wrong with it, which is what the "no problems" claims are measured against.
healthy_server() {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  test_tmux set -g window-status-format '#I:#W#{E:@tama_icons}#{E:@tama_flag}'
  test_tmux set -g window-status-current-format '#I:#W#{E:@tama_icons}#{E:@tama_flag}'
  tama_use_fake_backend
}

require_darwin() {
  [ "$(uname -s)" = 'Darwin' ] || skip 'this is about what a Mac does'
}

refute_darwin() {
  [ "$(uname -s)" != 'Darwin' ] || skip 'this is about what a machine that is not a Mac does'
}

# A notifier binary on PATH under the given name, the way a machine with one installed
# has it — which is how `auto` has to find it, by name, with no option pointing at it.
notifier_on_path() { # <name>
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cp "$PLUGIN_ROOT/tests/fixtures/fake-notifier" "$bin/$1"
  PATH="$bin:$PATH"
  export PATH
}

# Everything the README's block wires, so a settings file can be written with one event
# left out on purpose.
CC_EVENTS='SessionStart UserPromptSubmit PostToolUse PostToolUseFailure PermissionRequest
Notification Stop StopFailure SubagentStart SubagentStop SessionEnd'

# Writes a Claude Code settings file wiring every event except the ones named.
#
# Deliberately not a copy of the README's block: what is being tested is that doctor
# recognises a *user's* settings, and a user's are hand-merged, reindented and quoted
# however their editor left them. This writes the one thing that matters — the adapter
# invocation — inside JSON that is not byte-for-byte the documented block.
cc_settings_without() { # <event…>
  local event skip_event skipped
  {
    printf '{\n  "hooks": {\n'
    for event in $CC_EVENTS; do
      skipped='no'
      for skip_event in "$@"; do
        [ "$event" != "$skip_event" ] || skipped='yes'
      done
      [ "$skipped" = 'no' ] || continue
      printf '    "%s": [{"hooks": [{"type": "command",' "$event"
      printf ' "command": "exec \\"$tama\\" hook claude-code %s"}]}],\n' "$event"
    done
    printf '    "_": []\n  }\n}\n'
  } >"$CLAUDE_CONFIG_DIR/settings.json"
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
  [ ! -e "$(tama_socket_dir)/$socket" ]
}

@test "doctor says nothing is wrong when nothing is wrong, and exits 0" {
  healthy_server

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'no problems and no warnings'
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

@test "a status line with the icons on only one of the two formats says which one" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tama_use_fake_backend
  test_tmux set -g window-status-format '#I:#W#{E:@tama_icons}#{E:@tama_flag}'
  test_tmux set -g window-status-current-format '#I:#W'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'window-status-format draws both'
  assert_output_contains 'window-status-current-format mentions neither'
}

@test "an empty @tama_backend is a configuration and not a fault" {
  healthy_server
  test_tmux set -g @tama_backend ''

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'every capability is off, deliberately'
}

@test "a backend the user named that is not there is broken" {
  healthy_server
  test_tmux set -g @tama_backend "$BATS_TEST_TMPDIR/no-such-backend"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'which is not a directory'
}

@test "a backend name that would reach outside backends/ is broken" {
  healthy_server
  test_tmux set -g @tama_backend '../../etc'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'cannot name a backend'
}

@test "naming the macos backend without its notifier is broken, where auto would not have been" {
  healthy_server
  test_tmux set -g @tama_backend macos
  test_tmux set -g @tama_terminal_notifier "$BATS_TEST_TMPDIR/no-such-notifier"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_status 1
  assert_output_contains 'named the macos backend and its notifier is missing'
  assert_output_contains 'used as given or not at all'
}

@test "the resolved notifier is reported with the path it came from: an option" {
  healthy_server
  test_tmux set -g @tama_backend macos
  test_tmux set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_output_contains "terminal-notifier: $PLUGIN_ROOT/tests/fixtures/fake-notifier"
  assert_output_contains 'named outright by @tama_terminal_notifier'
}

@test "the resolved notifier is reported with the path it came from: PATH" {
  healthy_server
  test_tmux set -g @tama_backend macos
  notifier_on_path terminal-notifier

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_output_contains "terminal-notifier: $BATS_TEST_TMPDIR/bin/terminal-notifier"
  assert_output_contains 'found on $PATH'
}

@test "the capabilities a backend ships are reported, and so is what each absence costs" {
  healthy_server
  test_tmux set -g @tama_backend "$(tama_fake_backend_without focused)"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'capabilities: notify dismiss focus'
  assert_output_contains 'no focused: nothing is ever suppressed'
}

@test "a capability replaced by the user's own command says the backend is not consulted" {
  healthy_server
  test_tmux set -g @tama_notify_command '/bin/echo'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains '@tama_notify_command replaces the notify capability'
  assert_output_contains 'The backend is not consulted for those'
}

# --- what `auto` chose, and why ---------------------------------------------------

@test "auto on a Mac with no notifier says so, and how to fix it" {
  require_darwin
  healthy_server
  test_tmux set -gu @tama_backend
  # A name that is on no PATH and in neither Homebrew prefix, which is the same machine
  # state as not having installed it — and one this suite can produce on a developer's
  # Mac, where the real notifier is installed.
  test_tmux set -g @tama_terminal_notifier 'terminal-notifier-absent'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'backend: none'
  assert_output_contains "This is a Mac, so 'auto' wants the macos backend"
  assert_output_contains 'not on $PATH and not in /opt/homebrew/bin /usr/local/bin'
}

@test "auto on a Mac that does have notify-send says why it was not picked" {
  require_darwin
  healthy_server
  test_tmux set -gu @tama_backend
  test_tmux set -g @tama_terminal_notifier 'terminal-notifier-absent'
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
  test_tmux set -gu @tama_backend
  test_tmux set -g @tama_notify_send 'notify-send-absent'

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
  test_tmux set -gu @tama_backend
  notifier_on_path terminal-notifier
  notifier_on_path notify-send
  test_tmux set -g @tama_terminal_notifier "$BATS_TEST_TMPDIR/nowhere/terminal-notifier"
  test_tmux set -g @tama_notify_send "$BATS_TEST_TMPDIR/nowhere/notify-send"

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'backend: none'
  assert_output_contains 'which is not an executable file'
  assert_output_contains 'used as given or not at all'
}

# --- the focus check ---------------------------------------------------------------

@test "a title configuration the focus check cannot match warns, and says it fails toward noise" {
  healthy_server
  test_tmux set -g @tama_backend macos
  test_tmux set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"
  test_tmux set -g set-titles off

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'set-titles is'
  assert_output_contains 'extra banners, never missing ones'
  assert_output_contains "set -g set-titles-string '#S'"
}

@test "a set-titles-string that merely contains the session name is not enough" {
  healthy_server
  test_tmux set -g @tama_backend macos
  test_tmux set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"
  test_tmux set -g set-titles on
  test_tmux set -g set-titles-string '#S:#I:#W'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'which is not the session name alone'
  assert_output_contains 'for equality, not containment'
}

@test "the title configuration the backend needs is accepted" {
  healthy_server
  test_tmux set -g @tama_backend macos
  test_tmux set -g @tama_terminal_notifier "$PLUGIN_ROOT/tests/fixtures/fake-notifier"
  test_tmux set -g set-titles on
  test_tmux set -g set-titles-string '#S'

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains "set-titles is on and set-titles-string is '#S'"
}

@test "suppression turned off is reported as the deliberate thing it is" {
  healthy_server
  test_tmux set -g @tama_suppress_when_focused off

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'every banner is delivered'
}

@test "the libnotify backend reports whether there is a session bus to reach" {
  healthy_server
  test_tmux set -g @tama_backend libnotify
  test_tmux set -g @tama_notify_send "$PLUGIN_ROOT/tests/fixtures/fake-notify-send"
  unset DBUS_SESSION_BUS_ADDRESS

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'DBUS_SESSION_BUS_ADDRESS is not set'
  assert_output_contains 'every banner fails silently'
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

  run "$PLUGIN_ROOT/bin/tama" doctor
  assert_success
  assert_output_contains 'no Claude Code settings file found'
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

  run test_tmux source-file "$conf"
  assert_success

  # And what it told the user to paste is what the entrypoint really exports.
  assert_contains "$(test_tmux show -gv window-status-format)" '@tama_icons' 'the snippet'
  assert_contains "$(test_tmux show -gv window-status-current-format)" '@tama_flag' 'the snippet'
  assert_equal "$(test_tmux show -gv set-titles-string)" '#S'
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
    sed -n 's/.*hook claude-code \([A-Za-z]*\)".*/\1/p' | sort -u)"
  documented="$(sed -n 's/.*hook claude-code \([A-Za-z]*\)".*/\1/p' "$readme" | sort -u)"
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
