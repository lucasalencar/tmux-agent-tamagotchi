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

# The directory this file lives in, symlinked directories resolved. Same name as
# bin/tama exports, so anything under lib/ has one name to read.
case "${BASH_SOURCE[0]}" in
  */*) TAMA_PLUGIN_DIR="$(cd -P "${BASH_SOURCE[0]%/*}" && pwd)" ;;
  *) TAMA_PLUGIN_DIR="$PWD" ;;
esac
export TAMA_PLUGIN_DIR

# A failed `.` does not stop a script, and carrying on from here produces a
# cascade of bash diagnostics instead of one sentence naming the real problem.
# bin/tama is checked for the same reason one step removed: it is what gets
# published, and a path that cannot be run would fail inside an agent's hooks
# on every event, where the recipe can only see whether the option is empty.
if [ ! -r "$TAMA_PLUGIN_DIR/lib/common.sh" ] ||
  [ ! -r "$TAMA_PLUGIN_DIR/lib/version.sh" ] ||
  [ ! -x "$TAMA_PLUGIN_DIR/bin/tama" ]; then
  printf 'tamagotchi: %s is not a complete plugin directory; nothing was loaded\n' \
    "$TAMA_PLUGIN_DIR" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
. "$TAMA_PLUGIN_DIR/lib/common.sh"
# shellcheck source=lib/version.sh
. "$TAMA_PLUGIN_DIR/lib/version.sh"

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
  #
  # `set -g` is a global user option, which is how every tmux plugin is
  # configured and what both `show -gv` and `#{@tama_bin}` read. Whoever
  # interpolates this path into a `#()` format later owns quoting it and
  # escaping what tmux would otherwise read: `#` starts a format, and `%` is
  # consumed by strftime.
  tmux_run set -g @tama_bin "$TAMA_PLUGIN_DIR/bin/tama"
  tmux_run set -g @tama_bin_dir "$TAMA_PLUGIN_DIR/bin"

  # A failed write is not worth failing a config reload over.
  return 0
}

main "$@"
