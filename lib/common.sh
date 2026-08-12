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
    # shellcheck disable=SC2086  # deliberate: "-L socket" is two arguments
    "$TAMA_TMUX" $TAMA_TMUX_ARGS "$@"
  else
    "$TAMA_TMUX" "$@"
  fi
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
# configuration, so the two libraries travel together. Stripping the last path
# component leaves the name untouched when there is none, so a caller that
# sourced us by a bare relative name still finds it.
_tama_lib_dir="${BASH_SOURCE[0]%/*}"
[ "$_tama_lib_dir" = "${BASH_SOURCE[0]}" ] && _tama_lib_dir='.'
# shellcheck source-path=SCRIPTDIR
# shellcheck source=options.sh
. "$_tama_lib_dir/options.sh"
unset _tama_lib_dir
