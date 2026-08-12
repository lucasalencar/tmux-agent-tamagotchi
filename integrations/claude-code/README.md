# Claude Code

Paste the block below into your Claude Code settings — `~/.claude/settings.json` for every
project, `.claude/settings.json` for one — and the icons move on their own. If you already
have a `hooks` key, merge these entries into it; Claude Code merges hooks across settings
files rather than replacing them.

Nothing here is a payload format or a filter: every entry is one Claude Code event name
handed to the plugin. What each event means, which of them are worth a desktop banner, which
notifications are worth your attention and what a delegated run does live in `hook` next to
this file, so a change there reaches you by pulling the plugin.

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

| Event | What the pane shows | Banner |
| --- | --- | --- |
| `SessionStart` | idle — the pane has an agent in it now, and says so before you type | |
| `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure` | running | |
| `PermissionRequest` | waiting, and the window is flagged if you are looking elsewhere | no — the `Notification` below is the banner for it |
| `Notification` | waiting, for the types that mean you are wanted | yes, carrying the message Claude Code wrote — except the idle prompt, below |
| `Stop` | idle | yes, carrying the agent's last message |
| `StopFailure` | error — the turn ended on an API error | yes |
| `SubagentStart`, `SubagentStop` | the pane's subagent count, which is what renders an idle agent with live subagents as working in the background | never |
| `SessionEnd` | cleared — no trace left in tmux | |

A banner arrives only when you are not already looking at that window, it replaces the
previous one for the same window rather than stacking, clicking it puts your cursor on the
pane that spoke, and selecting the window takes it down. All of that is the plugin's job
rather than this adapter's — see `tama --help` — and `set -g @tama_notifications off` turns
the lot off while leaving the icons.

## Which events interrupt you, and which only move an icon

Three events raise a banner: `Notification`, `Stop` and `StopFailure`. A question and a
finished turn are the two things you can miss; everything else is visible in the status line
if you are looking at it and forgotten if you are not.

**`PermissionRequest` deliberately does not banner**, even though it is the event that turns
the pane `waiting`. Claude Code raises `Notification` for the same interruption a few seconds
later — measured at 6s on 2.1.228 — and that one carries the sentence the permission event has
no field for. Wiring both would mean two banners per question, collapsing into one only
because the plugin groups them per window, with the vaguer of the two arriving first. The
delay is not a cost either: a prompt you answer straight away never interrupts you at all,
while the icon and the window mark are there the instant the prompt appears. And the
`Notification` event does not depend on your own Claude Code notification settings — it
still fires with `preferredNotifChannel: notifications_disabled`.

**The idle prompt deliberately does not banner either**, for the same reason at the other end
of the turn. Sixty seconds after every turn ends — measured at exactly +60s on three
consecutive turns of a 2.1.228 session — Claude Code raises a `Notification` of type
`idle_prompt` whose message is always `Claude is waiting for your input`. `Stop` has already
bannered by then, carrying what the agent actually said. Wiring both would mean being
interrupted twice for one finished turn, and because banners are grouped per window the
second one would *replace* the first: a minute after being told what the agent said, you
would be told again in words that say nothing. So the idle prompt moves the icon to `waiting`
and stops there.

**Nothing a delegated run is attributed to raises a banner.** A subagent finishing is not
your session finishing, and a payload carrying `agent_id` is Claude Code telling the adapter
which run an event belongs to. Nothing is lost: a permission prompt raised *inside* a
subagent also arrives as a session-level `Notification` with no `agent_id` in it, so you get
the banner from the event that has the message in it.

## The things that depend on the payload

Every state above is decided from the event name alone. Four fields are read out of the JSON
Claude Code sends the hook on stdin, and nothing else is:

- **Subagent tracking** — and with it the background icon — needs `agent_id` from
  `SubagentStart`/`SubagentStop`. The plugin counts delegated runs by the id their agent
  gives them, and Claude Code offers that id nowhere but the payload: command hooks
  substitute only `${CLAUDE_PROJECT_DIR}` and its siblings into their arguments. The same
  field, on any event, is what marks it as belonging to a delegated run.
- **Which notifications mean you are wanted** needs `notification_type` from
  `Notification`, the only thing separating a permission prompt or a question from routine
  noise like `auth_success`. A type this version has not seen is treated as routine.
- **What a banner says** is `message` on `Notification` and `last_assistant_message` on
  `Stop`. This is the one value in the payload a model wrote rather than a machine, so the
  adapter decodes JSON escaping for it — a message with a quote in it is ordinary — and
  hands the result to the plugin's CLI as a single argument that nothing expands, splits or
  reads as shell. It is cut to 500 characters, which is more than a desktop banner draws.
  An event whose message cannot be read banners anyway, saying what happened.

So if a future Claude Code renames or reshapes those fields, that is what stops working —
the background icon goes missing, `Notification` stops raising `waiting`, or banners fall
back to their own wording — and nothing else changes. The reading is best effort by design:
no field, a payload that does not arrive, or a value that is not the shape it should be means
the plugin does without it and exits 0. It never fails your turn, and never prints into your
transcript.

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

## If the icons move but no banner arrives

- A banner needs a notifier the plugin can find. `backends/README.md` says what is expected on
  your platform; with none installed the plugin resolves to doing nothing rather than failing.
- You are looking at that window, in a terminal that is in front. That is the one case the
  plugin stays quiet on purpose.
- You answered the permission prompt within a few seconds. `PermissionRequest` never banners;
  the `Notification` that would have is raised a little later, and answering first means it
  never happens.
- The window mark (`*`, or whatever you put `#{E:@tama_flag}` next to) is raised by exactly
  the same decision as the banner. A marked window with no banner means the notifier is
  missing; no mark either means the plugin thinks you were looking.

Verified against Claude Code 2.1.228.
