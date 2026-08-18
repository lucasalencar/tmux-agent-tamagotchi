#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_fake_backend_env
  tama_start_server
  tama_use_fake_backend
  PANE="$(test_tmux list-panes -t t -F '#{pane_id}' | head -1)"
  WINDOW="$(test_tmux display-message -p -t "$PANE" '#{window_id}')"
}

teardown() {
  tama_detach_client
  tama_kill_server
}

hook() { # <event> [payload]
  local event="$1" input="${2:-}"
  TMUX_PANE="$PANE" run --separate-stderr \
    "$PLUGIN_ROOT/bin/tama" hook codex "$event" <<<"$input"
}

payload() { # <event> [extra JSON]
  printf '{"session_id":"thr_123","cwd":"/tmp","hook_event_name":"%s"%s}' \
    "$1" "${2:-}"
}

@test "Codex lifecycle is routed through the public hook seam" {
  hook SessionStart "$(payload SessionStart ',"source":"startup"')"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_pane_option "$PANE" state_main idle
  assert_pane_option "$PANE" agent codex

  hook UserPromptSubmit "$(payload UserPromptSubmit)"
  assert_success
  assert_pane_option "$PANE" state_main running

  hook Stop "$(payload Stop)"
  assert_success
  assert_pane_option "$PANE" state_main idle

  hook SessionEnd "$(payload SessionEnd ',"reason":"other"')"
  assert_success
  assert_pane_option_unset "$PANE" state_main
  assert_pane_option_unset "$PANE" agent
}

@test "session sources, compaction, post-tool use, and future events map safely" {
  local source
  for source in startup resume clear; do
    hook SessionStart "$(payload SessionStart ",\"source\":\"$source\"")"
    assert_success
    assert_pane_option "$PANE" state_main idle
    hook UserPromptSubmit "$(payload UserPromptSubmit)"
  done

  hook SessionStart "$(payload SessionStart ',"source":"compact"')"
  assert_success
  assert_pane_option "$PANE" state_main running

  hook PreCompact "$(payload PreCompact ',"trigger":"auto"')"
  hook PostCompact "$(payload PostCompact ',"trigger":"auto"')"
  hook SomeFutureEvent "$(payload SomeFutureEvent)"
  assert_success
  assert_pane_option "$PANE" state_main running

  hook Stop "$(payload Stop)"
  hook PostToolUse "$(payload PostToolUse ',"tool_name":"Bash"')"
  assert_success
  assert_pane_option "$PANE" state_main running
}

codex_recipe() {
  sed -n '/^```json$/,/^```$/p' "$PLUGIN_ROOT/integrations/codex/README.md" |
    sed '1d;$d'
}

@test "the canonical Codex recipe is valid JSON and binds lifecycle events" {
  local recipe="$BATS_TEST_TMPDIR/hooks.json"
  codex_recipe >"$recipe"

  run python3 - "$recipe" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
expected = {
    "SessionStart": ("startup|resume|clear|compact", 10),
    "UserPromptSubmit": (None, 10),
    "PostToolUse": (None, 10),
    "Stop": (None, 10),
    "SessionEnd": ("other", 3),
}
assert set(data["hooks"]) == set(expected)
for event, (matcher, timeout) in expected.items():
    group = data["hooks"][event][0]
    assert group.get("matcher") == matcher
    handler = group["hooks"][0]
    assert handler == {
        "type": "command",
        "command": f'"$(tmux show -gqv @tama_bin 2>/dev/null)" hook codex {event} >/dev/null 2>&1 || :',
        "timeout": timeout,
    }
PY
  assert_success
}

@test "project documentation points to the one canonical Codex recipe" {
  run grep -F 'integrations/codex/README.md' "$PLUGIN_ROOT/README.md"
  assert_success

  run grep -F 'integrations/codex/hook' "$PLUGIN_ROOT/integrations/README.md"
  assert_success

  run grep -F 'hook codex SessionStart' "$PLUGIN_ROOT/README.md"
  [ "$status" -ne 0 ]
  run grep -F 'hook codex SessionStart' "$PLUGIN_ROOT/integrations/README.md"
  [ "$status" -ne 0 ]
}
