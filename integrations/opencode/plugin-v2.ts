import { realpathSync } from "node:fs"

import { createEventAdapterV2, eventDirectoryV2 } from "./adapter-v2"
import {
  createCompletionScheduler,
  type CompletionClock,
  type CompletionReference,
  type CompletionScheduler,
} from "./completion-scheduler"
import {
  createEffectRunner,
  executeWithBun,
  type ProcessExecutor,
} from "./effect-runner"
import { createOpenCodeRuntime, type OpenCodeRuntime } from "./runtime"
import { buildResyncEvents, kindFromParentId } from "./resync"

// Structural subset of the OpenCode v2 plugin context used here. Kept local so
// the plugin has no v2 package dependency at load time; v2 validates the
// exported definition shape, not type provenance.
export type PluginContextV2 = Readonly<{
  location?: Readonly<{ directory?: unknown }>
  session: Readonly<{
    get(input: Readonly<{ sessionID: string }>): Promise<unknown>
    context(input: Readonly<{ sessionID: string }>): Promise<unknown>
    // Present on newer hosts (2.2+); absent on the pinned 2.0.10 types.
    // Always probed defensively so one host never breaks another.
    list?(input?: unknown): Promise<unknown>
    active?(): Promise<unknown>
  }>
  permission?: Readonly<{
    list?(input: unknown): Promise<unknown>
  }>
  event: Readonly<{
    subscribe(options?: Readonly<{ signal?: AbortSignal }>): AsyncIterable<unknown>
  }>
}>

export type PluginV2Dependencies = Readonly<{
  execute?: ProcessExecutor
  clock?: CompletionClock
  onCompletionEligible?(completion: CompletionReference): Promise<void>
  disposeLateWork?(): Promise<void> | void
}>

type SetupCleanup = () => Promise<void> | void

export function createTmuxAgentTamagotchiPluginV2(
  dependencies: PluginV2Dependencies = {},
): (ctx: PluginContextV2) => Promise<SetupCleanup> {
  return async (ctx) => {
    // v2 instantiates one plugin per location. Each instance only tracks the
    // sessions in its own directory and reports them to the tmux pane working
    // there; without this scope, every instance would reduce the whole server
    // into the single pane the server process happened to start in.
    const directory = typeof ctx.location?.directory === "string" ? ctx.location.directory : undefined
    const execute = dependencies.execute ?? executeWithBun
    const runner = createEffectRunner({
      execute,
      onCompletionEligible: dependencies.onCompletionEligible,
      resolvePane: directory ? () => resolvePaneForDirectory(execute, directory) : undefined,
    })
    let scheduler: CompletionScheduler
    const runtime = createOpenCodeRuntime({
      createAdapter: createEventAdapterV2,
      directory,
      loggingEnabled: Boolean(Bun.env.TAMA_LOG_FILE),
      lookupSession: async (sessionId) => {
        const session = await getSession(ctx, sessionId)
        if (!session || session.id !== sessionId) return undefined
        return {
          id: session.id,
          ...(Object.prototype.hasOwnProperty.call(session, "parentID")
            ? { parentID: session.parentID }
            : {}),
          ...(typeof session.directory === "string" ? { directory: session.directory } : {}),
        }
      },
      lookupLatestMessage: async (sessionId) => {
        const messages = await listMessages(ctx, sessionId)
        for (let index = messages.length - 1; index >= 0; index -= 1) {
          const message = messages[index]
          if (message?.type === "assistant") return shapeMessage(message, sessionId)
        }
        return undefined
      },
      runEffect: async (effect, context) => {
        scheduler.handle(effect, context)
        await runner.run(effect, context)
      },
      observeEvent: runner.observeEvent,
      clearPane: runner.clearPane,
      disposeLateWork: async () => {
        scheduler.dispose()
        await dependencies.disposeLateWork?.()
      },
    })
    scheduler = createCompletionScheduler({
      clock: dependencies.clock,
      lookupMessage: async ({ sessionId, messageId }) => {
        const messages = await listMessages(ctx, sessionId)
        const found = messages.find((message) => message?.id === messageId && message?.type === "assistant")
        if (!found) return undefined
        return {
          info: { id: messageId, sessionID: sessionId, role: "assistant" },
          parts: textParts(found.content),
        }
      },
      enqueue: (work) => {
        void runtime.enqueueLateWork(work)
      },
      notify: (message, completion) => runner.notify(
        message,
        completion.correlationId ? { correlationId: completion.correlationId } : undefined,
      ),
    })

    // The background service can restart under a live turn (update, config
    // reload): the new plugin instance starts with empty in-memory lifecycle
    // while the server keeps the sessions. The snapshot is read before the
    // subscription starts so live events order behind it instead of racing a
    // stale idle over fresh activity.
    await resyncV2(ctx, directory, runtime)

    const controller = new AbortController()
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          if (controller.signal.aborted) break
          if (directory) {
            const eventDirectory = eventDirectoryV2(event)
            if (eventDirectory !== undefined && !sameDirectory(eventDirectory, directory)) continue
          }
          void runtime.event(event)
        }
      } catch {
        // Aborted during unload or the transport closed underneath the stream.
      }
    })()

    return async () => {
      controller.abort()
      await runtime.dispose()
    }
  }
}

