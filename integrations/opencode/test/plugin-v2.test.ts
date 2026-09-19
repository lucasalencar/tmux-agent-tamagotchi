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
      "/plugin/bin/tama", "notify", "--", "OpenCode", "Delivered over v2.", "--pane", PANE,
    ])
    await cleanup()
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
      ["/plugin/bin/tama", "state", "subagent-start", "--", "child-a", "--pane", PANE],
      ["/plugin/bin/tama", "state", "subagent-stop", "--", "child-a", "--pane", PANE],
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
      ["/plugin/bin/tama", "notify", "--", "OpenCode", "Blew up.", "--pane", PANE],
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

    // The foreign session never reaches the lifecycle; the local one reports
    // without --pane because no opencode pane was listed for the directory.
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "idle", "OpenCode"],
      ["/plugin/bin/tama", "state", "running", "OpenCode"],
    ])
    await cleanup()
    expect(tamaCalls(commandCalls).at(-1)).toEqual(["/plugin/bin/tama", "state", "clear"])
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
  sessions: Record<string, { parentID?: string }>,
  messages: Record<string, Array<Record<string, unknown>>>,
): PluginContextV2 {
  return {
    location: { directory: DIRECTORY },
    session: {
      get: async ({ sessionID }: { sessionID: string }) => {
        const session = sessions[sessionID]
        return session ? { id: sessionID, ...session } : undefined
      },
      context: async ({ sessionID }: { sessionID: string }) => messages[sessionID] ?? [],
    },
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
