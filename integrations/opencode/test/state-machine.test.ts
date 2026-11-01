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
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "retry" },
        paneState: "running",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
      },
    ])
  })

  test("a completed root assistant message ends a turn without a later idle status", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
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
          { type: "agent-state", agentId: "root-a", state: "idle" },
          { type: "completion-eligible", agentId: "root-a", sessionId: "root-a", messageId: "message-a" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "idle",
        effects: [],
      },
      {
        event: { type: "user-message", sessionId: "root-a", kind: "root", messageId: "user-a" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
      },
    ])
  })

  test("an explicit execution start begins a new turn after the previous completion", () => {
    run(createLifecycleState(), [
      {
        event: { type: "execution-started", sessionId: "root-a", kind: "root" },
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
        event: { type: "execution-started", sessionId: "root-a", kind: "root" },
        paneState: "running",
        effects: [{ type: "pane-state", state: "running" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [],
      },
    ])
  })

  test("trailing busy noise after a completion does not restart the root", () => {
    run(createLifecycleState(), [
      {
        event: { type: "execution-started", sessionId: "root-a", kind: "root" },
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
    ])
  })

  test("a duplicate user message update after idle does not restart the root", () => {
    const created = reduceLifecycle(createLifecycleState(), {
      type: "user-message",
      sessionId: "root-a",
      kind: "root",
      messageId: "user-a",
    })
    const busy = reduceLifecycle(created.state, {
      type: "session-status",
      sessionId: "root-a",
      kind: "root",
      status: "busy",
    })
    const idle = reduceLifecycle(busy.state, {
      type: "session-status",
      sessionId: "root-a",
      kind: "root",
      status: "idle",
    })
    const duplicate = reduceLifecycle(idle.state, {
      type: "user-message",
      sessionId: "root-a",
      kind: "root",
      messageId: "user-a",
    } as LifecycleEvent)

    expect(duplicate.state.paneState).toBe("idle")
    expect(duplicate.effects).toEqual([])
  })

  test("a root error clears when the session reports any status after resuming", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
      },
      {
        event: { type: "session-error", sessionId: "root-a", kind: "root", message: "failed" },
        paneState: "error",
        effects: [
          { type: "pane-state", state: "error" },
          { type: "agent-state", agentId: "root-a", state: "error" },
          { type: "agent-error", agentId: "root-a", message: "failed" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy", parentId: "root-a" },
        paneState: "error",
        effects: [{ type: "agent-subagent-start", agentId: "root-a", subagentId: "child-a" }],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "idle", parentId: "root-a" },
        paneState: "error",
        effects: [{ type: "agent-subagent-stop", agentId: "root-a", subagentId: "child-a" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "retry" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
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
    expect(resumed.effects).toEqual([
      { type: "pane-state", state: "running" },
      { type: "agent-state", agentId: "root-a", state: "running" },
    ])
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
    expect(recreated.effects).toEqual([
      { type: "pane-state", state: "idle" },
      { type: "agent-state", agentId: "root-a", state: "idle" },
    ])
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

describe("per-agent independence", () => {
  test("one root completing does not wait for another root", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-b", kind: "root", status: "busy" },
        paneState: "running",
        effects: [{ type: "agent-state", agentId: "root-b", state: "running" }],
      },
      {
        event: {
          type: "terminal-assistant-message",
          sessionId: "root-a",
          kind: "root",
          messageId: "message-a",
          finish: "stop",
        },
        // The pane stays running for root-b, but root-a still reports its own
        // idle and completion independently.
        paneState: "running",
        effects: [
          { type: "agent-state", agentId: "root-a", state: "idle" },
          { type: "completion-eligible", agentId: "root-a", sessionId: "root-a", messageId: "message-a" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-b", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-b", state: "idle" },
        ],
      },
    ])
  })

  test("a waiting root does not hide another root's activity", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
      },
      {
        event: { type: "permission-asked", requestId: "permission-a", sessionId: "root-a", kind: "root" },
        paneState: "waiting",
        effects: [
          { type: "pane-state", state: "waiting" },
          { type: "agent-state", agentId: "root-a", state: "waiting" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-b", kind: "root", status: "busy" },
        paneState: "waiting",
        effects: [{ type: "agent-state", agentId: "root-b", state: "running" }],
      },
      {
        event: { type: "permission-replied", requestId: "permission-a" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
      },
    ])
  })

  test("deleting a root unregisters only its agent", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-b", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-b", state: "running" },
        ],
      },
      {
        event: { type: "session-deleted", sessionId: "root-b", kind: "root" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-clear", agentId: "root-b" },
        ],
      },
    ])
  })
})

