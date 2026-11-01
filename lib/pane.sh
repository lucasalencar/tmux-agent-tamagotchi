# shellcheck shell=bash
#
# Pane state model. Derived state is computed on read so concurrent main-state and
# subagent events cannot leave a stale stored derivation (ADR-0005).

# Splits a legacy `main subs…` pane record. Parameter expansion avoids a fork
# on the status-line hot path. Icons reads panes with an explicit per-command
# format instead, because the agent block joins by pane id rather than by
# position.
tama_pane_derive_record() { # <record>
  local main="${1%% *}"
  tama_pane_derive "$main" "${1#* }"
}

# Pane state and its live snapshot, read in one tmux round trip.
TAMA_PANE_READ_FIELDS='#{pane_id}
#{window_id}
#{@tama_pane_state_main}
#{@tama_pane_subagents}
#{@tama_pane_agents}
#{@tama_pane_cmd}
#{@tama_pane_agent}
#{@tama_pane_cwd}
#{pane_current_command}
#{pane_current_path}
.'
# Includes the sentinel required by tama_fields_read.
TAMA_PANE_READ_COUNT=11

# Populates TAMA_PANE_* and rejects incomplete or vanished-pane records.
# shellcheck disable=SC2034
tama_pane_read() {
  local raw field lines=0
  raw="$(tama_fields_read "$1" "$TAMA_PANE_READ_FIELDS")" || raw=''

  TAMA_PANE_ID=''
  TAMA_PANE_WINDOW_ID=''
  TAMA_PANE_STATE_MAIN=''
  TAMA_PANE_SUBAGENTS=''
  TAMA_PANE_AGENTS=''
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
      5) TAMA_PANE_AGENTS="$field" ;;
      6) TAMA_PANE_CMD="$field" ;;
      7) TAMA_PANE_AGENT="$field" ;;
      8) TAMA_PANE_CWD="$field" ;;
      9) TAMA_PANE_CURRENT_CMD="$field" ;;
      10) TAMA_PANE_CURRENT_PATH="$field" ;;
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

# Agent entries: independent per-agent reports inside one pane, for agents that
# can name their own runs (OpenCode session ids). One option per pane holds
# every entry, so the status line still reads the pane in a single round trip:
#
#   @tama_pane_agents = 'id=state/sub1,sub2;id=state/'
#
# An entry is `agent-id=main-state/subagent-id,subagent-id`; an empty subagent
# list is a bare trailing `/`. Agent ids are integration-supplied opaque
# values in `[A-Za-z0-9._-]+`: no whitespace (they travel in space-separated
# lists and option names), no control characters (nothing storable survives
# them), and none of the structural `= / , ;` characters. Main states are the
# four reportable domain states; `background` is derived on read, never stored.
#
# Several writers share the one option, so every mutation is read-modify-write
# with the same optimistic retry the flat subagent list uses: writers verify
# their own slice on read-back, and a pane `clear` always wins. Concurrent
# writes carrying identical sticky values are harmless, which is the common
# case — states persist until something changes them.

# Whether <id> may name an agent entry. Loud boundary like the subagent id
# check, but stricter: these ids are embedded in option names and in the
# encoded record, where whitespace, control characters, and the structural
# `= / , ;` characters would corrupt the pane or its neighbours.
tama_agent_id_is_valid() { # <id>
  case "$1" in
    '') return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  tama_pane_value_is_storable "$1"
}

# Whether <state> is a reportable agent main state. Unknown states are never
# stored: like the pane-level `state` command, a hook written for a newer
# plugin stays silent on an older one rather than failing its turn.
tama_agent_state_is_valid() { # <state>
  case "$1" in
    running | waiting | idle | error) return 0 ;;
  esac
  return 1
}

