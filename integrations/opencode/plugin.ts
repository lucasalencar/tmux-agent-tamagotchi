import type { Plugin } from "@opencode-ai/plugin"

import {
  createCompletionScheduler,
  type CompletionClock,
  type CompletionReference,
  type CompletionScheduler,
} from "./completion-scheduler"
import {
  createEffectRunner,
  executeWithBun,
  type ProcessExecutor,
} from "./effect-runner"
import { createOpenCodeRuntime } from "./runtime"

export type PluginDependencies = Readonly<{
  execute?: ProcessExecutor
  clock?: CompletionClock
  onCompletionEligible?(completion: CompletionReference): Promise<void>
  disposeLateWork?(): Promise<void> | void
}>

export function createTmuxAgentTamagotchiPlugin(dependencies: PluginDependencies = {}): Plugin {
  return async (input) => {
    const runner = createEffectRunner({
      execute: dependencies.execute ?? executeWithBun,
      onCompletionEligible: dependencies.onCompletionEligible,
    })
    let scheduler: CompletionScheduler
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
      runEffect: async (effect) => {
        scheduler.handle(effect)
        await runner.run(effect)
      },
      clearPane: runner.clearPane,
      disposeLateWork: async () => {
        scheduler.dispose()
        await dependencies.disposeLateWork?.()
      },
    })
    scheduler = createCompletionScheduler({
      clock: dependencies.clock,
      lookupMessage: async ({ sessionId, messageId }) => {
        const response = await input.client.session.message({
          path: { id: sessionId, messageID: messageId },
          query: { directory: input.directory },
        })
        return response.data
      },
      enqueue: (work) => {
        void runtime.enqueueLateWork(work)
      },
      notify: runner.notify,
    })

    return {
      event: ({ event }) => runtime.event(event),
      dispose: runtime.dispose,
    }
  }
}
