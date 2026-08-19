import { describe, expect, test } from "bun:test"
import type { Plugin, PluginInput } from "@opencode-ai/plugin"

import { createTmuxAgentTamagotchiPlugin } from "../plugin"
import { FakeClock } from "./fake-clock"

test("the entrypoint exposes exactly one loadable plugin function", async () => {
  const entrypoint = await import("../index")

  expect(Object.keys(entrypoint)).toEqual(["TmuxAgentTamagotchi"])
  expect(typeof entrypoint.TmuxAgentTamagotchi).toBe("function")

  const plugin: Plugin = entrypoint.TmuxAgentTamagotchi
  const hooks = await plugin(fakePluginInput(async () => undefined))

  expect(Object.keys(hooks).sort()).toEqual(["dispose", "event"])
  await expect(hooks.event?.({ event: { type: "server.connected", properties: {} } })).resolves.toBeUndefined()
  await expect(hooks.dispose?.()).resolves.toBeUndefined()
})

describe("wired plugin", () => {
  test("uses the OpenCode client for classification and publishes ordered CLI argv", async () => {
    const clientCalls: unknown[] = []
    const commandCalls: string[][] = []
    const plugin = createTmuxAgentTamagotchiPlugin({
      execute: async (argv) => {
        commandCalls.push([...argv])
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
    })
    const input = fakePluginInput(async (options) => {
      clientCalls.push(options)
      const id = options.path.id
      return id === "root-a"
        ? { id: "root-a" }
        : { id, parentID: "root-a" }
    })
    const hooks = await plugin(input)

    const running = hooks.event?.({ event: statusEvent("root-a", "busy") as never })
    const waiting = hooks.event?.({
      event: {
        type: "permission.updated",
        properties: { id: "request-a", sessionID: "root-a" },
      } as never,
    })
    await Promise.all([running, waiting])
    await hooks.event?.({
      event: {
        type: "permission.replied",
        properties: { permissionID: "request-a", response: "once", sessionID: "root-a" },
      } as never,
    })
    await hooks.event?.({ event: statusEvent("child;not shell", "busy") as never })
    await hooks.dispose?.()

    expect(clientCalls).toEqual([
      { path: { id: "root-a" }, query: { directory: "/workspace" } },
      { path: { id: "child;not shell" }, query: { directory: "/workspace" } },
    ])
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "running", "OpenCode"],
      ["/plugin/bin/tama", "state", "waiting", "OpenCode"],
      ["/plugin/bin/tama", "state", "running", "OpenCode"],
      ["/plugin/bin/tama", "state", "subagent-start", "--", "child;not shell"],
      ["/plugin/bin/tama", "state", "subagent-stop", "--", "child;not shell"],
      ["/plugin/bin/tama", "state", "clear"],
    ])
  })

  test("looks up the eligible terminal message and notifies through tama after ten idle seconds", async () => {
    const clock = new FakeClock()
    const clientCalls: unknown[] = []
    const commandCalls: string[][] = []
    const plugin = createTmuxAgentTamagotchiPlugin({
      clock,
      execute: async (argv) => {
        commandCalls.push([...argv])
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
    })
    const input = fakePluginInput(
      async (options) => {
        clientCalls.push({ operation: "session", options })
        return { id: options.path.id }
      },
      async (options) => {
        clientCalls.push({ operation: "message", options })
        return {
          info: {
            id: options.path.messageID,
            sessionID: options.path.id,
            role: "assistant",
          },
          parts: [{ type: "text", text: "Delivered from the SDK." }],
        }
      },
    )
    const hooks = await plugin(input)

    await hooks.event?.({ event: statusEvent("root-a", "busy") as never })
    await hooks.event?.({
      event: {
        type: "message.updated",
        properties: {
          info: {
            id: "message-a",
            sessionID: "root-a",
            role: "assistant",
            time: { completed: 1 },
          },
        },
      } as never,
    })
    await hooks.event?.({ event: statusEvent("root-a", "idle") as never })

    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "running", "OpenCode"],
      ["/plugin/bin/tama", "state", "idle", "OpenCode"],
    ])
    await clock.advance(9_999)
    expect(tamaCalls(commandCalls)).toHaveLength(2)
    await clock.advance(1)

    expect(clientCalls).toEqual([
      {
        operation: "session",
        options: { path: { id: "root-a" }, query: { directory: "/workspace" } },
      },
      {
        operation: "message",
        options: {
          path: { id: "root-a", messageID: "message-a" },
          query: { directory: "/workspace" },
        },
      },
    ])
    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "running", "OpenCode"],
      ["/plugin/bin/tama", "state", "idle", "OpenCode"],
      ["/plugin/bin/tama", "notify", "--", "OpenCode", "Delivered from the SDK."],
    ])
  })

  test("disposal clears the pane without allowing pending message work to notify", async () => {
    const clock = new FakeClock()
    const commandCalls: string[][] = []
    const pendingMessage = deferred<unknown>()
    const plugin = createTmuxAgentTamagotchiPlugin({
      clock,
      execute: async (argv) => {
        commandCalls.push([...argv])
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
    })
    const hooks = await plugin(fakePluginInput(
      async ({ path }) => ({ id: path.id }),
      async () => pendingMessage.promise,
    ))

    await hooks.event?.({ event: statusEvent("root-a", "busy") as never })
    await hooks.event?.({
      event: {
        type: "message.updated",
        properties: {
          info: {
            id: "message-a",
            sessionID: "root-a",
            role: "assistant",
            time: { completed: 1 },
          },
        },
      } as never,
    })
    await hooks.event?.({ event: statusEvent("root-a", "idle") as never })
    await clock.advance(1_999)
    await hooks.dispose?.()
    pendingMessage.resolve({
      info: { id: "message-a", sessionID: "root-a", role: "assistant" },
      parts: [{ type: "text", text: "late completion" }],
    })
    await clock.advance(20_000)

    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "running", "OpenCode"],
      ["/plugin/bin/tama", "state", "idle", "OpenCode"],
      ["/plugin/bin/tama", "state", "clear"],
    ])
  })

  test("activity from another root invalidates the pane-level completion", async () => {
    const clock = new FakeClock()
    const commandCalls: string[][] = []
    const plugin = createTmuxAgentTamagotchiPlugin({
      clock,
      execute: async (argv) => {
        commandCalls.push([...argv])
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
    })
    const hooks = await plugin(fakePluginInput(
      async ({ path }) => ({ id: path.id }),
      async ({ path }) => ({
        info: { id: path.messageID, sessionID: path.id, role: "assistant" },
        parts: [{ type: "text", text: "root A finished" }],
      }),
    ))

    await hooks.event?.({ event: statusEvent("root-a", "busy") as never })
    await hooks.event?.({
      event: {
        type: "message.updated",
        properties: {
          info: {
            id: "message-a",
            sessionID: "root-a",
            role: "assistant",
            time: { completed: 1 },
          },
        },
      } as never,
    })
    await hooks.event?.({ event: statusEvent("root-a", "idle") as never })
    await clock.advance(9_900)
    await hooks.event?.({ event: statusEvent("root-b", "busy") as never })
    await clock.advance(10_000)

    expect(tamaCalls(commandCalls)).toEqual([
      ["/plugin/bin/tama", "state", "running", "OpenCode"],
      ["/plugin/bin/tama", "state", "idle", "OpenCode"],
      ["/plugin/bin/tama", "state", "running", "OpenCode"],
    ])
  })

  test("keeps a blocked notification ordered before later pane activity", async () => {
    const clock = new FakeClock()
    const commandCalls: string[][] = []
    const notificationStarted = deferred<void>()
    const releaseNotification = deferred<void>()
    const plugin = createTmuxAgentTamagotchiPlugin({
      clock,
      execute: async (argv) => {
        commandCalls.push([...argv])
        if (argv[0] === "tmux") return { exitCode: 0, stdout: "/plugin/bin/tama\n" }
        if (argv[1] === "notify") {
          notificationStarted.resolve()
          await releaseNotification.promise
        }
        return { exitCode: 0, stdout: "" }
      },
    })
    const hooks = await plugin(fakePluginInput(
      async ({ path }) => ({ id: path.id }),
      async ({ path }) => ({
        info: { id: path.messageID, sessionID: path.id, role: "assistant" },
        parts: [{ type: "text", text: "finished" }],
      }),
    ))

    await completeTurn(hooks, "root-a", "message-a")
    await clock.advance(10_000)
    expect(tamaCalls(commandCalls).at(-1)).toEqual([
      "/plugin/bin/tama", "notify", "--", "OpenCode", "finished",
    ])
    await notificationStarted.promise

    const activity = hooks.event?.({ event: statusEvent("root-b", "busy") as never })
    await Promise.resolve()
    expect(tamaCalls(commandCalls).at(-1)?.[1]).toBe("notify")

    releaseNotification.resolve()
    await activity
    expect(tamaCalls(commandCalls).at(-1)).toEqual([
      "/plugin/bin/tama", "state", "running", "OpenCode",
    ])
  })

  test("drains a blocked admitted notification before disposal clears the pane", async () => {
    const clock = new FakeClock()
    const commandCalls: string[][] = []
    const notificationStarted = deferred<void>()
    const releaseNotification = deferred<void>()
    const plugin = createTmuxAgentTamagotchiPlugin({
      clock,
      execute: async (argv) => {
        commandCalls.push([...argv])
        if (argv[0] === "tmux") return { exitCode: 0, stdout: "/plugin/bin/tama\n" }
        if (argv[1] === "notify") {
          notificationStarted.resolve()
          await releaseNotification.promise
        }
        return { exitCode: 0, stdout: "" }
      },
    })
    const hooks = await plugin(fakePluginInput(
      async ({ path }) => ({ id: path.id }),
      async ({ path }) => ({
        info: { id: path.messageID, sessionID: path.id, role: "assistant" },
        parts: [{ type: "text", text: "finished" }],
      }),
    ))

    await completeTurn(hooks, "root-a", "message-a")
    await clock.advance(10_000)
    expect(tamaCalls(commandCalls).at(-1)?.[1]).toBe("notify")
    await notificationStarted.promise

    const disposal = hooks.dispose?.()
    await Promise.resolve()
    expect(tamaCalls(commandCalls).some((argv) => argv[2] === "clear")).toBe(false)

    releaseNotification.resolve()
    await disposal
    expect(tamaCalls(commandCalls).at(-1)).toEqual([
      "/plugin/bin/tama", "state", "clear",
    ])
  })
})