# Prints one `id state subs` line per entry, with an empty state for entries
# that only track subagents so far. Unset-but-valid callers treat a missing
# option as the empty record; anything malformed fails: rendering must never
# draw a neighbour's bytes as an agent.
tama_agents_parse() { # <record>
  local rest="$1" rec id rs state subs s r2
  [ -n "$rest" ] || return 1
  while [ -n "$rest" ]; do
    rec="${rest%%;*}"
    if [ "$rec" = "$rest" ]; then rest=''; else rest="${rest#*;}"; fi
    case "$rec" in *=*/*) ;; *) return 1 ;; esac
    id="${rec%%=*}"
    rs="${rec#*=}"
    state="${rs%%/*}"
    subs="${rs#*/}"
    tama_agent_id_is_valid "$id" || return 1
    if [ -n "$state" ]; then
      tama_agent_state_is_valid "$state" || return 1
    fi
    if [ -n "$subs" ]; then
      r2="$subs"
      while :; do
        s="${r2%%,*}"
        tama_agent_id_is_valid "$s" || return 1
        [ "$s" = "$r2" ] && break
        r2="${r2#*,}"
      done
    fi
    printf '%s %s %s\n' "$id" "$state" "$subs"
  done
}

# Splits one `id state subs` line from tama_agents_parse. The result is in
# TAMA_AGENTS_AID, TAMA_AGENTS_ASTATE, and TAMA_AGENTS_ASUBS, so every
# consumer unpacks the parse format in exactly one place.
# shellcheck disable=SC2034  # read by the tama_agents_* callers
tama_agents_split_line() { # <line>
  TAMA_AGENTS_AID="${1%% *}"
  TAMA_AGENTS_ASTATE="${1#* }"; TAMA_AGENTS_ASTATE="${TAMA_AGENTS_ASTATE%% *}"
  TAMA_AGENTS_ASUBS="${1##* }"
}

# Prints the record with <id> reporting <state>, preserving entry order: an
# existing entry keeps its position, a new one appends. State and id are
# validated; anything else fails before touching tmux.
tama_agents_set_state() { # <record> <id> <state>
  local record="$1" id="$2" state="$3" line aid astate asubs out='' found=no parsed
  tama_agent_id_is_valid "$id" || return 1
  tama_agent_state_is_valid "$state" || return 1
  if [ -n "$record" ]; then
    parsed="$(tama_agents_parse "$record")" || return 1
    while IFS= read -r line; do
      tama_agents_split_line "$line"
      aid="$TAMA_AGENTS_AID"; astate="$TAMA_AGENTS_ASTATE"; asubs="$TAMA_AGENTS_ASUBS"
      if [ "$aid" = "$id" ]; then
        astate="$state"
        found=yes
      fi
      out="${out:+$out;}$aid=$astate/$asubs"
    done <<EOF
$parsed
EOF
  fi
  if [ "$found" = yes ]; then
    printf '%s' "$out"
  else
    printf '%s' "${out:+$out;}$id=$state/"
  fi
}

# Prints the record without <id>. An unknown id leaves the record alone, so
# unregistering twice is harmless.
tama_agents_remove() { # <record> <id>
  local record="$1" id="$2" line aid astate asubs out='' parsed
  tama_agent_id_is_valid "$id" || return 1
  [ -n "$record" ] || { printf ''; return 0; }
  parsed="$(tama_agents_parse "$record")" || return 1
  while IFS= read -r line; do
    tama_agents_split_line "$line"
    aid="$TAMA_AGENTS_AID"; astate="$TAMA_AGENTS_ASTATE"; asubs="$TAMA_AGENTS_ASUBS"
    [ "$aid" = "$id" ] && continue
    out="${out:+$out;}$aid=$astate/$asubs"
  done <<EOF
$parsed
EOF
  printf '%s' "$out"
}

# Prints the record with <id>'s subagent list replaced. An unknown agent is
# created stateless: like the flat subagent list, tracking may precede the
# first state report, and a stateless entry draws nothing until one arrives.
tama_agents_set_subs() { # <record> <id> <space-separated subs>
  local record="$1" id="$2" subs="$3" line aid astate asubs out='' found=no parsed stored
  tama_agent_id_is_valid "$id" || return 1
  # The record joins subagents with commas while the rest of the plugin speaks
  # space-separated lists; validate each id, then store the joined form.
  if [ -n "$subs" ]; then
    local r2="$subs" s
    stored=''
    set -f
    # shellcheck disable=SC2086 # deliberate: the caller's list is space separated
    for s in $subs; do
      tama_agent_id_is_valid "$s" || { set +f; return 1; }
      stored="${stored:+$stored,}$s"
    done
    set +f
  else
    stored=''
  fi
  if [ -n "$record" ]; then
    parsed="$(tama_agents_parse "$record")" || return 1
    while IFS= read -r line; do
      tama_agents_split_line "$line"
      aid="$TAMA_AGENTS_AID"; astate="$TAMA_AGENTS_ASTATE"; asubs="$TAMA_AGENTS_ASUBS"
      if [ "$aid" = "$id" ]; then
        asubs="$stored"
        found=yes
      fi
      out="${out:+$out;}$aid=$astate/$asubs"
    done <<EOF
$parsed
EOF
  fi
  if [ "$found" = yes ]; then
    printf '%s' "$out"
  else
    printf '%s' "${out:+$out;}$id=/$stored"
  fi
}

