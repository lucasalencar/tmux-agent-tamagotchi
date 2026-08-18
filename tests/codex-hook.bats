#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_fake_backend_env
  tama_start_server
  tama_use_fake_backend
  export CODEX_HOME="$BATS_TEST_TMPDIR/default-codex-home"
  mkdir -p "$CODEX_HOME"
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
  assert_success
  hook PostCompact "$(payload PostCompact ',"trigger":"auto"')"
  assert_success
  hook SomeFutureEvent "$(payload SomeFutureEvent)"
  assert_success
  assert_pane_option "$PANE" state_main running

  hook Stop "$(payload Stop)"
  assert_success
  hook PostToolUse "$(payload PostToolUse ',"tool_name":"Bash"')"
  assert_success
  assert_pane_option "$PANE" state_main running
}

codex_recipe() {
  sed -n '/^```json$/,/^```$/p' "$PLUGIN_ROOT/integrations/codex/README.md" |
    sed '1d;$d'
}

codex_recipe_command() { # <event>
  codex_recipe | python3 -c '
import json, sys
event = sys.argv[1]
print(json.load(sys.stdin)["hooks"][event][0]["hooks"][0]["command"])
' "$1"
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
    "PreToolUse": ("^request_user_input$", 10),
    "PermissionRequest": ("*", 10),
    "PostToolUse": (None, 10),
    "SubagentStart": ("*", 10),
    "SubagentStop": ("*", 10),
    "Stop": (None, 10),
    "SessionEnd": (None, 3),
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

@test "the pasted recipe command drives the adapter and stays harmless when unloaded" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tama_shim_tmux_on_path
  local command
  command="$(codex_recipe_command UserPromptSubmit)"

  TMUX_PANE="$PANE" run --separate-stderr sh -c "$command" \
    <<<"$(payload UserPromptSubmit)"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_pane_option "$PANE" state_main running

  local plugin_with_spaces="$BATS_TEST_TMPDIR/plugin with spaces"
  tama_copy_plugin "$plugin_with_spaces"
  test_tmux set -g @tama_bin "$plugin_with_spaces/bin/tama"
  TMUX_PANE="$PANE" run --separate-stderr sh -c "$command" \
    <<<"$(payload UserPromptSubmit)"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  test_tmux set -gu @tama_bin
  TMUX_PANE="$PANE" run --separate-stderr sh -c "$command" \
    <<<"$(payload UserPromptSubmit)"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "request_user_input waits and notifies with the first question" {
  hook UserPromptSubmit "$(payload UserPromptSubmit)"
  hook PreToolUse "$(payload PreToolUse ',"tool_name":"request_user_input","tool_input":{"questions":[{"header":"Database","question":"Which database should we use?","options":[]}]}}')"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_pane_option "$PANE" state_main waiting
  assert_backend_value notify argv2 'Which database should we use?'

  hook PostToolUse "$(payload PostToolUse ',"tool_name":"request_user_input"')"
  assert_success
  assert_pane_option "$PANE" state_main running
}

@test "human approval and completed turns notify with useful text after state" {
  hook PermissionRequest "$(payload PermissionRequest ',"tool_name":"Bash","tool_input":{"command":"deploy","description":"Deploy the release to production?"}}')"
  assert_success
  assert_pane_option "$PANE" state_main waiting
  assert_backend_value notify argv2 'Deploy the release to production?'
  assert_contains "$(tama_backend_value notify argv1)" 'codex - ' 'the notification title'

  hook Stop "$(payload Stop ',"last_assistant_message":"The release is ready for review."')"
  assert_success
  assert_pane_option "$PANE" state_main idle
  assert_backend_value notify argv2 'The release is ready for review.'
}

@test "attention text decoding and fallbacks stay useful and bounded" {
  hook PreToolUse "$(payload PreToolUse ',"tool_name":"request_user_input","tool_input":{"questions":[{"question":"He asked \"now or later?\"\nPlease choose."}]}}')"
  assert_success
  assert_backend_value notify argv2 "$(printf 'He asked "now or later?"\nPlease choose.')"

  hook Stop "$(payload Stop ',"last_assistant_message":"Revisão concluída \u2705"')"
  assert_success
  assert_backend_value notify argv2 'Revisão concluída ✅'

  hook Stop "$(payload Stop ',"last_assistant_message":"Line one\rLine two\bchecked\fformatted"')"
  assert_success
  assert_backend_value notify argv2 "$(printf 'Line one\nLine two checked formatted')"

  hook PermissionRequest '{"tool_name":"Bash","tool_input":{"description":"truncated}'
  assert_success
  assert_backend_value notify argv2 'Codex needs your approval'

  hook PermissionRequest "$(payload PermissionRequest ',"tool_name":"Bash","tool_input":{"description":"Run \q now"}}')"
  assert_success
  assert_backend_value notify argv2 'Codex needs your approval'

  local long='The result is ready' i=0
  while [ "$i" -lt 200 ]; do
    long="$long word$i"
    i=$((i + 1))
  done
  hook Stop "$(payload Stop ",\"last_assistant_message\":\"$long\"")"
  assert_success
  local got
  got="$(tama_backend_value notify argv2)"
  [ "${#got}" -le 500 ]
  case "$long" in "$got"*) ;; *) return 1 ;; esac
}

