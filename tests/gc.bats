#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

# The plugin is loaded in every test here, because half of what the sweep has to
# prove is what the status line stops showing, and the other half runs from the hooks
# the entrypoint wires.
setup() {
  tama_fake_backend_env
  tama_start_server
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  WINDOW="$(tama_window_id t:0)"
  PANE="$(tama_pane_of t:0)"
  # Every pane in this suite runs a command the test named, because staleness is a
  # claim about what a pane is running: a pane left on the developer's own shell
  # reports whatever that shell's startup happens to be doing at the time.
  pane_running "$PANE" 'sleep 300'
}

@test "switching sessions acknowledges only the tmux window the client lands on" {
  tama_use_fake_backend
  tmux_test_server_run -f /dev/null new-session -d -s other 'sleep 300'
  tmux_test_server_run new-window -d -t other: 'sleep 300'
  local landed landed_pane elsewhere elsewhere_pane client group
  landed="$(tama_window_id other:0)"
  landed_pane="$(tama_pane_of other:0)"
  elsewhere="$(tama_window_id other:1)"
  elsewhere_pane="$(tama_pane_of other:1)"

  tama_attach_client t
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$landed_pane"
  assert_success
  pane_running_shell "$landed_pane"
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$landed_pane"
  assert_success
  group="$(tama_backend_value notify env.TAMA_GROUP)"
  run "$PLUGIN_ROOT/bin/tama" state waiting Claude --pane "$elsewhere_pane"
  assert_success
  pane_running_shell "$elsewhere_pane"

  client="$(tmux_test_server_run list-clients -F '#{client_name}')"
  tmux_test_server_run switch-client -c "$client" -t other:0

  wait_until_not_flagged "$landed"
  wait_until_no_icons "$landed"
  wait_until_backend_called dismiss
  assert_backend_value dismiss argv1 "$group"
  assert_flagged "$elsewhere"
  [ -n "$(tama_icons "$elsewhere")" ]
}

@test "switching sessions with no pending notification starts no notifier" {
  tama_use_fake_backend
  tmux_test_server_run -f /dev/null new-session -d -s other 'sleep 300'
  local landed landed_pane client
  landed="$(tama_window_id other:0)"
  landed_pane="$(tama_pane_of other:0)"

  tama_attach_client t
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$landed_pane"
  assert_success
  pane_running_shell "$landed_pane"
  run "$PLUGIN_ROOT/bin/tama" flag "$landed"
  assert_success

  client="$(tmux_test_server_run list-clients -F '#{client_name}')"
  tmux_test_server_run switch-client -c "$client" -t other:0

  wait_until_not_flagged "$landed"
  wait_until_no_icons "$landed"
  refute_backend_called dismiss
}

teardown() {
  tama_detach_client
  tmux_test_server_stop
}

# Puts <pane> on a known command, and waits for tmux to agree it is running it.
# Polled rather than slept on: a process takes as long as the machine takes.
pane_running() { # <pane> <command>
  tmux_test_server_run respawn-pane -k -t "$1" "$2"
  wait_for_command "$1" "${2%% *}"
}

wait_for_command() { # <pane> <expected>
  local waited=0
  while [ "$(pane_command "$1")" != "$2" ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'pane %s was still running %s after 10s, not %s\n' \
        "$1" "$(pane_command "$1")" "$2" >&2
      return 1
    fi
    sleep 0.05
  done
}

pane_command() { # <pane>
  tmux_test_server_run display-message -p -t "$1" '#{pane_current_command}'
}

# Puts <pane> back on a plain shell, the way a pane whose agent exited ends up. Which
# shell that turns out to be is the machine's business, so this waits for the command
# to change rather than for a name — `sh` is bash on macOS and dash on Debian.
#
# This is what "the agent has gone" looks like to the sweep, and the only thing it
# accepts as evidence: a pane running some other *program* is at least as likely to be
# a tool call that opened an editor as an agent that exited, and clearing that would
# take a live agent's icon and subagent list away. So every test here that expects a
# sweep leaves the pane at a prompt.
pane_running_shell() { # <pane>
  local before waited=0
  before="$(pane_command "$1")"
  tmux_test_server_run respawn-pane -k -t "$1" 'sh'
  while [ "$(pane_command "$1")" = "$before" ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'pane %s never left %s\n' "$1" "$before" >&2
      return 1
    fi
    sleep 0.05
  done
  assert_shell_in_default_allowlist "$1"
}

# The default allowlist, for the one test that depends on this machine's own shell
# being in it. A shell nobody guessed is a skip and not a failure: what that test is
# about is the fallback, not the list.
assert_shell_in_default_allowlist() { # <pane>
  local shell
  shell="$(pane_command "$1")"
  case ' sh bash zsh fish dash ksh mksh ash csh tcsh ' in
    *" $shell "*) ;;
    *) skip "this machine's shell reports as '$shell', which the default list omits" ;;
  esac
}

