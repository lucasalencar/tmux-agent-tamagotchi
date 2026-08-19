# OpenCode integration

This directory contains the native TypeScript integration for OpenCode (ADR-0010). It is best
effort and outside the stable `tama` contract, like the other agent-specific integrations.

The current scaffold is deliberately inert. It proves that OpenCode can load the entrypoint and
fixes the upstream contract used by the implementation that follows; lifecycle aggregation and
effects are added in later slices.

## Tested toolchain

| Component | Version |
| --- | --- |
| OpenCode | 1.18.18 |
| `@opencode-ai/plugin` | 1.18.18 |
| `@opencode-ai/sdk` | 1.18.18 |
| Bun | 1.3.14 |
| TypeScript | 5.8.2 |

The versions are exact development pins, not a runtime rejection policy. Compatibility with other
OpenCode versions remains best effort. Bun and TypeScript match the versions recorded by the
[OpenCode 1.18.18 workspace](https://github.com/anomalyco/opencode/blob/v1.18.18/package.json).

## Verified upstream contract

- A local TypeScript module may export a named async plugin function. It receives `PluginInput` and
  returns `Hooks`; this entrypoint exports exactly one runtime value because OpenCode treats every
  named export in a legacy module as a plugin function.
- The `event` hook receives `{ event }`. OpenCode invokes these callbacks without awaiting them, so
  the completed integration must own event ordering and catch every rejection.
- During scope shutdown, OpenCode awaits each hook's optional `dispose` callback before its listener
  unsubscribe finalizer runs. The integration must therefore stop accepting callbacks itself before
  it drains accepted work.
- Sessions expose an optional `parentID`. `session.status` carries `busy`, `retry`, or `idle`; the
  documented events also provide creation, deletion, attributed errors, messages, and permissions.
- The SDK supports exact session and message lookup with
  `client.session.get({ path: { id } })` and
  `client.session.message({ path: { id, messageID } })`.
- Global configuration lives at `~/.config/opencode/opencode.json`. The loader accepts an absolute
  path (or `file://` URL) to this directory's TypeScript source. The canonical installation recipe
  will be documented when the integration is wired end to end.

There are two known 1.18.18 typing drifts. The runtime adds an `id` to the event envelope, which the
generated SDK `Event` union omits. The documentation and runtime also publish `permission.asked`
plus `permission.replied` with `requestID`/`reply`, while that union still contains the earlier
`permission.updated` and `permissionID`/`response` shapes. `contract.ts` records the observed
runtime payload explicitly; the adapter must normalize unknown input rather than rely on exhaustive
SDK narrowing.

Primary references are the tagged
[plugin documentation](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/web/src/content/docs/plugins.mdx),
[plugin runtime](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/plugin/index.ts),
[plugin loader](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/plugin/shared.ts),
[configuration resolver](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/config/plugin.ts),
[permission schema](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/schema/src/v1/permission.ts),
and the published 1.18.18 plugin and SDK typings pinned in `package.json` and `bun.lock`.

## Development

Run all commands from this directory:

```sh
bun install --frozen-lockfile
bun test
bun run typecheck
```