@test "a confidently selected top-level auto reviewer suppresses false attention" {
  export CODEX_HOME="$BATS_TEST_TMPDIR/codex-home"
  mkdir -p "$CODEX_HOME"
  local reviewer
  for reviewer in '"auto_review"' "'auto_review'"; do
    printf '%s\n' \
      '# user-level reviewer' \
      "approvals_reviewer = $reviewer # let the reviewer decide" \
      '[profiles.work]' \
      'approvals_reviewer = "user"' >"$CODEX_HOME/config.toml"

    hook UserPromptSubmit "$(payload UserPromptSubmit)"
    hook PermissionRequest "$(payload PermissionRequest ',"tool_name":"Bash","tool_input":{"description":"Run a privileged command?"}}')"
    assert_success
    assert_pane_option "$PANE" state_main running
  done
  refute_backend_called notify
}

@test "uncertain reviewer configuration falls back to human attention" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  export CODEX_HOME="$BATS_TEST_TMPDIR/codex-home"
  mkdir -p "$CODEX_HOME"

  local config
  for config in \
    'approvals_reviewer = "user"' \
    $'[profiles.work]\napprovals_reviewer = "auto_review"' \
    $'approvals_reviewer = "auto_review"\napprovals_reviewer = "auto_review"' \
    'approvals_reviewer = "auto_ review"' \
    'approvals_ reviewer = "auto_review"' \
    'approvals_reviewer = auto_review'; do
    local before
    before="$(tama_backend_calls notify)"
    printf '%s\n' "$config" >"$CODEX_HOME/config.toml"
    hook UserPromptSubmit "$(payload UserPromptSubmit)"
    hook PermissionRequest "$(payload PermissionRequest ',"tool_name":"Bash"')"
    assert_success
    assert_pane_option "$PANE" state_main waiting
    [ "$(tama_backend_calls notify)" -eq $((before + 1)) ]
  done

  : >"$CODEX_HOME/config.toml"
  hook UserPromptSubmit "$(payload UserPromptSubmit)"
  hook PermissionRequest "$(payload PermissionRequest ',"tool_name":"Bash"')"
  assert_pane_option "$PANE" state_main waiting
  assert_backend_called notify
  assert_flagged "$WINDOW"
}

@test "unreadable and oversized reviewer configuration require human attention" {
  export CODEX_HOME="$BATS_TEST_TMPDIR/codex-home"
  mkdir -p "$CODEX_HOME/config.toml"

  hook PermissionRequest "$(payload PermissionRequest ',"tool_name":"Bash"')"
  assert_success
  assert_pane_option "$PANE" state_main waiting
  [ "$(tama_backend_calls notify)" -eq 1 ]

  rmdir "$CODEX_HOME/config.toml"
  python3 - "$CODEX_HOME/config.toml" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as config:
    config.write('approvals_reviewer = "auto_review"\n')
    config.write("\n" * 65537)
PY
  hook UserPromptSubmit "$(payload UserPromptSubmit)"
  hook PermissionRequest "$(payload PermissionRequest ',"tool_name":"Bash"')"
  assert_success
  assert_pane_option "$PANE" state_main waiting
  [ "$(tama_backend_calls notify)" -eq 2 ]
}

