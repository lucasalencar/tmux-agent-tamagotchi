import { expect, test } from "bun:test"

import { TESTED_VERSIONS, type OpenCodeLifecycleEvent } from "../contract"

test("keeps the recorded toolchain synchronized with the package manifest", async () => {
  const manifest = (await Bun.file(new URL("../package.json", import.meta.url)).json()) as {
    packageManager: string
    tamagotchi: { testedOpenCode: string }
    devDependencies: Record<string, string>
  }
  const recordedVersions: Record<keyof typeof TESTED_VERSIONS, string> = TESTED_VERSIONS

  expect(recordedVersions).toEqual({
    opencode: manifest.tamagotchi.testedOpenCode,
    plugin: manifest.devDependencies["@opencode-ai/plugin"],
    sdk: manifest.devDependencies["@opencode-ai/sdk"],
    bun: manifest.packageManager.replace("bun@", ""),
    typescript: manifest.devDependencies.typescript,
  })
})

test("accepts the documented permission event payloads despite stale SDK names", () => {
  const asked = {
    id: "evt_asked",
    type: "permission.asked",
    properties: {
      id: "per_123",
      sessionID: "ses_child",
      permission: "bash",
      patterns: ["git status"],
      metadata: {},
      always: ["git status"],
      tool: { messageID: "msg_123", callID: "call_123" },
    },
  } satisfies OpenCodeLifecycleEvent
  const replied = {
    id: "evt_replied",
    type: "permission.replied",
    properties: {
      sessionID: "ses_child",
      requestID: "per_123",
      reply: "once",
    },
  } satisfies OpenCodeLifecycleEvent

  expect([asked.type, replied.type]).toEqual(["permission.asked", "permission.replied"])
})
