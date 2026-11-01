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
      event: { type: "execution-started", sessionId: "root-a", kind: "root" },
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

  test("ignores location-less events for sessions outside the instance directory", async () => {
    let lookups = 0
    const adapter = createEventAdapterV2({
      directory: "/workspace",
      lookupSession: async (sessionId) => {
        lookups += 1
        return sessionId === "root-foreign"
          ? { id: sessionId, directory: "/elsewhere" }
          : { id: sessionId, directory: "/workspace" }
      },
    })

    expect(await adapter.adapt({
      type: "session.execution.started",
      data: { sessionID: "root-foreign" },
    })).toEqual({ status: "unknown" })
    expect(await adapter.adapt({
      type: "session.execution.succeeded",
      data: { sessionID: "root-foreign" },
    })).toEqual({ status: "unknown" })
    expect(await adapter.adapt({
      type: "session.execution.failed",
      data: { sessionID: "root-foreign", error: { message: "boom" } },
    })).toEqual({ status: "unknown" })
    expect(await adapter.adapt({
      type: "session.created",
      data: { sessionID: "root-foreign" },
    })).toEqual({ status: "unknown" })
    expect(await adapter.adapt({
      type: "session.execution.started",
      data: { sessionID: "root-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "execution-started", sessionId: "root-a", kind: "root" },
    })
    expect(lookups).toBeGreaterThan(0)
  })

  test("keeps attributing every session without an instance directory", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId, directory: "/elsewhere" }),
    })

    expect(await adapter.adapt({
      type: "session.execution.started",
      data: { sessionID: "root-foreign" },
    })).toEqual({
      status: "adapted",
      event: { type: "execution-started", sessionId: "root-foreign", kind: "root" },
    })
  })

  test("stays lenient when the session location cannot be recovered", async () => {
    const adapter = createEventAdapterV2({
      directory: "/workspace",
      lookupSession: async (sessionId) => ({ id: sessionId }),
    })

    expect(await adapter.adapt({
      type: "session.execution.started",
      data: { sessionID: "root-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "execution-started", sessionId: "root-a", kind: "root" },
    })
  })

  test("falls back to plain idle without a terminal assistant message", async () => {
    for (const latest of [
      undefined,
      { id: "message-a", sessionID: "root-a", role: "user", time: { completed: 2 } },
      { id: "message-a", sessionID: "root-a", role: "assistant", time: { created: 1 } },
      {
        id: "message-a",
        sessionID: "root-a",
        role: "assistant",
        time: { completed: 2 },
        summary: true,
      },
      { id: "message-a", sessionID: "other", role: "assistant", time: { completed: 2 } },
    ]) {
      const adapter = createEventAdapterV2({
        lookupSession: async (sessionId) => ({ id: sessionId }),
        lookupLatestMessage: async () => latest,
      })
      expect(await adapter.adapt({ type: "session.idle", data: { sessionID: "root-a" } })).toEqual({
        status: "adapted",
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
      })
    }
  })

  test("maps step started onto running without clearing on step end", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
    })

    // A step starting means the turn is active even when the execution
    // start was missed (late subscribe, service restart gap). Step endings
    // must not idle the pane: further steps may follow in the same turn.
    expect(await adapter.adapt({
      type: "session.step.started",
      data: { sessionID: "root-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
    })
    expect(await adapter.adapt({
      type: "session.step.ended",
      data: { sessionID: "root-a" },
    })).toEqual({ status: "unknown" })
    expect(await adapter.adapt({ type: "session.step.started", data: {} })).toEqual({
      status: "malformed",
    })
  })

  test("maps tool and text activity onto running while endings stay unknown", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
    })

    // Mid-step subscribes may first see a tool call or text delta instead of
    // the step start: any activity means busy. Endings never idle the pane.
    for (const type of [
      "session.tool.called",
      "session.tool.input.started",
      "session.tool.input.delta",
      "session.tool.progress",
      "session.text.started",
      "session.text.delta",
      "session.reasoning.started",
      "session.step.streamed",
    ]) {
      expect(await adapter.adapt({ type, data: { sessionID: "root-a" } })).toEqual({
        status: "adapted",
        event: { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
      })
    }
    for (const type of [
      "session.tool.success",
      "session.tool.failed",
      "session.text.ended",
      "session.reasoning.ended",
      "session.step.ended",
      "session.step.failed",
    ]) {
      expect(await adapter.adapt({ type, data: { sessionID: "root-a" } })).toEqual({
        status: "unknown",
      })
    }
  })

  test("tracks delegated step activity as subagent work with 2.2.5 locations", async () => {
    const adapter = createEventAdapterV2({
      directory: "/workspace",
      lookupSession: async (sessionId) => ({
        id: sessionId,
        parentID: "root-a",
        location: { directory: "/workspace" },
      }),
    })

    // 2.2.5 nests the directory under location and always includes parentID
    // for delegated sessions. Activity must start subagent tracking so the
    // core can derive background instead of leaving the pane idle.
    expect(await adapter.adapt({
      type: "session.step.started",
      data: { sessionID: "child-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy", parentId: "root-a" },
    })
    expect(await adapter.adapt({
      type: "session.tool.called",
      data: { sessionID: "child-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy", parentId: "root-a" },
    })
  })

  test("accepts full 2.2.5 step payloads with extra fields", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
    })

    // Captured from the live 2.2.5 server: extra step fields and the
    // top-level location must be ignored beyond attribution.
    expect(await adapter.adapt({
      type: "session.step.started",
      location: { directory: "/workspace" },
      data: {
        sessionID: "root-a",
        assistantMessageID: "msg_123",
        agent: "build",
        model: { providerID: "opencode-go", modelID: "muse-spark" },
        started: 1793494602,
      },
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
  })

  test("reports plain idle when the message lookup fails or the session is delegated", async () => {
    const throwing = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
      lookupLatestMessage: async () => {
        throw new Error("client unavailable")
      },
    })
    expect(await throwing.adapt({ type: "session.idle", data: { sessionID: "root-a" } })).toEqual({
      status: "adapted",
      event: { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
    })

    const delegated = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId, parentID: "root-a" }),
      lookupLatestMessage: async () => ({
        id: "message-a",
        sessionID: "child-a",
        role: "assistant",
        time: { completed: 2 },
        finish: "stop",
      }),
    })
    expect(await delegated.adapt({ type: "session.idle", data: { sessionID: "child-a" } })).toEqual({
      status: "adapted",
      event: { type: "session-status", sessionId: "child-a", kind: "delegated", status: "idle", parentId: "root-a" },
    })
  })

  test("maps retry onto running and failure without a message onto plain error", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async (sessionId) => ({ id: sessionId }),
    })

    expect(await adapter.adapt({
      type: "session.status",
      data: { sessionID: "root-a", status: { type: "retry" } },
    })).toEqual({
      status: "adapted",
      event: { type: "session-status", sessionId: "root-a", kind: "root", status: "retry" },
    })
    expect(await adapter.adapt({
      type: "session.execution.failed",
      data: { sessionID: "root-a", error: { type: "boom" } },
    })).toEqual({
      status: "adapted",
      event: { type: "session-error", sessionId: "root-a", kind: "root" },
    })
    expect(await adapter.adapt({
      type: "session.execution.failed",
      data: { sessionID: "root-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "session-error", sessionId: "root-a", kind: "root" },
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

  test("attributes delegated permission, failure, and deletion to the inline parent", async () => {
    const adapter = createEventAdapterV2({
      lookupSession: async () => {
        throw new Error("inline parent IDs need no lookup")
      },
    })

    await adapter.adapt({ type: "session.created", data: { sessionID: "child-a", parentID: "root-a" } })
    expect(await adapter.adapt({
      type: "permission.asked",
      data: { id: "request-a", sessionID: "child-a" },
    })).toEqual({
      status: "adapted",
      event: {
        type: "permission-asked",
        requestId: "request-a",
        sessionId: "child-a",
        kind: "delegated",
        parentId: "root-a",
      },
    })
    expect(await adapter.adapt({
      type: "session.execution.failed",
      data: { sessionID: "child-a", error: { message: "delegated blew up" } },
    })).toEqual({
      status: "adapted",
      event: {
        type: "session-error",
        sessionId: "child-a",
        kind: "delegated",
        message: "delegated blew up",
        parentId: "root-a",
      },
    })
    expect(await adapter.adapt({
      type: "session.deleted",
      data: { sessionID: "child-a" },
    })).toEqual({
      status: "adapted",
      event: { type: "session-deleted", sessionId: "child-a", kind: "delegated", parentId: "root-a" },
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
