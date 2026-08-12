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
#
# `-u` says this client speaks UTF-8. Without it tmux decides from the ambient
# locale, and a server whose locale is C — a CI runner, a systemd unit, a cron job —
# hands back `_` for every byte of every multibyte character it prints. That would
# turn an agent name or a path with an accent in it into a value that never equals
# itself, so the pane would be rewritten on every tool call.
tmux_run() {
  if [ -n "${TAMA_TMUX_ARGS:-}" ]; then
    # Split into words, but with globbing off: a socket name is not a pattern.
    set -f
    # shellcheck disable=SC2086  # deliberate: "-L socket" is two arguments
    set -- $TAMA_TMUX_ARGS "$@"
    set +f
  fi
  "$TAMA_TMUX" -u "$@"
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