// Re-establishes pane state from the v2 list/active snapshot. Best effort by
// contract: unknown hosts (no list/active), lookup failures, and pagination
// limits settle to presence or skip the session, and never reject into
// OpenCode or delay setup beyond the snapshot reads.
async function resyncV2(
  ctx: PluginContextV2,
  directory: string | undefined,
  runtime: OpenCodeRuntime,
): Promise<void> {
  try {
    const session = ctx.session as {
      get(input: Readonly<{ sessionID: string }>): Promise<unknown>
      list?(input?: unknown): Promise<unknown>
      active?(): Promise<unknown>
    }
    type KnownSession = { parentID?: unknown; directory?: string }
    const byId = new Map<string, KnownSession>()
    if (typeof session.list === "function") {
      let cursor: string | undefined
      for (let page = 0; page < 10; page += 1) {
        let raw: unknown
        try {
          raw = await session.list(
            directory !== undefined
              ? { directory, limit: 100, ...(cursor !== undefined ? { cursor } : {}) }
              : { limit: 100, ...(cursor !== undefined ? { cursor } : {}) },
          )
        } catch {
          break
        }
        const { items, next } = unwrapSessionPage(raw)
        for (const item of items) {
          if (directory !== undefined && item.directory !== undefined && !sameDirectory(item.directory, directory)) {
            continue
          }
          if (!byId.has(item.id)) byId.set(item.id, item)
        }
        if (next === undefined) break
        cursor = next
      }
    }
    const activeIds = new Set<string>()
    if (typeof session.active === "function") {
      try {
        const raw = await session.active()
        for (const sessionId of Object.keys(unwrapActiveMap(raw))) {
          if (sessionId) activeIds.add(sessionId)
        }
      } catch {
        // Without the running set every listed session settles to idle
        // presence, still better than the cleared pane.
      }
    }
    // Active sessions the list omitted (delegated children are not
    // top-level): only running ones justify an extra lookup.
    for (const sessionId of Array.from(activeIds)) {
      if (byId.has(sessionId)) continue
      const fetched = await getSession(ctx, sessionId).catch(() => undefined)
      if (!fetched) continue
      if (directory !== undefined && fetched.directory !== undefined && !sameDirectory(fetched.directory, directory)) {
        continue
      }
      byId.set(sessionId, fetched)
    }
    if (byId.size === 0) return
    const permissions: Array<{ requestId: string; sessionId: string; kind: "root" | "delegated"; directory?: string }> = []
    const listPermission = ctx.permission?.list
    if (typeof listPermission === "function") {
      for (const [sessionId, sessionInfo] of Array.from(byId)) {
        const kind = kindFromParentId(sessionInfo.parentID) ?? "root"
        try {
          const raw = await listPermission({ sessionID: sessionId }).catch(() => undefined)
          for (const requestId of unwrapPermissionIds(raw)) {
            permissions.push({
              requestId,
              sessionId,
              kind,
              ...(directory !== undefined ? { directory } : {}),
            })
          }
        } catch {
          continue
        }
      }
    }
    const events = buildResyncEvents(
      Array.from(byId).flatMap(([sessionId, sessionInfo]) => {        const kind = kindFromParentId(sessionInfo.parentID)
        if (!kind) return []
        return [{
          sessionId,
          kind,
          status: activeIds.has(sessionId) ? "busy" as const : "idle" as const,
          ...(directory !== undefined ? { directory } : {}),
        }]
      }),
      permissions,
    )
    if (events.length > 0) await runtime.resync(events)
  } catch {
    // Resync must never break plugin setup.
  }
}

type AssistantMessage = {
  id: string
  type: string
  time?: { completed?: number }
  finish?: string
  content?: unknown
}

function shapeMessage(message: AssistantMessage, sessionId: string) {
  return {
    id: message.id,
    sessionID: sessionId,
    role: "assistant",
    ...(typeof message.finish === "string" ? { finish: message.finish } : {}),
    ...(message.time ? { time: message.time } : {}),
  }
}

