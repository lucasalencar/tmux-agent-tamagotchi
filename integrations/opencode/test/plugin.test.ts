import { expect, test } from "bun:test"
import type { Plugin, PluginInput } from "@opencode-ai/plugin"

test("the entrypoint exposes exactly one loadable plugin function", async () => {
  const entrypoint = await import("../index")

  expect(Object.keys(entrypoint)).toEqual(["TmuxAgentTamagotchi"])
  expect(typeof entrypoint.TmuxAgentTamagotchi).toBe("function")

  const plugin: Plugin = entrypoint.TmuxAgentTamagotchi
  const hooks = await plugin({} as PluginInput)

  expect(Object.keys(hooks).sort()).toEqual(["dispose", "event"])
  await expect(hooks.event?.({ event: { type: "server.connected", properties: {} } })).resolves.toBeUndefined()
  await expect(hooks.dispose?.()).resolves.toBeUndefined()
})
