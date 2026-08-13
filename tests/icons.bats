#!/usr/bin/env bats

# What the status line shows for a window: one glyph per agent pane, in pane
# order. Asserted both on the command's own output and on the format the plugin
# exports for the user to interpolate, since that is what actually runs.

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
  WINDOW="$(test_tmux display-message -p -t t '#{window_id}')"
  PANE="$(test_tmux list-panes -t t -F '#{pane_id}' | head -1)"
}

teardown() {
  tama_kill_server
}

# Reports a state on a pane the way an agent hook would.
report() {
  local pane="$1"
  shift
  run "$PLUGIN_ROOT/bin/tama" state "$@" --pane "$pane"
  assert_success
}

@test "each state has its own glyph" {
  report "$PANE" running
  assert_equal "$(tama_icons "$WINDOW")" ' ●'

  report "$PANE" waiting
  assert_equal "$(tama_icons "$WINDOW")" ' ◐'

  report "$PANE" idle
  assert_equal "$(tama_icons "$WINDOW")" ' ○'

  report "$PANE" error
  assert_equal "$(tama_icons "$WINDOW")" ' ✕'
}

@test "an idle agent with a live subagent shows the background glyph" {
  report "$PANE" subagent-start sub-1
  report "$PANE" idle

  # Not the idle glyph, which would read as finished, and not the running one.
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
}

@test "a window with two agent panes shows two glyphs, in pane order" {
  test_tmux split-window -d -t t
  local first second
  first="$(test_tmux list-panes -t t -F '#{pane_id}' | head -1)"
  second="$(test_tmux list-panes -t t -F '#{pane_id}' | tail -1)"

  report "$first" waiting
  report "$second" running
  assert_equal "$(tama_icons "$WINDOW")" ' ◐●'

  # Reversing the states reverses the glyphs, which is what makes this pane
  # order rather than an accident of the option values.
  report "$first" running
  report "$second" waiting
  assert_equal "$(tama_icons "$WINDOW")" ' ●◐'
}

@test "a pane with no agent in it contributes nothing" {
  test_tmux split-window -d -t t
  local second
  second="$(test_tmux list-panes -t t -F '#{pane_id}' | tail -1)"

  report "$second" running
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
}

@test "the icons are the window's own, not the whole server's" {
  test_tmux new-window -d -t t:
  local other_window other_pane
  other_window="$(test_tmux list-windows -t t -F '#{window_id}' | tail -1)"
  other_pane="$(test_tmux list-panes -t "$other_window" -F '#{pane_id}')"

  report "$PANE" running
  report "$other_pane" waiting

  assert_equal "$(tama_icons "$WINDOW")" ' ●'
  assert_equal "$(tama_icons "$other_window")" ' ◐'
}

@test "the exported format names the window by identity, not by index" {
  # A window index is only unique within its session, and moves under
  # renumber-windows; the command also runs some moments after the format naming
  # the window was expanded. So an index would draw one session's icons onto
  # another session's window.
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  test_tmux new-session -d -s other
  local other_window other_pane
  other_window="$(test_tmux display-message -p -t other '#{window_id}')"
  other_pane="$(test_tmux list-panes -t other -F '#{pane_id}')"
  # Both are window 0 — of different sessions.
  assert_equal "$(test_tmux display-message -p -t "$WINDOW" '#{window_index}')" \
    "$(test_tmux display-message -p -t "$other_window" '#{window_index}')"

  report "$PANE" running
  report "$other_pane" waiting

  # Whichever window a bare index happened to resolve to, it cannot be both.
  assert_equal "$(tama_render_icons "$WINDOW")" ' ●'
  assert_equal "$(tama_render_icons "$other_window")" ' ◐'
}