# Prints the record keeping only the listed ids, in listed order; states and
# subagent lists of survivors are preserved. Nothing listed empties the
# record. This is the existence healing the per-agent world needs: integrations
# with an authoritative snapshot drop ghosts without touching live entries.
# Duplicate listed ids are harmless: each entry is emitted once.
tama_agents_prune() { # <record> <id>…
  local record="$1" id out='' line aid astate asubs want parsed deduped=''
  shift
  [ -n "$record" ] || { printf ''; return 0; }
  for id in "$@"; do
    tama_agent_id_is_valid "$id" || return 1
    case " $deduped " in
      *" $id "*) ;;
      *) deduped="${deduped:+$deduped }$id" ;;
    esac
  done
  # Ids cannot hold whitespace by construction, so word splitting is exact.
  # shellcheck disable=SC2086
  set -- $deduped
  parsed="$(tama_agents_parse "$record")" || return 1
  while IFS= read -r line; do
    tama_agents_split_line "$line"
    aid="$TAMA_AGENTS_AID"; astate="$TAMA_AGENTS_ASTATE"; asubs="$TAMA_AGENTS_ASUBS"
    want=no
    for id in "$@"; do
      if [ "$aid" = "$id" ]; then want=yes; break; fi
    done
    [ "$want" = yes ] || continue
    out="${out:+$out;}$aid=$astate/$asubs"
  done <<EOF
$parsed
EOF
  # Listed order, not stored order: the snapshot is authoritative.
  local ordered='' oid rest seg sid
  for oid in "$@"; do
    rest="$out"
    while [ -n "$rest" ]; do
      seg="${rest%%;*}"
      if [ "$seg" = "$rest" ]; then rest=''; else rest="${rest#*;}"; fi
      sid="${seg%%=*}"
      [ "$sid" = "$oid" ] || continue
      ordered="${ordered:+$ordered;}$seg"
    done
  done
  printf '%s' "$ordered"
}

# Prints the record keeping the listed ids plus every stored entry outside
# <namespace>; entries under the namespace but not listed are dropped. Unlike
# prune, survivors keep stored order: the snapshot only covers the caller's
# own namespace, so it cannot claim authority over anyone else's positions.
# This is how an integration reconciles its live set on a pane it shares
# without dropping entries it can never enumerate.
tama_agents_prune_namespace() { # <record> <namespace> <id>…
  local record="$1" namespace="$2" line aid astate asubs out='' want parsed id
  shift 2
  [ -n "$namespace" ] || return 1
  tama_agent_id_is_valid "$namespace" || return 1
  [ -n "$record" ] || { printf ''; return 0; }
  for id in "$@"; do
    tama_agent_id_is_valid "$id" || return 1
  done
  parsed="$(tama_agents_parse "$record")" || return 1
  while IFS= read -r line; do
    tama_agents_split_line "$line"
    aid="$TAMA_AGENTS_AID"; astate="$TAMA_AGENTS_ASTATE"; asubs="$TAMA_AGENTS_ASUBS"
    case "$aid" in
      "$namespace"*)
        want=no
        for id in "$@"; do
          if [ "$aid" = "$id" ]; then want=yes; break; fi
        done
        [ "$want" = yes ] || continue
        ;;
    esac
    out="${out:+$out;}$aid=$astate/$asubs"
  done <<EOF
$parsed
EOF
  printf '%s' "$out"
}

# Whether <id> names an entry of the record, in any state.
tama_agents_has() { # <record> <id>
  local line parsed
  [ -n "$1" ] || return 1
  parsed="$(tama_agents_parse "$1")" || return 1
  while IFS= read -r line; do
    tama_agents_split_line "$line"
    [ "$TAMA_AGENTS_AID" = "$2" ] && return 0
  done <<EOF
$parsed
EOF
  return 1
}

