import { describe, expect, test } from "bun:test"

import {
  buildResyncEvents,
  isInstanceScope,
  kindFromParentId,
  raceSessionWait,
  statusFromServerType,
  unwrapKeyedMap,
} from "../resync"
import { FakeClock } from "./fake-clock"

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

describe("unwrapKeyedMap", () => {
  test("reads direct and wrapped maps", () => {
    expect(unwrapKeyedMap({ "root-a": { type: "busy" } })).toEqual({ "root-a": { type: "busy" } })
    expect(unwrapKeyedMap({ data: { "root-a": { type: "busy" } } })).toEqual({ "root-a": { type: "busy" } })
  })

  test("rejects arrays and unknown shapes instead of inventing keys", () => {
    expect(unwrapKeyedMap([{ type: "busy" }])).toEqual({})
    expect(unwrapKeyedMap(undefined)).toEqual({})
    expect(unwrapKeyedMap("busy")).toEqual({})
  })
})

describe("isInstanceScope", () => {
  test("everything is in scope without an instance directory", () => {
    expect(isInstanceScope("/elsewhere", undefined)).toBe(true)
    expect(isInstanceScope(undefined, undefined)).toBe(true)
  })

  test("unknown session directories stay lenient", () => {
    expect(isInstanceScope(undefined, "/workspace")).toBe(true)
  })

  test("known directories must match", () => {
    expect(isInstanceScope("/workspace", "/workspace")).toBe(true)
    expect(isInstanceScope("/elsewhere", "/workspace")).toBe(false)
  })
})

describe("raceSessionWait", () => {
  test("a fulfilled wait is idle without waiting for the deadline", async () => {
    const clock = new FakeClock()
    const raced = raceSessionWait(async () => undefined, 1000, clock)

    await expect(raced).resolves.toBe("idle")
  })

  test("a pending wait is busy once the deadline passes", async () => {
    const clock = new FakeClock()
    const raced = raceSessionWait(() => new Promise(() => {}), 1000, clock)

    const verdict = new Promise<string>((resolve) => {
      void raced.then((status) => resolve(status))
    })
    await clock.advance(999)
    await clock.advance(1)

    await expect(verdict).resolves.toBe("busy")
  })

  test("a rejected wait settles to idle presence", async () => {
    const clock = new FakeClock()
    const raced = raceSessionWait(async () => {
      throw new Error("session gone")
    }, 1000, clock)

    await expect(raced).resolves.toBe("idle")
  })
})
