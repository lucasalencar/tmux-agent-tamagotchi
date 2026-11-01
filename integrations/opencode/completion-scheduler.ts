import type { StateMachineEffect } from "./state-machine"

export type CompletionReference = Readonly<{
  agentId: string
  sessionId: string
  messageId: string
  correlationId?: string
}>

export type MessageResponse = Readonly<{
  info: unknown
  parts: readonly unknown[]
}>

export type CompletionClock = Readonly<{
  setTimeout(callback: () => void, delayMs: number): unknown
  clearTimeout(handle: unknown): void
}>

export type CompletionSchedulerDependencies = Readonly<{
  lookupMessage(completion: CompletionReference): Promise<MessageResponse | undefined>
  enqueue(work: () => Promise<void>): void
  notify(message: string, completion: CompletionReference): Promise<void>
  clock?: CompletionClock
}>

export type CompletionScheduler = Readonly<{
  handle(effect: StateMachineEffect, context?: Readonly<{ correlationId?: string }>): void
  dispose(): void
}>

const COMPLETION_DELAY_MS = 5_000
const LOOKUP_DEADLINE_MS = 2_000
const GENERIC_COMPLETION = "OpenCode finished its turn"
const NOTIFICATION_TEXT_MAX = 500

type PendingCompletion = {
  generation: number
  agentId: string
  lookupTimer?: unknown
  notificationTimer?: unknown
}

const systemClock: CompletionClock = {
  setTimeout: (callback, delayMs) => setTimeout(callback, delayMs),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
}

export function createCompletionScheduler(
  dependencies: CompletionSchedulerDependencies,
): CompletionScheduler {
  const clock = dependencies.clock ?? systemClock
  const generations = new Map<string, number>()
  const pending = new Map<string, PendingCompletion>()

  function cancelPending(agentId?: string): void {
    const cancel = (own: PendingCompletion | undefined) => {
      if (own?.lookupTimer !== undefined) clock.clearTimeout(own.lookupTimer)
      if (own?.notificationTimer !== undefined) clock.clearTimeout(own.notificationTimer)
    }
    if (agentId === undefined) {
      pending.forEach((own) => cancel(own))
      pending.clear()
      generations.clear()
      return
    }
    generations.set(agentId, (generations.get(agentId) ?? 0) + 1)
    cancel(pending.get(agentId))
    pending.delete(agentId)
    // Session ids are never reused: without this the counter grows for every
    // root the long-lived plugin process ever sees. Deleting is safe — a late
    // timer still fails the identity half of isCurrent first.
    if (!pending.has(agentId)) generations.delete(agentId)
  }

  function isCurrent(own: PendingCompletion): boolean {
    return pending.get(own.agentId) === own
      && own.generation === (generations.get(own.agentId) ?? 0)
  }

  // Completion is tracked per agent: only the completing agent's own later
  // activity cancels its pending notification, and two agents finishing
  // together each keep their own. Legacy aggregate effects carry no agent and
  // are ignored here — every legacy transition an agented integration reports
  // arrives alongside its per-agent twin, which is the one this scheduler
  // answers to. The one exception is a legacy subagent start: it has no twin
  // by design (the parent could not be recovered), so untracked activity
  // cancels every pending completion rather than risk announcing a pane
  // whose delegated work is still busy.
  function handle(effect: StateMachineEffect, context?: Readonly<{ correlationId?: string }>): void {
    if (effect.type === "agent-subagent-start") {
      cancelPending(effect.agentId)
      return
    }
    if (effect.type === "subagent-start") {
      cancelPending()
      return
    }
    if (effect.type === "agent-state") {
      if (effect.state !== "idle") cancelPending(effect.agentId)
      return
    }
    if (effect.type === "agent-clear") {
      cancelPending(effect.agentId)
      return
    }
    if (effect.type !== "completion-eligible") return
    cancelPending(effect.agentId)
    const own: PendingCompletion = {
      generation: generations.get(effect.agentId) ?? 0,
      agentId: effect.agentId,
    }
    pending.set(effect.agentId, own)
    const completion: CompletionReference = {
      agentId: effect.agentId,
      sessionId: effect.sessionId,
      messageId: effect.messageId,
      ...(context?.correlationId ? { correlationId: context.correlationId } : {}),
    }
    const content = new Promise<string | undefined>((resolve) => {
      let settled = false
      const finish = (message: string | undefined) => {
        if (settled) return
        settled = true
        if (own.lookupTimer !== undefined) {
          clock.clearTimeout(own.lookupTimer)
          own.lookupTimer = undefined
        }
        resolve(message)
      }
      own.lookupTimer = clock.setTimeout(() => finish(undefined), LOOKUP_DEADLINE_MS)
      try {
        void dependencies.lookupMessage(completion)
          .then((response) => {
            try {
              finish(visibleText(response, completion))
            } catch {
              finish(undefined)
            }
          }, () => finish(undefined))
      } catch {
        finish(undefined)
      }
    })
    own.notificationTimer = clock.setTimeout(() => {
      own.notificationTimer = undefined
      void content.then((message) => {
        try {
          dependencies.enqueue(async () => {
            if (!isCurrent(own)) return
            try {
              await dependencies.notify(message || GENERIC_COMPLETION, completion)
            } catch {
              // A notification backend cannot reject into OpenCode.
            } finally {
              if (isCurrent(own)) {
                pending.delete(own.agentId)
                if (!pending.has(own.agentId)) generations.delete(own.agentId)
              }
            }
          })
        } catch {
          if (isCurrent(own)) {
            pending.delete(own.agentId)
            if (!pending.has(own.agentId)) generations.delete(own.agentId)
          }
        }
      })
    }, COMPLETION_DELAY_MS)
  }

  return {
    handle,
    dispose() {
      cancelPending()
    },
  }
}

function visibleText(
  response: MessageResponse | undefined,
  completion: CompletionReference,
): string | undefined {
  if (!response || !isRecord(response.info) || !Array.isArray(response.parts)) return undefined
  const info = response.info
  if (
    info.id !== completion.messageId
    || info.sessionID !== completion.sessionId
    || info.role !== "assistant"
    || info.summary === true
  ) {
    return undefined
  }

  const visibleParts = response.parts.flatMap((part) => {
    if (
      !isRecord(part)
      || part.type !== "text"
      || typeof part.text !== "string"
      || part.synthetic === true
      || part.ignored === true
    ) {
      return []
    }
    const text = sanitizeNotificationText(part.text)
    return text ? [text] : []
  })
  return sanitizeNotificationText(visibleParts.join("\n"))
}

export function sanitizeNotificationText(input: string): string | undefined {
  const text = input
    .replace(/\r\n?/g, "\n")
    .replace(/[\u0008\u000C]/g, " ")
    .replace(/[\u0000-\u0007\u000B\u000E-\u001F\u007F-\u009F]/g, "")
    .trim()
  if (!text) return undefined

  const characters = Array.from(text)
  if (characters.length <= NOTIFICATION_TEXT_MAX) return text
  const prefix = characters.slice(0, NOTIFICATION_TEXT_MAX).join("")
  const boundary = Math.max(
    prefix.lastIndexOf(" "),
    prefix.lastIndexOf("\n"),
    prefix.lastIndexOf("\t"),
  )
  return (boundary > 0 ? prefix.slice(0, boundary) : prefix).trimEnd()
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}
