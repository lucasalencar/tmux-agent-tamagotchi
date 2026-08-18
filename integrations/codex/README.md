# Codex

This is the Codex half of the wiring. Install and configure the tmux plugin first, including
the status-line formats from the [project README](../../README.md).

The adapter is best effort and outside the plugin's stable version promise. It was verified
against Codex CLI 0.147.0 and uses only the official lifecycle-hook interface. Unknown events
and operational failures are silent; no hook event is interpreted as `error` because Codex
does not currently expose a reliable failure lifecycle hook (ADR-0009).

## Configure the global hooks

Add the entries below to `~/.codex/hooks.json`. If that file already contains a `hooks`
object, merge these event entries into it instead of replacing the file. Codex combines
matching hooks from active configuration layers, so existing handlers for the same event can
remain alongside these. After adding or changing command hooks, open `/hooks` in Codex,
review their source and trust the exact definitions before expecting them to run.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "\"$(tmux show -gqv @tama_bin 2>/dev/null)\" hook codex SessionStart >/dev/null 2>&1 || :",
            "timeout": 10
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$(tmux show -gqv @tama_bin 2>/dev/null)\" hook codex UserPromptSubmit >/dev/null 2>&1 || :",
            "timeout": 10
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "^request_user_input$",
        "hooks": [
          {
            "type": "command",
            "command": "\"$(tmux show -gqv @tama_bin 2>/dev/null)\" hook codex PreToolUse >/dev/null 2>&1 || :",
            "timeout": 10
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "\"$(tmux show -gqv @tama_bin 2>/dev/null)\" hook codex PermissionRequest >/dev/null 2>&1 || :",
            "timeout": 10
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$(tmux show -gqv @tama_bin 2>/dev/null)\" hook codex PostToolUse >/dev/null 2>&1 || :",
            "timeout": 10
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "\"$(tmux show -gqv @tama_bin 2>/dev/null)\" hook codex SubagentStart >/dev/null 2>&1 || :",
            "timeout": 10
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "\"$(tmux show -gqv @tama_bin 2>/dev/null)\" hook codex SubagentStop >/dev/null 2>&1 || :",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$(tmux show -gqv @tama_bin 2>/dev/null)\" hook codex Stop >/dev/null 2>&1 || :",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$(tmux show -gqv @tama_bin 2>/dev/null)\" hook codex SessionEnd >/dev/null 2>&1 || :",
            "timeout": 3
          }
        ]
      }
    ]
  }
}
```

Every command asks the current tmux server for `@tama_bin`; no installation on `PATH` and
no hard-coded clone path are required. Missing tmux state, an unloaded plugin or an adapter
failure becomes silent success. Hooks are synchronous so lifecycle updates retain their
order; the shorter `SessionEnd` timeout is Codex's documented maximum.

## What this slice reports

`SessionStart` from startup, resume or clear makes the pane idle; compact startup preserves
the existing state. `UserPromptSubmit` and `PostToolUse` report running. A
`request_user_input` call or a human `PermissionRequest` reports waiting and requests a
notification through the core; `Stop` reports idle before requesting its completion
notification. `SessionEnd` clears the pane. `PreCompact`, `PostCompact` and unknown events
are harmless no-ops.

For permission requests, the adapter reads only the top-level
`approvals_reviewer = "auto_review"` value from the user-level
`$CODEX_HOME/config.toml` (normally `~/.codex/config.toml`). When that exact value can be
identified unambiguously, the reviewer is automatic, so the pane remains running and no
notification or flag is requested. Missing, unreadable, malformed, duplicated or non-auto
values conservatively request human attention. Official hook payloads do not reveal the
effective value contributed by a selected profile, project override, one-off configuration
or `--approve-for-me`, so the adapter cannot resolve those cases and deliberately falls back
to human attention.

Question text, approval descriptions and final assistant messages are decoded from the hook
payload when usable. Reads and messages are bounded. A truncated approval or completion uses
a short fallback, while source-dependent session starts, questions and subagent bookkeeping
are ignored because their partial fields cannot be trusted. Payload-independent main-turn
transitions and `SessionEnd` cleanup still run. The adapter never calls the
standalone flag command: waiting states and notifications compose with the core's existing
focus suppression, persistent flag, grouping, dismissal and click behavior.

`SubagentStart` and `SubagentStop` maintain only the non-empty opaque `agent_id` supplied by
Codex. An idle pane with live subagents uses the core's existing derived background state;
multiple ids and duplicate events are harmless. These hooks do not inspect the subagent's
type, prompt, output, progress or transcript and never notify. Any other lifecycle event
carrying an `agent_id` is treated as delegated work and ignored completely, so a reviewer or
subagent cannot overwrite or interrupt the main pane's lifecycle.

## Smoke test

From a tmux pane with the plugin loaded, start Codex and submit a harmless prompt. Confirm the
icon moves from idle to running and back to idle. Start a delegated agent, let the main turn
become idle and confirm the background icon remains until that agent stops. Archive or end
the Codex session and confirm the icon and any subagent state disappear. If nothing moves,
check that `tmux show -gqv @tama_bin` prints the plugin's executable path and use `/hooks` to
confirm the definitions are trusted.

The adapter requires neither `jq` nor a Codex process in the plugin's automated test suite.
