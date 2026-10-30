import { describe, expect, test } from "bun:test"

import { createTmuxAgentTamagotchiPluginV2, type PluginContextV2 } from "../plugin-v2"
import { FakeClock } from "./fake-clock"

const DIRECTORY = "/workspace"
const PANE = "%pane-a"

describe("v2 setup", () => {
  test("reports running then idle over the event subscription using the v2 client", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({ execute: fakeExecute(commandCalls) })
    const events: unknown[] = [
      { type: "session.created", data: { sessionID: "root-a" } },
      { type: "session.status", data: { sessionID: "root-a", status: { type: "busy" } } },
      { type: "session.idle", data: { sessionID: "root-a" } },
    ]
    const cleanup = await setup(fakeContextV2(events, { "root-a": {} }, {}))
    await settle()

    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
    ])
    await cleanup()
    expect(tamaCalls(commandCalls).at(-1)).toEqual([
      "/plugin/bin/tama", "state", "clear", "--pane", PANE,
    ])
  })

  test("reports running then idle from execution events without status transitions", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({ execute: fakeExecute(commandCalls) })
    const events: unknown[] = [
      { type: "session.created", data: { sessionID: "root-a" } },
      { type: "session.execution.started", data: { sessionID: "root-a" } },
      { type: "session.execution.succeeded", data: { sessionID: "root-a" } },
    ]
    const cleanup = await setup(fakeContextV2(events, { "root-a": {} }, {}))
    await settle()

    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
    ])
    await cleanup()
  })

  test("ignores location-less events for sessions outside the instance directory", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({ execute: fakeExecute(commandCalls) })
    const events: unknown[] = [
      { type: "session.created", data: { sessionID: "root-a" } },
      { type: "session.execution.started", data: { sessionID: "root-foreign" } },
      { type: "session.execution.failed", data: { sessionID: "root-foreign", error: { message: "boom" } } },
      { type: "session.execution.started", data: { sessionID: "root-a" } },
    ]
    const cleanup = await setup(fakeContextV2(
      events,
      { "root-a": {}, "root-foreign": { location: { directory: "/elsewhere" } } },
      {},
    ))
    await settle()

    // Only the local session reaches tama; the foreign turn and its failure
    // never touch this instance's pane.
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
    ])
    await cleanup()
  })

  test("notifies completion text looked up over the v2 client after five idle seconds", async () => {
    const clock = new FakeClock()
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({
      clock,
      execute: fakeExecute(commandCalls),
    })
    const assistant = {
      id: "message-a",
      type: "assistant",
      time: { created: 1, completed: 2 },
      finish: "stop",
      content: [{ type: "text", text: "Delivered over v2." }],
    }
    const events: unknown[] = [
      { type: "session.created", data: { sessionID: "root-a" } },
      { type: "session.status", data: { sessionID: "root-a", status: { type: "busy" } } },
      { type: "session.idle", data: { sessionID: "root-a" } },
    ]
    const cleanup = await setup(fakeContextV2(events, { "root-a": {} }, { "root-a": [assistant] }))
    await settle()

    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
    ])
    await clock.advance(4_999)
    expect(tamaCalls(commandCalls)).toHaveLength(3)
    await clock.advance(1)

    expect(tamaCalls(commandCalls)).toContainEqual([
      "/plugin/bin/tama", "notify", "--pane", PANE, "--", "OpenCode", "Delivered over v2.",
    ])
    await cleanup()
  })

  test("notifies completion for execution-driven turns after five idle seconds", async () => {
    const clock = new FakeClock()
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({
      clock,
      execute: fakeExecute(commandCalls),
    })
    const assistant = {
      id: "message-a",
      type: "assistant",
      time: { created: 1, completed: 2 },
      finish: "stop",
      content: [{ type: "text", text: "Executed over v2." }],
    }
    const events: unknown[] = [
      { type: "session.created", data: { sessionID: "root-a" } },
      { type: "session.execution.started", data: { sessionID: "root-a" } },
      { type: "session.execution.succeeded", data: { sessionID: "root-a" } },
    ]
    const cleanup = await setup(fakeContextV2(events, { "root-a": {} }, { "root-a": [assistant] }))
    await settle()

    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
    ])
    await clock.advance(5_000)

    expect(tamaCalls(commandCalls)).toContainEqual([
      "/plugin/bin/tama", "notify", "--pane", PANE, "--", "OpenCode", "Executed over v2.",
    ])
    await cleanup()
  })

  test("skips pane resolution failures without breaking later effects", async () => {
    const commandCalls: string[][] = []
    let listCalls = 0
    const setup = createTmuxAgentTamagotchiPluginV2({
      execute: async (argv) => {
        commandCalls.push([...argv])
        if (argv.includes("list-panes")) {
          listCalls += 1
          if (listCalls === 1) return { exitCode: 1, stdout: "" }
          return { exitCode: 0, stdout: `${PANE}\topencode\t${DIRECTORY}\n` }
        }
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
    })
    const events: unknown[] = [
      { type: "session.created", data: { sessionID: "root-a" } },
      { type: "session.execution.started", data: { sessionID: "root-a" } },
    ]
    const cleanup = await setup(fakeContextV2(events, { "root-a": {} }, {}))
    await settle()

    // The first resolution fails, so the idle write is skipped; the second
    // succeeds and the running write carries the pane.
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
    ])
    await cleanup()
  })

  test("survives client lookup failures without dropping later lifecycle", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({ execute: fakeExecute(commandCalls) })
    const events: unknown[] = [
      { type: "session.execution.started", data: { sessionID: "root-a" } },
      { type: "session.execution.succeeded", data: { sessionID: "root-a" } },
    ]
    const context = fakeContextV2(events, { "root-a": {} }, {})
    const throwing = {
      ...context,
      session: {
        get: async () => {
          throw new Error("service unavailable")
        },
        context: async () => {
          throw new Error("service unavailable")
        },
      },
    }
    const cleanup = await setup(throwing)
    await settle()

    // Classification lookups fail with no cached classification to fall back
    // on, so both events are skipped and nothing rejects into the host.
    expect(tamaCalls(commandCalls)).toEqual([])
    await cleanup()
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "clear", "--pane", PANE],
    ])
  })

  test("tracks delegated sessions from the inline parentID and cancels the pending completion", async () => {
    const clock = new FakeClock()
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({
      clock,
      execute: fakeExecute(commandCalls),
    })
    const assistant = {
      id: "message-a",
      type: "assistant",
      time: { created: 1, completed: 2 },
      finish: "stop",
      content: [{ type: "text", text: "Root finished." }],
    }
    const events: unknown[] = [
      { type: "session.created", data: { sessionID: "root-a" } },
      { type: "session.status", data: { sessionID: "root-a", status: { type: "busy" } } },
      { type: "session.idle", data: { sessionID: "root-a" } },
      { type: "session.created", data: { sessionID: "child-a", parentID: "root-a" } },
      { type: "session.status", data: { sessionID: "child-a", status: { type: "busy" } } },
      { type: "session.status", data: { sessionID: "child-a", status: { type: "idle" } } },
    ]
    const cleanup = await setup(fakeContextV2(
      events,
      { "root-a": {}, "child-a": { parentID: "root-a" } },
      { "root-a": [assistant] },
    ))
    await settle()
    await clock.advance(5_000)

    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "subagent-start", "--pane", PANE, "--", "child-a"],
      ["/plugin/bin/tama", "state", "subagent-stop", "--pane", PANE, "--", "child-a"],
    ])
    await cleanup()
  })

  test("raises waiting on permission.asked and an error notification on failure", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({ execute: fakeExecute(commandCalls) })
    const events: unknown[] = [
      { type: "session.created", data: { sessionID: "root-a" } },
      {
        type: "permission.asked",
        data: { id: "request-a", sessionID: "root-a", action: "bash", resources: [] },
      },
      {
        type: "permission.replied",
        data: { sessionID: "root-a", requestID: "request-a", reply: "once" },
      },
      {
        type: "session.execution.failed",
        data: { sessionID: "root-a", error: { type: "boom", message: "Blew up." } },
      },
    ]
    const cleanup = await setup(fakeContextV2(events, { "root-a": {} }, {}))
    await settle()

    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "waiting", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "error", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "notify", "--pane", PANE, "--", "OpenCode", "Blew up."],
    ])
    await cleanup()
  })

  test("ignores events from other directories and reports nothing without a pane", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({
      execute: async (argv) => {
        commandCalls.push([...argv])
        if (argv.includes("list-panes")) return { exitCode: 0, stdout: "" }
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
    })
    const events: unknown[] = [
      {
        type: "session.created",
        location: { directory: "/elsewhere" },
        data: { sessionID: "root-foreign" },
      },
      {
        type: "session.status",
        location: { directory: "/elsewhere" },
        data: { sessionID: "root-foreign", status: { type: "busy" } },
      },
      { type: "session.created", data: { sessionID: "root-a" } },
      { type: "session.status", data: { sessionID: "root-a", status: { type: "busy" } } },
    ]
    const cleanup = await setup(fakeContextV2(events, { "root-a": {} }, {}))
    await settle()

    // The foreign session never reaches the lifecycle; the local one resolves
    // no pane, so its states are skipped instead of leaking onto the
    // process pane, and disposal clears nothing.
    expect(tamaCalls(commandCalls)).toEqual([])
    await cleanup()
    expect(tamaCalls(commandCalls)).toEqual([])
  })

  test("resyncs running sessions from the list/active snapshot before live events", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({ execute: fakeExecute(commandCalls) })
    const events: unknown[] = [
      { type: "session.idle", data: { sessionID: "root-a" } },
    ]
    const cleanup = await setup(fakeContextV2(events, { "root-a": {} }, {}, {
      list: [{ id: "root-a" }],
      // A busy vocabulary entry counts as running work, like "running" does.
      active: { "root-a": { type: "busy" } },
    }))
    await settle()

    // Presence, then activity from the snapshot, then the live idle lands last.
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
    ])
    await cleanup()
  })

  test("resyncs idle presence without active and follows paginated lists", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({ execute: fakeExecute(commandCalls) })
    const cleanup = await setup(fakeContextV2(
      [],
      // root-b is deliberately absent here so only the second list page can
      // provide it: the active-only lookup cannot resolve it either.
      { "root-a": {} },
      {},
      {
        listPages: [[{ id: "root-a" }], [{ id: "root-b" }]],
        active: { "root-b": { type: "running" } },
      },
    ))
    await settle()

    // The second page is read (its running root lights the pane); a dropped
    // cursor would leave only the first page's idle behind.
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
    ])
    await cleanup()
  })

  test("resyncs active sessions the list omits via lookup", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({ execute: fakeExecute(commandCalls) })
    const cleanup = await setup(fakeContextV2(
      [],
      { "root-a": {}, "child-b": { parentID: "root-a" } },
      {},
      {
        list: [{ id: "root-a" }],
        active: { "child-b": { type: "running" } },
      },
    ))
    await settle()

    // child-b never appears in the top-level list, yet its delegated work is
    // tracked from the active set.
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "subagent-start", "--pane", PANE, "--", "child-b"],
    ])
    await cleanup()
  })

  test("resync ignores foreign sessions and restores waiting from permissions", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({ execute: fakeExecute(commandCalls) })
    const cleanup = await setup(fakeContextV2(
      [],
      {
        "root-a": {},
        "root-foreign": { location: { directory: "/elsewhere" } },
        "child-foreign": { parentID: "root-foreign", location: { directory: "/elsewhere" } },
        "ghost-foreign": { parentID: "root-foreign", location: { directory: "/elsewhere" } },
      },
      {},
      {
        list: [
          { id: "root-a" },
          { id: "root-foreign", location: { directory: "/elsewhere" } },
          { id: "child-foreign", parentID: "root-foreign", location: { directory: "/elsewhere" } },
        ],
        active: {
          "root-a": { type: "running" },
          "root-foreign": { type: "running" },
          "child-foreign": { type: "running" },
          "ghost-foreign": { type: "running" },
        },
        permissions: { "root-a": ["request-a"] },
      },
    ))
    await settle()

    // Only the local session reaches tama; its pending permission overlays
    // waiting above the resynced running state. The foreign delegated work
    // (listed and active-only alike) must not start subagent tracking.
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "waiting", "OpenCode", "--pane", PANE],
    ])
    await cleanup()
  })

  test("setup without list/active on old hosts publishes nothing by itself", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({ execute: fakeExecute(commandCalls) })
    const cleanup = await setup(fakeContextV2([], {}, {}))
    await settle()

    expect(tamaCalls(commandCalls)).toEqual([])
    await cleanup()
  })

  test("derives running from the wait race when active is absent", async () => {
    const commandCalls: string[][] = []
    const setup = createTmuxAgentTamagotchiPluginV2({
      execute: fakeExecute(commandCalls),
      resyncWaitMs: 20,
    })
    const cleanup = await setup(fakeContextV2([], { "root-a": {}, "root-b": {} }, {}, {
      list: [{ id: "root-a" }, { id: "root-b" }],
      waits: { "root-a": "running", "root-b": "idle" },
    }))
    await settle()

    // root-a pends past the deadline (busy) while root-b resolves at once.
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
    ])
    await cleanup()
  })

  test("buffers live events emitted during the snapshot and replays them after the seed", async () => {
    const commandCalls: string[][] = []
    const order: string[] = []
    let resolveList!: () => void
    const listGate = new Promise<void>((resolve) => {
      resolveList = resolve
    })
    const fallback = setTimeout(() => resolveList(), 1000)
    const setup = createTmuxAgentTamagotchiPluginV2({ execute: fakeExecute(commandCalls) })
    const context = fakeContextV2(
      [{ type: "session.execution.started", data: { sessionID: "root-a" } }],
      { "root-a": {} },
      {},
    )
    const slowListContext = {
      ...context,
      session: {
        ...context.session,
        list: async () => {
          order.push("list-start")
          await listGate
          order.push("list-end")
          return { data: [{ id: "root-a" }], cursor: {} }
        },
      },
      event: {
        subscribe: async function* (options?: { signal?: AbortSignal }) {
          order.push("subscribed")
          resolveList()
          yield { type: "session.execution.started", data: { sessionID: "root-a" } }
          await new Promise<void>((resolve) => {
            if (options?.signal?.aborted) return resolve()
            options?.signal?.addEventListener("abort", () => resolve(), { once: true })
          })
        },
      },
    }
    const cleanup = await setup(slowListContext)
    await settle()
    clearTimeout(fallback)

    // The subscription starts before the snapshot completes, so the resume
    // transition survives instead of being lost in the gap; the FIFO still
    // orders the idle seed before it.
    expect(order.indexOf("subscribed")).toBeLessThan(order.indexOf("list-end"))
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode", "--pane", PANE],
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", PANE],
    ])
    await cleanup()
  })
})

