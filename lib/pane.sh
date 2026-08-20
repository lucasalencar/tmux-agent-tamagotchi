# shellcheck shell=bash
#
# Pane state model. Derived state is computed on read so concurrent main-state and
# subagent events cannot leave a stale stored derivation (ADR-0005).

# Keep render format and parser together so their field order cannot drift.
# shellcheck disable=SC2034  # read by libexec/icons, which sources this file
TAMA_PANE_RENDER_FORMAT='#{@tama_pane_state_main} #{@tama_pane_subagents}'

# Parameter expansion avoids a fork on the status-line hot path.
tama_pane_derive_record() { # <record>
  local main="${1%% *}"
  tama_pane_derive "$main" "${1#* }"
}

# Pane state and its live snapshot, read in one tmux round trip.
TAMA_PANE_READ_FIELDS='#{pane_id}
#{window_id}
#{@tama_pane_state_main}
#{@tama_pane_subagents}
#{@tama_pane_cmd}
#{@tama_pane_agent}
#{@tama_pane_cwd}
#{pane_current_command}
#{pane_current_path}
.'
# Includes the sentinel required by tama_fields_read.
TAMA_PANE_READ_COUNT=10

# Populates TAMA_PANE_* and rejects incomplete or vanished-pane records.
# shellcheck disable=SC2034
tama_pane_read() {
  local raw field lines=0
  raw="$(tama_fields_read "$1" "$TAMA_PANE_READ_FIELDS")" || raw=''

  TAMA_PANE_ID=''
  TAMA_PANE_WINDOW_ID=''
  TAMA_PANE_STATE_MAIN=''
  TAMA_PANE_SUBAGENTS=''
  TAMA_PANE_CMD=''
  TAMA_PANE_AGENT=''
  TAMA_PANE_CWD=''
  TAMA_PANE_CURRENT_CMD=''
  TAMA_PANE_CURRENT_PATH=''
  while IFS= read -r field; do
    lines=$((lines + 1))
    case "$lines" in
      1) TAMA_PANE_ID="$field" ;;
      2) TAMA_PANE_WINDOW_ID="$field" ;;
      3) TAMA_PANE_STATE_MAIN="$field" ;;
      4) TAMA_PANE_SUBAGENTS="$field" ;;
      5) TAMA_PANE_CMD="$field" ;;
      6) TAMA_PANE_AGENT="$field" ;;
      7) TAMA_PANE_CWD="$field" ;;
      8) TAMA_PANE_CURRENT_CMD="$field" ;;
      9) TAMA_PANE_CURRENT_PATH="$field" ;;
    esac
  done <<EOF
$raw
EOF

  tama_pane_derive "$TAMA_PANE_STATE_MAIN" "$TAMA_PANE_SUBAGENTS"
  TAMA_PANE_DISPLAY="$TAMA_PANE_DERIVED"

  # A short read is a pane that is gone — tmux says so by expanding #{pane_id} to
  # nothing rather than by failing — or a record that did not survive the trip, and
  # writing from either would write somewhere else.
  [ "$lines" -eq "$TAMA_PANE_READ_COUNT" ] && [ -n "$TAMA_PANE_ID" ]
}

# The plugin's one derivation, in the one place everything that renders or compares
# a state reaches it: an `idle` main state with at least one live subagent displays
# as `background`, which is "its children are still busy", not "finished". Sets
# TAMA_PANE_DERIVED.
#
# A pane with no main state has no display state either — that, and not an empty
# string, is what makes it not an agent pane.
# shellcheck disable=SC2034  # TAMA_PANE_DERIVED is read by the caller
tama_pane_derive() { # <state_main> <subagents>
  case "$1" in
    '') TAMA_PANE_DERIVED='' ;;
    idle)
      if [ -n "$2" ]; then
        TAMA_PANE_DERIVED='background'
      else
        TAMA_PANE_DERIVED='idle'
      fi
      ;;
    *) TAMA_PANE_DERIVED="$1" ;;
  esac
}

# The subagent list: opaque ids the agent's hooks supply, space separated. The
# plugin counts them and knows nothing else about them.
#
# Globbing is off around the splits because an id is not a pattern: an id
# containing `*` would otherwise be replaced by the working directory's contents.

# Whether <id> is one of the live subagents in <list>. Also what the writer uses
# to ask whether its own call still holds after the fact.
tama_subagents_contains() { # <list> <id>
  local id="$2" existing
  set -f
  # shellcheck disable=SC2086  # deliberate: the list is space separated
  set -- $1
  set +f
  for existing in "$@"; do
    [ "$existing" = "$id" ] && return 0
  done
  return 1
}

# Sets TAMA_SUBAGENTS_NEW to the list with <id> present. Already being there is
# the whole answer — a duplicate start is idempotent, which is what makes a hook
# that fires twice harmless.
# shellcheck disable=SC2034  # TAMA_SUBAGENTS_NEW is read by the caller
tama_subagents_add() { # <list> <id>
  if tama_subagents_contains "$1" "$2"; then
    TAMA_SUBAGENTS_NEW="$1"
  else
    TAMA_SUBAGENTS_NEW="${1:+$1 }$2"
  fi
}

