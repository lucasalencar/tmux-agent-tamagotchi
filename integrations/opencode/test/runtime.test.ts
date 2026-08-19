import { describe, expect, test } from "bun:test"

import { createOpenCodeRuntime } from "../runtime"
import type { StateMachineEffect } from "../state-machine"

describe("OpenCode runtime", () => {
  test("serializes fire-and-forget callbacks behind slow classification", async () => {
    const lookup = deferred<{ id: string } | undefined>()
    const effects: StateMachineEffect[] = []
    const runtime = createOpenCodeRuntime({
      lookupSession: async () => lookup.promise,
      runEffect: async (effect) => {
        effects.push(effect)
      },
      clearPane: async () => undefined,
    })

    const first = runtime.event(statusEvent("root-a", "busy"))
    const second = runtime.event({
      type: "permission.asked",
      properties: { id: "request-a", sessionID: "root-a" },
    })
    expect(effects).toEqual([])

    lookup.resolve({ id: "root-a" })
    await expect(Promise.all([first, second])).resolves.toEqual([undefined, undefined])
    expect(effects).toEqual([
      { type: "pane-state", state: "running" },
      { type: "pane-state", state: "waiting" },
    ])
  })

  test("contains operational failures and continues processing later events", async () => {
    const attempted: StateMachineEffect[] = []
    let lookups = 0
    const runtime = createOpenCodeRuntime({
      lookupSession: async (sessionId) => {
        lookups += 1
        return { id: sessionId }
      },
      runEffect: async (effect) => {
        attempted.push(effect)
        if (effect.type === "pane-state" && effect.state === "running") {
          throw new Error("tama unavailable")
        }
      },
      clearPane: async () => {
        throw new Error("tmux unavailable")
      },
    })

    const running = runtime.event(statusEvent("root-a", "busy"))
    const waiting = runtime.event({
      type: "permission.asked",
      properties: { id: "request-a", sessionID: "root-a" },
    })
    await expect(Promise.all([running, waiting])).resolves.toEqual([undefined, undefined])
    expect(attempted).toEqual([
      { type: "pane-state", state: "running" },
      { type: "pane-state", state: "waiting" },
    ])

    await expect(runtime.dispose()).resolves.toBeUndefined()
    await expect(runtime.event(statusEvent("late-root", "busy"))).resolves.toBeUndefined()
    expect(lookups).toBe(1)
  })

  test("serializes admitted late work before later pane activity", async () => {
    const workStarted = deferred<void>()
    const releaseWork = deferred<void>()
    const log: string[] = []
    const runtime = createOpenCodeRuntime({
      lookupSession: async (sessionId) => ({ id: sessionId }),
      runEffect: async (effect) => {
        if (effect.type === "pane-state") log.push(`state:${effect.state}`)
      },
      clearPane: async () => undefined,
    })

    const work = runtime.enqueueLateWork(async () => {
      log.push("notify:start")
      workStarted.resolve()
      await releaseWork.promise
      log.push("notify:end")
    })
    await workStarted.promise
    const activity = runtime.event(statusEvent("root-a", "busy"))

    expect(log).toEqual(["notify:start"])
    releaseWork.resolve()
    await expect(Promise.all([work, activity])).resolves.toEqual([undefined, undefined])
    expect(log).toEqual(["notify:start", "notify:end", "state:running"])
  })

  test("drains admitted events, suppresses their late effects, and makes disposal idempotent", async () => {
    const errorEffectStarted = deferred<void>()
    const releaseErrorEffect = deferred<void>()
    const log: string[] = []
    const runtime = createOpenCodeRuntime({
      lookupSession: async (sessionId) => ({ id: sessionId }),
      runEffect: async (effect) => {
        log.push(effect.type === "pane-state" ? `state:${effect.state}` : effect.type)
        if (effect.type === "pane-state" && effect.state === "error") {
          errorEffectStarted.resolve()
          await releaseErrorEffect.promise
        }
      },
      disposeLateWork: () => {
        log.push("cancel-late-work")
      },
      clearPane: async () => {
        log.push("clear")
      },
    })
    await runtime.event({ type: "session.created", properties: { info: { id: "root-a" } } })
    const admitted = runtime.event({
      type: "session.error",
      properties: { sessionID: "root-a", error: { data: { message: "boom" } } },
    })
    await errorEffectStarted.promise

    const disposal = runtime.dispose()
    expect(runtime.dispose()).toBe(disposal)
    const late = runtime.event({
      type: "permission.asked",
      properties: { id: "late-request", sessionID: "root-a" },
    })
    expect(log).toEqual(["state:idle", "state:error", "cancel-late-work"])

    releaseErrorEffect.resolve()
    await expect(Promise.all([admitted, late, disposal])).resolves.toEqual([undefined, undefined, undefined])
    expect(log).toEqual([
      "state:idle",
      "state:error",
      "cancel-late-work",
      "cancel-late-work",
      "clear",
    ])
  })

  test("stops tracked delegated sessions before clearing the pane", async () => {
    const log: string[] = []
    const runtime = createOpenCodeRuntime({
      lookupSession: async (sessionId) => sessionId === "root-a"
        ? { id: "root-a" }
        : { id: sessionId, parentID: "root-a" },
      runEffect: async (effect) => {
        log.push(effect.type === "subagent-start" || effect.type === "subagent-stop"
          ? `${effect.type}:${effect.sessionId}`
          : effect.type)
      },
      clearPane: async () => {
        log.push("clear")
      },
    })

    await runtime.event(statusEvent("child-a", "busy"))
    await runtime.dispose()

    expect(log).toEqual([
      "subagent-start:child-a",
      "subagent-stop:child-a",
      "clear",
    ])
  })
})

function statusEvent(sessionID: string, type: "busy" | "retry" | "idle") {
  return { type: "session.status", properties: { sessionID, status: { type } } }
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => {
    resolve = done
  })
  return { promise, resolve }
}
