import type { Plugin } from "@opencode-ai/plugin"

import {
  createEffectRunner,
  executeWithBun,
  type CompletionReference,
  type ProcessExecutor,
} from "./effect-runner"
import { createOpenCodeRuntime } from "./runtime"

export type PluginDependencies = Readonly<{
  execute?: ProcessExecutor
  onCompletionEligible?(completion: CompletionReference): Promise<void>
  disposeLateWork?(): Promise<void> | void
}>

export function createTmuxAgentTamagotchiPlugin(dependencies: PluginDependencies = {}): Plugin {
  return async (input) => {
    const runner = createEffectRunner({
      execute: dependencies.execute ?? executeWithBun,
      onCompletionEligible: dependencies.onCompletionEligible,
    })
    const runtime = createOpenCodeRuntime({
      lookupSession: async (sessionId) => {
        const response = await input.client.session.get({
          path: { id: sessionId },
          query: { directory: input.directory },
        })
        const session = response.data
        return session
          ? {
              id: session.id,
              ...(Object.prototype.hasOwnProperty.call(session, "parentID")
                ? { parentID: session.parentID }
                : {}),
            }
          : undefined
      },
      runEffect: runner.run,
      clearPane: runner.clearPane,
      disposeLateWork: dependencies.disposeLateWork,
    })

    return {
      event: ({ event }) => runtime.event(event),
      dispose: runtime.dispose,
    }
  }
}
