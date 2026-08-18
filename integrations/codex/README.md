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
        "matcher": "other",
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
the existing state. `UserPromptSubmit` and `PostToolUse` report running, `Stop` reports idle,
and `SessionEnd` clears the pane. `PreCompact`, `PostCompact` and unknown events are harmless
no-ops.

## Smoke test

From a tmux pane with the plugin loaded, start Codex and submit a harmless prompt. Confirm the
icon moves from idle to running and back to idle. Archive or end the Codex session and confirm
the icon disappears. If nothing moves, check that `tmux show -gqv @tama_bin` prints the
plugin's executable path and use `/hooks` to confirm the definitions are trusted.

The adapter requires neither `jq` nor a Codex process in the plugin's automated test suite.