# Sets TAMA_SUBAGENTS_NEW to the list without <id>. An id that is not there
# leaves the list alone, so stopping an unknown subagent is a no-op.
# shellcheck disable=SC2034  # TAMA_SUBAGENTS_NEW is read by the caller
tama_subagents_remove() { # <list> <id>
  local list="$1" id="$2" kept='' existing
  set -f
  # shellcheck disable=SC2086  # deliberate: the list is space separated
  set -- $list
  set +f
  for existing in "$@"; do
    [ "$existing" = "$id" ] && continue
    kept="${kept:+$kept }$existing"
  done
  TAMA_SUBAGENTS_NEW="$kept"
}

# Whether a write would change what a status line shows, which is the only thing
# worth refreshing every client for. Both arguments are derived states, so the
# comparison is of what a user would see and not of what was stored.
tama_pane_display_changed() { # <derived_before> <derived_after>
  [ "$1" != "$2" ]
}

# Whether a value can survive being stored in a pane option and read back as one
# line of the record above. A control character cannot: a newline adds a line and
# shifts every field after it, and the others come back escaped into several
# characters on some tmux versions and locales — so the value would never equal
# itself again, and every later report would write and refresh for nothing.
tama_pane_value_is_storable() { # <value>
  case "$1" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# Every owned pane option must be cleared here and represented in stale residue.
# `label` is omitted from the hot read path but still belongs in this list.
TAMA_PANE_OPTIONS='state_main
subagents
cmd
agent
cwd
label'

# Writes are batched into a single tmux invocation, because the alternative is
# one round trip per option on the hottest write path in the plugin.

# The count is kept alongside the array rather than read off it, because bash 3.2
# — the /bin/bash every macOS ships — treats expanding an empty array as an unset
# variable under `nounset` and dies. Nothing may expand TAMA_BATCH until something
# has been added to it.
tama_batch_reset() {
  TAMA_BATCH=()
  TAMA_BATCH_COUNT=0
}

# tmux parses a trailing `;` as a command separator even inside an argument. Escape
# that final byte centrally so every stored value survives the batch unchanged.
tama_batch_add() {
  local word
  [ "$TAMA_BATCH_COUNT" -eq 0 ] || TAMA_BATCH+=(';')
  for word in "$@"; do
    case "$word" in
      *\;) TAMA_BATCH+=("${word%;}\\;") ;;
      *) TAMA_BATCH+=("$word") ;;
    esac
  done
  TAMA_BATCH_COUNT=$((TAMA_BATCH_COUNT + 1))
}

# Stages one pane option — or nothing at all, when what is stored already says
# this. An empty new value *unsets* the option rather than writing an empty
# string: a cleared pane has to be indistinguishable from one that never ran an
# agent, and an option set to "" is still an option that is set.
tama_pane_stage() { # <pane_id> <option> <new> <stored>
  [ "$3" = "$4" ] && return 0
  if [ -n "$3" ]; then
    # A value that tmux would read as a command separator is escaped by
    # tama_batch_add, for every caller rather than for this one.
    tama_batch_add set -p -t "$1" "@tama_pane_$2" "$3"
  else
    tama_batch_add set -puq -t "$1" "@tama_pane_$2"
  fi
}

# Stages the removal of every trace of an agent from <pane_id>. Unconditional,
# unlike tama_pane_stage: `set -puq` on an option nobody set is free and cannot
# fail, and asking first would cost a read per option — which the sweep, judging a
# whole server from one list-panes, deliberately does not have. The caller decides
# whether there was anything to remove at all.
tama_pane_stage_clear() { # <pane_id>
  local option
  while IFS= read -r option; do
    tama_batch_add set -puq -t "$1" "@tama_pane_$option"
  done <<EOF
$TAMA_PANE_OPTIONS
EOF
}

# Sends what was staged. Nothing staged sends nothing and returns non-zero — the
# short-circuit that makes a repeated `state running` free.
#
# Whether to force the clients to redraw is asked for separately. Writing any user
# option already redraws every attached client, so this is not about the redraw: it
# is that tmux reruns a `#()` job at most once a second and otherwise draws the
# output it already had, so a change nobody forced can sit on screen stale until
# that client's own status-interval comes round — measured at over six seconds for
# changes a third of a second apart. Only a change the status line would show is
# worth that, and there is nothing to force for a snapshot nobody draws.
tama_batch_flush() { # <refresh: yes|no> [changed window id]
  local refresh="$1" window_id="${2:-}"
  [ "$TAMA_BATCH_COUNT" -gt 0 ] || return 1
  [ "$refresh" = 'no' ] || [ -n "$window_id" ] || tama_batch_add refresh-client -S
  # A write that did not land is not worth failing an agent's turn over.
  tmux_run "${TAMA_BATCH[@]}" >/dev/null 2>&1 || true
  tama_batch_reset
  [ "$refresh" = 'no' ] || [ -z "$window_id" ] || tama_summary_refresh_window "$window_id"
  return 0
}