describe("pane aggregation", () => {
  test("several roots use error before running before idle, and deletion removes only its root", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-idle", kind: "root" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-idle", state: "idle" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-running", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-running", state: "running" },
        ],
      },
      {
        event: { type: "session-error", sessionId: "root-error", kind: "root" },
        paneState: "error",
        effects: [
          { type: "pane-state", state: "error" },
          { type: "agent-state", agentId: "root-error", state: "error" },
          { type: "agent-error", agentId: "root-error", message: undefined },
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
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-clear", agentId: "root-error" },
        ],
      },
      {
        event: { type: "session-deleted", sessionId: "root-running", kind: "root" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-clear", agentId: "root-running" },
        ],
      },
      {
        event: { type: "session-deleted", sessionId: "root-idle", kind: "root" },
        paneState: "idle",
        effects: [{ type: "agent-clear", agentId: "root-idle" }],
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
          { type: "agent-state", agentId: "root-a", state: "error" },
          { type: "agent-error", agentId: "root-a", message: "boom" },
        ],
      },
      {
        event: {
          type: "permission-asked",
          requestId: "permission-child",
          sessionId: "child-a",
          kind: "delegated",
          parentId: "root-a",
        },
        paneState: "waiting",
        effects: [
          { type: "pane-state", state: "waiting" },
          { type: "agent-state", agentId: "root-a", state: "waiting" },
        ],
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
        effects: [
          { type: "pane-state", state: "error" },
          { type: "agent-state", agentId: "root-a", state: "error" },
        ],
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
    expect(rootCreation.effects).toEqual([
      { type: "pane-state", state: "idle" },
      { type: "agent-state", agentId: "root-a", state: "idle" },
    ])
  })

  test("busy starts a subagent on the owning agent and idle, error, or deletion stops it", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
      },
      {
        event: { type: "session-created", sessionId: "child-a", kind: "delegated", parentId: "root-a" },
        paneState: "idle",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy", parentId: "root-a" },
        paneState: "idle",
        effects: [{ type: "agent-subagent-start", agentId: "root-a", subagentId: "child-a" }],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "retry", parentId: "root-a" },
        paneState: "idle",
        effects: [],
      },
      {
        event: { type: "session-error", sessionId: "child-a", kind: "delegated", message: "failed", parentId: "root-a" },
        paneState: "idle",
        effects: [{ type: "agent-subagent-stop", agentId: "root-a", subagentId: "child-a" }],
      },
      {
        event: { type: "session-error", sessionId: "child-a", kind: "delegated", parentId: "root-a" },
        paneState: "idle",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy", parentId: "root-a" },
        paneState: "idle",
        effects: [{ type: "agent-subagent-start", agentId: "root-a", subagentId: "child-a" }],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "idle", parentId: "root-a" },
        paneState: "idle",
        effects: [{ type: "agent-subagent-stop", agentId: "root-a", subagentId: "child-a" }],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "idle", parentId: "root-a" },
        paneState: "idle",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy", parentId: "root-a" },
        paneState: "idle",
        effects: [{ type: "agent-subagent-start", agentId: "root-a", subagentId: "child-a" }],
      },
      {
        event: { type: "session-deleted", sessionId: "child-a", kind: "delegated", parentId: "root-a" },
        paneState: "idle",
        effects: [{ type: "agent-subagent-stop", agentId: "root-a", subagentId: "child-a" }],
      },
    ])
  })

  test("delegated activity without a recoverable parent falls back to pane-level tracking", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
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
    ])
  })

  test("deleting a session removes its outstanding permission requests", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
      },
      {
        event: {
          type: "permission-asked",
          requestId: "permission-child",
          sessionId: "child-a",
          kind: "delegated",
          parentId: "root-a",
        },
        paneState: "waiting",
        effects: [
          { type: "pane-state", state: "waiting" },
          { type: "agent-state", agentId: "root-a", state: "waiting" },
        ],
      },
      {
        event: { type: "session-deleted", sessionId: "child-a", kind: "delegated", parentId: "root-a" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
      },
      {
        event: {
          type: "permission-asked",
          requestId: "permission-root",
          sessionId: "root-a",
          kind: "root",
        },
        paneState: "waiting",
        effects: [
          { type: "pane-state", state: "waiting" },
          { type: "agent-state", agentId: "root-a", state: "waiting" },
        ],
      },
      {
        event: { type: "session-deleted", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-clear", agentId: "root-a" },
        ],
      },
    ])
  })
})

