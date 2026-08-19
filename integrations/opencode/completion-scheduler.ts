import type { StateMachineEffect } from "./state-machine"

export type CompletionReference = Readonly<{
  sessionId: string
  messageId: string
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
  notify(message: string): Promise<void>
  clock?: CompletionClock
}>

export type CompletionScheduler = Readonly<{
  handle(effect: StateMachineEffect): void
  dispose(): void
}>

const COMPLETION_DELAY_MS = 10_000
const LOOKUP_DEADLINE_MS = 2_000
const GENERIC_COMPLETION = "OpenCode finished its turn"
const NOTIFICATION_TEXT_MAX = 500

type PendingCompletion = {
  generation: number
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
  let generation = 0
  let pending: PendingCompletion | undefined

  function cancelPending(): void {
    generation += 1
    if (pending?.lookupTimer !== undefined) clock.clearTimeout(pending.lookupTimer)
    if (pending?.notificationTimer !== undefined) clock.clearTimeout(pending.notificationTimer)
    pending = undefined
  }

  function handle(effect: StateMachineEffect): void {
    if (effect.type === "subagent-start") {
      cancelPending()
      return
    }
    if (effect.type === "pane-state") {
      if (effect.state !== "idle") cancelPending()
      return
    }
    if (effect.type !== "completion-eligible") return
    cancelPending()
    const own: PendingCompletion = { generation }
    pending = own
    const completion = { sessionId: effect.sessionId, messageId: effect.messageId }
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
            if (pending !== own || own.generation !== generation) return
            try {
              await dependencies.notify(message || GENERIC_COMPLETION)
            } catch {
              // A notification backend cannot reject into OpenCode.
            } finally {
              if (pending === own && own.generation === generation) pending = undefined
            }
          })
        } catch {
          if (pending === own && own.generation === generation) pending = undefined
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
