# shellcheck shell=bash
#
# The window half of the model: which window an event belongs to, whether the user
# is looking at it, and the one mark that says a window wants attention.
#
# Sourced by lib/common.sh, so every command has it.
#
# Why this is not in lib/pane.sh: a pane owns a state, a window owns a flag, and
# the question this file exists to answer — "is the user looking at this?" — is
# asked about a window by two callers that have nothing else in common (the flag
# path here, and notification suppression later). Keeping it apart from the pane
# record also keeps the two round trips distinct: a `state running` reports on a
# pane and never asks anything about the window.

# The flag: a *window* option, because it means "something in this window wanted
# you", and it deliberately outlives the state that raised it. Only the user clears
# it, by selecting the window — see tama_flag_clear.
TAMA_WINDOW_FLAG_OPTION='@tama_window_flag'

# Everything the flag path and the notification path need to know about a window, in
# one tmux round trip.
#
# One value per line, like the pane record — see tama_fields_read in lib/common.sh
# for why, and for why the last field is followed by a sentinel. This record started
# out space separated on one line, because every field in it was a tmux-assigned id
# or an integer tmux counted itself; `#{session_name}` is neither, and a session
# called `my project` would have shifted every field after it.
#
# `#{window_active}` is the whole point of this file. It is resolved against the
# session of the *target*, not against whichever client happens to be ambient — so
# an agent in another session is judged by what that session is showing, which is
# the bug this replaces: comparing window *indexes* against the ambient client's
# index meant an agent in `work:3` was silently not flagged while the user looked at
# `main:3`. Indexes move under `renumber-windows` besides. Nothing here compares an
# index, and every write below targets `#{window_id}`.
#
# `#{pane_id}` is here because a target may be either: a hook reporting a state has
# a pane, a key binding has a window, and the notification path needs both — the
# window to flag and group by, and the pane to expand a title against and to land
# the click on. Against a window target tmux resolves it to that window's active
# pane, which is the pane a user clicking that window's banner means.
#
# `#{@tama_window_flag}` is read, not only written, so that the user arriving at a
# window can tell "there was a mark here" from "there was not" without a second
# round trip — which is what keeps a banner from being dismissed on every window
# selection. Reading an option through a format falls back to the window, session
# and global scopes, the same asymmetry lib/pane.sh documents; the exported
# `@tama_flag` format has always had it too.
TAMA_WINDOW_READ_FIELDS='#{window_id}
#{window_active}
#{session_attached}
#{session_name}
#{pane_id}
#{@tama_window_flag}
.'
TAMA_WINDOW_READ_COUNT=7

# Reads the window holding <target>, which may be a pane id, a window id, or
# anything else tmux resolves — the callers have a pane (a hook reporting a state)
# or a window (a key binding), and tmux resolves both to the one window this is
# about. Returns non-zero when there is no such window, or when the record did not
# come back whole; every caller treats that as nothing to do.
#
# Sets TAMA_WINDOW_ID — the canonical `@id`, which is what every write targets —
# plus the two facts tama_window_user_is_looking judges, the session the window
# belongs to, the pane the target resolved to, and whether the mark is already there.
# The fields are this library's output, read by its callers rather than by it.
# shellcheck disable=SC2034
tama_window_read() { # <target>
  local raw field lines=0
  raw="$(tama_fields_read "$1" "$TAMA_WINDOW_READ_FIELDS")" || raw=''

  TAMA_WINDOW_ID=''
  TAMA_WINDOW_IS_CURRENT=''
  TAMA_WINDOW_SESSION_CLIENTS=''
  TAMA_WINDOW_SESSION=''
  TAMA_WINDOW_PANE_ID=''
  TAMA_WINDOW_FLAG=''
  while IFS= read -r field; do
    lines=$((lines + 1))
    case "$lines" in
      1) TAMA_WINDOW_ID="$field" ;;
      2) TAMA_WINDOW_IS_CURRENT="$field" ;;
      3) TAMA_WINDOW_SESSION_CLIENTS="$field" ;;
      4) TAMA_WINDOW_SESSION="$field" ;;
      5) TAMA_WINDOW_PANE_ID="$field" ;;
      6) TAMA_WINDOW_FLAG="$field" ;;
    esac
  done <<EOF
