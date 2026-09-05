import type { Event as SdkEvent } from "@opencode-ai/sdk"

export const TESTED_VERSIONS = {
  opencode: "1.18.18",
  plugin: "1.18.18",
  sdk: "1.18.18",
  bun: "1.3.14",
  typescript: "5.8.2",
} as const

type WithEventId<Event> = Event extends unknown ? Event & { id: string } : never

type SdkLifecycleEvent = WithEventId<
  Extract<
    SdkEvent,
    {
      type:
        | "message.updated"
        | "session.created"
        | "session.deleted"
        | "session.idle"
        | "session.error"
        | "session.status"
    }
  >
>

type PermissionAskedEvent = {
  id: string
  type: "permission.asked"
  properties: {
    id: string
    sessionID: string
    permission: string
    patterns: string[]
    metadata: Record<string, unknown>
    always: string[]
    tool?: {
      messageID: string
      callID: string
    }
  }
}

type PermissionRepliedEvent = {
  id: string
  type: "permission.replied"
  properties: {
    sessionID: string
    requestID: string
    reply: "once" | "always" | "reject"
  }
}

// The runtime envelope includes id and uses permission.asked/replied, while the
// 1.18.18 generated SDK Event union omits id and exposes the former permission.updated shape.
export type OpenCodeLifecycleEvent = SdkLifecycleEvent | PermissionAskedEvent | PermissionRepliedEvent
