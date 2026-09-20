import type { Event as SdkEvent } from "@opencode-ai/sdk"

export const TESTED_VERSIONS = {
  opencode: "1.18.18",
  plugin: "1.18.18",
  sdk: "1.18.18",
  opencodeV2: "2.0.10",
  pluginV2: "2.0.10",
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

// OpenCode v2 delivers flat discriminated events over ctx.event.subscribe()
// instead of the v1 { type, properties } envelope. Only the lifecycle subset
// below is consumed; every other v2 event is ignored defensively.
export type OpenCodeV2Event = Readonly<
  | {
    type: "session.created"
    data: { sessionID: string; parentID?: string }
  }
  | {
    type: "session.deleted"
    data: { sessionID: string }
  }
  | {
    type: "session.status"
    data: { sessionID: string; status: { type: string } }
  }
  | {
    type: "session.idle"
    data: { sessionID: string }
  }
  | {
    type: "session.execution.started"
    data: { sessionID: string }
  }
  | {
    type: "session.execution.succeeded"
    data: { sessionID: string }
  }
  | {
    type: "session.execution.interrupted"
    data: { sessionID: string }
  }
  | {
    type: "session.execution.failed"
    data: { sessionID: string; error?: { message?: string } }
  }
  | {
    type: "permission.asked"
    data: { id: string; sessionID: string }
  }
  | {
    type: "permission.replied"
    data: { sessionID: string; requestID: string }
  }
>