function fakeExecute(commandCalls: string[][]) {
  return async (argv: readonly string[]) => {
    commandCalls.push([...argv])
    if (argv.includes("list-panes")) {
      return { exitCode: 0, stdout: `${PANE}\topencode\t${DIRECTORY}\n%other\tzsh\t${DIRECTORY}\n` }
    }
    return argv[0] === "tmux"
      ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
      : { exitCode: 0, stdout: "" }
  }
}

function fakeContextV2(
  events: unknown[],
  sessions: Record<string, { parentID?: string; location?: { directory: string } }>,
  messages: Record<string, Array<Record<string, unknown>>>,
  snapshot?: {
    list?: Array<Record<string, unknown>>
    listPages?: Array<Array<Record<string, unknown>>>
    active?: Record<string, unknown>
    waits?: Record<string, "idle" | "running">
    permissions?: Record<string, string[]>
  },
): PluginContextV2 {
  let listCalls = 0
  return {
    location: { directory: DIRECTORY },
    session: {
      get: async ({ sessionID }: { sessionID: string }) => {
        const session = sessions[sessionID]
        return session ? { id: sessionID, ...session } : undefined
      },
      context: async ({ sessionID }: { sessionID: string }) => messages[sessionID] ?? [],
      ...(snapshot && ("list" in snapshot || "listPages" in snapshot)
        ? {
          list: async () => {
            listCalls += 1
            if (snapshot.listPages) {
              const page = snapshot.listPages[listCalls - 1] ?? []
              const next = listCalls < snapshot.listPages.length ? `cursor-${listCalls}` : undefined
              return { data: page, cursor: next !== undefined ? { next } : {} }
            }
            return { data: snapshot.list ?? [], cursor: {} }
          },
        }
        : {}),
      ...(snapshot && "active" in snapshot
        ? { active: async () => snapshot.active ?? {} }
        : {}),
      ...(snapshot && "waits" in snapshot
        ? {
          wait: async (input: unknown) => {
            const sessionID = (input as { sessionID?: unknown }).sessionID
            if (typeof sessionID === "string" && snapshot.waits?.[sessionID] === "running") {
              await new Promise<void>(() => {})
            }
          },
        }
        : {}),
    },
    ...(snapshot && "permissions" in snapshot
      ? {
        permission: {
          list: async (input: unknown) => {
            const sessionID = (input as { sessionID?: unknown }).sessionID
            return {
              data: (typeof sessionID === "string" ? snapshot.permissions?.[sessionID] ?? [] : []).map((id) => ({
                id,
                sessionID,
              })),
            }
          },
        },
      }
      : {}),
    event: {
      subscribe: async function* (options?: { signal?: AbortSignal }) {
        for (const event of events) {
          if (options?.signal?.aborted) break
          yield event
        }
        await new Promise<void>((resolve) => {
          if (options?.signal?.aborted) return resolve()
          options?.signal?.addEventListener("abort", () => resolve(), { once: true })
        })
      },
    },
  }
}

function tamaCalls(calls: string[][]): string[][] {
  return calls.filter((argv) => argv[0] !== "tmux")
}

async function settle(times = 50): Promise<void> {
  for (let index = 0; index < times; index += 1) {
    await new Promise((resolve) => setImmediate(resolve))
  }
}
