import type { Plugin, PluginInput } from "@opencode-ai/plugin"

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
import { buildResyncEvents, isInstanceScope, kindFromParentId, statusFromServerType, statusTypeOf, unwrapKeyedMap } from "./resync"

export type PluginDependencies = Readonly<{
  execute?: ProcessExecutor
  clock?: CompletionClock
  onCompletionEligible?(completion: CompletionReference): Promise<void>
  disposeLateWork?(): Promise<void> | void
}>

export function createTmuxAgentTamagotchiPlugin(dependencies: PluginDependencies = {}): Plugin {
  return async (input) => {
    const runner = createEffectRunner({
      execute: dependencies.execute ?? executeWithBun,
      onCompletionEligible: dependencies.onCompletionEligible,
    })
    let scheduler: CompletionScheduler
    const runtime = createOpenCodeRuntime({
      loggingEnabled: Boolean(Bun.env.TAMA_LOG_FILE),
      lookupSession: async (sessionId) => {
        const response = await input.client.session.get({
          path: { id: sessionId },
          query: { directory: input.directory },
        })
        const session = response.data
        return session
          ? {
              id: session.id,
              ...(Object.prototype.hasOwnProperty.call(session, "parentID")
                ? { parentID: session.parentID }
                : {}),
            }
            : undefined
      },
      lookupLatestMessage: async (sessionId) => {
        const response = await input.client.session.messages({
          path: { id: sessionId },
          query: { directory: input.directory, limit: 50 },
        })
        const messages = response.data ?? []
        for (let index = messages.length - 1; index >= 0; index -= 1) {
          const info = messages[index]?.info as { role?: string } | undefined
          if (info?.role === "assistant") return info as never
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
        const response = await input.client.session.message({
          path: { id: sessionId, messageID: messageId },
          query: { directory: input.directory },
        })
        return response.data
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
    // while the server keeps the sessions. Re-read the authoritative snapshot
    // before returning the hooks so later live events order behind it.
    await resyncV1(input, runtime)

    return {
      event: ({ event }) => runtime.event(event),
      dispose: runtime.dispose,
    }
  }
}

// Re-establishes pane state from the v1 list/status snapshot. Best effort by
// contract: any lookup failure settles to presence (idle) or skips the
// session, and never rejects into OpenCode or delays setup.
async function resyncV1(input: PluginInput, runtime: OpenCodeRuntime): Promise<void> {
  try {
    const directory = typeof input.directory === "string" ? input.directory : undefined
    const sessionClient = (input as unknown as { client?: { session?: Record<string, unknown> } }).client?.session
    if (!sessionClient || typeof sessionClient.list !== "function") return
    const listed = unwrapSessionArray(
      await (sessionClient.list as (args: unknown) => Promise<unknown>)({
        query: directory !== undefined ? { directory } : {},
      }).catch(() => undefined),
    )
    let statuses: Record<string, unknown> = {}
    if (typeof sessionClient.status === "function") {
      statuses = unwrapKeyedMap(
        await (sessionClient.status as (args: unknown) => Promise<unknown>)({
          query: directory !== undefined ? { directory } : {},
        }).catch(() => undefined),
      )
    }
    if (listed.length === 0 && Object.keys(statuses).length === 0) return
    const byId = new Map<string, { parentID?: unknown; directory?: unknown }>()
    for (const session of listed) {
      if (typeof session.id !== "string" || !session.id) continue
      if (!isInstanceScope(
        typeof session.directory === "string" ? session.directory : undefined,
        directory,
      )) {
        continue
      }
      byId.set(session.id, session)
    }
    // Statuses can name sessions the list omitted (deleted races, filters):
    // only running ones are worth an extra lookup, since idle only affects
    // presence the list already established.
    if (typeof sessionClient.get === "function") {
      for (const sessionId of Object.keys(statuses)) {
        if (byId.has(sessionId)) continue
        if (statusFromServerType(statusTypeOf(statuses[sessionId])) === "idle") continue
        try {
          const fetched = unwrapSessionRecord(
            await (sessionClient.get as (args: unknown) => Promise<unknown>)({
              path: { id: sessionId },
              query: directory !== undefined ? { directory } : {},
            }).catch(() => undefined),
          )
          if (!fetched) continue
          if (!isInstanceScope(
            typeof fetched.directory === "string" ? fetched.directory : undefined,
            directory,
          )) {
            continue
          }
          byId.set(sessionId, fetched)
        } catch {
          continue
        }
      }
    }
    const events = buildResyncEvents(
      Array.from(byId).flatMap(([sessionId, session]) => {
        const kind = kindFromParentId(session.parentID)
        if (!kind) return []
        return [{
          sessionId,
          kind,
          status: statusFromServerType(statusTypeOf(statuses[sessionId])),
          ...(directory !== undefined ? { directory } : {}),
        }]
      }),
    )
    if (events.length > 0) await runtime.resync(events)
  } catch {
    // Resync must never break plugin setup.
  }
}

type ListedSession = { id: string; parentID?: unknown; directory?: unknown }

function unwrapSessionArray(response: unknown): ListedSession[] {
  const data = isRecord(response) && "data" in response ? response.data : response
  if (!Array.isArray(data)) return []
  const sessions: ListedSession[] = []
  for (const entry of data) {
    if (!isRecord(entry) || typeof entry.id !== "string" || !entry.id) continue
    sessions.push({
      id: entry.id,
      ...(Object.prototype.hasOwnProperty.call(entry, "parentID") ? { parentID: entry.parentID } : {}),
      ...(typeof entry.directory === "string" ? { directory: entry.directory } : {}),
    })
  }
  return sessions
}

function unwrapSessionRecord(response: unknown): ListedSession | undefined {
  const data = isRecord(response) && "data" in response ? response.data : response
  if (!isRecord(data) || typeof data.id !== "string" || !data.id) return undefined
  return {
    id: data.id,
    ...(Object.prototype.hasOwnProperty.call(data, "parentID") ? { parentID: data.parentID } : {}),
    ...(typeof data.directory === "string" ? { directory: data.directory } : {}),
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}
