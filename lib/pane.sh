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

# Everything a status line needs about one pane, as a format, and the one function
# that takes such a record apart. Both live here, next to the writer of the values:
# a rename or a reordering on one side and not the other would leave every status
# line empty with nothing to say why.
#
# The fields are separated by a space, because a state is one of five words and
# nothing else is read from this: whatever follows the first one is the subagent
# list, and only whether it is empty matters. It cannot be a control character —
# see tama_pane_read.
# shellcheck disable=SC2034  # read by libexec/icons, which sources this file
TAMA_PANE_RENDER_FORMAT='#{@tama_pane_state_main} #{@tama_pane_subagents}'

# Derives the state of one such record. Parameter expansion rather than `read`,
# because the caller is the icon command and it must not fork.
tama_pane_derive_record() { # <record>
  # Everything after the first space is the subagent list, whole, so a record that
  # grows a field cannot quietly turn every idle pane into a busy one.
  local main="${1%% *}"
  tama_pane_derive "$main" "${1#* }"
}

# The read: the pane's identity, everything it last said about itself — there are
# five options and no state file, the tmux server is the database — and the live
# command and path a fresh report snapshots.
#
# One `display-message` per field, batched into a single invocation, so each value
# arrives on a line of its own and nothing has to separate them. A separator was the
# obvious thing and is not available: tmux prints to a client through an escaper, so
# a byte like a unit separator arrives as the four characters `\037` on some versions
# and locales and intact on others. That collapsed every field into one, and since
# the first field is the pane every write targets, the plugin quietly wrote nothing
# anywhere — green on one machine, dead on another. A newline cannot be smuggled
# either; it arrives as `_`.
#
# The number of lines is therefore the integrity check, and a value holding a
# control character is refused at the boundary — see tama_pane_value_is_storable —
# rather than left to shift the record.
#
# One asymmetry to know about: reading an option through a *format* falls back to
# the window, session and global scopes, while `show -p` does not. Nothing sets
# these names at any other scope, and a user who set `@tama_pane_state_main`
# globally would give every pane on the server an icon — which is why the names are
# specific enough that nobody will.
TAMA_PANE_READ_FIELDS='#{pane_id}
#{@tama_pane_state_main}
#{@tama_pane_subagents}
#{@tama_pane_cmd}
#{@tama_pane_agent}
#{@tama_pane_cwd}
#{pane_current_command}
#{pane_current_path}
.'
# Nine, not eight: the sentinel at the end is there because command substitution
# strips trailing newlines, so a last field that is legitimately empty — tmux cannot
# always tell what a pane's directory is — would be indistinguishable from a line
# that never arrived.
TAMA_PANE_READ_COUNT=9

# Reads everything about a pane at once. Returns non-zero when there is no such
# pane, or when the record did not come back whole.
#
# Sets TAMA_PANE_ID and one variable per field, plus TAMA_PANE_DISPLAY: what this
# pane draws as of this read, since every writer needs it to decide whether a
# refresh is owed. TAMA_PANE_ID is the canonical `%id`, which is what every write
# below targets — the caller may well have been given a pane by index, and an index
# moves.
# The fields are this library's output, read by its callers rather than by it.
# shellcheck disable=SC2034
tama_pane_read() {
  local raw field lines=0 target="$1"
  # One tmux command per field, all in one invocation. Built here rather than kept
  # as a constant because the target belongs in every one of them.
  set --
  while IFS= read -r field; do
    [ "$#" -eq 0 ] || set -- "$@" ';'
    set -- "$@" display-message -p -t "$target" "$field"
  done <<EOF
$TAMA_PANE_READ_FIELDS
EOF
  raw="$(tmux_run "$@" 2>/dev/null)" || raw=''

  TAMA_PANE_ID=''
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
      2) TAMA_PANE_STATE_MAIN="$field" ;;
      3) TAMA_PANE_SUBAGENTS="$field" ;;
      4) TAMA_PANE_CMD="$field" ;;
      5) TAMA_PANE_AGENT="$field" ;;
      6) TAMA_PANE_CWD="$field" ;;
      7) TAMA_PANE_CURRENT_CMD="$field" ;;
      8) TAMA_PANE_CURRENT_PATH="$field" ;;
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

# Every pane option the plugin owns, in one list, because two things take a pane
# apart again: `state clear` and the stale-state sweep. An option added to the
# record above and not here would survive both of them, and a pane that keeps one
# is a pane a later read can still tell from one that never ran an agent.
TAMA_PANE_OPTIONS='state_main
subagents
cmd
agent
cwd'

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
tama_batch_flush() { # <refresh: yes|no>
  [ "$TAMA_BATCH_COUNT" -gt 0 ] || return 1
  [ "$1" = 'no' ] || tama_batch_add refresh-client -S
  # A write that did not land is not worth failing an agent's turn over.
  tmux_run "${TAMA_BATCH[@]}" >/dev/null 2>&1 || true
  tama_batch_reset
  return 0
}