@test "a cleared pane contributes no icon, like a pane that never ran an agent" {
  report "$PANE" running
  report "$PANE" clear

  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "a window with no agent pane contributes nothing at all, not even a space" {
  run "$PLUGIN_ROOT/bin/tama" icons "$WINDOW"
  assert_success
  assert_equal "$output" ''
  # Byte for byte, because a stray space would pad every ordinary window in the
  # status line.
  assert_equal "$("$PLUGIN_ROOT/bin/tama" icons "$WINDOW" | wc -c | tr -d ' ')" '0'
}

@test "icons for a window that is gone says nothing and exits 0" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" icons @999
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "icons rejects invocations a status line author has to fix" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" icons
  assert_usage_error

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" icons "$WINDOW" extra
  assert_usage_error

  # A format that failed to expand, rather than a request for whichever window
  # tmux would have picked — which would draw one window's icons onto another.
  report "$PANE" running
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" icons ''
  assert_usage_error
}

@test "a pane with subagents but no state of its own is not an agent pane" {
  # Reachable from an agent whose subagent hook fires before any state hook: the
  # pane has a subagent list and nothing else, and a list alone is not a state.
  report "$PANE" subagent-start sub-1

  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "the icons are not exported for a plugin path a status line cannot express" {
  # `#{q:}` escapes what a shell acts on, but not a newline: the job would become
  # two commands, and the second would run once per window per status interval.
  # Loaded from a good clone first, so what is asserted below is that the option
  # was taken away rather than never set: a leftover value would keep running the
  # other clone once per window per status interval.
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  [ -n "$(test_tmux show -gqv @tama_icons)" ]

  local plugin
  plugin="$(printf '%s/one\ntwo/tamagotchi' "$BATS_TEST_TMPDIR")"
  mkdir -p "$plugin"
  tama_copy_plugin "$plugin"

  run --separate-stderr "$plugin/tamagotchi.tmux"
  assert_success
  [ -n "$stderr" ]
  assert_equal "$(test_tmux show -gqv @tama_icons)" ''
  # Everything else still loads: the icons are one feature, not the plugin.
  assert_equal "$(test_tmux show -gqv @tama_bin)" "$(cd -P "$plugin" && pwd)/bin/tama"
}

@test "the exported format renders the icons the way a status line would" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  report "$PANE" running

  # Not the command the test calls, but the one tmux runs: the plugin path as
  # the plugin published it, the window id substituted by tmux, and a shell
  # doing the parsing.
  assert_equal "$(tama_render_icons "$WINDOW")" ' ●'
}

@test "the exported format survives a plugin path with characters tmux eats" {
  # `#` opens a format, `%` is a strftime conversion, a space splits a word in the
  # shell tmux runs the command with, and `)` would end the job early — tmux finds
  # that paren before it expands anything, so a path inside the job cannot contain
  # one at all.
  local plugin="$BATS_TEST_TMPDIR/od#d p%th (1) qu'ote/tamagotchi"
  mkdir -p "$(dirname "$plugin")"
  tama_copy_plugin "$plugin"
  plugin="$(cd -P "$plugin" && pwd)"

  run "$plugin/tamagotchi.tmux"
  assert_success
  report "$PANE" running

  assert_equal "$(tama_render_icons "$WINDOW")" ' ●'
}

#
# Configuration. Every option is a global user option, read on every invocation,
# so what these set is what the next call to the CLI draws.
#

@test "each state's glyph can be replaced on its own" {
  test_tmux set -g @tama_icon_running 'R'
  test_tmux set -g @tama_icon_waiting 'W'
  test_tmux set -g @tama_icon_idle 'I'
  test_tmux set -g @tama_icon_error 'E'
  test_tmux set -g @tama_icon_background 'B'

  report "$PANE" running
  assert_equal "$(tama_icons "$WINDOW")" ' R'

  report "$PANE" waiting
  assert_equal "$(tama_icons "$WINDOW")" ' W'

  report "$PANE" error
  assert_equal "$(tama_icons "$WINDOW")" ' E'

  report "$PANE" idle
  assert_equal "$(tama_icons "$WINDOW")" ' I'

  report "$PANE" subagent-start sub-1
  assert_equal "$(tama_icons "$WINDOW")" ' B'
}

@test "one state's override leaves the others alone" {
  test_tmux set -g @tama_icon_waiting '!!'

  report "$PANE" running
  assert_equal "$(tama_icons "$WINDOW")" ' ●'

  report "$PANE" waiting
  assert_equal "$(tama_icons "$WINDOW")" ' !!'
}