async function getSession(
  ctx: PluginContextV2,
  sessionId: string,
): Promise<{ id: string; parentID?: string; directory?: string } | undefined> {
  try {
    const response = await ctx.session.get({ sessionID: sessionId })
    const session = unwrapData(response)
    if (!isRecord(session) || typeof session.id !== "string" || !session.id) return undefined
    const location = session.location
    return {
      id: session.id,
      ...(typeof session.parentID === "string" || session.parentID === undefined
        ? { parentID: session.parentID as string | undefined }
        : {}),
      ...(isRecord(location) && typeof location.directory === "string"
        ? { directory: location.directory as string }
        : {}),
    }
  } catch {
    return undefined
  }
}

async function listMessages(
  ctx: PluginContextV2,
  sessionId: string,
): Promise<AssistantMessage[]> {
  try {
    const response = await ctx.session.context({ sessionID: sessionId })
    const data = unwrapData(response)
    if (!Array.isArray(data)) return []
    return data.filter(isAssistantMessage)
  } catch {
    return []
  }
}

function isAssistantMessage(value: unknown): value is AssistantMessage {
  return isRecord(value) && typeof value.id === "string" && typeof value.type === "string"
}

function textParts(content: unknown): Array<{ type: string; text: string }> {
  if (!Array.isArray(content)) return []
  const parts: Array<{ type: string; text: string }> = []
  for (const part of content) {
    if (isRecord(part) && part.type === "text" && typeof part.text === "string") {
      parts.push({ type: "text", text: part.text })
    }
  }
  return parts
}

function unwrapData(response: unknown): unknown {
  if (isRecord(response) && "data" in response) return response.data
  return response
}

// Reads one v2 session page defensively: the client returns SessionsResponse
// ({ data, cursor }) directly while older hosts may wrap it in { data }.
// Items normalize both the flat v1-style { directory } and the v2
// { location: { directory } } shapes; entries without an id are dropped.
function unwrapSessionPage(response: unknown): {
  items: Array<{ id: string; parentID?: unknown; directory?: string }>
  next?: string
} {
  const root = unwrapData(response)
  const data = isRecord(root) && Array.isArray(root.data) ? root.data : Array.isArray(root) ? root : []
  const items: Array<{ id: string; parentID?: unknown; directory?: string }> = []
  for (const entry of data) {
    if (!isRecord(entry) || typeof entry.id !== "string" || !entry.id) continue
    const location = entry.location
    const directory = typeof entry.directory === "string"
      ? entry.directory
      : isRecord(location) && typeof location.directory === "string"
        ? (location.directory as string)
        : undefined
    items.push({
      id: entry.id,
      ...(Object.prototype.hasOwnProperty.call(entry, "parentID") ? { parentID: entry.parentID } : {}),
      ...(directory !== undefined ? { directory } : {}),
    })
  }
  const cursor = isRecord(root) ? root.cursor : undefined
  const next = isRecord(cursor) && typeof cursor.next === "string" && cursor.next ? cursor.next : undefined
  return next !== undefined ? { items, next } : { items }
}

// Reads the active-session map ({ sessionID: { type: "running" } }) from
// either the direct client shape or a { data } wrapper.
function unwrapActiveMap(response: unknown): Record<string, unknown> {
  const data = unwrapData(response)
  return isRecord(data) ? { ...data } : {}
}

// Reads pending permission requests for one session: an array of
// { id, sessionID } in either direct or { data } form.
function unwrapPermissionIds(response: unknown): string[] {
  const data = unwrapData(response)
  const list = Array.isArray(data) ? data : isRecord(data) && Array.isArray(data.data) ? data.data : []
  const ids: string[] = []
  for (const entry of list) {
    if (isRecord(entry) && typeof entry.id === "string" && entry.id) ids.push(entry.id)
  }
  return ids
}

// Finds the tmux pane running OpenCode in the given directory. Panes are
// matched by exact working directory (symlinks resolved, so /tmp and
// /private/tmp compare equal on macOS) and by the foreground command, so a
// plain shell sitting in the same directory never receives agent states. The
// first match wins when several panes share a directory.
async function resolvePaneForDirectory(
  execute: ProcessExecutor,
  directory: string,
): Promise<string | undefined> {
  try {
    const target = canonicalize(directory)
    const result = await execute([
      "tmux",
      "list-panes",
      "-a",
      "-F",
      "#{pane_id}\t#{pane_current_command}\t#{pane_current_path}",
    ])
    if (result.exitCode !== 0) return undefined
    for (const line of result.stdout.split("\n")) {
      const [paneId, command, path] = line.split("\t")
      if (!paneId || command !== "opencode" || !path) continue
      if (canonicalize(path) === target) return paneId
    }
    return undefined
  } catch {
    return undefined
  }
}

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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}
