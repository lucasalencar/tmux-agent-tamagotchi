# shellcheck shell=bash
#
# Shared helpers, sourced by bin/tama and by every script under libexec/.
#
# Failure policy (see the CLI contract in bin/tama): usage errors exit 2 with a
# message on stderr, because a wrong hook is the user's fault and must be visible
# while they are editing it. Everything else exits 0 silently — a notification
# that did not appear must never fail an agent's turn.

set -o nounset

# Every script reaches tmux through this indirection so tests can point it at
# their own server. TAMA_TMUX is a command line, not a path: "tmux -L socket".
IFS=' ' read -r -a TAMA_TMUX_ARGV <<<"${TAMA_TMUX:-tmux}"

# tmux, wherever it is. Never quote-mangles the caller's arguments.
tmux_run() {
  "${TAMA_TMUX_ARGV[@]}" "$@"
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
# configuration, so the two libraries travel together.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=options.sh
. "${BASH_SOURCE[0]%/*}/options.sh"
