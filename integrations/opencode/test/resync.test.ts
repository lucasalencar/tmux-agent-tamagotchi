import { describe, expect, test } from "bun:test"

import {
  buildResyncEvents,
  kindFromParentId,
  statusFromServerType,
} from "../resync"

describe("buildResyncEvents", () => {
  test("seeds created before status for every session", () => {
    expect(buildResyncEvents([
      { sessionId: "root-a", kind: "root", status: "busy" },
      { sessionId: "child-a", kind: "delegated", status: "busy" },
    ])).toEqual([
      { type: "session-created", sessionId: "root-a", kind: "root" },
      { type: "session-status", sessionId: "root-a", kind: "root", status: "busy" },
      { type: "session-created", sessionId: "child-a", kind: "delegated" },
      { type: "session-status", sessionId: "child-a", kind: "delegated", status: "busy" },
    ])
  })

  test("carries directory provenance and appends permissions last", () => {
    expect(buildResyncEvents(
      [{ sessionId: "root-a", kind: "root", status: "idle", directory: "/workspace" }],
      [{ requestId: "request-a", sessionId: "root-a", kind: "root", directory: "/workspace" }],
    )).toEqual([
      { type: "session-created", sessionId: "root-a", kind: "root", directory: "/workspace" },
      { type: "session-status", sessionId: "root-a", kind: "root", status: "idle", directory: "/workspace" },
      { type: "permission-asked", requestId: "request-a", sessionId: "root-a", kind: "root", directory: "/workspace" },
    ])
  })

  test("drops sessions and permissions without identities", () => {
    expect(buildResyncEvents(
      [
        { sessionId: "", kind: "root", status: "idle" },
        { sessionId: "root-a", kind: "root", status: "idle" },
      ],
      [
        { requestId: "", sessionId: "root-a", kind: "root" },
        { requestId: "request-a", sessionId: "", kind: "root" },
      ],
    )).toEqual([
      { type: "session-created", sessionId: "root-a", kind: "root" },
      { type: "session-status", sessionId: "root-a", kind: "root", status: "idle" },
    ])
  })

  test("empty snapshots seed nothing", () => {
    expect(buildResyncEvents([])).toEqual([])
  })
})

describe("kindFromParentId", () => {
  test("absent parent is a root", () => {
    expect(kindFromParentId(undefined)).toBe("root")
  })

  test("non-empty parent is delegated", () => {
    expect(kindFromParentId("root-a")).toBe("delegated")
  })

  test("empty or non-string parents are unattributed", () => {
    expect(kindFromParentId("")).toBeUndefined()
    expect(kindFromParentId(null)).toBeUndefined()
    expect(kindFromParentId(42)).toBeUndefined()
  })
})

describe("statusFromServerType", () => {
  test("busy and retry stay distinct", () => {
    expect(statusFromServerType("busy")).toBe("busy")
    expect(statusFromServerType("retry")).toBe("retry")
  })

  test("unknown and missing types settle to idle presence", () => {
    expect(statusFromServerType("idle")).toBe("idle")
    expect(statusFromServerType("unknown")).toBe("idle")
    expect(statusFromServerType(undefined)).toBe("idle")
  })
})
