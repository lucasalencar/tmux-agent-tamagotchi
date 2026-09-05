import { describe, expect, test } from "bun:test"

import { createEventAdapter } from "../adapter"

describe("OpenCode event adapter", () => {
  test("classifies session events from their parent metadata and cached session kind", async () => {
    const adapter = createEventAdapter({
      lookupSession: async () => {
        throw new Error("cached session metadata should avoid a lookup")
      },
    })

    await expect(adapter.adapt({
      type: "session.created",
      properties: { info: { id: "child-a", parentID: "root-a" } },
    })).resolves.toEqual({ type: "session-created", sessionId: "child-a", kind: "delegated" })
    await expect(adapter.adapt({
      type: "session.created",
      properties: { info: { id: "root-a", parentID: undefined } },
    })).resolves.toEqual({ type: "session-created", sessionId: "root-a", kind: "root" })
    await expect(adapter.adapt({
      type: "session.status",
      properties: { sessionID: "child-a", status: { type: "busy" } },
    })).resolves.toEqual({
      type: "session-status",
      sessionId: "child-a",
      kind: "delegated",
      status: "busy",
    })
  })

  test("normalizes documented and stale SDK permission events by request id", async () => {
    const adapter = createEventAdapter({
      lookupSession: async (sessionId) => sessionId === "root-a" ? { id: "root-a" } : undefined,
    })

    await expect(adapter.adapt({
      type: "permission.asked",
      properties: { id: "request-a", sessionID: "root-a" },
    })).resolves.toEqual({
      type: "permission-asked",
      requestId: "request-a",
      sessionId: "root-a",
      kind: "root",
    })
    await expect(adapter.adapt({
      type: "permission.updated",
      properties: { id: "request-b", sessionID: "root-a" },
    })).resolves.toEqual({
      type: "permission-asked",
      requestId: "request-b",
      sessionId: "root-a",
      kind: "root",
    })
    await expect(adapter.adapt({
      type: "permission.replied",
      properties: { requestID: "request-a", sessionID: "root-a", reply: "once" },
    })).resolves.toEqual({ type: "permission-replied", requestId: "request-a" })
    await expect(adapter.adapt({
      type: "permission.replied",
      properties: { permissionID: "request-b", sessionID: "root-a", response: "once" },
    })).resolves.toEqual({ type: "permission-replied", requestId: "request-b" })
  })

  test("translates attributed errors and only terminal non-summary assistant messages", async () => {
    const adapter = createEventAdapter({
      lookupSession: async (sessionId) => sessionId === "root-a" ? { id: "root-a" } : undefined,
    })

    await expect(adapter.adapt({
      type: "session.error",
      properties: { sessionID: "root-a", error: { data: { message: "provider failed" } } },
    })).resolves.toEqual({
      type: "session-error",
      sessionId: "root-a",
      kind: "root",
      message: "provider failed",
    })
    await expect(adapter.adapt({
      type: "session.error",
      properties: { error: { data: { message: "unattributed" } } },
    })).resolves.toBeUndefined()
    await expect(adapter.adapt({
      type: "message.updated",
      properties: {
        info: {
          id: "message-a",
          sessionID: "root-a",
          role: "assistant",
          time: { created: 1, completed: 2 },
          finish: "stop",
        },
      },
    })).resolves.toEqual({
      type: "terminal-assistant-message",
      sessionId: "root-a",
      kind: "root",
      messageId: "message-a",
      finish: "stop",
    })
    await expect(adapter.adapt({
      type: "message.updated",
      properties: {
        info: {
          id: "summary-a",
          sessionID: "root-a",
          role: "assistant",
          summary: true,
          time: { created: 1, completed: 2 },
        },
      },
    })).resolves.toBeUndefined()
  })

  test("normalizes the standalone session idle event", async () => {
    const adapter = createEventAdapter({
      lookupSession: async () => ({ id: "root-a" }),
    })

    await expect(adapter.adapt({
      type: "session.idle",
      properties: { sessionID: "root-a" },
    })).resolves.toEqual({
      type: "session-status",
      sessionId: "root-a",
      kind: "root",
      status: "idle",
    })
  })

  test("ignores unavailable or invalid session metadata and invalidates a deleted session", async () => {
    const sessions = new Map<string, { id: string; parentID?: string }>([
      ["child-a", { id: "child-a", parentID: "root-a" }],
      ["invalid-child", { id: "invalid-child", parentID: "" }],
    ])
    const adapter = createEventAdapter({
      lookupSession: async (sessionId) => sessions.get(sessionId),
    })

    await expect(adapter.adapt(statusEvent("unknown-child"))).resolves.toBeUndefined()
    await expect(adapter.adapt(statusEvent("invalid-child"))).resolves.toBeUndefined()
    await expect(adapter.adapt(statusEvent("child-a"))).resolves.toMatchObject({ kind: "delegated" })

    await expect(adapter.adapt({
      type: "session.deleted",
      properties: { info: { id: "child-a", parentID: "root-a" } },
    })).resolves.toEqual({ type: "session-deleted", sessionId: "child-a", kind: "delegated" })
    sessions.delete("child-a")
    await expect(adapter.adapt(statusEvent("child-a"))).resolves.toBeUndefined()
  })
})

function statusEvent(sessionID: string) {
  return { type: "session.status", properties: { sessionID, status: { type: "busy" } } }
}
