import type { CompletionClock } from "../completion-scheduler"

export class FakeClock implements CompletionClock {
  private now = 0
  private nextId = 1
  private timers = new Map<number, { at: number; callback: () => void }>()

  setTimeout(callback: () => void, delayMs: number): unknown {
    const id = this.nextId++
    this.timers.set(id, { at: this.now + delayMs, callback })
    return id
  }

  clearTimeout(handle: unknown): void {
    this.timers.delete(handle as number)
  }

  async advance(ms: number): Promise<void> {
    const target = this.now + ms
    await flushMicrotasks()
    while (true) {
      const due = Array.from(this.timers.entries())
        .filter(([, timer]) => timer.at <= target)
        .sort((left, right) => left[1].at - right[1].at || left[0] - right[0])[0]
      if (!due) break
      this.now = due[1].at
      this.timers.delete(due[0])
      due[1].callback()
      await flushMicrotasks()
    }
    this.now = target
    await flushMicrotasks()
  }
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}