@test "an icon set to nothing draws nothing for that state" {
  test_tmux set -g @tama_icon_running ''

  report "$PANE" running
  # Not the default glyph: an option set to the empty string is a configuration,
  # not an option that was never set.
  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "the ascii preset replaces the whole set" {
  # For terminals with no wide-glyph support: every one of these is a single
  # column of ASCII.
  test_tmux set -g @tama_icon_set ascii

  report "$PANE" running
  assert_equal "$(tama_icons "$WINDOW")" ' *'

  report "$PANE" waiting
  assert_equal "$(tama_icons "$WINDOW")" ' ?'

  report "$PANE" error
  assert_equal "$(tama_icons "$WINDOW")" ' !'

  report "$PANE" idle
  assert_equal "$(tama_icons "$WINDOW")" ' .'

  report "$PANE" subagent-start sub-1
  assert_equal "$(tama_icons "$WINDOW")" ' +'
}

@test "the pets preset replaces the whole set" {
  test_tmux set -g @tama_icon_set pets

  report "$PANE" running
  assert_equal "$(tama_icons "$WINDOW")" ' 🐥'

  report "$PANE" waiting
  assert_equal "$(tama_icons "$WINDOW")" ' 🍼'

  report "$PANE" error
  assert_equal "$(tama_icons "$WINDOW")" ' 💀'

  report "$PANE" idle
  assert_equal "$(tama_icons "$WINDOW")" ' 😴'

  report "$PANE" subagent-start sub-1
  assert_equal "$(tama_icons "$WINDOW")" ' 🥚'
}

@test "an individual icon wins over the preset" {
  test_tmux set -g @tama_icon_set ascii
  test_tmux set -g @tama_icon_running '●'

  report "$PANE" running
  assert_equal "$(tama_icons "$WINDOW")" ' ●'

  # And only that one: the rest of the preset still stands.
  report "$PANE" waiting
  assert_equal "$(tama_icons "$WINDOW")" ' ?'
}

@test "a preset nobody recognises draws the default set" {
  # A typo in an option must not empty the status line it was meant to decorate.
  test_tmux set -g @tama_icon_set 'asci'

  report "$PANE" running
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
}

@test "turning idle off takes those icons away and leaves the others" {
  test_tmux set -g @tama_icon_set ascii
  test_tmux set -g @tama_show_idle off
  test_tmux split-window -d -t t
  local first second
  first="$(test_tmux list-panes -t t -F '#{pane_id}' | head -1)"
  second="$(test_tmux list-panes -t t -F '#{pane_id}' | tail -1)"

  report "$first" idle
  report "$second" running
  assert_equal "$(tama_icons "$WINDOW")" ' *'
}

@test "a window whose only agent pane is idle contributes nothing when idle is off" {
  test_tmux set -g @tama_show_idle off

  report "$PANE" idle
  # Not a bare prefix: the prefix exists to separate icons from the window name,
  # and there are no icons.
  assert_equal "$(tama_icons "$WINDOW")" ''
  assert_equal "$("$PLUGIN_ROOT/bin/tama" icons "$WINDOW" | wc -c | tr -d ' ')" '0'
}

@test "every spelling tmux has for off turns idle icons off" {
  # `off` was the only one this suite ever wrote, so narrowing the parser to it alone
  # used to survive the whole run — while the three options that really were narrow
  # went on reading `false` as on. All four, on one option of each kind, from here on.
  local spelling icons
  for spelling in $TAMA_OFF_SPELLINGS; do
    test_tmux set -g @tama_show_idle "$spelling"
    report "$PANE" idle
    icons="$(tama_icons "$WINDOW")"
    [ -z "$icons" ] || {
      printf '@tama_show_idle %s still drew an icon: %s\n' "$spelling" "$icons" >&2
      return 1
    }
  done
}

@test "a value outside that vocabulary leaves idle icons on" {
  # Including a typo: an option nobody can spell must not take a feature away
  # silently, which is the whole reason the vocabulary is a list and not a negation.
  local spelling icons
  for spelling in $TAMA_ON_SPELLINGS; do
    test_tmux set -g @tama_show_idle "$spelling"
    report "$PANE" idle
    icons="$(tama_icons "$WINDOW")"
    [ "$icons" = ' ○' ] || {
      printf '@tama_show_idle %s drew %s, not the idle glyph\n' "$spelling" "$icons" >&2
      return 1
    }
  done
}

@test "every spelling tmux has for off stops background being distinguished" {
  local spelling icons
  for spelling in $TAMA_OFF_SPELLINGS; do
    test_tmux set -g @tama_show_background "$spelling"
    report "$PANE" subagent-start sub-1
    report "$PANE" idle
    icons="$(tama_icons "$WINDOW")"
    [ "$icons" = ' ●' ] || {
      printf '@tama_show_background %s drew %s, not the running glyph\n' \
        "$spelling" "$icons" >&2
      return 1
    }
  done
}

@test "turning background off draws those panes as running, not as nothing" {
  test_tmux set -g @tama_show_background off
  report "$PANE" subagent-start sub-1
  report "$PANE" idle

  # The option means "do not distinguish": the agent is still working, so it
  # draws as working.
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
}

@test "background falls back to whatever running was configured to be" {
  test_tmux set -g @tama_show_background off
  test_tmux set -g @tama_icon_running 'R'
  test_tmux set -g @tama_icon_background 'B'
  report "$PANE" subagent-start sub-1
  report "$PANE" idle

  assert_equal "$(tama_icons "$WINDOW")" ' R'
}

@test "the prefix, separator and suffix are the user's" {
  test_tmux set -g @tama_icon_prefix ' ['
  test_tmux set -g @tama_icon_separator '|'
  test_tmux set -g @tama_icon_suffix ']'
  test_tmux split-window -d -t t
  local first second
  first="$(test_tmux list-panes -t t -F '#{pane_id}' | head -1)"
  second="$(test_tmux list-panes -t t -F '#{pane_id}' | tail -1)"

  report "$first" running
  report "$second" waiting
  assert_equal "$(tama_icons "$WINDOW")" ' [●|◐]'
}

@test "the separator only ever comes between two icons" {
  test_tmux set -g @tama_icon_separator '|'

  report "$PANE" running
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
}

@test "an empty prefix means no prefix" {
  # The distinction the option reader exists for: never set means the default
  # space, set to empty means the user put the icons somewhere that does not
  # want one.
  test_tmux set -g @tama_icon_prefix ''
  report "$PANE" running

  assert_equal "$(tama_icons "$WINDOW")" '●'
}

@test "the prefix and suffix are absent when nothing is drawn" {
  test_tmux set -g @tama_icon_prefix '['
  test_tmux set -g @tama_icon_suffix ']'

  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "an option takes effect on source-file, with no server restart" {
  report "$PANE" running
  assert_equal "$(tama_icons "$WINDOW")" ' ●'

  local conf="$BATS_TEST_TMPDIR/icons.conf"
  cat >"$conf" <<'CONF'
set -g @tama_icon_set ascii
set -g @tama_icon_prefix '<'
CONF
  test_tmux source-file "$conf"

  assert_equal "$(tama_icons "$WINDOW")" '<*'
}

@test "a hash in an option cannot become a format" {
  # A status line expands what this prints — a job's output is expanded again as
  # a format — so a `#` has to arrive doubled, which is how a format spells one.
  # Otherwise an icon of `#{...}` would be a format the user did not write, and
  # one of `#(...)` a command run once per window per status interval.
  test_tmux set -g @tama_icon_running '#{host}'
  test_tmux set -g @tama_icon_prefix ' #'
  report "$PANE" running

  assert_equal "$(tama_icons "$WINDOW")" ' ####{host}'
}

@test "the icons render under the bash macOS ships" {
  # bash 3.2 is /bin/bash on every macOS, and tmux runs this command in a shell of
  # its own — so an incompatibility here is invisible until the status line is
  # simply blank on somebody's machine.
  tama_use_bash_32_or_skip

  report "$PANE" subagent-start sub-1
  report "$PANE" idle

  # Including on stderr: a 3.2-only diagnostic would otherwise be printed into
  # the status line on every tick, on machines whose suite is green.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" icons "$WINDOW"
  assert_success
  assert_equal "$output" ' ⚙'
  [ -z "$stderr" ]
}