# Nothing of the plugin's is left on the pane. Asked of the pane rather than of a
# list of names, so an option the plugin learns to write but the sweep forgets fails
# here without anybody remembering to add it.
assert_no_trace() { # <pane>
  local remaining
  remaining="$(tmux_test_server_run show -p -t "$1" | grep -c '^@tama_' || true)"
  assert_equal "$remaining" 0
}

# Waits for a sweep that a tmux hook started, since `run-shell -b` is deliberately
# asynchronous. Polled on the fact the test is about.
wait_until_no_icons() { # <window>
  local waited=0
  while [ -n "$(tama_icons "$1")" ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'window %s still drew icons after 10s\n' "$1" >&2
      return 1
    fi
    sleep 0.05
  done
}

@test "a pane back at a prompt after reporting is swept" {
  # The whole point: an agent that exited without saying so leaves an icon claiming
  # it is working. The pane is still there, running a plain shell now.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ●'

  pane_running_shell "$PANE"
  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success

  assert_equal "$(tama_icons "$WINDOW")" ''
  assert_no_trace "$PANE"
}

@test "a pane whose agent shelled out to something is left alone" {
  # `pane_current_command` is not the process the agent runs in — it is whatever holds
  # the pane's tty — so a tool call that opens an editor or a pager stops matching the
  # snapshot while the agent is very much alive. Clearing on that alone took the icon
  # and the subagent list away at the one moment the user was waiting on the thing that
  # took the tty, and nothing put them back: an agent blocked on that child has no next
  # event to report.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-a --pane "$PANE"
  assert_success

  # A child of the agent's, not a shell: everything the sweep can see is the same as
  # for a dead agent except that this is not a prompt.
  pane_running "$PANE" 'cat'
  run "$PLUGIN_ROOT/bin/tama" gc --all
  assert_success

  assert_equal "$(tama_icons "$WINDOW")" ' ●'
  assert_pane_option "$PANE" state_main running
  assert_pane_option "$PANE" subagents sub-a
}

@test "a pane that only ever notified is swept" {
  # `notify` writes the agent's name and the label without ever writing a state — a
  # pane whose state hooks were never wired, which the hand-wiring recipe and the
  # `tama notify` key binding both allow. Such a pane draws no icon, so nothing about
  # it can ever heal, and it keeps a dead agent's name for `@tama_title_format` and any
  # status-line format of the user's to expand. The sweep could not see it at all: the
  # first thing it asked was whether there was a state, and there was not.
  run "$PLUGIN_ROOT/bin/tama" notify Claude 'permission needed' --pane "$PANE"
  assert_success
  assert_pane_option "$PANE" agent Claude
  assert_equal "$(tama_icons "$WINDOW")" ''

  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success
  assert_no_trace "$PANE"
}

@test "a pane that only ever reported a subagent is swept" {
  # The same leak from the other direction: a `SubagentStart` that arrives before
  # anything reports a state leaves a subagent list on a pane with no state on it.
  # There is nothing for that list to qualify and nothing that will ever clear it.
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-a --pane "$PANE"
  assert_success
  assert_pane_option "$PANE" subagents sub-a
  assert_equal "$(tama_icons "$WINDOW")" ''

  run "$PLUGIN_ROOT/bin/tama" gc --all
  assert_success
  assert_no_trace "$PANE"
}

@test "a pane with residue and no state is swept whatever it is running" {
  # Unconditionally, and not through the shell allowlist: there is no live agent to
  # protect — a pane with no main state draws nothing — and no snapshot to judge one
  # by, so waiting for a prompt would only mean the residue outlives the pane's next
  # occupant.
  run "$PLUGIN_ROOT/bin/tama" notify Claude 'permission needed' --pane "$PANE"
  assert_success

  # Still on `sleep 300`, which is neither a shell nor anything the plugin recorded.
  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success
  assert_no_trace "$PANE"
}

@test "a pane still running what it reported is left alone" {
  # The other half, and the more important one: a sweep that took a live agent's icon
  # away would be worse than one that took nothing.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success

  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success

  assert_equal "$(tama_icons "$WINDOW")" ' ●'
  assert_pane_option "$PANE" state_main running
  assert_pane_option "$PANE" cmd sleep
  assert_pane_option "$PANE" agent Claude
}

@test "the sweep takes a leaked subagent id with it" {
  # A delegated run that crashed leaves its id behind, and the pane reads as
  # `background` — busier than it is — for as long as the id is there. The sweep is
  # what heals that: it is named as the cure in lib/pane.sh, next to the retry loop
  # that cannot rule the leak out.
  run "$PLUGIN_ROOT/bin/tama" state subagent-start sub-leaked --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state idle Claude --pane "$PANE"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'

  pane_running_shell "$PANE"
  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success

  assert_pane_option_unset "$PANE" subagents
  assert_no_trace "$PANE"
  # And the consequence a user would have seen: the next agent to report `idle` in
  # this pane draws the finished glyph rather than inheriting a dead id.
  run "$PLUGIN_ROOT/bin/tama" state idle Claude --pane "$PANE"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "the sweep clears the command snapshot along with the state" {
  # Otherwise the next agent in the pane is judged against a command that has not run
  # there since, and its state is swept the moment it reports one.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success

  pane_running_shell "$PANE"
  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success
  assert_pane_option_unset "$PANE" cmd

  pane_running "$PANE" 'cat'
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  assert_pane_option "$PANE" cmd cat
  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
}

@test "a pane with no recorded command is swept when it is running a shell" {
  # There is nothing to compare — a state written before the plugin recorded commands,
  # or one whose command could not survive being stored — so the allowlist is all
  # there is: an agent does not run as the user's shell.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  tmux_test_server_run set -pu -t "$PANE" @tama_pane_cmd

  pane_running_shell "$PANE"
  assert_shell_in_default_allowlist "$PANE"

  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ''
  assert_no_trace "$PANE"
}

@test "a pane with no recorded command running something else is left alone" {
  # "Not a shell I recognise" is not evidence that an agent has gone, and taking a
  # live agent's icon away is the expensive mistake.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  tmux_test_server_run set -pu -t "$PANE" @tama_pane_cmd

  pane_running "$PANE" 'cat'
  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
}

@test "the shell allowlist is the user's, and is read at invocation time" {
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  tmux_test_server_run set -pu -t "$PANE" @tama_pane_cmd
  pane_running "$PANE" 'cat'

  # Not a shell by the default list, so nothing happens…
  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ●'

  # …and it is a shell by this user's, with no reload of anything.
  tmux_test_server_run set -g @tama_gc_shells 'cat mysh'
  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "the sweep is confined to the window it was given" {
  local other other_pane
  tmux_test_server_run new-window -t t: -d 'sleep 300'
  other="$(tama_window_id t:1)"
  other_pane="$(tama_pane_of t:1)"
  wait_for_command "$other_pane" sleep

  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state waiting Claude --pane "$other_pane"
  assert_success
  pane_running_shell "$PANE"
  pane_running_shell "$other_pane"

  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ''
  # The window nobody swept is still lying, which is what --all is for.
  assert_equal "$(tama_icons "$other")" ' ◐'

  run "$PLUGIN_ROOT/bin/tama" gc --all
  assert_success
  assert_equal "$(tama_icons "$other")" ''
}

@test "the whole-server sweep reaches another session" {
  # `--all` is `list-panes -a`, which is the server and not the ambient session: the
  # windows most likely to be lying are the ones the user has not visited.
  tmux_test_server_run -f /dev/null new-session -d -s other 'sleep 300'
  local other other_pane
  other="$(tama_window_id other:0)"
  other_pane="$(tama_pane_of other:0)"
  wait_for_command "$other_pane" sleep

  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$other_pane"
  assert_success
  pane_running_shell "$other_pane"
  assert_equal "$(tama_icons "$other")" ' ●'

  run "$PLUGIN_ROOT/bin/tama" gc --all
  assert_success
  assert_equal "$(tama_icons "$other")" ''
  assert_no_trace "$other_pane"
}

@test "one window can hold a live agent and a dead one" {
  # A split window is two agent panes and one icon each, so the sweep has to be a
  # decision per pane rather than per window.
  local dead live
  dead="$PANE"
  tmux_test_server_run split-window -t "$WINDOW" -d 'sleep 300'
  live="$(tmux_test_server_run list-panes -t "$WINDOW" -F '#{pane_id}' | tail -1)"
  wait_for_command "$live" sleep

  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$dead"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state waiting Claude --pane "$live"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ●◐'

  pane_running_shell "$dead"
  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success

  assert_equal "$(tama_icons "$WINDOW")" ' ◐'
  assert_no_trace "$dead"
  assert_pane_option "$live" state_main waiting
}

@test "a sweep with nothing to do writes nothing at all" {
  # This runs on every pane selection, so the ordinary case — no pane in the window
  # is stale — has to be one read and no write: a write would wake every client for
  # a status line that has not changed.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success

  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success

  assert_tmux_command 'list-panes'
  refute_tmux_command 'set'
  refute_tmux_command 'refresh-client'
}

@test "a window with no agent pane at all is swept without a write" {
  tama_log_tmux_calls
  run "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success

  refute_tmux_command 'set'
  refute_tmux_command 'refresh-client'
}

@test "gc with no target sweeps the window tmux is on" {
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  pane_running_shell "$PANE"

  # No target, no $TMUX_PANE: what a user typing `tama gc` has.
  run "$PLUGIN_ROOT/bin/tama" gc
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "gc takes a target as an argument, and a pane resolves to its window" {
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  pane_running_shell "$PANE"

  run "$PLUGIN_ROOT/bin/tama" gc "$WINDOW"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ''

  pane_running "$PANE" 'sleep 300'
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  pane_running_shell "$PANE"
  run "$PLUGIN_ROOT/bin/tama" gc --pane "$PANE"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "gc ignores the phantom pane tmux hands a hook" {
  # The trap the recipes exist to avoid: inside a hook's run-shell $TMUX_PANE names a
  # pane that does not exist. A target that resolves to nothing must sweep nothing,
  # quietly — and must not pick a window for itself, which would clear a live agent
  # somewhere the user never asked about.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  pane_running_shell "$PANE"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" gc --pane '%101'
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_equal "$(tama_icons "$WINDOW")" ' ●'
}

@test "selecting a pane sweeps the window it happened in" {
  # Through the hook the entrypoint wired, not by calling gc: this is the claim that
  # the common case needs no manual step.
  tmux_test_server_run split-window -t "$WINDOW" -d 'sleep 300'
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  pane_running_shell "$PANE"
  assert_equal "$(tama_icons "$WINDOW")" ' ●'

  tmux_test_server_run select-pane -t "$(tmux_test_server_run list-panes -t "$WINDOW" -F '#{pane_id}' | tail -1)"
  wait_until_no_icons "$WINDOW"
}

@test "selecting a window sweeps it as well as clearing its flag" {
  tmux_test_server_run new-window -t t: -d 'sleep 300'
  local target target_pane
  target="$(tama_window_id t:1)"
  target_pane="$(tama_pane_of t:1)"
  wait_for_command "$target_pane" sleep

  run "$PLUGIN_ROOT/bin/tama" state waiting Claude --pane "$target_pane"
  assert_success
  assert_flagged "$target"
  pane_running_shell "$target_pane"

  tama_attach_client t
  tmux_test_server_run select-window -t t:1
  wait_until_no_icons "$target"
  assert_not_flagged "$target"
}

@test "on-select sweeps the window it was called for" {
  run "$PLUGIN_ROOT/bin/tama" state waiting Claude --pane "$PANE"
  assert_success
  pane_running_shell "$PANE"

  run "$PLUGIN_ROOT/bin/tama" on-select --window "$WINDOW"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ''
  assert_not_flagged "$WINDOW"
}

@test "on-select --all sweeps every window, and unflags only the one it was given" {
  tmux_test_server_run -f /dev/null new-session -d -s other 'sleep 300'
  local elsewhere elsewhere_pane
  elsewhere="$(tama_window_id other:0)"
  elsewhere_pane="$(tama_pane_of other:0)"
  wait_for_command "$elsewhere_pane" sleep

  run "$PLUGIN_ROOT/bin/tama" state waiting Claude --pane "$PANE"
  assert_success
  run "$PLUGIN_ROOT/bin/tama" state waiting Claude --pane "$elsewhere_pane"
  assert_success
  pane_running_shell "$PANE"
  pane_running_shell "$elsewhere_pane"

  run "$PLUGIN_ROOT/bin/tama" on-select --all --window "$WINDOW"
  assert_success

  # The state was a lie in both windows, so both are swept.
  assert_equal "$(tama_icons "$WINDOW")" ''
  assert_equal "$(tama_icons "$elsewhere")" ''
  # The mark is a different matter: it says something happened while nobody was
  # looking, and the user is looking at exactly one window.
  assert_not_flagged "$WINDOW"
  assert_flagged "$elsewhere"
}

@test "the terminal regaining focus sweeps the whole server and clears the mark it came back to" {
  # The gap the flag had until now. A flag raised on the active window of a detached
  # session was waiting for a `select-window` that never comes: the user attaches and
  # is already on that window, so tmux fires no selection hook and the mark stays put
  # while they read it. Focus arriving is the event that says they are looking.
  tmux_test_server_run -f /dev/null new-session -d -s other 'sleep 300'
  local target target_pane
  target="$(tama_window_id other:0)"
  target_pane="$(tama_pane_of other:0)"
  wait_for_command "$target_pane" sleep

  # Raised while nobody is attached to that session, on its active window.
  run "$PLUGIN_ROOT/bin/tama" state waiting Claude --pane "$target_pane"
  assert_success
  assert_flagged "$target"

  # And something stale in a window of another session, which only the whole-server
  # scope reaches.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  pane_running_shell "$PANE"

  # This test is about the focus path alone, so both attachment-time hooks are taken
  # back off: otherwise attaching below would clear the mark and this would pass
  # without focus ever arriving. The next test is the one that covers attaching.
  # Attaching is not a selection: the mark is still there, which is the wart itself.
  tama_attach_client_without_attach_hook other
  assert_flagged "$target"

  # The user's terminal comes to the front. `-R` runs the hook the way tmux does when
  # the terminal reports focus, against the client that has it.
  tmux_test_server_run set-hook -R client-focus-in

  wait_until_not_flagged "$target"
  wait_until_no_icons "$WINDOW"
}

@test "attaching sweeps the whole server and clears the mark on the window attached to" {
  # The other half of coming back, and the half a real terminal is more likely to fire:
  # tmux sends client-attached for a bare `attach`, and client-focus-in only if the
  # terminal reports focus and `focus-events` is on. Wiring focus alone would leave the
  # mark sitting on the window a user attached straight onto — no selection happened, so
  # nothing else re-evaluates it — on every terminal that does not report focus.
  #
  # Nothing is simulated here: the hook the entrypoint wired is fired by tmux itself,
  # for a client that really attaches.
  tmux_test_server_run -f /dev/null new-session -d -s other 'sleep 300'
  tama_use_fake_backend
  local target target_pane
  target="$(tama_window_id other:0)"
  target_pane="$(tama_pane_of other:0)"
  wait_for_command "$target_pane" sleep

  # Raised while nobody was attached, on the window that session is already on.
  run "$PLUGIN_ROOT/bin/tama" notify claude-code 'permission needed' --pane "$target_pane"
  assert_success
  assert_flagged "$target"

  # And something stale in another session, which only the whole-server scope reaches.
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  pane_running_shell "$PANE"

  tama_attach_client other

  wait_until_not_flagged "$target"
  wait_until_no_icons "$WINDOW"
  wait_until_backend_called dismiss
  # A second asynchronous acknowledgement used to arrive just after the first.
  sleep 0.5
  assert_equal "$(tama_backend_calls dismiss)" 1
}

@test "attaching leaves the mark on the windows the user did not land on" {
  # --all widens the sweep and only the sweep. A mark on some other window says
  # something happened there while nobody was looking, and that is still true after
  # attaching somewhere else.
  tmux_test_server_run -f /dev/null new-session -d -s other 'sleep 300'
  tmux_test_server_run new-window -d -t other: 'sleep 300'
  local landed landed_pane elsewhere elsewhere_pane
  landed="$(tama_window_id other:0)"
  landed_pane="$(tama_pane_of other:0)"
  elsewhere="$(tama_window_id other:1)"
  elsewhere_pane="$(tama_pane_of other:1)"
  wait_for_command "$elsewhere_pane" sleep

  # The window the client will land on is other:0, and its agent has walked out.
  assert_equal "$(tama_window_id other:)" "$landed"
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$landed_pane"
  assert_success
  pane_running_shell "$landed_pane"

  # The other window's agent is real and waiting, and its mark is earned.
  run "$PLUGIN_ROOT/bin/tama" state waiting Claude --pane "$elsewhere_pane"
  assert_success
  assert_flagged "$elsewhere"

  tama_attach_client other

  # The sweep reached the window that was attached to.
  wait_until_no_icons "$landed"
  # And left the other window's truth alone: still drawing, still marked.
  [ -n "$(tama_icons "$elsewhere")" ]
  assert_flagged "$elsewhere"
}

@test "the sweep is a quiet no-op outside tmux" {
  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  pane_running "$PANE" 'cat'

  run --separate-stderr env -u TMUX "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  # Nothing was swept, because there was no tmux to sweep in.
  assert_pane_option "$PANE" state_main running

  run --separate-stderr env -u TMUX "$PLUGIN_ROOT/bin/tama" gc --all
  assert_success
  [ -z "$output" ]
}

@test "a window that is gone is not an error" {
  tmux_test_server_run new-window -t t: -d
  local doomed
  doomed="$(tama_window_id t:1)"
  tmux_test_server_run kill-window -t "$doomed"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" gc --window "$doomed"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "the sweep runs under the bash macOS ships" {
  # bash 3.2 is /bin/bash on every macOS and differs from bash 5 at runtime as well
  # as at parse time. The record is taken apart with parameter expansion rather than
  # an array for that reason; a diagnostic on stderr would be a broken plugin even
  # with the right result.
  tama_use_bash_32_or_skip

  run "$PLUGIN_ROOT/bin/tama" state running Claude --pane "$PANE"
  assert_success
  pane_running_shell "$PANE"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" gc --window "$WINDOW"
  assert_success
  [ -z "$stderr" ]
  assert_no_trace "$PANE"

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" gc --all
  assert_success
  [ -z "$stderr" ]
}

@test "gc rejects a wrong invocation loudly" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" gc --nope
  assert_usage_error 'unknown option'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" gc @1 @2
  assert_usage_error 'at most one target'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" gc ''
  assert_usage_error 'needs a target'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" gc --window
  assert_usage_error '--window needs a window id'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" gc --pane
  assert_usage_error '--pane needs a pane id'
}
