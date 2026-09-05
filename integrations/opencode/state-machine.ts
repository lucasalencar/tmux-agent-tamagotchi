export type PaneState = "waiting" | "error" | "running" | "idle"
export type SessionKind = "root" | "delegated"
export type SessionStatus = "busy" | "retry" | "idle"

export type LifecycleEvent =
  | { type: "session-created"; sessionId: string; kind: SessionKind }
  | { type: "session-deleted"; sessionId: string; kind: SessionKind }
  | { type: "session-status"; sessionId: string; kind: SessionKind; status: SessionStatus }
  | { type: "session-error"; sessionId: string; kind: SessionKind; message?: string }
  | {
      type: "terminal-assistant-message"
      sessionId: string
      kind: SessionKind
      messageId: string
      finish?: string
    }
  | { type: "permission-asked"; requestId: string; sessionId: string; kind: SessionKind }
  | { type: "permission-replied"; requestId: string }

export type StateMachineEffect =
  | { type: "pane-state"; state: PaneState }
  | { type: "root-error"; sessionId: string; message?: string }
  | { type: "subagent-start"; sessionId: string }
  | { type: "subagent-stop"; sessionId: string }
  | { type: "completion-eligible"; sessionId: string; messageId: string }

type RootState = "error" | "running" | "idle"

export type LifecycleState = Readonly<{
  paneState: PaneState
  roots: ReadonlyMap<string, RootState>
  permissions: ReadonlyMap<string, string>
  activeDelegatedSessions: ReadonlySet<string>
  terminalAssistantMessages: ReadonlyMap<string, string>
  paneStatePublished: boolean
}>

export type Reduction = Readonly<{
  state: LifecycleState
  effects: StateMachineEffect[]
}>

export function createLifecycleState(): LifecycleState {
  return {
    paneState: "idle",
    roots: new Map(),
    permissions: new Map(),
    activeDelegatedSessions: new Set(),
    terminalAssistantMessages: new Map(),
    paneStatePublished: false,
  }
}

function establishesPaneState(event: LifecycleEvent): boolean {
  switch (event.type) {
    case "permission-asked":
      return true
    case "session-created":
    case "session-deleted":
    case "session-error":
    case "session-status":
      return event.kind === "root"
    case "permission-replied":
    case "terminal-assistant-message":
      return false
  }
}

export function reduceLifecycle(state: LifecycleState, event: LifecycleEvent): Reduction {
  const roots = new Map(state.roots)
  const permissions = new Map(state.permissions)
  const activeDelegatedSessions = new Set(state.activeDelegatedSessions)
  const terminalAssistantMessages = new Map(state.terminalAssistantMessages)
  let delegatedEffect: StateMachineEffect | undefined
  let completionEffect: StateMachineEffect | undefined
  if (event.type === "permission-asked") {
    if (!permissions.has(event.requestId)) {
      permissions.set(event.requestId, event.sessionId)
    }
  } else if (event.type === "permission-replied") {
    permissions.delete(event.requestId)
  } else if (event.type === "session-deleted") {
    if (event.kind === "root") {
      roots.delete(event.sessionId)
      terminalAssistantMessages.delete(event.sessionId)
    } else if (activeDelegatedSessions.delete(event.sessionId)) {
      delegatedEffect = { type: "subagent-stop", sessionId: event.sessionId }
    }
    permissions.forEach((sessionId, requestId) => {
      if (sessionId === event.sessionId) permissions.delete(requestId)
    })
  } else if (event.kind === "delegated") {
    if (event.type === "session-status") {
      if (event.status === "idle") {
        if (activeDelegatedSessions.delete(event.sessionId)) {
          delegatedEffect = { type: "subagent-stop", sessionId: event.sessionId }
        }
      } else if (!activeDelegatedSessions.has(event.sessionId)) {
        activeDelegatedSessions.add(event.sessionId)
        delegatedEffect = { type: "subagent-start", sessionId: event.sessionId }
      }
    } else if (event.type === "session-error" && activeDelegatedSessions.delete(event.sessionId)) {
      delegatedEffect = { type: "subagent-stop", sessionId: event.sessionId }
    }
  } else if (event.type === "terminal-assistant-message") {
    const current = roots.get(event.sessionId)
    if (
      event.kind === "root"
      && current === "running"
      && event.finish === "stop"
      && permissions.size === 0
      && activeDelegatedSessions.size === 0
      && !Array.from(roots).some(([sessionId, rootState]) =>
        sessionId !== event.sessionId && (rootState === "running" || rootState === "error"))
    ) {
      roots.set(event.sessionId, "idle")
      terminalAssistantMessages.delete(event.sessionId)
      completionEffect = {
        type: "completion-eligible",
        sessionId: event.sessionId,
        messageId: event.messageId,
      }
    } else {
      terminalAssistantMessages.set(event.sessionId, event.messageId)
    }
  } else if (event.type === "session-created") {
    const current = roots.get(event.sessionId)
    if (current === undefined || current === "error") roots.set(event.sessionId, "idle")
  } else if (event.type === "session-error") {
    roots.set(event.sessionId, "error")
    terminalAssistantMessages.delete(event.sessionId)
  } else {
    const current = roots.get(event.sessionId)
    roots.set(event.sessionId, event.status === "idle" ? "idle" : "running")
    if (event.status === "idle") {
      const messageId = terminalAssistantMessages.get(event.sessionId)
      if (current === "running" && messageId) {
        completionEffect = {
          type: "completion-eligible",
          sessionId: event.sessionId,
          messageId,
        }
      }
    }
    terminalAssistantMessages.delete(event.sessionId)
  }

  const rootStates = Array.from(roots.values())
  const paneState = permissions.size > 0
    ? "waiting"
    : rootStates.includes("error")
    ? "error"
    : rootStates.includes("running")
      ? "running"
      : "idle"
  if (paneState !== "idle" || activeDelegatedSessions.size > 0) completionEffect = undefined
  const shouldPublish =
    paneState !== state.paneState || (!state.paneStatePublished && establishesPaneState(event))
  const effects: StateMachineEffect[] = shouldPublish ? [{ type: "pane-state", state: paneState }] : []
  if (event.type === "session-error" && event.kind === "root") {
    effects.push({ type: "root-error", sessionId: event.sessionId, message: event.message })
  }
  if (delegatedEffect) effects.push(delegatedEffect)
  if (completionEffect) effects.push(completionEffect)
  return {
    state: {
      paneState,
      roots,
      permissions,
      activeDelegatedSessions,
      terminalAssistantMessages,
      paneStatePublished: state.paneStatePublished || shouldPublish,
    },
    effects,
  }
}