function fakePluginInput(
  lookup: (options: { path: { id: string }; query: { directory: string } }) => Promise<unknown>,
  lookupMessage: (options: {
    path: { id: string; messageID: string }
    query: { directory: string }
  }) => Promise<unknown> = async () => undefined,
): PluginInput {
  return {
    directory: "/workspace",
    client: {
      session: {
        get: async (options: { path: { id: string }; query: { directory: string } }) => ({
          data: await lookup(options),
        }),
        message: async (options: {
          path: { id: string; messageID: string }
          query: { directory: string }
        }) => ({
          data: await lookupMessage(options),
        }),
      },
    },
  } as unknown as PluginInput
}

function statusEvent(sessionID: string, type: "busy" | "retry" | "idle") {
  return { type: "session.status", properties: { sessionID, status: { type } } }
}

function tamaCalls(calls: string[][]): string[][] {
  return calls.filter((argv) => argv[0] !== "tmux")
}

async function completeTurn(
  hooks: Awaited<ReturnType<Plugin>>,
  sessionId: string,
  messageId: string,
): Promise<void> {
  await hooks.event?.({ event: statusEvent(sessionId, "busy") as never })
  await hooks.event?.({
    event: {
      type: "message.updated",
      properties: {
        info: {
          id: messageId,
          sessionID: sessionId,
          role: "assistant",
          time: { completed: 1 },
        },
      },
    } as never,
  })
  await hooks.event?.({ event: statusEvent(sessionId, "idle") as never })
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => {
    resolve = done
  })
  return { promise, resolve }
}
