# shellcheck shell=bash
#
# Configuration reader. Every option lives in a global tmux user option, set with
# `set -g @tama_…` the way every tmux plugin is configured, and is read at
# invocation time, never cached, so `tmux source-file` takes effect on the very
# next command with no server restart.

# tama_opt <option-name-without-@> <default>
tama_opt() {
  local value default="${2-}"
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
