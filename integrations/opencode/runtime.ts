import { createEventAdapter, type EventAdapterDependencies } from "./adapter"
import { createLifecycleState, reduceLifecycle, type StateMachineEffect } from "./state-machine"

export type OpenCodeRuntimeDependencies = EventAdapterDependencies & Readonly<{
  runEffect(effect: StateMachineEffect): Promise<void>
  clearPane(): Promise<void>
  disposeLateWork?(): Promise<void> | void
}>

export type OpenCodeRuntime = Readonly<{
  event(event: unknown): Promise<void>
  enqueueLateWork(work: () => Promise<void>): Promise<void>
  dispose(): Promise<void>
}>

type Phase = "active" | "draining" | "disposed"

export function createOpenCodeRuntime(dependencies: OpenCodeRuntimeDependencies): OpenCodeRuntime {
  const adapter = createEventAdapter(dependencies)
  let state = createLifecycleState()
  let phase: Phase = "active"
  let tail = Promise.resolve()
  let disposal: Promise<void> | undefined

  function enqueue(work: () => Promise<void>): Promise<void> {
    if (phase !== "active") return Promise.resolve()
    const accepted = async () => {
      try {
        await work()
      } catch {
        // Operational boundaries cannot reject back into OpenCode or stop the FIFO.
      }
    }
    tail = tail.then(accepted, accepted)
    return tail
  }

  function event(event: unknown): Promise<void> {
    return enqueue(async () => {
      try {
        const lifecycleEvent = await adapter.adapt(event)
        if (!lifecycleEvent) return
        const reduction = reduceLifecycle(state, lifecycleEvent)
        state = reduction.state
        for (const effect of reduction.effects) {
          if (phase !== "active") break
          try {
            await dependencies.runEffect(effect)
          } catch {
            // One effect failure must not suppress the remaining reduction effects.
          }
        }
      } catch {
        // Malformed upstream data and lookup failures are ignored conservatively.
      }
    })
  }

  const enqueueLateWork = (work: () => Promise<void>) => enqueue(work)

  function dispose(): Promise<void> {
    if (disposal) return disposal
    phase = "draining"
    const drained = tail
    const lateWorkDisposed = settle(dependencies.disposeLateWork)
    disposal = (async () => {
      await drained
      await lateWorkDisposed
      await settle(dependencies.disposeLateWork)
      for (const sessionId of Array.from(state.activeDelegatedSessions)) {
        await settle(() => dependencies.runEffect({ type: "subagent-stop", sessionId }))
      }
      await settle(dependencies.clearPane)
      adapter.clear()
      state = createLifecycleState()
      phase = "disposed"
    })().catch(() => {
      adapter.clear()
      state = createLifecycleState()
      phase = "disposed"
    })
    return disposal
  }

  return { event, enqueueLateWork, dispose }
}

async function settle(operation: (() => Promise<void> | void) | undefined): Promise<void> {
  try {
    await operation?.()
  } catch {
    // Disposal is best effort but must always reach the disposed phase.
  }
}