describe("completion eligibility", () => {
  test("a root completion waits for its own subagents, not other roots'", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy", parentId: "root-a" },
        paneState: "running",
        effects: [{ type: "agent-subagent-start", agentId: "root-a", subagentId: "child-a" }],
      },
      {
        event: {
          type: "terminal-assistant-message",
          sessionId: "root-a",
          kind: "root",
          messageId: "message-a",
          finish: "stop",
        },
        // The message is stored, not completed: root-a's own subagent is
        // still running. Nothing publishes.
        paneState: "running",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "idle", parentId: "root-a" },
        paneState: "running",
        effects: [{ type: "agent-subagent-stop", agentId: "root-a", subagentId: "child-a" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
          { type: "completion-eligible", agentId: "root-a", sessionId: "root-a", messageId: "message-a" },
        ],
      },
    ])
  })

  test("a sibling root's busy subagent does not block completion", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "child-b", kind: "delegated", status: "busy", parentId: "root-b" },
        paneState: "running",
        effects: [
          { type: "agent-state", agentId: "root-b", state: "idle" },
          { type: "agent-subagent-start", agentId: "root-b", subagentId: "child-b" },
        ],
      },
      {
        event: {
          type: "terminal-assistant-message",
          sessionId: "root-a",
          kind: "root",
          messageId: "message-a",
          finish: "stop",
        },
        // child-b is rooted under root-b, so root-a is quiescent and still
        // completes. (The aggregate only knows root-a, which just went idle.)
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
          { type: "completion-eligible", agentId: "root-a", sessionId: "root-a", messageId: "message-a" },
        ],
      },
    ])
  })

  test("an unowned busy subagent blocks every root's completion", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "child-x", kind: "delegated", status: "busy" },
        paneState: "running",
        effects: [{ type: "subagent-start", sessionId: "child-x" }],
      },
      {
        event: {
          type: "terminal-assistant-message",
          sessionId: "root-a",
          kind: "root",
          messageId: "message-a",
          finish: "stop",
        },
        // child-x has no recoverable parent: it might belong to root-a,
        // so the message is stored without completing and nothing publishes.
        paneState: "running",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "child-x", kind: "delegated", status: "idle" },
        paneState: "running",
        effects: [{ type: "subagent-stop", sessionId: "child-x" }],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
          { type: "completion-eligible", agentId: "root-a", sessionId: "root-a", messageId: "message-a" },
        ],
      },
    ])
  })

  test("each root completes independently; delegated terminal messages never complete", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-b", kind: "root", status: "busy" },
        paneState: "running",
        effects: [{ type: "agent-state", agentId: "root-b", state: "running" }],
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
        effects: [
          { type: "agent-state", agentId: "root-a", state: "idle" },
          { type: "completion-eligible", agentId: "root-a", sessionId: "root-a", messageId: "message-a" },
        ],
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
          finish: "stop",
        },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-b", state: "idle" },
          { type: "completion-eligible", agentId: "root-b", sessionId: "root-b", messageId: "message-b" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
      },
    ])
  })

  test("opening, a missing terminal message, and permission-delayed idle do not qualify", () => {
    run(createLifecycleState(), [
      {
        event: { type: "session-created", sessionId: "root-a", kind: "root" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "retry" },
        paneState: "running",
        effects: [
          { type: "pane-state", state: "running" },
          { type: "agent-state", agentId: "root-a", state: "running" },
        ],
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
        effects: [
          { type: "pane-state", state: "waiting" },
          { type: "agent-state", agentId: "root-a", state: "waiting" },
        ],
      },
      {
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
        paneState: "waiting",
        effects: [],
      },
      {
        event: { type: "permission-replied", requestId: "permission-a" },
        paneState: "idle",
        effects: [
          { type: "pane-state", state: "idle" },
          { type: "agent-state", agentId: "root-a", state: "idle" },
        ],
      },
    ])
  })
})
