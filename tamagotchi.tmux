#!/usr/bin/env bash
#
# TPM entrypoint. Runs on every `tmux source-file`, so everything it does must
# be idempotent, and it must resolve its own location rather than assume one:
# a TPM clone, a git submodule and a symlinked worktree are all valid homes.
#
# Below the minimum tmux version it warns and wires nothing at all — a partial
# install produces symptoms that are far harder to read than a message.

set -o nounset

PLUGIN_DIR="$(
  src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
)"

# shellcheck source=lib/common.sh
. "$PLUGIN_DIR/lib/common.sh"

TAMA_MIN_TMUX_VERSION='3.1a'

# Reads `tmux -V` as a comparable pair: the numeric version and the letter
# suffix that tmux appends to its bugfix releases ("3.1a", "3.7b").
tama_tmux_version() {
  local raw
  raw="$(tmux_run -V 2>/dev/null)" || raw=''
  # "tmux 3.7b", "tmux next-3.4", "tmux openbsd-7.5", "tmux master"
  raw="${raw#tmux }"
  raw="${raw##*-}"
  printf '%s' "$raw"
}

# tama_version_at_least <version> <minimum>
# Unparseable versions (a self-built "master") get the benefit of the doubt:
# refusing to install on a tmux we cannot read is worse than trying.
tama_version_at_least() {
  local version="$1" minimum="$2"
  local version_number="${version%%[!0-9.]*}" minimum_number="${minimum%%[!0-9.]*}"
  local version_suffix="${version#"$version_number"}" minimum_suffix="${minimum#"$minimum_number"}"

  case "$version_number" in
    '' | *[!0-9.]* | .* | *.) return 0 ;;
  esac

  local version_major="${version_number%%.*}" minimum_major="${minimum_number%%.*}"
  local version_minor="${version_number#*.}" minimum_minor="${minimum_number#*.}"
  version_minor="${version_minor%%.*}"
  minimum_minor="${minimum_minor%%.*}"
  [ "$version_minor" = "$version_number" ] && version_minor=0
  [ "$minimum_minor" = "$minimum_number" ] && minimum_minor=0

  [ "$version_major" -gt "$minimum_major" ] && return 0
  [ "$version_major" -lt "$minimum_major" ] && return 1
  [ "$version_minor" -gt "$minimum_minor" ] && return 0
  [ "$version_minor" -lt "$minimum_minor" ] && return 1

  # Same numeric version: compare the bugfix letters lexically, where no letter
  # sorts before "a" — 3.1 is older than 3.1a.
  [[ ! "$version_suffix" < "$minimum_suffix" ]]
}

main() {
  local version
  version="$(tama_tmux_version)"
  if ! tama_version_at_least "$version" "$TAMA_MIN_TMUX_VERSION"; then
    tmux_run display-message \
      "tamagotchi: tmux $version is too old, $TAMA_MIN_TMUX_VERSION or newer is required; nothing was loaded"
    return 0
  fi

  # The only way anything finds this plugin: hook recipes and the user's status
  # line ask tmux where it lives. Nothing is written outside this directory and
  # nothing is installed onto PATH (ADR-0003).
  tmux_run set -g @tama_bin "$PLUGIN_DIR/bin/tama"
  tmux_run set -g @tama_bin_dir "$PLUGIN_DIR/bin"
}

main "$@"