# Prints the subagent list of one entry, space separated like the flat list,
# or nothing when the entry is unknown. Stateless entries still report their
# tracked ids: read-modify-write builds on this, and dropping them would
# silently discard subagents tracked before the first state report. The
# record stores them comma-separated; the translation happens here so the
# rest of the plugin keeps speaking the flat list's language.
tama_agents_subs() { # <record> <id>
  local line aid parsed
  [ -n "$1" ] || return 0
  parsed="$(tama_agents_parse "$1")" || return 1
  while IFS= read -r line; do
    tama_agents_split_line "$line"
    aid="$TAMA_AGENTS_AID"
    if [ "$aid" = "$2" ]; then
      printf '%s' "${TAMA_AGENTS_ASUBS//,/ }"
      return 0
    fi
  done <<EOF
$parsed
EOF
  return 0
}
# Space-joined derived states of one agent record, first-seen order.
# Stateless entries contribute nothing. Empty when the pane holds no agent
# entries — which is how every other writer knows the legacy single state
# still owns the pane.
tama_agents_display() { # <record>
  local line aid astate asubs out='' parsed
  [ -n "$1" ] || return 0
  parsed="$(tama_agents_parse "$1")" || return 1
  while IFS= read -r line; do
    tama_agents_split_line "$line"
    aid="$TAMA_AGENTS_AID"; astate="$TAMA_AGENTS_ASTATE"; asubs="$TAMA_AGENTS_ASUBS"
    [ -n "$astate" ] || continue
    tama_pane_derive "$astate" "$asubs"
    out="${out:+$out }$TAMA_PANE_DERIVED"
  done <<EOF
$parsed
EOF
  printf '%s' "$out"
}

# What a pane shows: its agents when it has any, the legacy single state
# otherwise. One rule everywhere something compares or renders a display, so
# an agent pane never flickers between the two halves.
tama_pane_agent_display() { # <agents record> <main> <subs>
  local agents_display
  agents_display="$(tama_agents_display "$1")" || agents_display=''
  if [ -n "$agents_display" ]; then
    printf '%s' "$agents_display"
  else
    tama_pane_derive "$2" "$3"
    printf '%s' "$TAMA_PANE_DERIVED"
  fi
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

# Number of opaque ids in the pane's space-delimited set, without exposing them.
# The result is in TAMA_SUBAGENTS_COUNT.
# shellcheck disable=SC2034  # read by writers in libexec/, which source this file
tama_subagents_count() { # <list>
  TAMA_SUBAGENTS_COUNT=0
  [ -n "$1" ] || return 0
  set -f
  # shellcheck disable=SC2086 # the record owns this space-delimited representation
  set -- $1
  set +f
  TAMA_SUBAGENTS_COUNT=$#
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
agents
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

# Stages the removal of every trace of an agent from <pane_id>, except the
# option named by <skip> when one is given (`agents`, for a clear that takes
# down one integration's presence while entries another integration still owns
# stay live). Unconditional, unlike tama_pane_stage: `set -puq` on an option
# nobody set is free and cannot fail, and asking first would cost a read per
# option — which the sweep, judging a whole server from one list-panes,
# deliberately does not have. The caller decides whether there was anything to
# remove at all.
tama_pane_stage_clear() { # <pane_id> [skip-option]
  local option
  while IFS= read -r option; do
    [ "${2:-}" = "$option" ] && continue
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
# shellcheck disable=SC2034  # TAMA_BATCH_WRITE_STATUS is read by writers in libexec/
tama_batch_flush() { # <refresh: yes|no> [changed window id]
  local refresh="$1" window_id="${2:-}"
  if [ "$TAMA_BATCH_COUNT" -eq 0 ]; then
    TAMA_BATCH_WRITE_STATUS=skipped
    return 1
  fi
  [ "$refresh" = 'no' ] || [ -n "$window_id" ] || tama_batch_add refresh-client -S
  # A write that did not land is not worth failing an agent's turn over.
  if tmux_run "${TAMA_BATCH[@]}" >/dev/null 2>&1; then
    TAMA_BATCH_WRITE_STATUS=applied
  else
    TAMA_BATCH_WRITE_STATUS=failed
  fi
  tama_batch_reset
  [ "$refresh" = 'no' ] || [ -z "$window_id" ] || tama_summary_refresh_window "$window_id"
  return 0
}
