# shellcheck shell=bash
#
# The state model: everything the plugin knows about a pane, read in one tmux
# round trip, derived into the one state a status line shows, and written back
# only where it actually changed.
#
# The derived state is *not* stored. It was, and two commands wrote it — a state
# report derived it from the subagents it had just read, a subagent event from the
# state it had just read — so the ordinary pair of events an agent ends a turn with
# (its own `idle` and its last subagent stopping) raced, and the loser left a pane
# claiming `background` with no subagents, or `idle` with one still live. Nothing
# healed it, because `idle` is the last thing an agent says until the user types
# again. Deriving where it is read costs nothing — the icons already read the pane
# options of a whole window in one call, and now read two of them instead of one —
# and there is no second writer to disagree with.
#
# Sourced by lib/common.sh, so every command has it.
#
# Why one round trip: `state running` is reported on every tool call of every
# agent, and a tmux round trip costs a few milliseconds. Reading the pane's five
# options one `show -p` at a time would cost more than the event being reported.

# Field separator for the batched read and write. A unit separator appears in no
# pane id, state name, agent name or path anybody will ever have.
TAMA_US=$'\037'

# Everything a status line needs about one pane, as a format, and the one function
# that takes such a record apart. Both live here, next to the writer of the values:
# a rename or a reordering on one side and not the other would leave every status
# line empty with nothing to say why.
TAMA_PANE_RENDER_FORMAT="#{@tama_pane_state_main}$TAMA_US#{@tama_pane_subagents}"

# Derives the state of one such record. Parameter expansion rather than `read`,
# because the caller is the icon command and it must not fork.
tama_pane_derive_record() { # <record>
  local main="${1%%"$TAMA_US"*}" rest="${1#*"$TAMA_US"}"
  # Everything after the first separator is the subagent list, so a record that
  # grows a field cannot quietly turn every idle pane into a busy one.
  tama_pane_derive "$main" "${rest%%"$TAMA_US"*}"
}

# The read: the pane's identity, everything it last said about itself — there are
# five options and no state file, the tmux server is the database — and the live
# command and path a fresh report snapshots. Spelled out field by field, in the
# order the variables below are: a loop over a list of names would look like it
# enforced that order without doing it, since the unpack has to name them anyway.
#
# One asymmetry to know about: reading an option through a *format* falls back to
# the window, session and global scopes, while `show -p` does not. Nothing sets
# these names at any other scope, and a user who set `@tama_pane_state_main`
# globally would give every pane on the server an icon — which is why the names are
# specific enough that nobody will.
TAMA_PANE_READ_FORMAT="#{pane_id}$TAMA_US$TAMA_PANE_RENDER_FORMAT"
TAMA_PANE_READ_FORMAT="$TAMA_PANE_READ_FORMAT$TAMA_US#{@tama_pane_cmd}"
TAMA_PANE_READ_FORMAT="$TAMA_PANE_READ_FORMAT$TAMA_US#{@tama_pane_agent}"
TAMA_PANE_READ_FORMAT="$TAMA_PANE_READ_FORMAT$TAMA_US#{@tama_pane_cwd}"
TAMA_PANE_READ_FORMAT="$TAMA_PANE_READ_FORMAT$TAMA_US#{pane_current_command}"
TAMA_PANE_READ_FORMAT="$TAMA_PANE_READ_FORMAT$TAMA_US#{pane_current_path}"

