# Claude Code

Paste the block below into your Claude Code settings — `~/.claude/settings.json` for every
project, `.claude/settings.json` for one — and the icons move on their own. If you already
have a `hooks` key, merge these entries into it; Claude Code merges hooks across settings
files rather than replacing them.

Nothing here is a payload format or a filter: every entry is one Claude Code event name
handed to the plugin. What each event means, which notifications are worth your attention
and what a delegated run does live in `hook` next to this file, so a change there reaches
you by pulling the plugin.

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tama=$(tmux show -gqv @tama_bin); [ -x \"$tama\" ] || exit 0; exec \"$tama\" hook claude-code SessionStart" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tama=$(tmux show -gqv @tama_bin); [ -x \"$tama\" ] || exit 0; exec \"$tama\" hook claude-code UserPromptSubmit" } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tama=$(tmux show -gqv @tama_bin); [ -x \"$tama\" ] || exit 0; exec \"$tama\" hook claude-code PostToolUse" } ] }
    ],
    "PostToolUseFailure": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tama=$(tmux show -gqv @tama_bin); [ -x \"$tama\" ] || exit 0; exec \"$tama\" hook claude-code PostToolUseFailure" } ] }
    ],
    "PermissionRequest": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tama=$(tmux show -gqv @tama_bin); [ -x \"$tama\" ] || exit 0; exec \"$tama\" hook claude-code PermissionRequest" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tama=$(tmux show -gqv @tama_bin); [ -x \"$tama\" ] || exit 0; exec \"$tama\" hook claude-code Notification" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tama=$(tmux show -gqv @tama_bin); [ -x \"$tama\" ] || exit 0; exec \"$tama\" hook claude-code Stop" } ] }
    ],
    "StopFailure": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tama=$(tmux show -gqv @tama_bin); [ -x \"$tama\" ] || exit 0; exec \"$tama\" hook claude-code StopFailure" } ] }
    ],
    "SubagentStart": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tama=$(tmux show -gqv @tama_bin); [ -x \"$tama\" ] || exit 0; exec \"$tama\" hook claude-code SubagentStart" } ] }
    ],
    "SubagentStop": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tama=$(tmux show -gqv @tama_bin); [ -x \"$tama\" ] || exit 0; exec \"$tama\" hook claude-code SubagentStop" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tama=$(tmux show -gqv @tama_bin); [ -x \"$tama\" ] || exit 0; exec \"$tama\" hook claude-code SessionEnd" } ] }
    ]
  }
}
```

Every command is the same three lines, which is the recipe every hook in this plugin
follows and the reason it survives you moving the plugin: bail out when there is no tmux to
talk to, ask tmux where the plugin is, bail out again if it is not installed on this
machine. No absolute path to the plugin appears anywhere in your settings (ADR-0003).

## What you get

| Event | What the pane shows |
| --- | --- |
| `SessionStart` | idle — the pane has an agent in it now, and says so before you type |
| `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure` | running |
| `PermissionRequest` | waiting, and the window is flagged if you are looking elsewhere |
| `Notification` | waiting, for the types that mean you are wanted |
| `Stop` | idle |
| `StopFailure` | error — the turn ended on an API error |
| `SubagentStart`, `SubagentStop` | the pane's subagent count, which is what renders an idle agent with live subagents as working in the background |
| `SessionEnd` | cleared — no trace left in tmux |

## The two things that depend on the payload

Every state above is decided from the event name alone, except for two, which read one
field each out of the JSON Claude Code sends the hook on stdin:

- **Subagent tracking** — and with it the background icon — needs `agent_id` from
  `SubagentStart`/`SubagentStop`. The plugin counts delegated runs by the id their agent
  gives them, and Claude Code offers that id nowhere but the payload: command hooks
  substitute only `${CLAUDE_PROJECT_DIR}` and its siblings into their arguments.
- **Which notifications mean you are wanted** needs `notification_type` from
  `Notification`, the only thing separating a permission prompt or a question from routine
  noise like `auth_success`. A type this version has not seen is treated as routine.

So if a future Claude Code renames or reshapes those fields, these two behaviours are what
stops working — the background icon goes missing and `Notification` stops raising `waiting`
— and nothing else changes. The reading is best effort by design: no field, a payload that
does not arrive, or a value that is not a plain token means the plugin does without it and
exits 0. It never fails your turn, and never prints into your transcript.

## If nothing moves

- The plugin has to be loaded in the tmux server the agent is running in — `tmux show -gqv
  @tama_bin` from that pane must print a path.
- The icons appear where you put `#{E:@tama_icons}` in your own status line; the plugin
  never edits it for you. See `tama --help`.
- Hooks configured in a project's `.claude/settings.json` only run after you accept the
  workspace trust prompt for that folder.
- Claude Code's `claude --debug` prints what each hook did.
- If everything moves except the background icon, it is the `agent_id` read above that has
  broken; everything else works without the payload.

Verified against Claude Code 2.1.227.
