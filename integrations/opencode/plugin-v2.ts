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
import { createOpenCodeRuntime } from "./runtime"

// Structural subset of the OpenCode v2 plugin context used here. Kept local so
// the plugin has no v2 package dependency at load time; v2 validates the
// exported definition shape, not type provenance.
export type PluginContextV2 = Readonly<{
  location?: Readonly<{ directory?: unknown }>
  session: Readonly<{
    get(input: Readonly<{ sessionID: string }>): Promise<unknown>
    context(input: Readonly<{ sessionID: string }>): Promise<unknown>
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
