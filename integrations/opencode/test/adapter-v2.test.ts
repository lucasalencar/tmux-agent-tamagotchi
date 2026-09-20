import { describe, expect, test } from "bun:test"

import { createEventAdapterV2 } from "../adapter-v2"

describe("v2 flat events", () => {
  test("classifies session.created from the inline parentID without a lookup", async () => {
    let lookups = 0
    const adapter = createEventAdapterV2({
      lookupSession: async () => {
        lookups += 1
        return undefined
      },
    })

    expect(await adapter.adapt({ type: "session.created", data: { sessionID: "root-a" } })).toEqual({
      status: "adapted",
      event: { type: "session-created", sessionId: "root-a", kind: "root" },
    })
    expect(await adapter.adapt({
      type: "session.created",
      data: { sessionID: "child-a", parentID: "root-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "session-created", sessionId: "child-a", kind: "delegated" },
    })
    expect(lookups).toBe(0)
  })

  test("treats a created event without parentID as a root session", async () => {
    let lookups = 0
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => {
        lookups += 1
        return sessionId === "child-a" ? { id: "child-a", parentID: "root-a" } : { id: sessionId }
      },
    })

    expect(await adapter.adapt({ type: "session.created", data: {} })).toEqual({ status: "malformed" })
    expect(await adapter.adapt({ type: "session.created", data: { sessionID: "root-a" } })).toEqual({
      status: "adapted",
      event: { type: "session-created", sessionId: "root-a", kind: "root" },
    })
    expect(await adapter.adapt({
      type: "session.created",
      data: { sessionID: "child-a", parentID: 42 },
    })).toEqual({
      status: "adapted",
      event: { type: "session-created", sessionId: "child-a", kind: "delegated" },
    })
    expect(lookups).toBe(1)
  })

  test("evicts the classification on session.deleted", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => {
        throw new Error(`gone: ${sessionId}`)
      },
    })
    await adapter.adapt({ type: "session.created", data: { sessionID: "root-a" } })

    expect(await adapter.adapt({ type: "session.deleted", data: { sessionID: "root-a" } })).toEqual({
      status: "adapted",
      event: { type: "session-deleted", sessionId: "root-a", kind: "root" },
    })
    expect(await adapter.adapt({ type: "session.deleted", data: { sessionID: "never-seen" } })).toEqual({
      status: "malformed",
    })
  })

  test("maps session.status values and keeps unknown ones out of the lifecycle", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
    })

    expect(await adapter.adapt({
      type: "session.status",
      data: { sessionID: "root-a", status: { type: "busy" } },
    })).toEqual({
      status: "adapted",
      event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
    })
    expect(await adapter.adapt({
      type: "session.status",
      data: { sessionID: "root-a", status: { type: "migrating" } },
    })).toEqual({ status: "unknown" })
    expect(await adapter.adapt({ type: "session.status", data: { sessionID: "root-a" } })).toEqual({
      status: "unknown",
    })
  })

  test("reports a terminal assistant message on session.idle for a root session", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
      lookupLatestMessage: async () => ({
        id: "message-a",
        sessionID: "root-a",
        role: "assistant",
        time: { completed: 2 },
        finish: "stop",
      }),
    })

    expect(await adapter.adapt({ type: "session.idle", data: { sessionID: "root-a" } })).toEqual({
      status: "adapted",
      event: {
        type: "terminal-assistant-message",
        sessionId: "root-a",
        kind: "root",
        messageId: "message-a",
        finish: "stop",
      },
    })
  })

  test("maps execution started, succeeded, and interrupted onto the running and idle states", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
    })

    expect(await adapter.adapt({
      type: "session.execution.started",
      data: { sessionID: "root-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
    })
    expect(await adapter.adapt({
      type: "session.execution.succeeded",
      data: { sessionID: "root-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
    })
    expect(await adapter.adapt({
      type: "session.execution.interrupted",
      data: { sessionID: "root-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
    })
    expect(await adapter.adapt({ type: "session.execution.started", data: {} })).toEqual({
      status: "malformed",
    })
  })

  test("reports a terminal assistant message on execution succeeded for a root session", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
      lookupLatestMessage: async () => ({
        id: "message-a",
        sessionID: "root-a",
        role: "assistant",
        time: { completed: 2 },
        finish: "stop",
      }),
    })

    expect(await adapter.adapt({
      type: "session.execution.succeeded",
      data: { sessionID: "root-a" },
    })).toEqual({
      status: "adapted",
      event: {
        type: "terminal-assistant-message",
        sessionId: "root-a",
        kind: "root",
        messageId: "message-a",
        finish: "stop",
      },
    })
  })

  test("adapts permission and failure events", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
    })

    expect(await adapter.adapt({
      type: "permission.asked",
      data: { id: "request-a", sessionID: "root-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "permission-asked", requestId: "request-a", sessionId: "root-a", kind: "root" },
    })
    expect(await adapter.adapt({
      type: "permission.replied",
      data: { sessionID: "root-a", requestID: "request-a", reply: "once" },
    })).toEqual({ status: "adapted", event: { type: "permission-replied", requestId: "request-a" } })
    expect(await adapter.adapt({
      type: "session.execution.failed",
      data: { sessionID: "root-a", error: { type: "boom", message: "Blew up." } },
    })).toEqual({
      status: "adapted",
      event: { type: "session-error", sessionId: "root-a", kind: "root", message: "Blew up." },
    })
  })

  test("rejects non-envelopes and ignores unrelated event types", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
    })

    expect(await adapter.adapt(undefined)).toEqual({ status: "malformed" })
    expect(await adapter.adapt({ type: "session.created" })).toEqual({ status: "malformed" })
    expect(await adapter.adapt({ type: "command.updated", data: {} })).toEqual({ status: "unknown" })
  })

  test("carries the event directory for pane attribution", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
    })

    expect(await adapter.adapt({
      type: "session.status",
      location: { directory: "/workspace" },
      data: { sessionID: "root-a", status: { type: "busy" } },
    })).toEqual({
      status: "adapted",
      event: {
        type: "session-status",
        sessionId: "root-a",
        kind: "root",
        status: "busy",
        directory: "/workspace",
      },
    })
    expect(await adapter.adapt({
      type: "session.created",
      data: { sessionID: "root-b", location: { directory: "/other" } },
    })).toEqual({
      status: "adapted",
      event: { type: "session-created", sessionId: "root-b", kind: "root", directory: "/other" },
    })
  })
})
