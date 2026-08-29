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
  observeEvent(observation: LogObservation): Promise<void>
  run(effect: StateMachineEffect, context?: LogContext): Promise<void>
  notify(message: string, context?: LogContext): Promise<void>
  clearPane(): Promise<void>
}>

export type LogContext = Readonly<{ correlationId: string }>
export type LogObservation = LogContext & Readonly<{
  event: string
  outcome: "applied" | "skipped"
  reason?: "unknown_event" | "malformed_event"
}>

const AGENT_NAME = "OpenCode"
const GENERIC_ERROR = "OpenCode session failed"
const GENERIC_COMPLETION = "OpenCode finished its turn"

export function createEffectRunner(dependencies: EffectRunnerDependencies): EffectRunner {
  async function invokeTama(
    args: readonly string[],
    integrationEvent: string,
    context?: LogContext,
    classifyEffect = true,
  ): Promise<void> {
    try {
      const resolved = await dependencies.execute(["tmux", "show", "-gqv", "@tama_bin"])
      if (resolved.exitCode !== 0) return
      const executable = parseExecutable(resolved.stdout)
      if (!executable) return
      await dependencies.execute([executable, ...args], {
        ...(classifyEffect ? {
          TAMA_LOG_INTEGRATION: "opencode",
          TAMA_LOG_INTEGRATION_EVENT: integrationEvent,
        } : {}),
        ...(context ? { TAMA_LOG_CORRELATION_ID: context.correlationId } : {}),
      })
    } catch {
      // An integration must never make OpenCode fail because tmux or tama is unavailable.
    }
  }

  async function run(effect: StateMachineEffect, context?: LogContext): Promise<void> {
    try {
      switch (effect.type) {
        case "pane-state":
          await invokeTama(["state", effect.state, AGENT_NAME], effect.type, context)
          break
        case "root-error":
          await invokeTama([
            "notify",
            "--",
            AGENT_NAME,
            sanitizeNotificationText(effect.message ?? "") ?? GENERIC_ERROR,
          ], effect.type, context)
          break
        case "subagent-start":
        case "subagent-stop":
          await invokeTama(["state", effect.type, "--", effect.sessionId], effect.type, context)
          break
        case "completion-eligible":
          await dependencies.onCompletionEligible?.({
            sessionId: effect.sessionId,
            messageId: effect.messageId,
            ...(context ? { correlationId: context.correlationId } : {}),
          })
          break
      }
    } catch {
      // Completion scheduling is another operational boundary and follows the same policy.
    }
  }

  return {
    observeEvent: (observation) => invokeTama([
      "hook",
      "opencode",
      observation.event,
      observation.outcome,
      ...(observation.reason ? [observation.reason] : []),
    ], observation.event, observation, false),
    run,
    notify: (message, context) => invokeTama([
      "notify",
      "--",
      AGENT_NAME,
      sanitizeNotificationText(message) ?? GENERIC_COMPLETION,
    ], "completion-notification", context),
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
