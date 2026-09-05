# shellcheck shell=bash
#
# Clears state left by agents that exit without reporting. A changed
# `pane_current_command` is not sufficient evidence because tmux may report an
# editor or pager opened by a live agent; only an allowlisted shell confirms it.

# tmux performs the comparisons so free-form command names cannot shift fields.
# The fourth digit also exposes residue on panes that have no main state.
TAMA_STALE_READ_FORMAT='#{pane_id} #{window_id} #{?@tama_pane_state_main,1,0}#{?@tama_pane_cmd,1,0}#{==:#{@tama_pane_cmd},#{pane_current_command}}#{?#{@tama_pane_subagents}#{@tama_pane_cmd}#{@tama_pane_agent}#{@tama_pane_cwd}#{@tama_pane_label},1,0} #{pane_current_command}'

# Only a known shell is evidence that the agent returned to a prompt.
TAMA_STALE_SHELLS_DEFAULT='sh bash zsh fish dash ksh mksh ash csh tcsh'

# Lazily cached so the common sweep remains one tmux round trip.
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

tama_stale_sweep_window() { # <target>
  _tama_stale_sweep list-panes -t "$1"
}

# The server-wide sweep runs only when the terminal regains focus.
tama_stale_sweep_server() {
  _tama_stale_sweep list-panes -a
}

# Clears every stale pane the given `list-panes` invocation reports. One tmux call
# to read, one to write, and no write at all when nothing was stale — which is the
# ordinary case, and this runs on every pane selection.
#
# Never fails: every caller is a hook or a key binding, where a non-zero exit is
# noise in the server log and nothing a user can act on.
# shellcheck disable=SC2034 # TAMA_STALE_SWEEP_STATUS is read by command owners.
_tama_stale_sweep() { # <list-panes …>
  local raw line pane window_id flags current found=0 changed_windows=''
  TAMA_STALE_SWEEP_STATUS=skipped

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
    window_id="${flags%% *}"
    flags="${flags#* }"
    # The live command is whatever follows the digits, taken whole: it is the one
    # field that can hold a space.
    current="${flags#* }"
    flags="${flags%% *}"

    # Flags: main state, snapshot, snapshot match, and any plugin residue.
    case "$flags" in
      0??0) continue ;;
      # Residue without state cannot heal because the pane draws no icon.
      0??1) ;;
      111?) continue ;;
      # A mismatch is stale only when the pane has returned to a known shell.
      1???) tama_stale_is_shell "$current" || continue ;;
      # Malformed records must not clear a possibly live agent.
      *) continue ;;
    esac

    tama_pane_stage_clear "$pane"
    case "
$changed_windows
" in
      *"
$window_id
"*) ;;
      *) changed_windows="${changed_windows:+$changed_windows
}$window_id" ;;
    esac
    found=1
  done <<EOF
$raw
EOF

  [ "$found" = 1 ] || return 0
  # An icon going away is a change the user sees, so this is worth the redraw.
  tama_batch_flush 'no' || true
  TAMA_STALE_SWEEP_STATUS="$TAMA_BATCH_WRITE_STATUS"
  while IFS= read -r window_id; do
    [ -n "$window_id" ] || continue
    tama_summary_refresh_window "$window_id"
  done <<EOF
$changed_windows
EOF
  return 0
}
