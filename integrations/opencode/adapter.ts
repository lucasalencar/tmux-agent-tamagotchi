import type { LifecycleEvent, SessionKind } from "./state-machine"

export type SessionInfo = Readonly<{
  id: string
  parentID?: string
}>

export type EventAdapterDependencies = Readonly<{
  lookupSession(sessionId: string): Promise<SessionInfo | undefined>
  maxParentDepth?: number
}>

export type EventAdapter = Readonly<{
  adapt(event: unknown): Promise<LifecycleEvent | undefined>
  clear(): void
}>

type SessionRecord = Readonly<{ parentId: string | null }>

const DEFAULT_MAX_PARENT_DEPTH = 64

export function createEventAdapter(dependencies: EventAdapterDependencies): EventAdapter {
  const records = new Map<string, SessionRecord>()
  const classifications = new Map<string, SessionKind>()
  const maxParentDepth = dependencies.maxParentDepth ?? DEFAULT_MAX_PARENT_DEPTH

  function remember(info: SessionInfo): boolean {
    if (!isIdentifier(info.id)) return false
    const parent = readParentId(info)
    if (parent === undefined) return false
    records.set(info.id, { parentId: parent })
    classifications.clear()
    return true
  }

  async function recordFor(sessionId: string): Promise<SessionRecord | undefined> {
    const cached = records.get(sessionId)
    if (cached) return cached
    try {
      const info = await dependencies.lookupSession(sessionId)
      if (!info || info.id !== sessionId || !remember(info)) return undefined
      return records.get(sessionId)
    } catch {
      return undefined
    }
  }

  async function classify(sessionId: string): Promise<SessionKind | undefined> {
    const cached = classifications.get(sessionId)
    if (cached) return cached

    const path: string[] = []
    const visited = new Set<string>()
    let current = sessionId
    for (let depth = 0; depth <= maxParentDepth; depth += 1) {
      if (visited.has(current)) return undefined
      visited.add(current)

      const known = classifications.get(current)
      if (known) {
        path.forEach((id) => classifications.set(id, "delegated"))
        return path.length === 0 ? known : "delegated"
      }

      const record = await recordFor(current)
      if (!record) return undefined
      if (record.parentId === null) {
        classifications.set(current, "root")
        path.forEach((id) => classifications.set(id, "delegated"))
        return path.length === 0 ? "root" : "delegated"
      }
      path.push(current)
      current = record.parentId
    }
    return undefined
  }

  async function adapt(event: unknown): Promise<LifecycleEvent | undefined> {
    if (!isRecord(event) || !isRecord(event.properties)) return undefined
    const properties = event.properties
    if (event.type === "session.created" || event.type === "session.deleted") {
      if (!isSessionInfo(properties.info) || !remember(properties.info)) return undefined
      const sessionId = properties.info.id
      const kind = await classify(sessionId)
      if (event.type === "session.deleted") {
        records.delete(sessionId)
        classifications.clear()
      }
      if (!kind) return undefined
      return {
        type: event.type === "session.created" ? "session-created" : "session-deleted",
        sessionId,
        kind,
      }
    }
    if (event.type === "session.status") {
      const sessionId = properties.sessionID
      const status = isRecord(properties.status) ? properties.status.type : undefined
      if (!isIdentifier(sessionId) || (status !== "busy" && status !== "retry" && status !== "idle")) {
        return undefined
      }
      const kind = await classify(sessionId)
      return kind ? { type: "session-status", sessionId, kind, status } : undefined
    }
    if (event.type === "permission.asked" || event.type === "permission.updated") {
      const requestId = properties.id ?? properties.permissionID
      const sessionId = properties.sessionID
      if (!isIdentifier(requestId) || !isIdentifier(sessionId)) return undefined
      const kind = await classify(sessionId)
      return kind
        ? { type: "permission-asked", requestId, sessionId, kind }
        : undefined
    }
    if (event.type === "permission.replied") {
      const requestId = properties.requestID ?? properties.permissionID
      return isIdentifier(requestId) ? { type: "permission-replied", requestId } : undefined
    }
    if (event.type === "session.error") {
      const sessionId = properties.sessionID
      if (!isIdentifier(sessionId)) return undefined
      const kind = await classify(sessionId)
      if (!kind) return undefined
      const message = errorMessage(properties.error)
      return message
        ? { type: "session-error", sessionId, kind, message }
        : { type: "session-error", sessionId, kind }
    }
    if (event.type === "message.updated") {
      const info = properties.info
      if (
        !isRecord(info)
        || info.role !== "assistant"
        || info.summary === true
        || !isIdentifier(info.id)
        || !isIdentifier(info.sessionID)
        || !isRecord(info.time)
        || typeof info.time.completed !== "number"
      ) {
        return undefined
      }
      const kind = await classify(info.sessionID)
      return kind
        ? {
            type: "terminal-assistant-message",
            sessionId: info.sessionID,
            kind,
            messageId: info.id,
          }
        : undefined
    }
    return undefined
  }

  return {
    adapt,
    clear() {
      records.clear()
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
  if (!("parentID" in info)) return null
  return isIdentifier(info.parentID) ? info.parentID : undefined
}

function errorMessage(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined
  if (isIdentifier(value.message)) return value.message
  return isRecord(value.data) && isIdentifier(value.data.message) ? value.data.message : undefined
}
