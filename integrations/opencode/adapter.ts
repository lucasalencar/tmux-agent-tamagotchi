import type { LifecycleEvent, SessionKind } from "./state-machine"

export type SessionInfo = Readonly<{
  id: string
  parentID?: string
}>

export type SessionMessageInfo = Readonly<{
  id: string
  sessionID: string
  role: string
  summary?: boolean
  time?: Readonly<{ completed?: number }>
  finish?: string
}>

export type EventAdapterDependencies = Readonly<{
  lookupSession(sessionId: string): Promise<SessionInfo | undefined>
  lookupLatestMessage?(sessionId: string): Promise<SessionMessageInfo | undefined>
}>

export type EventAdapter = Readonly<{
  adapt(event: unknown): Promise<Adaptation>
  clear(): void
}>

export type Adaptation = Readonly<
  | { status: "adapted"; event: LifecycleEvent }
  | { status: "unknown" }
  | { status: "malformed" }
>

export function createEventAdapter(dependencies: EventAdapterDependencies): EventAdapter {
  const classifications = new Map<string, SessionKind>()

  function remember(info: SessionInfo): SessionKind | undefined {
    if (!isIdentifier(info.id)) return undefined
    const parent = readParentId(info)
    if (parent === undefined) return undefined
    const kind = parent === null ? "root" : "delegated"
    classifications.set(info.id, kind)
    return kind
  }

  async function classify(sessionId: string): Promise<SessionKind | undefined> {
    const cached = classifications.get(sessionId)
    if (cached) return cached
    try {
      const info = await dependencies.lookupSession(sessionId)
      if (!info || info.id !== sessionId) return undefined
      return remember(info)
    } catch {
      return undefined
    }
  }

  async function adapt(event: unknown): Promise<Adaptation> {
    if (!isRecord(event) || !isRecord(event.properties)) return { status: "malformed" }
    const properties = event.properties
    if (event.type === "session.created" || event.type === "session.deleted") {
      if (!isSessionInfo(properties.info)) return { status: "malformed" }
      const sessionId = properties.info.id
      const kind = remember(properties.info)
      if (event.type === "session.deleted") {
        classifications.delete(sessionId)
      }
      if (!kind) return { status: "malformed" }
      return {
        status: "adapted",
        event: {
          type: event.type === "session.created" ? "session-created" : "session-deleted",
          sessionId,
          kind,
        },
      }
    }
    if (event.type === "session.status" || event.type === "session.idle") {
      const sessionId = properties.sessionID
      const status = event.type === "session.idle"
        ? "idle"
        : isRecord(properties.status)
          ? properties.status.type
          : undefined
      if (!isIdentifier(sessionId)) return { status: "malformed" }
      if (status !== "busy" && status !== "retry" && status !== "idle") {
        return { status: "unknown" }
      }
      const kind = await classify(sessionId)
      if (!kind) return { status: "malformed" }
      if (kind === "root" && status === "idle") {
        try {
          const latest = await dependencies.lookupLatestMessage?.(sessionId)
          if (latest && isTerminalAssistant(latest, sessionId)) {
            return {
              status: "adapted",
              event: {
                type: "terminal-assistant-message",
                sessionId,
                kind,
                messageId: latest.id,
                ...(typeof latest.finish === "string" ? { finish: latest.finish } : {}),
              },
            }
          }
        } catch {
          // An optional message lookup cannot block lifecycle state updates.
        }
      }
      return { status: "adapted", event: { type: "session-status", sessionId, kind, status } }
    }
    if (event.type === "permission.asked" || event.type === "permission.updated") {
      const requestId = properties.id ?? properties.permissionID
      const sessionId = properties.sessionID
      if (!isIdentifier(requestId) || !isIdentifier(sessionId)) return { status: "malformed" }
      const kind = await classify(sessionId)
      if (!kind) return { status: "malformed" }
      return { status: "adapted", event: { type: "permission-asked", requestId, sessionId, kind } }
    }
    if (event.type === "permission.replied") {
      const requestId = properties.requestID ?? properties.permissionID
      if (!isIdentifier(requestId)) return { status: "malformed" }
      return { status: "adapted", event: { type: "permission-replied", requestId } }
    }
    if (event.type === "session.error") {
      const sessionId = properties.sessionID
      if (!isIdentifier(sessionId)) return { status: "malformed" }
      const kind = await classify(sessionId)
      if (!kind) return { status: "malformed" }
      const message = errorMessage(properties.error)
      return {
        status: "adapted",
        event: message
          ? { type: "session-error", sessionId, kind, message }
          : { type: "session-error", sessionId, kind },
      }
    }
    if (event.type === "message.updated") {
      const info = properties.info
      if (!isRecord(info) || !isIdentifier(info.id) || !isIdentifier(info.sessionID)) {
        return { status: "malformed" }
      }
      const kind = await classify(info.sessionID)
      if (!kind) return { status: "malformed" }
      if (info.role === "user") {
        return {
          status: "adapted",
          event: { type: "user-message", sessionId: info.sessionID, kind, messageId: info.id },
        }
      }
      if (!isTerminalAssistant(info, info.sessionID)) return { status: "unknown" }
      return {
        status: "adapted",
        event: {
          type: "terminal-assistant-message",
          sessionId: info.sessionID,
          kind,
          messageId: info.id,
          ...(typeof info.finish === "string" ? { finish: info.finish } : {}),
        },
      }
    }
    return { status: "unknown" }
  }

  return {
    adapt,
    clear() {
      classifications.clear()
    },
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}

function isIdentifier(value: unknown): value is string {
  return typeof value === "string" && value.length > 0
}

function isSessionInfo(value: unknown): value is SessionInfo {
  return isRecord(value) && isIdentifier(value.id)
}

function readParentId(info: SessionInfo): string | null | undefined {
  if (info.parentID === undefined) return null
  return isIdentifier(info.parentID) ? info.parentID : undefined
}

function errorMessage(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined
  if (isIdentifier(value.message)) return value.message
  return isRecord(value.data) && isIdentifier(value.data.message) ? value.data.message : undefined
}

function isTerminalAssistant(
  info: SessionMessageInfo | Record<string, unknown>,
  sessionId: string,
): info is SessionMessageInfo {
  return info.role === "assistant"
    && isIdentifier(info.id)
    && info.sessionID === sessionId
    && info.summary !== true
    && isRecord(info.time)
    && typeof info.time.completed === "number"
}
