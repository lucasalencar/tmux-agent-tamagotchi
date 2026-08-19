import { describe, expect, test } from "bun:test"
import type { Plugin, PluginInput } from "@opencode-ai/plugin"

import { createTmuxAgentTamagotchiPlugin } from "../plugin"

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
})

function fakePluginInput(
  lookup: (options: { path: { id: string }; query: { directory: string } }) => Promise<unknown>,
): PluginInput {
  return {
    directory: "/workspace",
    client: {
      session: {
        get: async (options: { path: { id: string }; query: { directory: string } }) => ({
          data: await lookup(options),
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
