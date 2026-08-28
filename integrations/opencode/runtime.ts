import { createEventAdapter, type EventAdapterDependencies } from "./adapter"
import { createLifecycleState, reduceLifecycle, type StateMachineEffect } from "./state-machine"
import type { LogContext, LogObservation } from "./effect-runner"

export type OpenCodeRuntimeDependencies = EventAdapterDependencies & Readonly<{
  loggingEnabled?: boolean
  observeEvent?(observation: LogObservation): Promise<void>
  runEffect(effect: StateMachineEffect, context?: LogContext): Promise<void>
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
  let logSequence = 0

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
      const context = dependencies.loggingEnabled
        ? { correlationId: `oc-${Date.now().toString(36)}-${++logSequence}` }
        : undefined
      const eventName = context ? observableEventName(event) : ""
      try {
        const lifecycleEvent = await adapter.adapt(event)
        if (!lifecycleEvent) {
          if (context) await settle(() => dependencies.observeEvent?.({
            ...context,
            event: eventName,
            outcome: "skipped",
            reason: eventName === "malformed" ? "malformed_event" : "unknown_event",
          }))
          return
        }
        if (context) await settle(() => dependencies.observeEvent?.({
          ...context,
          event: eventName,
          outcome: "applied",
        }))
        const reduction = reduceLifecycle(state, lifecycleEvent)
        state = reduction.state
        for (const effect of reduction.effects) {
          if (phase !== "active") break
          try {
            await dependencies.runEffect(effect, context)
          } catch {
            // One effect failure must not suppress the remaining reduction effects.
          }
        }
      } catch {
        if (context) await settle(() => dependencies.observeEvent?.({
          ...context,
          event: eventName,
          outcome: "skipped",
          reason: "malformed_event",
        }))
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

function observableEventName(event: unknown): string {
  if (!event || typeof event !== "object" || !("type" in event)) return "malformed"
  const type = (event as { type?: unknown }).type
  return typeof type === "string" && /^[A-Za-z0-9_.-]{1,64}$/.test(type)
    ? type
    : "malformed"
}

async function settle(operation: (() => Promise<void> | void) | undefined): Promise<void> {
  try {
    await operation?.()
  } catch {
    // Disposal is best effort but must always reach the disposed phase.
  }
}
