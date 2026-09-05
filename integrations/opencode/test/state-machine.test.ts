import { describe, expect, test } from "bun:test"

import {
  createLifecycleState,
  reduceLifecycle,
  type LifecycleEvent,
  type LifecycleState,
  type PaneState,
  type StateMachineEffect,
} from "../state-machine"

type Step = {
  event: LifecycleEvent
  paneState: PaneState
  effects: StateMachineEffect[]
}

function run(initial: LifecycleState, steps: Step[]): LifecycleState {
  return steps.reduce((state, step) => {
    const result = reduceLifecycle(state, step.event)

    expect(result.state.paneState).toBe(step.paneState)
    expect(result.effects).toEqual(step.effects)
    return result.state
  }, initial)
}

describe("root session activity", () => {
  test("a root starts idle, runs while busy or retrying, and becomes idle on completion", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [{ type: "pane-state", state: "running" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "retry" },
        paneState: "running",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
    ])
  })

  test("a completed root assistant message ends a turn without a later idle status", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [{ type: "pane-state", state: "running" }],
      },
      {
        event: {
          type: "terminal-assistant-message",
          sessionId: "root-a",
          kind: "root",
          messageId: "message-a",
          finish: "stop",
        },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "completion-eligible", sessionId: "root-a", messageId: "message-a" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "idle",
        effects: [],
      },
      {
        event: { type: "user-message", sessionId: "root-a", kind: "root" },
        paneState: "running",
        effects: [{ type: "pane-state", state: "running" }],
      },
    ])
  })

  test("a root error clears when the session reports any status after resuming", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
      {
        event: { type: "session-error", sessionId: "root-a", kind: "root", message: "failed" },
        paneState: "error",
        effects: [
          { type: "pane-state", state: "error" },
          { type: "root-error", sessionId: "root-a", message: "failed" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy" },
        paneState: "error",
        effects: [{ type: "subagent-start", sessionId: "child-a" }],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "idle" },
        paneState: "error",
        effects: [{ type: "subagent-stop", sessionId: "child-a" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "retry" },
        paneState: "running",
        effects: [{ type: "pane-state", state: "running" }],
      },
    ])
  })

  test.each(["busy", "retry"] as const)("%s resumes an errored root as running", (status) => {
    const created = reduceLifecycle(createLifecycleState(), {
      type: "session-error",
      sessionId: "root-a",
      kind: "root",
    })

    const resumed = reduceLifecycle(created.state, {
      type: "session-status",
      sessionId: "root-a",
      kind: "root",
      status,
    })

    expect(resumed.state.paneState).toBe("running")
    expect(resumed.effects).toEqual([{ type: "pane-state", state: "running" }])
  })

  test("re-creating a session resets a stuck errored root", () => {
    const errored = reduceLifecycle(createLifecycleState(), {
      type: "session-error",
      sessionId: "root-a",
      kind: "root",
    })

    const recreated = reduceLifecycle(errored.state, {
      type: "session-created",
      sessionId: "root-a",
      kind: "root",
    })

    expect(recreated.state.paneState).toBe("idle")
    expect(recreated.effects).toEqual([{ type: "pane-state", state: "idle" }])
  })

  test("re-creating a running root does not clobber its state", () => {
    const running = reduceLifecycle(createLifecycleState(), {
      type: "session-status",
      sessionId: "root-a",
      kind: "root",
      status: "busy",
    })

    const recreated = reduceLifecycle(running.state, {
      type: "session-created",
      sessionId: "root-a",
      kind: "root",
    })

    expect(recreated.state.paneState).toBe("running")
    expect(recreated.effects).toEqual([])
  })
})

describe("pane aggregation", () => {
  test("several roots use error before running before idle, and deletion removes only its root", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-idle", kind: "root" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
      {
        event: { type: "session-status", sessionId: "root-running", kind: "root", status: "busy" },
        paneState: "running",
        effects: [{ type: "pane-state", state: "running" }],
      },
      {
        event: { type: "session-error", sessionId: "root-error", kind: "root" },
        paneState: "error",
        effects: [
          { type: "pane-state", state: "error" },
          { type: "root-error", sessionId: "root-error", message: undefined },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-idle", kind: "root", status: "idle" },
        paneState: "error",
        effects: [],
      },
      {
        event: { type: "session-deleted", sessionId: "root-error", kind: "root" },
        paneState: "running",
        effects: [{ type: "pane-state", state: "running" }],
      },
      {
        event: { type: "session-deleted", sessionId: "root-running", kind: "root" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
      {
        event: { type: "session-deleted", sessionId: "root-idle", kind: "root" },
        paneState: "idle",
        effects: [],
      },
    ])
  })

  test("concurrent permissions overlay every root state and resolve independently by request id", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-error", sessionId: "root-a", kind: "root", message: "boom" },
        paneState: "error",
        effects: [
          { type: "pane-state", state: "error" },
          { type: "root-error", sessionId: "root-a", message: "boom" },
        ],
      },
      {
        event: {
          type: "permission-asked",
          requestId: "permission-child",
          sessionId: "child-a",
          kind: "delegated",
        },
        paneState: "waiting",
        effects: [{ type: "pane-state", state: "waiting" }],
      },
      {
        event: {
          type: "permission-asked",
          requestId: "permission-root",
          sessionId: "root-a",
          kind: "root",
        },
        paneState: "waiting",
        effects: [],
      },
      {
        event: { type: "permission-replied", requestId: "permission-child" },
        paneState: "waiting",
        effects: [],
      },
      {
        event: { type: "permission-replied", requestId: "permission-child" },
        paneState: "waiting",
        effects: [],
      },
      {
        event: { type: "permission-replied", requestId: "permission-root" },
        paneState: "error",
        effects: [{ type: "pane-state", state: "error" }],
      },
    ])
  })
})

