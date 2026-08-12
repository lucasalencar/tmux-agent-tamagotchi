# shellcheck shell=bash
#
# Shared helpers, sourced by bin/tama and by every script under libexec/.
# Sourcing this file turns on `nounset` for the caller, deliberately: every
# script in the plugin runs under it.
#
# Failure policy (see the CLI contract in bin/tama): usage errors exit 2 with a
# message on stderr, because a wrong hook is the user's fault and must be visible
# while they are editing it. Everything else exits 0 silently — a notification
# that did not appear must never fail an agent's turn.

set -o nounset

# Every script reaches tmux through this indirection so tests can point it at
# their own server. TAMA_TMUX is the path to the binary — it may contain spaces,
# so it is never split — and TAMA_TMUX_ARGS holds leading arguments, which may
# not.
TAMA_TMUX="${TAMA_TMUX:-tmux}"

# tmux, wherever it is. Never quote-mangles the caller's arguments.
tmux_run() {
  if [ -n "${TAMA_TMUX_ARGS:-}" ]; then
    # Split into words, but with globbing off: a socket name is not a pattern.
    set -f
    # shellcheck disable=SC2086  # deliberate: "-L socket" is two arguments
    set -- $TAMA_TMUX_ARGS "$@"
    set +f
  fi
  "$TAMA_TMUX" "$@"
}

# Interpolating a path into a tmux format takes two escapes, in this order,
# because that is the order the two layers run in: tmux expands the format first,
# then a shell parses what came out.

# For the shell tmux runs a `#()` job with: single quotes, so a plugin directory
# with a space in it stays one word.
tama_shell_quote() {
  local escaped="${1//\'/\'\\\'\'}"
  printf "'%s'" "$escaped"
}

# For the format itself: `#` introduces a format and `%` a strftime conversion,
# and both are consumed before the result reaches that shell.
tama_format_escape() {
  local escaped="${1//\#/\#\#}"
  printf '%s' "${escaped//%/%%}"
}

# Usage error: loud, on stderr, exit 2. The hint carries an absolute path
# because nothing is installed onto PATH — `tama` alone is not runnable.
die_usage() {
  printf 'tama: %s\n' "$1" >&2
  printf "Try '%s --help'.\\n" "${TAMA_BIN:-tama}" >&2
  exit 2
}

# Outside tmux there is nothing to act on, and hooks are configured once for
# both contexts, so every tmux-acting command is a quiet no-op.
require_tmux() {
  [ -n "${TMUX:-}" ] || exit 0
}

# The configuration reader needs tmux_run, and everything that reads tmux reads
# configuration; the state model needs both, and every command that does anything
# at all acts on a pane. So the three travel together. Stripping the last path
# component leaves the name untouched when there is none, so a caller that
# sourced us by a bare relative name still finds them.
_tama_lib_dir="${BASH_SOURCE[0]%/*}"
[ "$_tama_lib_dir" = "${BASH_SOURCE[0]}" ] && _tama_lib_dir='.'

# A failed `.` does not stop a script, and carrying on would leave the failure
# policy itself undefined.
_tama_require_lib() {
  [ -r "$1" ] && return 0
  printf 'tama: no %s next to %s; this plugin directory is incomplete\n' \
    "${1##*/}" "${BASH_SOURCE[0]}" >&2
  exit 1
}

_tama_require_lib "$_tama_lib_dir/options.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=options.sh
. "$_tama_lib_dir/options.sh"

_tama_require_lib "$_tama_lib_dir/pane.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=pane.sh
. "$_tama_lib_dir/pane.sh"

unset _tama_lib_dir
unset -f _tama_require_lib