# Reads everything about a pane at once. Returns non-zero when there is no such
# pane: display-message reports that by expanding #{pane_id} to nothing rather
# than by failing, so the id is what gets checked.
#
# Sets TAMA_PANE_ID and one variable per field, plus TAMA_PANE_DISPLAY: what this
# pane draws as of this read, since every writer needs it to decide whether a
# refresh is owed. TAMA_PANE_ID is the canonical `%id`, which is what every write
# below targets — the caller may well have been given a pane by index, and an index
# moves.
# The fields are this library's output, read by its callers rather than by it.
# shellcheck disable=SC2034
tama_pane_read() {
  local raw
  raw="$(tmux_run display-message -p -t "$1" "$TAMA_PANE_READ_FORMAT" 2>/dev/null)" || raw=''
  # Checked before the unpack rather than after: the separator is not whitespace,
  # so `read` would hand the newline of an empty read to the first field and every
  # caller's "no such pane" guard would be dead code.
  [ -n "$raw" ] || return 1
  # `-d ''` reads to the end of the input rather than to the end of the first
  # line, so a newline inside a value is data instead of the end of the record.
  # Without it a directory — or an agent name — containing one truncates the read:
  # the command snapshot silently comes back empty, and the pane then differs from
  # itself on every report, which defeats the write short-circuit for good.
  IFS="$TAMA_US" read -r -d '' TAMA_PANE_ID TAMA_PANE_STATE_MAIN TAMA_PANE_SUBAGENTS \
    TAMA_PANE_CMD TAMA_PANE_AGENT TAMA_PANE_CWD \
    TAMA_PANE_CURRENT_CMD TAMA_PANE_CURRENT_PATH <<EOF
$raw
EOF
  # The last field ends at the newline the here-document adds, not at a separator.
  TAMA_PANE_CURRENT_PATH="${TAMA_PANE_CURRENT_PATH%$'\n'}"
  tama_pane_derive "$TAMA_PANE_STATE_MAIN" "$TAMA_PANE_SUBAGENTS"
  TAMA_PANE_DISPLAY="$TAMA_PANE_DERIVED"
  [ -n "$TAMA_PANE_ID" ]
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
# field of the record above. A newline would be kept by the read but lost from the
# last field, and the separator itself would shift every field after it — which
# corrupts the command snapshot and leaves the pane unable to recognise itself, so
# every later report writes and refreshes for nothing.
tama_pane_value_is_storable() { # <value>
  case "$1" in
    *[$'\n\r']* | *"$TAMA_US"*) return 1 ;;
  esac
}

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

# One tmux command, as its words. tmux takes `;` as its own argument.
tama_batch_add() {
  [ "$TAMA_BATCH_COUNT" -eq 0 ] || TAMA_BATCH+=(';')
  TAMA_BATCH+=("$@")
  TAMA_BATCH_COUNT=$((TAMA_BATCH_COUNT + 1))
}

# Stages one pane option — or nothing at all, when what is stored already says
# this. An empty new value *unsets* the option rather than writing an empty
# string: a cleared pane has to be indistinguishable from one that never ran an
# agent, and an option set to "" is still an option that is set.
tama_pane_stage() { # <pane_id> <option> <new> <stored>
  [ "$3" = "$4" ] && return 0
  if [ -n "$3" ]; then
    # tmux reads an argument that ends in `;` as the end of a command, strips it,
    # and starts parsing the next one — so a value ending in a semicolon would be
    # stored without it, and could take the rest of the batch with it. Escaping
    # only the last one is deliberate: tmux leaves a `;` anywhere else alone, and
    # would keep the backslash if we escaped it.
    case "$3" in
      *\;) tama_batch_add set -p -t "$1" "@tama_pane_$2" "${3%;}\\;" ;;
      *) tama_batch_add set -p -t "$1" "@tama_pane_$2" "$3" ;;
    esac
  else
    tama_batch_add set -puq -t "$1" "@tama_pane_$2"
  fi
}

# Sends what was staged. Nothing staged sends nothing and returns non-zero — the
# short-circuit that makes a repeated `state running` free.
#
# Refreshing the clients is asked for separately, because it costs far more than
# the write: it redraws every status line, which re-runs the icon command once per
# window on the server. Only a change the status line would show is worth that —
# the command and path snapshots are for a later sweep, and nobody draws them.
#
# The refresh goes last because tmux abandons the rest of a batch when one
# command fails, and this is the one that fails when no client is attached.
tama_batch_flush() { # <refresh: yes|no>
  [ "$TAMA_BATCH_COUNT" -gt 0 ] || return 1
  [ "$1" = 'no' ] || tama_batch_add refresh-client -S
  # A write that did not land is not worth failing an agent's turn over.
  tmux_run "${TAMA_BATCH[@]}" >/dev/null 2>&1 || true
  tama_batch_reset
  return 0
}
