#!/usr/bin/env bash
#
# TPM entrypoint. Runs on every `tmux source-file`, so everything it does must
# be idempotent, and it must resolve its own location rather than assume one:
# a TPM clone, a git submodule and a symlinked worktree are all valid homes.
# (`cd -P` resolves symlinked directories, which is what all three amount to;
# a symlink pointing at this file itself is not a documented install.)
#
# Below the minimum tmux version it warns and wires nothing at all — a partial
# install produces symptoms that are far harder to read than a message.

set -o nounset

case "${BASH_SOURCE[0]}" in
  */*) PLUGIN_DIR="$(cd -P "${BASH_SOURCE[0]%/*}" && pwd)" ;;
  *) PLUGIN_DIR="$PWD" ;;
esac

# shellcheck source=lib/common.sh
. "$PLUGIN_DIR/lib/common.sh"
# shellcheck source=lib/version.sh
. "$PLUGIN_DIR/lib/version.sh"

main() {
  local version warning
  version="$(tama_tmux_version)"
  if ! tama_version_at_least "$version" "$TAMA_MIN_TMUX_VERSION"; then
    # display-message expands its argument as a tmux format, and a format can
    # run a command, so nothing derived from the outside world keeps its `#`.
    warning="tamagotchi: tmux ${version//\#/} is too old"
    warning="$warning (needs $TAMA_MIN_TMUX_VERSION); nothing was loaded"
    # Both, because neither reaches everyone: display-message is dropped when no
    # client is attached, and stderr is dropped when there is no terminal.
    printf '%s\n' "$warning" >&2
    tmux_run display-message "$warning"
    return 0
  fi

  # The only way anything finds this plugin: hook recipes and the user's status
  # line ask tmux where it lives. Nothing is written outside this directory and
  # nothing is installed onto PATH (ADR-0003).
  tmux_run set -g @tama_bin "$PLUGIN_DIR/bin/tama"
  tmux_run set -g @tama_bin_dir "$PLUGIN_DIR/bin"
}

main "$@"
