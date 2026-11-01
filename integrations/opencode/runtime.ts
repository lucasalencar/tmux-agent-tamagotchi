import { createEventAdapter, type EventAdapter, type EventAdapterDependencies } from "./adapter"
import {
  createLifecycleState,
  reduceLifecycle,
  type LifecycleEvent,
  type Reduction,
  type StateMachineEffect,
} from "./state-machine"
import type { LogContext, LogObservation } from "./effect-runner"

export type OpenCodeRuntimeDependencies = EventAdapterDependencies & Readonly<{
  loggingEnabled?: boolean
  createAdapter?: (dependencies: EventAdapterDependencies) => EventAdapter
  observeEvent?(observation: LogObservation): Promise<void>
  runEffect(effect: StateMachineEffect, context?: LogContext): Promise<void>
  clearPane(): Promise<void>
  disposeLateWork?(): Promise<void> | void
}>

export type OpenCodeRuntime = Readonly<{
  event(event: unknown): Promise<void>
  resync(events: readonly LifecycleEvent[]): Promise<void>
  reconcileAgents(agentIds: readonly string[]): Promise<void>
  enqueueLateWork(work: () => Promise<void>): Promise<void>
  dispose(): Promise<void>
}>

type Phase = "active" | "draining" | "disposed"

export function createOpenCodeRuntime(dependencies: OpenCodeRuntimeDependencies): OpenCodeRuntime {
  const adapter = (dependencies.createAdapter ?? createEventAdapter)(dependencies)
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
        ? { correlationId: `oc-${process.pid}-${Date.now().toString(36)}-${++logSequence}` }
        : undefined
      const eventName = context ? observableEventName(event) : ""
      try {
        const adaptation = await adapter.adapt(event)
        if (adaptation.status !== "adapted") {
          if (context) await settle(() => dependencies.observeEvent?.({
            ...context,
            event: eventName,
            outcome: "skipped",
            reason: adaptation.status === "malformed" ? "malformed_event" : "unknown_event",
          }))
          return
        }
        const lifecycleEvent = adaptation.event
        if (context) await settle(() => dependencies.observeEvent?.({
          ...context,
          event: eventName,
          outcome: "applied",
        }))
        await applyReduction(reduceLifecycle(state, lifecycleEvent), context)
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

  // Drops agent entries the snapshot no longer lists, so sessions deleted
  // while the plugin was down do not pin their last state forever. Runs as
  // its own FIFO unit ahead of the seed: reconcile preserves survivors, and
  // the seed that follows re-establishes them.
  function reconcileAgents(agentIds: readonly string[]): Promise<void> {
    return enqueue(async () => {
      if (phase !== "active") return
      try {
        await dependencies.runEffect({ type: "agents-reconcile", agentIds: [...agentIds] })
      } catch {
        // One effect failure must not break setup.
      }
    })
  }

  // Re-establishes pane state from an authoritative server snapshot after the
  // background service restarts. The seed runs as one FIFO unit so live
  // events that arrive later cannot interleave halfway through the snapshot;
  // callers must therefore finish their snapshot reads before subscribing.
  // Resync carries no log correlation: it replays known state, not a new
  // upstream event.
  function resync(events: readonly LifecycleEvent[]): Promise<void> {
    if (events.length === 0) return Promise.resolve()
    return enqueue(async () => {
      for (const lifecycleEvent of events) {
        await applyReduction(reduceLifecycle(state, lifecycleEvent))
      }
    })
  }

  // Applies one reduction's effects in order. Shared by live events (with
  // their log correlation) and resync seeds (replayed state, no correlation):
  // one effect failure must not suppress the remaining effects.
  async function applyReduction(reduction: Reduction, context?: LogContext): Promise<void> {
    state = reduction.state
    for (const effect of reduction.effects) {
      if (phase !== "active") break
      try {
        await dependencies.runEffect(effect, context)
      } catch {
        // One effect failure must not suppress the remaining reduction effects.
      }
    }
  }

  function dispose(): Promise<void> {
    if (disposal) return disposal
    phase = "draining"
    const drained = tail
    const lateWorkDisposed = settle(dependencies.disposeLateWork)
    disposal = (async () => {
      await drained
      await lateWorkDisposed
      await settle(dependencies.disposeLateWork)
      const rooted = new Set<string>()
      for (const [rootId, subs] of Array.from(state.rootDelegated)) {
        for (const subagentId of Array.from(subs)) {
          rooted.add(subagentId)
          await settle(() => dependencies.runEffect({ type: "agent-subagent-stop", agentId: rootId, subagentId }))
        }
      }
      for (const sessionId of Array.from(state.activeDelegatedSessions)) {
        if (!rooted.has(sessionId)) {
          await settle(() => dependencies.runEffect({ type: "subagent-stop", sessionId }))
        }
      }
      // Unregister exactly the entries this instance reported, then wipe the
      // pane's legacy residue while keeping entries another integration still
      // owns: a full clear here would drop a foreign agent on a shared pane.
      for (const agentId of Array.from(state.emittedAgents.keys())) {
        await settle(() => dependencies.runEffect({ type: "agent-clear", agentId }))
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

  return { event, resync, reconcileAgents, enqueueLateWork, dispose }
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
