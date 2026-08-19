import { describe, expect, test } from "bun:test"

import {
  createCompletionScheduler,
  type MessageResponse,
} from "../completion-scheduler"
import { FakeClock } from "./fake-clock"

describe("completion scheduler", () => {
  test("notifies with the exact visible response ten seconds after eligible completion", async () => {
    const clock = new FakeClock()
    const notifications: string[] = []
    const lookups: Array<{ sessionId: string; messageId: string }> = []
    const scheduler = createCompletionScheduler({
      clock,
      lookupMessage: async (completion) => {
        lookups.push(completion)
        return message("root-a", "message-a", [
          { type: "text", text: "Finished **safely**." },
        ])
      },
      notify: async (text) => {
        notifications.push(text)
      },
    })

    scheduler.handle({ type: "completion-eligible", sessionId: "root-a", messageId: "message-a" })
    await clock.advance(9_999)
    expect(notifications).toEqual([])

    await clock.advance(1)
    expect(lookups).toEqual([{ sessionId: "root-a", messageId: "message-a" }])
    expect(notifications).toEqual(["Finished **safely**."])
  })

  test("new pane activity at 9.9 seconds cancels the pending completion", async () => {
    const clock = new FakeClock()
    const notifications: string[] = []
    const scheduler = createCompletionScheduler({
      clock,
      lookupMessage: async () => message("root-a", "message-a", [
        { type: "text", text: "stale completion" },
      ]),
      notify: async (text) => {
        notifications.push(text)
      },
    })

    scheduler.handle({ type: "completion-eligible", sessionId: "root-a", messageId: "message-a" })
    await clock.advance(9_900)
    scheduler.handle({ type: "pane-state", state: "running" })
    await clock.advance(10_000)

    expect(notifications).toEqual([])
  })

  test("a subagent starting at 9.9 seconds cancels the pending completion", async () => {
    const clock = new FakeClock()
    const notifications: string[] = []
    const scheduler = createCompletionScheduler({
      clock,
      lookupMessage: async () => message("root-a", "message-a", [
        { type: "text", text: "stale completion" },
      ]),
      notify: async (text) => {
        notifications.push(text)
      },
    })

    scheduler.handle({ type: "completion-eligible", sessionId: "root-a", messageId: "message-a" })
    await clock.advance(9_900)
    scheduler.handle({ type: "subagent-start", sessionId: "child-a" })
    await clock.advance(10_000)

    expect(notifications).toEqual([])
  })

  test("duplicate idle state does not restart the completion delay", async () => {
    const clock = new FakeClock()
    const notifications: string[] = []
    const scheduler = createCompletionScheduler({
      clock,
      lookupMessage: async () => message("root-a", "message-a", [
        { type: "text", text: "done" },
      ]),
      notify: async (text) => {
        notifications.push(text)
      },
    })

    scheduler.handle({ type: "completion-eligible", sessionId: "root-a", messageId: "message-a" })
    await clock.advance(5_000)
    scheduler.handle({ type: "pane-state", state: "idle" })
    await clock.advance(4_999)
    expect(notifications).toEqual([])
    await clock.advance(1)

    expect(notifications).toEqual(["done"])
  })

  test("uses the generic completion text when exact message lookup exceeds two seconds", async () => {
    const clock = new FakeClock()
    const lookup = deferred<MessageResponse | undefined>()
    const notifications: string[] = []
    const scheduler = createCompletionScheduler({
      clock,
      lookupMessage: async () => lookup.promise,
      notify: async (text) => {
        notifications.push(text)
      },
    })

    scheduler.handle({ type: "completion-eligible", sessionId: "root-a", messageId: "message-a" })
    await clock.advance(9_999)
    expect(notifications).toEqual([])
    await clock.advance(1)

    expect(notifications).toEqual(["OpenCode finished its turn"])
    lookup.resolve(message("root-a", "message-a", [{ type: "text", text: "too late" }]))
    await clock.advance(0)
    expect(notifications).toEqual(["OpenCode finished its turn"])
  })

  test("uses exact content when lookup completes just before the two-second deadline", async () => {
    const clock = new FakeClock()
    const lookup = deferred<MessageResponse | undefined>()
    const notifications: string[] = []
    const scheduler = createCompletionScheduler({
      clock,
      lookupMessage: async () => lookup.promise,
      notify: async (text) => {
        notifications.push(text)
      },
    })

    scheduler.handle({ type: "completion-eligible", sessionId: "root-a", messageId: "message-a" })
    await clock.advance(1_999)
    lookup.resolve(message("root-a", "message-a", [{ type: "text", text: "just in time" }]))
    await clock.advance(8_001)

    expect(notifications).toEqual(["just in time"])
  })

  test("includes only ordered visible text from the exact terminal assistant message", async () => {
    const clock = new FakeClock()
    const notifications: string[] = []
    const response = message("root-a", "message-a", [
      { type: "reasoning", text: "private chain of thought" },
      { type: "text", text: "  First **visible** line\r\n" },
      { type: "tool", state: { output: "secret tool output" } },
      { type: "text", text: "synthetic", synthetic: true },
      { type: "text", text: "ignored", ignored: true },
      { type: "metadata", text: "structured content" },
      { type: "compaction", text: "summary" },
      { type: "text", text: "Second\tline\u0007  " },
    ])
    const scheduler = createCompletionScheduler({
      clock,
      lookupMessage: async () => response,
      notify: async (text) => {
        notifications.push(text)
      },
    })

    scheduler.handle({ type: "completion-eligible", sessionId: "root-a", messageId: "message-a" })
    await clock.advance(10_000)

    expect(notifications).toEqual(["First **visible** line\nSecond\tline"])
  })

  test.each([
    ["lookup failure", async () => { throw new Error("SDK unavailable") }],
    ["wrong message identity", async () => message("root-b", "message-a", [
      { type: "text", text: "another session" },
    ])],
    ["compaction summary", async () => ({
      ...message("root-a", "message-a", [{ type: "text", text: "compressed history" }]),
      info: { id: "message-a", sessionID: "root-a", role: "assistant", summary: true },
    })],
    ["empty visible content", async () => message("root-a", "message-a", [
      { type: "reasoning", text: "private" },
      { type: "text", text: " \u0000\u0007 " },
      { type: "text", text: "hidden", ignored: true },
    ])],
    ["malformed message parts", async () => ({
      info: { id: "message-a", sessionID: "root-a", role: "assistant" },
      parts: undefined,
    }) as unknown as MessageResponse],
  ] as const)("uses fallback for %s", async (_case, lookupMessage) => {
    const clock = new FakeClock()
    const notifications: string[] = []
    const scheduler = createCompletionScheduler({
      clock,
      lookupMessage,
      notify: async (text) => {
        notifications.push(text)
      },
    })

    scheduler.handle({ type: "completion-eligible", sessionId: "root-a", messageId: "message-a" })
    await clock.advance(10_000)

    expect(notifications).toEqual(["OpenCode finished its turn"])
  })

  test("preserves Unicode, Markdown and line breaks while removing controls and capping at a word boundary", async () => {
    const clock = new FakeClock()
    const notifications: string[] = []
    const longText = `✅ **result**\u0000\r\n${"word ".repeat(120)}tail`
    const scheduler = createCompletionScheduler({
      clock,
      lookupMessage: async () => message("root-a", "message-a", [
        { type: "text", text: longText },
      ]),
      notify: async (text) => {
        notifications.push(text)
      },
    })

    scheduler.handle({ type: "completion-eligible", sessionId: "root-a", messageId: "message-a" })
    await clock.advance(10_000)

    const [notification] = notifications
    expect(notification).toStartWith("✅ **result**\nword ")
    expect(notification).not.toContain("\u0000")
    expect(Array.from(notification).length).toBeLessThanOrEqual(500)
    expect(notification.endsWith("word")).toBe(true)
  })

  test("a newer concurrent completion owns the pane generation", async () => {
    const clock = new FakeClock()
    const firstLookup = deferred<MessageResponse | undefined>()
    const notifications: string[] = []
    const scheduler = createCompletionScheduler({
      clock,
      lookupMessage: async ({ messageId }) => messageId === "message-a"
        ? firstLookup.promise
        : message("root-b", "message-b", [{ type: "text", text: "second result" }]),
      notify: async (text) => {
        notifications.push(text)
      },
    })

    scheduler.handle({ type: "completion-eligible", sessionId: "root-a", messageId: "message-a" })
    await clock.advance(1_000)
    scheduler.handle({ type: "completion-eligible", sessionId: "root-b", messageId: "message-b" })
    firstLookup.resolve(message("root-a", "message-a", [{ type: "text", text: "stale result" }]))
    await clock.advance(9_999)
    expect(notifications).toEqual([])
    await clock.advance(1)

    expect(notifications).toEqual(["second result"])
  })

  test("disposal cancels timers and suppresses late lookup work", async () => {
    const clock = new FakeClock()
    const lookup = deferred<MessageResponse | undefined>()
    const notifications: string[] = []
    const scheduler = createCompletionScheduler({
      clock,
      lookupMessage: async () => lookup.promise,
      notify: async (text) => {
        notifications.push(text)
      },
    })

    scheduler.handle({ type: "completion-eligible", sessionId: "root-a", messageId: "message-a" })
    await clock.advance(1_999)
    scheduler.dispose()
    lookup.resolve(message("root-a", "message-a", [{ type: "text", text: "too late" }]))
    await clock.advance(20_000)

    expect(notifications).toEqual([])
  })
})

function message(
  sessionId: string,
  messageId: string,
  parts: unknown[],
): MessageResponse {
  return {
    info: { id: messageId, sessionID: sessionId, role: "assistant" },
    parts,
  }
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => {
    resolve = done
  })
  return { promise, resolve }
}
