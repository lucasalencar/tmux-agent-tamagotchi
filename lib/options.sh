# shellcheck shell=bash
#
# Configuration readers. Most options live in global tmux user options, set with
# `set -g @tama_…`; the summary scope is intentionally per session. Everything is
# read at invocation time, never cached across invocations — but a single
# invocation may prefetch what it reads repeatedly (see tama_opt_batch), which
# is still reading at invocation time, only in fewer round-trips.

tama_opt() {
  local value default="${2-}" cached_set cached_value
  # A prefetched value wins over a live read; see tama_opt_batch. The _SET flag
  # distinguishes "read and found unset" from "never prefetched".
  cached_set="TAMA_OPT_CACHE_${1}_SET"
  if [ "${!cached_set:-}" = 1 ]; then
    cached_value="TAMA_OPT_CACHE_$1"
    printf '%s' "${!cached_value}"
    return 0
  elif [ "${!cached_set:-}" = 0 ]; then
    # Known absent: same answer as a live read that finds nothing, without
    # the round trip. (Absent and set-to-empty stay distinct: the batch
    # records both, and this branch only fires for the absent one.)
    printf '%s' "$default"
    return 0
  fi
  # `show -gv` without -q fails on an option that was never set, which is the
  # only way to tell it apart from one deliberately set to the empty string.
  # Emptying an option is a real configuration act: `set -g @tama_icon_prefix ''`
  # means "no prefix", not "give me the default back". An unreachable tmux also
  # lands on the default, which is the only useful thing to do with it.
  if value="$(tmux_run show -gv "@$1" 2>/dev/null)"; then
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
}

# Prefetch a fixed set of options in one tmux round-trip, so that later
# tama_opt calls for those names need no round-trips of their own. Per-process
# only — every CLI invocation starts cold — and only valid while the caller
# performs no global option writes in between, which holds for the read-mostly
# paths that use it. Values keep their exact bytes (including empty versus
# unset), through the same marker protocol libexec/icons uses.
tama_opt_batch() {
  local marker="__tama_opt_batch_$$_${RANDOM}_${RANDOM}__"
  local args=() first=1 name
  for name in "$@"; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      args+=(';')
    fi
    args+=(show -gqv "@$name" ';' display-message -p "$marker")
  done
  [ "$first" -eq 1 ] && return 0
  local out line section=0 acc='' acc_lines=0
  local names=("$@")
  out="$(tmux_run "${args[@]}" 2>/dev/null)" || out=''
  # An unreachable tmux yields nothing to cache; every later read then falls
  # back to the live path and its defaults, exactly as before batching. (A
  # trailing section without its closing marker is likewise dropped.)
  [ -n "$out" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$marker" ]; then
      tama_opt_batch_store "${names[$section]}" "$acc" "$acc_lines"
      section=$((section + 1))
      acc=''
      acc_lines=0
      continue
    fi
    if [ "$acc_lines" -eq 0 ]; then
      acc="$line"
    else
      acc="$acc
$line"
    fi
    acc_lines=$((acc_lines + 1))
  done <<<"$out"
}

# Record one batched option: present with its exact bytes, or absent. Exported
# so child processes that source lib/options.sh (backend capabilities) see the
# same snapshot instead of re-reading: they run immediately after, against a
# server nobody is reconfiguring mid-flight.
tama_opt_batch_store() { # <name> <value> <line count>
  printf -v "TAMA_OPT_CACHE_$1" '%s' "$2"
  if [ "$3" -eq 0 ]; then
    printf -v "TAMA_OPT_CACHE_$1_SET" '%s' 0
  else
    printf -v "TAMA_OPT_CACHE_$1_SET" '%s' 1
  fi
  export "TAMA_OPT_CACHE_$1" "TAMA_OPT_CACHE_$1_SET"
}

# tmux's own vocabulary for a flag option, and the only place in the plugin that
# decides what one means. Anything outside the list is `on`: a typo that quietly
# took a feature away is harder to notice than one that was ignored, and `off` is
# always something the user asked for in as many words.
#
# A predicate over a value the caller already holds rather than over an option
# name, because libexec/icons — the hottest path there is, run once per window per
# status interval — reads all eleven of its options in one batched tmux call and
# must not pay a round trip or a fork to ask what two of them mean. It gets the
# vocabulary; everything else gets tama_opt_enabled below.
tama_opt_value_is_off() { # <value>
  case "$1" in
    off | no | 0 | false) return 0 ;;
  esac
  return 1
}

# Whether a flag option is on, reading it and applying the vocabulary above: the
# one way every option outside libexec/icons asks this question. Every caller that
# spelled it `[ "$(tama_opt … on)" = 'on' ]` was a second, stricter vocabulary in
# which `no`, `0` and `false` all meant on — including `@tama_manage_hooks`, where
# the cost of being wrong is a plugin that wires nothing and says nothing.
tama_opt_enabled() { # <option-name-without-@> <default>
  ! tama_opt_value_is_off "$(tama_opt "$1" "${2-}")"
}

tama_summary_scope() { # <session id>
  local scope
  scope="$(tmux_run show-options -qv -t "$1" @tama_summary_scope 2>/dev/null)" || return 1
  case "$scope" in
    all) printf '%s' all ;;
    *) printf '%s' current ;;
  esac
}

# The summary renderer and doctor share one policy vocabulary and one set of
# bucket defaults. Keep the catalog here so diagnostics cannot drift from what
# the status line actually renders.
# shellcheck disable=SC2034  # consumed by commands that source this library
TAMA_SUMMARY_BUCKETS='running
waiting
idle
background
error
unknown'

tama_summary_policy_is_valid() { # <value>
  case "$1" in
    always | nonzero | never) return 0 ;;
  esac
  return 1
}

tama_summary_policy_default() { # <bucket>
  case "$1" in
    running | waiting | idle) printf '%s' always ;;
    background | error | unknown) printf '%s' nonzero ;;
    *) return 1 ;;
  esac
}
