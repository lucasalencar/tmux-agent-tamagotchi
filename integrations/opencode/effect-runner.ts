import { sanitizeNotificationText, type CompletionReference } from "./completion-scheduler"
import type { StateMachineEffect } from "./state-machine"

export type ProcessResult = Readonly<{
  exitCode: number
  stdout: string
}>

export type ProcessEnvironment = Readonly<Record<string, string>>
export type ProcessExecutor = (
  argv: readonly string[],
  environment?: ProcessEnvironment,
) => Promise<ProcessResult>

export type EffectRunnerDependencies = Readonly<{
  execute: ProcessExecutor
  onCompletionEligible?(completion: CompletionReference): Promise<void>
}>

export type EffectRunner = Readonly<{
  run(effect: StateMachineEffect): Promise<void>
  notify(message: string): Promise<void>
  clearPane(): Promise<void>
}>

const AGENT_NAME = "OpenCode"
const GENERIC_ERROR = "OpenCode session failed"
const GENERIC_COMPLETION = "OpenCode finished its turn"

export function createEffectRunner(dependencies: EffectRunnerDependencies): EffectRunner {
  async function invokeTama(args: readonly string[], integrationEvent: string): Promise<void> {
    try {
      const resolved = await dependencies.execute(["tmux", "show", "-gqv", "@tama_bin"])
      if (resolved.exitCode !== 0) return
      const executable = parseExecutable(resolved.stdout)
      if (!executable) return
      await dependencies.execute([executable, ...args], {
        TAMA_LOG_INTEGRATION: "opencode",
        TAMA_LOG_INTEGRATION_EVENT: integrationEvent,
      })
    } catch {
      // An integration must never make OpenCode fail because tmux or tama is unavailable.
    }
  }

  async function run(effect: StateMachineEffect): Promise<void> {
    try {
      switch (effect.type) {
        case "pane-state":
          await invokeTama(["state", effect.state, AGENT_NAME], "pane-state")
          break
        case "root-error":
          await invokeTama([
            "notify",
            "--",
            AGENT_NAME,
            sanitizeNotificationText(effect.message ?? "") ?? GENERIC_ERROR,
          ], "root-error")
          break
        case "subagent-start":
        case "subagent-stop":
          await invokeTama(["state", effect.type, "--", effect.sessionId], effect.type)
          break
        case "completion-eligible":
          await dependencies.onCompletionEligible?.({
            sessionId: effect.sessionId,
            messageId: effect.messageId,
          })
          break
      }
    } catch {
      // Completion scheduling is another operational boundary and follows the same policy.
    }
  }

  return {
    run,
    notify: (message) => invokeTama([
      "notify",
      "--",
      AGENT_NAME,
      sanitizeNotificationText(message) ?? GENERIC_COMPLETION,
    ], "completion-notification"),
    clearPane: () => invokeTama(["state", "clear"], "dispose"),
  }
}

export const executeWithBun: ProcessExecutor = async (argv, environment) => {
  const child = Bun.spawn([...argv], {
    env: environment ? { ...Bun.env, ...environment } : undefined,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "ignore",
  })
  const [stdout, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    child.exited,
  ])
  return { exitCode, stdout }
}

function parseExecutable(stdout: string): string | undefined {
  const executable = stdout.replace(/\r?\n$/, "")
  if (!executable || /[\0\r\n]/.test(executable)) return undefined
  return executable
}
