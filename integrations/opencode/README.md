# OpenCode

This is the native OpenCode integration for tmux-agent-tamagotchi. Install and configure the
tmux plugin first, including the status-line formats from the [project README](../../README.md).
OpenCode then loads this TypeScript source directly and the integration reports lifecycle changes
through the same public `tama` CLI used by the shell adapters; it does not use a private core API
or require a generated JavaScript build (ADR-0010).

The integration is best effort and outside the plugin's stable version promise. It was verified
against OpenCode 1.18.18 with Bun 1.3.14. Other OpenCode versions are not rejected, but an upstream
event or plugin API change may require an integration update.

## Configure the global plugin

OpenCode reads the global configuration from `~/.config/opencode/opencode.json`. Add the `plugin`
entry below, replacing the entire placeholder `/absolute/path/to/tmux-agent-tamagotchi` with the
absolute path returned by the command below. Keep any other configuration keys and merge this
string into an existing `plugin` array instead of replacing it.

To locate a TPM or manual clone after tmux-agent-tamagotchi is loaded, run
`dirname "$(dirname "$(tmux show -gqv @tama_bin)")"` inside tmux. The resulting configuration must
name the repository's real `integrations/opencode/index.ts`; copying the source elsewhere would
prevent a normal plugin update from updating the integration.

<!-- opencode-global-config:start -->
```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    "/absolute/path/to/tmux-agent-tamagotchi/integrations/opencode/index.ts"
  ]
}
```
<!-- opencode-global-config:end -->

An absolute `file://` URL is also accepted; URL-encode spaces and other special characters when
using that form. Restart OpenCode after changing its configuration. For a project-only setup, put
the same absolute plugin entry in `opencode.json` at that project's root instead of the global
file. The global configuration above is the canonical recipe and is the recommended setup.

## What it reports

The plugin tracks every root session observed by one OpenCode instance and reduces them into the
pane state with the precedence `waiting > error > running > idle`:

| OpenCode lifecycle | tmux-agent-tamagotchi behavior |
| --- | --- |
| Root session created | Sets the pane to `idle`, showing that OpenCode is present. |
| Root `busy` or `retry` | Sets that root to `running`; retry is not reported as failure. |
| Root `idle` | Sets that root to `idle`, unless its last attributed error is still active. |
| Permission asked | Sets the pane to `waiting`, including requests from delegated sessions. Concurrent requests remain independent. |
| Permission replied | Removes only that request and recomputes the aggregate state. |
| Attributed root error | Sets that root to persistent `error` and raises an error notification. A later `busy` or `retry`, or deleting the root, clears the error. |
| Attributed delegated error | Stops only that subagent; it does not fail the root pane. |
| Delegated `busy`/`retry` | Starts subagent tracking with the opaque OpenCode session id, allowing the core to derive `background`. |
| Delegated `idle`, error, or deletion | Stops that subagent id. Duplicate transitions are harmless. |
| Session deletion | Removes only that session and its permission requests, then recomputes the remaining aggregate. |
| OpenCode disposal | Drains admitted work, cancels pending completion work, stops tracked subagents, and clears the pane. |

Sessions are classified conservatively from `parentID`, using an exact SDK lookup when the event
does not include session information. Unattributed errors and events whose session metadata cannot
be recovered are ignored. Unknown or malformed events and operational failures are silent.

## Completion notifications

An eligible successful turn sets the pane to `idle` immediately, then waits ten seconds before
raising its completion banner. Duplicate idle events do not restart that delay. New root activity,
permission attention, or a delegated/background session starting cancels the pending completion;
a subagent's later stop does not resurrect it. This prevents a root completion from announcing
that the pane is finished while delegated work is still running.

Only a terminal, non-compaction assistant message qualifies. The integration retrieves that exact
message with a two-second bound and includes only its ordered, non-empty visible text parts. It
excludes reasoning, tool output, structured, synthetic, ignored, and compaction content. Markdown,
Unicode, and line breaks are preserved; unusable controls are removed and text is capped at 500
characters, preferably at a word boundary. Lookup failure, malformed content, or empty visible
text uses `OpenCode finished its turn` instead of dropping a valid completion notification.
Response content is enabled by default and this first version has no OpenCode-specific content
toggle.

## Troubleshooting

- Run `"$(tmux show -gqv @tama_bin)" doctor` in the same tmux server. Fix plugin loading and
  status-line warnings before debugging OpenCode.
- Confirm `tmux show -gqv @tama_bin` returns an executable path and that the path in
  `opencode.json` is absolute, exists, and ends in `integrations/opencode/index.ts`.
- Start OpenCode from inside the intended tmux pane so it inherits `TMUX` and `TMUX_PANE`, then
  restart it after changing configuration.
- Check that the configured entrypoint is readable by the account running OpenCode. No production
  build or global `tama` executable is expected.
- The integration deliberately contains lookup, tmux, CLI, and notification failures so they do
  not interrupt OpenCode. If OpenCode works but no state appears, use `doctor` and the path checks
  above; silence is the operational failure policy, not evidence that a command succeeded.

## Tested toolchain and development

| Component | Version |
| --- | --- |
| OpenCode | 1.18.18 |
| `@opencode-ai/plugin` | 1.18.18 |
| `@opencode-ai/sdk` | 1.18.18 |
| Bun | 1.3.14 |
| TypeScript | 5.8.2 |

Runtime source, development dependencies, lockfile, tests, and TypeScript configuration stay in
this directory so Bun never becomes a requirement of the shell core. From this directory:

```sh
bun install --frozen-lockfile
bun test
bun run typecheck
```

The 1.18.18 SDK typings lag two observed public payloads: the runtime event envelope adds an `id`,
and the documented permission events use `permission.asked`/`permission.replied` with
`requestID`/`reply` while the generated union still contains the older names. `contract.ts`
records this compatibility boundary and the adapter normalizes unknown input defensively.

Primary upstream references are the tagged
[plugin documentation](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/web/src/content/docs/plugins.mdx),
[plugin runtime](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/plugin/index.ts),
[plugin loader](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/plugin/shared.ts),
[configuration resolver](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/config/plugin.ts),
and [permission schema](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/schema/src/v1/permission.ts).
