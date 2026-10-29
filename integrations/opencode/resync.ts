import { realpathSync } from "node:fs"

import type { LifecycleEvent, SessionKind, SessionStatus } from "./state-machine"

// A server snapshot entry: everything resync needs to re-establish one
// session after the background service restarts and the plugin's in-memory
// lifecycle is lost.
export type ResyncSession = Readonly<{
  sessionId: string
  kind: SessionKind
  status: SessionStatus
  directory?: string
}>

export type ResyncPermission = Readonly<{
  requestId: string
  sessionId: string
  kind: SessionKind
  directory?: string
}>

// Builds the lifecycle seed that re-establishes pane state from an
// authoritative snapshot. Every session contributes created (presence) then
// status (activity), mirroring the live flow where creation precedes the
// first busy transition; pending permissions follow so waiting survives the
// restart too. Terminal assistant messages are never synthesized, so resync
// can never raise a completion notification for work it did not observe.
export function buildResyncEvents(
  sessions: readonly ResyncSession[],
  permissions: readonly ResyncPermission[] = [],
): LifecycleEvent[] {
  const events: LifecycleEvent[] = []
  for (const session of sessions) {
    if (!session.sessionId) continue
    const provenance = session.directory !== undefined ? { directory: session.directory } : {}
    events.push({ type: "session-created", sessionId: session.sessionId, kind: session.kind, ...provenance })
    events.push({
      type: "session-status",
      sessionId: session.sessionId,
      kind: session.kind,
      status: session.status,
      ...provenance,
    })
  }
  for (const permission of permissions) {
    if (!permission.requestId || !permission.sessionId) continue
    const provenance = permission.directory !== undefined ? { directory: permission.directory } : {}
    events.push({
      type: "permission-asked",
      requestId: permission.requestId,
      sessionId: permission.sessionId,
      kind: permission.kind,
      ...provenance,
    })
  }
  return events
}

// Classifies a session from its parent id with the same rule the adapters
// use: no parent is a root, a non-empty parent is delegated, anything else
// is unattributed and must be skipped rather than guessed.
export function kindFromParentId(parentID: unknown): SessionKind | undefined {
  if (parentID === undefined) return "root"
  if (typeof parentID === "string") return parentID.length > 0 ? "delegated" : undefined
  return undefined
}

// Normalizes a busy-like server status into the lifecycle vocabulary. Retry
// stays distinct because the state machine treats it as running without
// reporting failure; anything unrecognized settles to idle (presence without
// activity) rather than dropping the session.
export function statusFromServerType(type: unknown): SessionStatus {
  if (type === "busy") return "busy"
  if (type === "retry") return "retry"
  return "idle"
}

// Reads the status discriminator from either the direct client shape or a
// { data } wrapper, so the filter and the seeding below cannot disagree.
export function statusTypeOf(status: unknown): unknown {
  return isRecord(status) ? status.type : undefined
}

// Compares working directories with symlinks resolved, so /tmp and
// /private/tmp compare equal on macOS. Shared by the v1 and v2 resync paths
// so both scope snapshots exactly like the live v2 event filter.
export function sameDirectory(left: string, right: string): boolean {
  if (left === right) return true
  try {
    return canonicalize(left) === canonicalize(right)
  } catch {
    return false
  }
}

export function canonicalize(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}