describe("delegated sessions", () => {
  test("deleting an unobserved delegated session does not establish the agent pane", () => {
    const delegatedDeletion = reduceLifecycle(createLifecycleState(), {
      type: "session-deleted",
      sessionId: "child-a",
      kind: "delegated",
    })

    expect(delegatedDeletion.state.paneState).toBe("idle")
    expect(delegatedDeletion.effects).toEqual([])

    const rootCreation = reduceLifecycle(delegatedDeletion.state, {
      type: "session-created",
      sessionId: "root-a",
      kind: "root",
    })
    expect(rootCreation.effects).toEqual([{ type: "pane-state", state: "idle" }])
  })

  test("busy starts a subagent and idle, error, or deletion stops it without failing the pane", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
      {
        event: { type: "session-created", sessionId: "child-a", kind: "delegated" },
        paneState: "idle",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy" },
        paneState: "idle",
        effects: [{ type: "subagent-start", sessionId: "child-a" }],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "retry" },
        paneState: "idle",
        effects: [],
      },
      {
        event: { type: "session-error", sessionId: "child-a", kind: "delegated", message: "failed" },
        paneState: "idle",
        effects: [{ type: "subagent-stop", sessionId: "child-a" }],
      },
      {
        event: { type: "session-error", sessionId: "child-a", kind: "delegated" },
        paneState: "idle",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy" },
        paneState: "idle",
        effects: [{ type: "subagent-start", sessionId: "child-a" }],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "idle" },
        paneState: "idle",
        effects: [{ type: "subagent-stop", sessionId: "child-a" }],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "idle" },
        paneState: "idle",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy" },
        paneState: "idle",
        effects: [{ type: "subagent-start", sessionId: "child-a" }],
      },
      {
        event: { type: "session-deleted", sessionId: "child-a", kind: "delegated" },
        paneState: "idle",
        effects: [{ type: "subagent-stop", sessionId: "child-a" }],
      },
    ])
  })

  test("deleting a session removes its outstanding permission requests", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
      {
        event: {
          type: "permission-asked",
          requestId: "permission-child",
          sessionId: "child-a",
          kind: "delegated",
        },
        paneState: "waiting",
        effects: [{ type: "pane-state", state: "waiting" }],
      },
      {
        event: { type: "session-deleted", sessionId: "child-a", kind: "delegated" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
      {
        event: {
          type: "permission-asked",
          requestId: "permission-root",
          sessionId: "root-a",
          kind: "root",
        },
        paneState: "waiting",
        effects: [{ type: "pane-state", state: "waiting" }],
      },
      {
        event: { type: "session-deleted", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
    ])
  })
})

describe("completion eligibility", () => {
  test("a root completion remains ineligible while a delegated session keeps the pane in background", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [{ type: "pane-state", state: "running" }],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy" },
        paneState: "running",
        effects: [{ type: "subagent-start", sessionId: "child-a" }],
      },
      {
        event: {
          type: "terminal-assistant-message",
          sessionId: "root-a",
          kind: "root",
          messageId: "message-a",
        },
        paneState: "running",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
    ])
  })

  test("only a terminal assistant message from the root whose completion makes the pane idle is eligible", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [{ type: "pane-state", state: "running" }],
      },
      {
        event: { type: "session-status", sessionId: "root-b", kind: "root", status: "busy" },
        paneState: "running",
        effects: [],
      },
      {
        event: {
          type: "terminal-assistant-message",
          sessionId: "root-a",
          kind: "root",
          messageId: "message-a",
        },
        paneState: "running",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "running",
        effects: [],
      },
      {
        event: {
          type: "terminal-assistant-message",
          sessionId: "child-a",
          kind: "delegated",
          messageId: "message-child",
        },
        paneState: "running",
        effects: [],
      },
      {
        event: {
          type: "terminal-assistant-message",
          sessionId: "root-b",
          kind: "root",
          messageId: "message-b",
        },
        paneState: "running",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "root-b", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "completion-eligible", sessionId: "root-b", messageId: "message-b" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-b", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [],
      },
    ])
  })

  test("opening, a missing terminal message, and permission-delayed idle do not qualify", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [{ type: "pane-state", state: "running" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "retry" },
        paneState: "running",
        effects: [{ type: "pane-state", state: "running" }],
      },
      {
        event: {
          type: "terminal-assistant-message",
          sessionId: "root-a",
          kind: "root",
          messageId: "message-a",
        },
        paneState: "running",
        effects: [],
      },
      {
        event: {
          type: "permission-asked",
          requestId: "permission-a",
          sessionId: "root-a",
          kind: "root",
        },
        paneState: "waiting",
        effects: [{ type: "pane-state", state: "waiting" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "waiting",
        effects: [],
      },
      {
        event: { type: "permission-replied", requestId: "permission-a" },
        paneState: "idle",
        effects: [{ type: "pane-state", state: "idle" }],
      },
    ])
  })
})
