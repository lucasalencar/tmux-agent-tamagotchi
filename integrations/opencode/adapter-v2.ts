import { realpathSync } from "node:fs"

import {
  type EventAdapter,
  type EventAdapterDependencies,
  type SessionInfo,
  type SessionMessageInfo,
} from "./adapter"
import type { LifecycleEvent, SessionKind } from "./state-machine"

// Adapts OpenCode v2 flat events ({ type, data }) into the shared lifecycle.
// Session and message lookups reuse the v1 dependency shapes; plugin-v2
// synthesizes those shapes from the v2 client responses at the boundary.
export function createEventAdapterV2(dependencies: EventAdapterDependencies): EventAdapter {
  const classifications = new Map<string, { kind: SessionKind; directory?: string }>()

  function store(sessionId: string, kind: SessionKind, directory?: string): void {
    // Never let a directory-less write clobber a known directory: the next
    // location-less event would otherwise pay for another lookup.
    const cached = classifications.get(sessionId)
    const resolved = directory ?? cached?.directory
    classifications.set(sessionId, {
      kind,
      ...(resolved !== undefined ? { directory: resolved } : {}),
    })
  }

  function remember(info: SessionInfo): SessionKind | undefined {
    if (!isIdentifier(info.id)) return undefined
    const parent = readParentId(info)
    if (parent === undefined) return undefined
    const kind = parent === null ? "root" : "delegated"
    store(info.id, kind, typeof info.directory === "string" ? info.directory : undefined)
    return kind
  }

  async function classify(sessionId: string): Promise<SessionKind | undefined> {
    const cached = classifications.get(sessionId)
    if (cached) return cached.kind
    try {
      const info = await dependencies.lookupSession(sessionId)
      if (!info || info.id !== sessionId) return undefined
      return remember(info)
    } catch {
      return undefined
    }
  }

  function classifyInline(
    sessionId: string,
    parentID: unknown,
    directory?: string,
  ): SessionKind | undefined {
    if (typeof parentID === "string") {
      if (!isIdentifier(parentID)) return undefined
      store(sessionId, "delegated", directory)
      return "delegated"
    }
    if (parentID === undefined) {
      store(sessionId, "root", directory)
      return "root"
    }
    return undefined
  }

  // Location-less events (execution transitions carry no directory) reach every
  // per-directory plugin instance. Each instance only owns the sessions in its
  // own directory, verified here against the looked-up session location, so one
  // session's turn cannot light up every pane on the server. Unverifiable cases
  // stay lenient and flow into the regular classification below.
  async function ownsSession(sessionId: string): Promise<boolean> {
    if (!dependencies.directory) return true
    const cached = classifications.get(sessionId)
    if (cached?.directory !== undefined) {
      return sameDirectory(cached.directory, dependencies.directory)
    }
    try {
      const info = await dependencies.lookupSession(sessionId)
      if (!info || info.id !== sessionId || typeof info.directory !== "string") return true
      remember(info)
      return sameDirectory(info.directory, dependencies.directory)
    } catch {
      return true
    }
  }

  async function adaptSessionStatus(
    sessionId: string,
    status: "busy" | "retry" | "idle",
    provenance: { directory?: string },
  ): Promise<Adaptation> {
    if (provenance.directory === undefined && !(await ownsSession(sessionId))) {
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
              ...provenance,
            },
          }
        }
      } catch {
        // An optional message lookup cannot block lifecycle state updates.
      }
    }
    return {
      status: "adapted",
      event: { type: "session-status", sessionId, kind, status, ...provenance },
    }
  }

  async function adapt(event: unknown): Promise<Adaptation> {
    if (!isRecord(event) || typeof event.type !== "string" || !isRecord(event.data)) {
      return { status: "malformed" }
    }
    const data = event.data
    const directory = readDirectory(event, data)
    const provenance = directory ? { directory } : {}

    if (event.type === "session.created") {
      if (!isIdentifier(data.sessionID)) return { status: "malformed" }
      if (directory === undefined && !(await ownsSession(data.sessionID))) {
        return { status: "unknown" }
      }
      // A created event without a parentID is a root session; roots carry no
      // parent while delegated sessions always name theirs.
      const kind = !("parentID" in data)
        ? remember({ id: data.sessionID, ...(directory ? { directory } : {}) })
        : classifyInline(data.sessionID, data.parentID, directory) ?? (await classify(data.sessionID))
      if (!kind) return { status: "malformed" }
      return {
        status: "adapted",
        event: { type: "session-created", sessionId: data.sessionID, kind, ...provenance },
      }
    }
    if (event.type === "session.deleted") {
      if (!isIdentifier(data.sessionID)) return { status: "malformed" }
      if (directory === undefined && !(await ownsSession(data.sessionID))) {
        return { status: "unknown" }
      }
      const kind = classifications.get(data.sessionID)?.kind ?? (await classify(data.sessionID))
      classifications.delete(data.sessionID)
      if (!kind) return { status: "malformed" }
      return {
        status: "adapted",
        event: { type: "session-deleted", sessionId: data.sessionID, kind, ...provenance },
      }
    }
    if (event.type === "session.status" || event.type === "session.idle") {
      if (!isIdentifier(data.sessionID)) return { status: "malformed" }
      const status = event.type === "session.idle"
        ? "idle"
        : isRecord(data.status) && typeof data.status.type === "string"
          ? data.status.type
          : undefined
      if (status !== "busy" && status !== "retry" && status !== "idle") {
        return { status: "unknown" }
      }
      return adaptSessionStatus(data.sessionID, status, provenance)
    }
    if (
      event.type === "session.execution.started"
      || event.type === "session.execution.succeeded"
      || event.type === "session.execution.interrupted"
    ) {
      // Successful v2 turns run on execution events without session.status or
      // session.idle transitions: started means the turn is running while
      // succeeded and interrupted both leave the session idle.
      if (!isIdentifier(data.sessionID)) return { status: "malformed" }
      const status = event.type === "session.execution.started" ? "busy" : "idle"
      return adaptSessionStatus(data.sessionID, status, provenance)
    }
    if (event.type === "permission.asked") {
      if (!isIdentifier(data.id) || !isIdentifier(data.sessionID)) return { status: "malformed" }
      if (directory === undefined && !(await ownsSession(data.sessionID))) {
        return { status: "unknown" }
      }
      const kind = await classify(data.sessionID)
      if (!kind) return { status: "malformed" }
      return {
        status: "adapted",
        event: {
          type: "permission-asked",
          requestId: data.id,
          sessionId: data.sessionID,
          kind,
          ...provenance,
        },
      }
    }
    if (event.type === "permission.replied") {
      if (!isIdentifier(data.requestID)) return { status: "malformed" }
      return {
        status: "adapted",
        event: { type: "permission-replied", requestId: data.requestID, ...provenance },
      }
    }
    if (event.type === "session.execution.failed") {
      if (!isIdentifier(data.sessionID)) return { status: "malformed" }
      if (directory === undefined && !(await ownsSession(data.sessionID))) {
        return { status: "unknown" }
      }
      const kind = await classify(data.sessionID)
      if (!kind) return { status: "malformed" }
      const message = isRecord(data.error) && isIdentifier(data.error.message)
        ? data.error.message
        : undefined
      return {
        status: "adapted",
        event: message
          ? { type: "session-error", sessionId: data.sessionID, kind, message, ...provenance }
          : { type: "session-error", sessionId: data.sessionID, kind, ...provenance },
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

type Adaptation = Readonly<
  | { status: "adapted"; event: LifecycleEvent }
  | { status: "unknown" }
  | { status: "malformed" }
>

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}

// The working directory an event belongs to: the top-level location first,
// then the nested session location carried by creation events. Shared with
// the v2 setup so per-directory plugin instances only track their own scope.
export function eventDirectoryV2(event: unknown): string | undefined {
  if (!isRecord(event) || !isRecord(event.data)) return undefined
  return readDirectory(event, event.data)
}

function readDirectory(event: Record<string, unknown>, data: Record<string, unknown>): string | undefined {
  if (isRecord(event.location) && typeof event.location.directory === "string") {
    return event.location.directory
  }
  if (isRecord(data.location) && typeof data.location.directory === "string") {
    return data.location.directory
  }
  return undefined
}

function isIdentifier(value: unknown): value is string {
  return typeof value === "string" && value.length > 0
}

// Compares working directories with symlinks resolved, so /tmp and
// /private/tmp compare equal on macOS.
function sameDirectory(left: string, right: string): boolean {
  if (left === right) return true
  try {
    return canonicalize(left) === canonicalize(right)
  } catch {
    return false
  }
}

function canonicalize(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

function readParentId(info: SessionInfo): string | null | undefined {
  if (info.parentID === undefined) return null
  return isIdentifier(info.parentID) ? info.parentID : undefined
}

function isTerminalAssistant(info: SessionMessageInfo, sessionId: string): boolean {
  return info.role === "assistant"
    && isIdentifier(info.id)
    && info.sessionID === sessionId
    && info.summary !== true
    && isRecord(info.time)
    && typeof info.time.completed === "number"
}
