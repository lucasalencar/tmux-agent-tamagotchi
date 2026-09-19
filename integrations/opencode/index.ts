import type { Plugin } from "@opencode-ai/plugin"

import { createTmuxAgentTamagotchiPlugin } from "./plugin"
import type { PluginContextV2 } from "./plugin-v2"

export const TmuxAgentTamagotchi: Plugin = createTmuxAgentTamagotchiPlugin()

// OpenCode v2 loads a plugin directory through its default export, which must
// be a definition with an id and a setup function. The v2 setup module is
// imported lazily so this entrypoint keeps loading under v1, whose host only
// provides @opencode-ai/plugin: a static v2 import would break v1 entirely.
// The definition is structural on purpose — v2 validates the id/setup shape,
// not where the types came from — so this file has no v2 package dependency.
export default {
  id: "tmux-agent-tamagotchi",
  setup: async (ctx: PluginContextV2) => {
    const { createTmuxAgentTamagotchiPluginV2 } = await import("./plugin-v2")
    return createTmuxAgentTamagotchiPluginV2()(ctx)
  },
}
