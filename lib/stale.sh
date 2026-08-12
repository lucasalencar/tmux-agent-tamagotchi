# shellcheck shell=bash
#
# The sweep: state stops lying about panes whose agent is gone.
#
# An agent that exits without reporting — it crashed, the user killed it, the pane
# went back to being a plain shell — leaves a pane option saying it is working. The
# status line then shows a busy agent forever, which is worse than showing nothing:
# the whole point of the icons is to be trusted from across the room.
#
# There is no process to ask, because the plugin never launched one and holds no pid
# (ADR-0001: everything arrives as argv from the agent's own hooks). What it does
# have is the snapshot `state` took when it wrote: the pane's command *then*. If the
# pane's command now is a different one, whatever reported that state is not what is
# running in there any more.
#
# Sourced by lib/common.sh, so every command has it.

# What one pane contributes to the sweep's decision, as a format.
#
# The comparisons are made by tmux rather than by the shell, and that is the point
# of the shape: a record read as fields cannot hold a value with a space in it
# without shifting everything after it, and both a recorded command and a live one
# are strings from outside. So tmux answers three yes/no questions as digits — is
# this an agent pane, does it have a snapshot, does the snapshot still match — and
# the only free-form value is the live command, which comes last and is taken whole.
#
# `#{==:a,b}` splits its arguments at the literal comma in *this* string, before
# either side is expanded, so a comma inside a command name is not a delimiter.
#
# Reading a pane option through a format falls back to the window, session and
# global scopes, the same asymmetry lib/pane.sh documents for the pane record. The
# names are specific enough that nothing else sets them.
TAMA_STALE_READ_FORMAT='#{pane_id} #{?@tama_pane_state_main,1,0}#{?@tama_pane_cmd,1,0}#{==:#{@tama_pane_cmd},#{pane_current_command}} #{pane_current_command}'

# The fallback for a pane with no snapshot: a state written before the plugin
# recorded commands, or one whose command tmux could not express in a value the
# record can hold. Then there is nothing to compare, and the only safe reading of
# the pane is what it is running now — if that is a shell, nobody's agent is in
# there. Anything else is left alone, because "not a shell I know" is not evidence.
#
# Configurable, since a user's shell need not be one anybody guessed:
# `set -g @tama_gc_shells 'zsh nu'`.
TAMA_STALE_SHELLS_DEFAULT='sh bash zsh fish dash ksh mksh ash csh tcsh'

# Read at most once per process, and only when a pane without a snapshot actually
# turns up — which is the rare case. The common sweep is one tmux round trip.
_TAMA_STALE_SHELLS=''
_TAMA_STALE_SHELLS_READ=0

# Whether <command> is one of the shells the fallback recognises.
tama_stale_is_shell() { # <command>
  local command="$1" candidate
  # A login shell is `-zsh` to whoever counts argv[0]; tmux normally reports the
  # bare name, but the dash costs nothing to tolerate.
  command="${command#-}"
  [ -n "$command" ] || return 1

  if [ "$_TAMA_STALE_SHELLS_READ" = 0 ]; then
    _TAMA_STALE_SHELLS="$(tama_opt tama_gc_shells "$TAMA_STALE_SHELLS_DEFAULT")"
    _TAMA_STALE_SHELLS_READ=1
  fi

  # Globbing off: a shell name is not a pattern, and `*` in the option must not
  # match every command by way of the working directory.
  set -f
  # shellcheck disable=SC2086  # deliberate: the allowlist is space separated
  set -- $_TAMA_STALE_SHELLS
  set +f
  for candidate in "$@"; do
    [ "$command" = "$candidate" ] && return 0
  done
  return 1
}

# The stale panes of one window.
tama_stale_sweep_window() { # <target>
  _tama_stale_sweep list-panes -t "$1"
}

# The stale panes of the whole server. The expensive scope, wired to the one event
# that is both rare and exactly when the user is about to read every window at
# once: their terminal regaining focus.
tama_stale_sweep_server() {
  _tama_stale_sweep list-panes -a
}

# Clears every stale pane the given `list-panes` invocation reports. One tmux call
# to read, one to write, and no write at all when nothing was stale — which is the
# ordinary case, and this runs on every pane selection.
#
# Never fails: every caller is a hook or a key binding, where a non-zero exit is
# noise in the server log and nothing a user can act on.
_tama_stale_sweep() { # <list-panes …>
  local raw line pane flags current found=0

  # A window or a pane that has gone between the event and this running is nothing
  # to do, not an error.
  raw="$(tmux_run "$@" -F "$TAMA_STALE_READ_FORMAT" 2>/dev/null)" || return 0

  tama_batch_reset
  # A here-document rather than a pipe, so the loop is not in a subshell and the
  # batch it stages survives it.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pane="${line%% *}"
    flags="${line#* }"
    # The live command is whatever follows the digits, taken whole: it is the one
    # field that can hold a space.
    current="${flags#* }"
    flags="${flags%% *}"

    # Three digits: is this an agent pane, does it have a snapshot, does the
    # snapshot still match what the pane is running.
    case "$flags" in
      # Not an agent pane: nothing of ours to sweep. The overwhelming majority.
      0??) continue ;;
      # A snapshot that still matches: the agent that reported this is still what
      # is running in there. Preserved, and that is half of what this command is
      # for — a sweep that cleared a live agent would be worse than one that
      # cleared nothing at all.
      111) continue ;;
      # A snapshot, and the pane is running something else now. Stale.
      110) ;;
      # No snapshot to compare, so the allowlist decides. The third digit says
      # nothing here: tmux compared the live command against an empty string.
      10?) tama_stale_is_shell "$current" || continue ;;
      # A record that did not come back in the shape this asked for. Leaving the
      # pane alone is the direction that cannot take a live agent's icon away.
      *) continue ;;
    esac

    tama_pane_stage_clear "$pane"
    found=1
  done <<EOF
$raw
EOF

  [ "$found" = 1 ] || return 0
  # An icon going away is a change the user sees, so this is worth the redraw.
  tama_batch_flush 'yes' || true
  return 0
}