@test "opaque subagent ids independently derive background until they stop" {
  hook SessionStart "$(payload SessionStart ',"source":"startup"')"
  hook SubagentStart "$(payload SubagentStart ',"agent_id":"agent_1","agent_type":"default"')"
  hook SubagentStart "$(payload SubagentStart ',"agent_id":"agent-2","agent_type":"reviewer"')"
  hook SubagentStart "$(payload SubagentStart ',"agent_id":"agent_1","agent_type":"default"')"
  assert_success
  assert_pane_option "$PANE" state_main idle
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
  refute_backend_called notify

  hook SubagentStop "$(payload SubagentStop ',"agent_id":"agent_1","agent_type":"default"')"
  hook SubagentStop "$(payload SubagentStop ',"agent_id":"agent_1","agent_type":"default"')"
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'

  hook SubagentStop "$(payload SubagentStop ',"agent_id":"agent-2","agent_type":"reviewer"')"
  assert_pane_option_unset "$PANE" subagents
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "delegated lifecycle events cannot overwrite or interrupt the main turn" {
  hook SessionStart "$(payload SessionStart ',"source":"startup"')"
  hook SubagentStart "$(payload SubagentStart ',"agent_id":"review_1","agent_type":"reviewer"')"

  local event extra
  for event in SessionStart UserPromptSubmit PostToolUse Stop PermissionRequest SessionEnd; do
    extra=',"agent_id":"review_1"'
    if [ "$event" = SessionStart ]; then
      extra="$extra,"'"source":"clear"'
    fi
    if [ "$event" = PermissionRequest ]; then
      extra="$extra,"'"tool_name":"Bash","tool_input":{"description":"Approve delegated work?"}'
    fi
    hook "$event" "$(payload "$event" "$extra")"
    assert_success
    assert_pane_option "$PANE" state_main idle
  done

  hook PreToolUse "$(payload PreToolUse ',"agent_id":"review_1","tool_name":"request_user_input","tool_input":{"questions":[{"question":"Delegated question?"}]}}')"
  assert_success
  assert_pane_option "$PANE" state_main idle
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
  refute_backend_called notify
}

@test "nested agent_id fields do not turn a main event into delegated work" {
  hook PermissionRequest "$(payload PermissionRequest ',"tool_name":"mcp__deploy","tool_input":{"agent_id":"production","description":"Deploy the service?"}}')"
  assert_success
  assert_pane_option "$PANE" state_main waiting
  assert_backend_value notify argv2 'Deploy the service?'
}

@test "text-shaped content cannot impersonate the documented payload field" {
  hook PermissionRequest "$(payload PermissionRequest ',"metadata":{"description":"Metadata only"},"tool_name":"Bash","tool_input":{"command":"deploy","description":"Approve the real command?"}}')"
  assert_success
  assert_backend_value notify argv2 'Approve the real command?'
}

@test "scoped fields cannot escape into sibling objects" {
  hook PermissionRequest "$(payload PermissionRequest ',"tool_name":"Bash","tool_input":{"command":"deploy"},"metadata":{"description":"Sibling text"}')"
  assert_success
  assert_pane_option "$PANE" state_main waiting
  assert_backend_value notify argv2 'Codex needs your approval'

  hook PreToolUse "$(payload PreToolUse ',"tool_name":"request_user_input","tool_input":{"questions":[]},"metadata":{"question":"Sibling question"}')"
  assert_success
  assert_backend_value notify argv2 'Codex has a question'
}

@test "a payload cut at the input bound cannot raise attention from partial JSON" {
  hook SessionStart "$(payload SessionStart ',"source":"startup"')"
  local oversized
  oversized="$(python3 - <<'PY'
print('{"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_input":{"questions":[{"question":"Partial question"}]},"padding":"' + ('x' * 70000) + '"}')
PY
)"
  hook PreToolUse "$oversized"
  assert_success
  assert_pane_option "$PANE" state_main idle
  refute_backend_called notify
}