$raw
EOF

  [ "$lines" -eq "$TAMA_WINDOW_READ_COUNT" ] || return 1

  # A window that is gone: tmux says so by expanding `#{window_id}` to nothing
  # rather than by failing, and writing from that would write somewhere else.
  [ -n "$TAMA_WINDOW_ID" ]
}

# The one implementation of "is the user looking at this window?", over what
# tama_window_read just read. Two callers by design: the flag path below, and the
# cheap half of the notification suppression `AND` (ADR-0004), which consults the
# backend only when this says yes.
#
# Both halves are required. A window can be the active window of a session nobody
# has attached to — an agent working away in a detached session — and calling that
# "the user is looking at it" is how a flag goes unraised for the one case where the
# user most needs it. So: the active window of its own session, *and* that session
# has at least one client attached.
#
# The failure direction is deliberate and matches ADR-0004: when in doubt this says
# "not looking", which raises a flag that turns out to be unnecessary rather than
# swallowing one that mattered. A flag the user did not need costs a glance; a flag
# they never got costs the agent sitting blocked.
tama_window_user_is_looking() {
  [ "$TAMA_WINDOW_IS_CURRENT" = '1' ] || return 1
  # A count, so anything but zero is a client. Empty is a read that said nothing,
  # which is not a client either.
  case "$TAMA_WINDOW_SESSION_CLIENTS" in
    '' | 0) return 1 ;;
  esac
  return 0
}

# Raises the flag on the window holding <target> — unless the user is looking at it,
# which is the whole condition: the flag records that something happened while
# nobody was looking.
#
# Raised on the *event*, not on a change. An agent already in `waiting` that reports
# `waiting` again after the user glanced at the window and left has to raise it
# again, so this must never sit behind the "nothing changed, write nothing"
# short-circuit in libexec/state.
#
# No client refresh is asked for: `@tama_flag` is a plain format rather than a `#()`
# job, so writing the option is enough to redraw it. The `-S` in lib/pane.sh exists
# because tmux caches a job's output for up to a status interval; there is no job
# here to be stale.
tama_flag_raise() { # <target>
  tama_window_read "$1" || return 0
  tama_window_user_is_looking && return 0
  tama_flag_set
}

# The write on its own, over the window tama_window_read last read, for a caller that
# has already made the judgement itself.
#
# There is one such caller and it is not a second opinion about the same question: the
# notification path knows more than the cheap check does. When the backend reports
# that the terminal is behind a browser, tmux calling this the current window is
# simply wrong about the user, the banner goes out — and the mark belongs there too,
# because something did happen while nobody was looking. Deliver and mark are the same
# decision, so they are made once. See lib/notify.sh.
#
# Targeted by id, never by the caller's target: an index could have moved to another
# window between the read and this write.
tama_flag_set() {
  tmux_run set -w -t "$TAMA_WINDOW_ID" "$TAMA_WINDOW_FLAG_OPTION" on \
    >/dev/null 2>&1 || true
}

# Clears the flag on the window holding <target>. Only ever called for the user
# selecting the window: an agent moving on to another state must not clear it, or the
# mark stops meaning "something happened while you were away".
#
# Unsets rather than writing an empty string, like a cleared pane in lib/pane.sh: an
# option set to "" is still an option that is set, and `@tama_flag` asks whether this
# one is there at all.
#
# Returns zero only when there really was a mark to take off — and leaves the window
# it read in TAMA_WINDOW_*, which libexec/on-select then has without a second round
# trip. That answer is load-bearing rather than a nicety: a window with no mark has no
# banner of ours pending either, because `notify` raises the mark whenever it delivers
# one, so it is what keeps a window selection from spawning a notifier process every
# time the user presses a key. The invariant is stated at both ends; breaking it at
# one would leave banners on screen with nothing to say why.
#
# Never fails on the write: every caller is a hook or a key binding.
tama_flag_clear() { # <target>
  tama_window_read "$1" || return 1
  tmux_run set -wuq -t "$TAMA_WINDOW_ID" "$TAMA_WINDOW_FLAG_OPTION" \
    >/dev/null 2>&1 || true
  [ -n "$TAMA_WINDOW_FLAG" ]
}
