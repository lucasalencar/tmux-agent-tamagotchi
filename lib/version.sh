# shellcheck shell=bash
#
# tmux version reading and comparison. Lives here rather than in the entrypoint
# because `doctor` has to report the same verdict, and two implementations of
# "supported" would eventually disagree.

# Pane user options, appendable hooks and format modifiers.
# Read by whoever sources this file.
# shellcheck disable=SC2034
TAMA_MIN_TMUX_VERSION='3.1a'

# What `tmux -V` says, with the prefixes stripped: "tmux 3.7b" and "tmux
# next-3.4" both become a bare version. An "openbsd-7.5" build loses its prefix
# too and is then read as version 7.5 — the OS release rather than tmux's, which
# happens to always clear the minimum, so those builds are effectively given the
# benefit of the doubt.
tama_tmux_version() {
  local raw
  raw="$(tmux_run -V 2>/dev/null)" || raw=''
  raw="${raw#tmux }"
  printf '%s' "${raw##*-}"
}

# The minor component, defaulting to 0 for a version with no dot at all.
tama_version_minor() {
  local rest
  case "$1" in
    *.*)
      rest="${1#*.}"
      printf '%s' "${rest%%.*}"
      ;;
    *) printf '%s' 0 ;;
  esac
}

# tama_version_at_least <version> <minimum>
# A tmux version is <major>.<minor> plus the letter tmux appends to a bugfix
# release ("3.1a"). A version we cannot parse — a self-built "master" — gets the
# benefit of the doubt: refusing to load on a tmux we cannot read is worse than
# trying.
tama_version_at_least() {
  local version="$1" minimum="$2"
  local version_number="${version%%[!0-9.]*}" minimum_number="${minimum%%[!0-9.]*}"
  local version_bugfix="${version#"$version_number"}"
  local minimum_bugfix="${minimum#"$minimum_number"}"

  case "$version_number" in
    '' | .* | *. | *[!0-9.]*) return 0 ;;
  esac

  local version_major="${version_number%%.*}" minimum_major="${minimum_number%%.*}"
  if [ "$version_major" -ne "$minimum_major" ]; then
    [ "$version_major" -gt "$minimum_major" ]
    return
  fi

  local version_minor minimum_minor
  version_minor="$(tama_version_minor "$version_number")"
  minimum_minor="$(tama_version_minor "$minimum_number")"
  if [ "$version_minor" -ne "$minimum_minor" ]; then
    [ "$version_minor" -gt "$minimum_minor" ]
    return
  fi

  # Same major.minor. A third component — which only distro builds produce — is
  # newer than any bugfix letter. Otherwise compare the letters, where no letter
  # sorts before "a", so 3.1 is older than 3.1a.
  case "$version_number" in
    *.*.*) return 0 ;;
  esac
  [[ ! "$version_bugfix" < "$minimum_bugfix" ]]
}