@test "payload-independent events and fallbacks survive the input bound" {
  local oversized
  oversized="$(python3 - <<'PY'
print('{"last_assistant_message":"Untrusted complete text","tool_input":{"description":"Also untrusted"},"padding":"' + ('x' * 70000) + '"}')
PY
)"

  hook UserPromptSubmit "$oversized"
  assert_success
  assert_pane_option "$PANE" state_main running

  hook Stop "$oversized"
  assert_success
  assert_pane_option "$PANE" state_main idle
  assert_backend_value notify argv2 'Codex finished its turn'

  hook PermissionRequest "$oversized"
  assert_success
  assert_pane_option "$PANE" state_main waiting
  assert_backend_value notify argv2 'Codex needs your approval'

  hook SessionEnd "$oversized"
  assert_success
  assert_pane_option_unset "$PANE" state_main
  assert_pane_option_unset "$PANE" agent
}

@test "truncated payloads cannot change source-dependent or subagent state" {
  hook UserPromptSubmit "$(payload UserPromptSubmit)"
  local oversized_start oversized_subagent
  oversized_start="$(python3 - <<'PY'
print('{"source":"startup","padding":"' + ('x' * 70000) + '"}')
PY
)"
  oversized_subagent="$(python3 - <<'PY'
print('{"agent_id":"ghost_1","padding":"' + ('x' * 70000) + '"}')
PY
)"

  hook SessionStart "$oversized_start"
  assert_success
  assert_pane_option "$PANE" state_main running

  hook SubagentStart "$oversized_subagent"
  assert_success
  assert_pane_option_unset "$PANE" subagents

  hook Stop "$(payload Stop)"
  hook SubagentStart "$(payload SubagentStart ',"agent_id":"live_1"')"
  hook SubagentStop "$oversized_subagent"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
}

@test "truncated delegated payloads remain isolated when common fields precede event data" {
  hook SessionStart "$(payload SessionStart ',"source":"startup"')"
  local delegated
  delegated="$(python3 - <<'PY'
print('{"agent_id":"review_1","padding":"' + ('x' * 70000) + '"}')
PY
)"

  hook UserPromptSubmit "$delegated"
  hook PermissionRequest "$delegated"
  assert_success
  assert_pane_option "$PANE" state_main idle
  refute_backend_called notify
}

@test "a text value that exhausts the escape bound uses its fallback" {
  local malformed
  malformed="$(python3 - <<'PY'
print('{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"description":"' + ('word\\n' * 256) + 'unterminated},"other":"quote"}')
PY
)"
  hook PermissionRequest "$malformed"
  assert_success
  assert_backend_value notify argv2 'Codex needs your approval'
}

@test "missing, malformed, and invalid subagent ids are silent and harmless" {
  hook SessionStart "$(payload SessionStart ',"source":"startup"')"
  hook SubagentStart "$(payload SubagentStart ',"agent_id":"agent.alpha:1"')"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'

  local event_payload
  for event_payload in \
    "$(payload SubagentStart)" \
    "$(payload SubagentStart ',"agent_id":42')" \
    '{"agent_id":"unterminated}' \
    "$(payload SubagentStart ',"agent_id":"two ids"')"; do
    hook SubagentStart "$event_payload"
    assert_success
    [ -z "$output" ]
    [ -z "$stderr" ]
  done
  hook SubagentStop "$(payload SubagentStop ',"agent_id":"two ids"')"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
  refute_backend_called notify

  hook SessionEnd "$(payload SessionEnd ',"reason":"other"')"
  assert_pane_option_unset "$PANE" subagents
  assert_equal "$(tama_icons "$WINDOW")" ''
}
