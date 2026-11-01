import { describe, expect, test } from "bun:test"

import { createEffectRunner, type ProcessExecutor, type ProcessResult } from "../effect-runner"

describe("tama effect runner", () => {
  test("marks public CLI effects with privacy-safe OpenCode lifecycle metadata", async () => {
    const environments: Array<Readonly<Record<string, string>> | undefined> = []
    const runner = createEffectRunner({
      execute: async (argv, environment) => {
        if (argv[0] !== "tmux") environments.push(environment)
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
    })

    await runner.run({ type: "pane-state", state: "waiting" }, { correlationId: "oc-1" })
    await runner.run({ type: "subagent-start", sessionId: "opaque-child" })

    expect(environments).toEqual([
      {
        TAMA_LOG_INTEGRATION: "opencode",
        TAMA_LOG_INTEGRATION_EVENT: "pane-state",
        TAMA_LOG_CORRELATION_ID: "oc-1",
      },
      { TAMA_LOG_INTEGRATION: "opencode", TAMA_LOG_INTEGRATION_EVENT: "subagent-start" },
    ])
  })

  test("records the native event boundary without misclassifying it as an effect", async () => {
    const calls: Array<{ argv: string[]; environment?: Readonly<Record<string, string>> }> = []
    const runner = createEffectRunner({
      execute: async (argv, environment) => {
        calls.push({ argv: [...argv], environment })
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
    })

    await runner.observeEvent({
      event: "session.error",
      outcome: "skipped",
      reason: "unknown_event",
      correlationId: "oc-event-1",
    })

    expect(calls[1]).toEqual({
      argv: [
        "/plugin/bin/tama",
        "hook",
        "opencode",
        "session.error",
        "skipped",
        "unknown_event",
      ],
      environment: { TAMA_LOG_CORRELATION_ID: "oc-event-1" },
    })
  })

  test("resolves the public CLI through tmux and invokes it only with argv", async () => {
    const calls: string[][] = []
    const execute: ProcessExecutor = async (argv) => {
      calls.push([...argv])
      return argv[0] === "tmux"
        ? { exitCode: 0, stdout: "/repo with spaces/bin/tama\n" }
        : { exitCode: 0, stdout: "" }
    }
    const completions: Array<{ agentId: string; sessionId: string; messageId: string }> = []
    const runner = createEffectRunner({
      execute,
      onCompletionEligible: async (completion) => {
        completions.push(completion)
      },
    })

    await runner.run({ type: "pane-state", state: "waiting" })
    await runner.run({ type: "agent-error", agentId: "root-a", message: "provider failed" })
    await runner.run({ type: "subagent-start", sessionId: "child; touch /tmp/not-executed" })
    await runner.run({ type: "subagent-stop", sessionId: "-child" })
    await runner.run({ type: "completion-eligible", agentId: "root-a", sessionId: "root-a", messageId: "message-a" })
    await runner.clearPane()

    expect(calls).toEqual([
      ["tmux", "show", "-gqv", "@tama_bin"],
      ["/repo with spaces/bin/tama", "state", "waiting", "OpenCode"],
      ["tmux", "show", "-gqv", "@tama_bin"],
      ["/repo with spaces/bin/tama", "notify", "--agent", "opencode-root-a", "--", "OpenCode", "provider failed"],
      ["tmux", "show", "-gqv", "@tama_bin"],
      ["/repo with spaces/bin/tama", "state", "subagent-start", "--", "child; touch /tmp/not-executed"],
      ["tmux", "show", "-gqv", "@tama_bin"],
      ["/repo with spaces/bin/tama", "state", "subagent-stop", "--", "-child"],
      ["tmux", "show", "-gqv", "@tama_bin"],
      ["/repo with spaces/bin/tama", "state", "clear", "--keep-agents"],
    ])
    expect(completions).toEqual([{ agentId: "root-a", sessionId: "root-a", messageId: "message-a" }])
  })

  test("contains missing executables, malformed paths, process failures, and completion failures", async () => {
    const results: Array<ProcessResult | Error> = [
      new Error("tmux missing"),
      { exitCode: 1, stdout: "" },
      { exitCode: 0, stdout: "/tmp/tama\nmalicious\n" },
    ]
    const execute: ProcessExecutor = async () => {
      const result = results.shift()
      if (result instanceof Error) throw result
      return result ?? { exitCode: 0, stdout: "" }
    }
    const runner = createEffectRunner({
      execute,
      onCompletionEligible: async () => {
        throw new Error("scheduler unavailable")
      },
    })

    await expect(runner.run({ type: "pane-state", state: "running" })).resolves.toBeUndefined()
    await expect(runner.run({ type: "agent-error", agentId: "root-a" })).resolves.toBeUndefined()
    await expect(runner.clearPane()).resolves.toBeUndefined()
    await expect(runner.run({
      type: "completion-eligible",
      agentId: "root-a",
      sessionId: "root-a",
      messageId: "message-a",
    })).resolves.toBeUndefined()
  })

  test("sanitizes and bounds agent error banners with a safe fallback", async () => {
    const calls: string[][] = []
    const runner = createEffectRunner({
      execute: async (argv) => {
        calls.push([...argv])
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
    })
    const longError = `Provider failed\u0000\r\n${"detail ".repeat(100)}tail`

    await runner.run({ type: "agent-error", agentId: "root-a", message: longError })
    await runner.run({ type: "agent-error", agentId: "root-b", message: "\u0000\u0007 " })

    const messages = calls
      .filter((argv) => argv[1] === "notify")
      .map((argv) => argv[argv.indexOf("--") + 2])
    expect(messages[0]).toStartWith("Provider failed\n")
    expect(messages[0]).not.toContain("\u0000")
    expect(Array.from(messages[0]).length).toBeLessThanOrEqual(500)
    expect(messages[1]).toBe("OpenCode session failed")
  })

  test("targets an explicitly resolved pane and falls back when resolution fails", async () => {
    const calls: string[][] = []
    const runner = createEffectRunner({
      execute: async (argv) => {
        calls.push([...argv])
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
      resolvePane: async () => "%pane-a",
    })

    await runner.run({ type: "pane-state", state: "running" })
    await runner.notify("Done.", { agentId: "root-a" })
    await runner.clearPane()

    expect(calls.filter((argv) => argv[0] !== "tmux")).toEqual([
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--pane", "%pane-a"],
      ["/plugin/bin/tama", "notify", "--agent", "opencode-root-a", "--pane", "%pane-a", "--", "OpenCode", "Done."],
      ["/plugin/bin/tama", "state", "clear", "--keep-agents", "--pane", "%pane-a"],
    ])

    const fallbackCalls: string[][] = []
    const fallback = createEffectRunner({
      execute: async (argv) => {
        fallbackCalls.push([...argv])
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
      resolvePane: async () => {
        throw new Error("tmux unavailable")
      },
    })

    // With an explicit resolver (v2 knows its directory) an unresolvable pane
    // skips state writes instead of leaking them onto the process pane, while
    // notifications still go out unattributed.
    await fallback.run({ type: "pane-state", state: "running" })
    await fallback.run({ type: "subagent-start", sessionId: "child-a" })
    await fallback.run({ type: "agent-error", agentId: "root-a", message: "boom" })
    await fallback.notify("Done.", { agentId: "root-a" })
    await fallback.clearPane()

    expect(fallbackCalls.filter((argv) => argv[0] !== "tmux")).toEqual([
      ["/plugin/bin/tama", "notify", "--agent", "opencode-root-a", "--", "OpenCode", "boom"],
      ["/plugin/bin/tama", "notify", "--agent", "opencode-root-a", "--", "OpenCode", "Done."],
    ])
  })

  test("keeps the legacy process-pane fallback without an explicit resolver", async () => {
    const calls: string[][] = []
    const runner = createEffectRunner({
      execute: async (argv) => {
        calls.push([...argv])
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
    })

    await runner.run({ type: "pane-state", state: "running" })
    await runner.clearPane()

    expect(calls.filter((argv) => argv[0] !== "tmux")).toEqual([
      ["/plugin/bin/tama", "state", "running", "OpenCode"],
      ["/plugin/bin/tama", "state", "clear", "--keep-agents"],
    ])
  })

  test("addresses per-agent effects at their own entry", async () => {
    const calls: string[][] = []
    const runner = createEffectRunner({
      execute: async (argv) => {
        calls.push([...argv])
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
      resolvePane: async () => "%pane-a",
    })

    await runner.run({ type: "agent-state", agentId: "root-a", state: "running" })
    await runner.run({ type: "agent-subagent-start", agentId: "root-a", subagentId: "child-a" })
    await runner.run({ type: "agent-subagent-stop", agentId: "root-a", subagentId: "child-a" })
    await runner.run({ type: "agent-clear", agentId: "root-a" })
    await runner.run({ type: "agents-reconcile", agentIds: ["root-a", "root-b"] })
    await runner.run({ type: "agents-reconcile", agentIds: [] })
    await runner.run({ type: "agent-error", agentId: "root-a", message: "boom" })

    expect(calls.filter((argv) => argv[0] !== "tmux")).toEqual([
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--agent", "opencode-root-a", "--pane", "%pane-a"],
      ["/plugin/bin/tama", "state", "subagent-start", "--agent", "opencode-root-a", "--pane", "%pane-a", "--", "child-a"],
      ["/plugin/bin/tama", "state", "subagent-stop", "--agent", "opencode-root-a", "--pane", "%pane-a", "--", "child-a"],
      ["/plugin/bin/tama", "state", "clear", "--agent", "opencode-root-a", "--pane", "%pane-a"],
      ["/plugin/bin/tama", "state", "agent-reconcile", "--namespace", "opencode-", "--pane", "%pane-a", "--", "opencode-root-a", "opencode-root-b"],
      ["/plugin/bin/tama", "state", "agent-reconcile", "--namespace", "opencode-", "--pane", "%pane-a", "--"],
      ["/plugin/bin/tama", "notify", "--agent", "opencode-root-a", "--pane", "%pane-a", "--", "OpenCode", "boom"],
    ])
  })

  test("namespaces every CLI-visible agent id so integrations cannot collide", async () => {
    const calls: string[][] = []
    const runner = createEffectRunner({
      execute: async (argv) => {
        calls.push([...argv])
        return argv[0] === "tmux"
          ? { exitCode: 0, stdout: "/plugin/bin/tama\n" }
          : { exitCode: 0, stdout: "" }
      },
      resolvePane: async () => "%pane-a",
    })

    // A bare session id must never reach the CLI: another integration
    // reporting the same raw id would address this integration's entry.
    await runner.run({ type: "agent-state", agentId: "ses_shared", state: "running" })
    await runner.notify("Done.", { agentId: "ses_shared" })

    for (const argv of calls.filter((call) => call[0] !== "tmux")) {
      const agentIndex = argv.indexOf("--agent")
      expect(agentIndex).toBeGreaterThan(-1)
      expect(argv[agentIndex + 1].startsWith("opencode-")).toBe(true)
    }
    expect(calls.filter((argv) => argv[0] !== "tmux")).toEqual([
      ["/plugin/bin/tama", "state", "running", "OpenCode", "--agent", "opencode-ses_shared", "--pane", "%pane-a"],
      ["/plugin/bin/tama", "notify", "--agent", "opencode-ses_shared", "--pane", "%pane-a", "--", "OpenCode", "Done."],
    ])
  })
})
