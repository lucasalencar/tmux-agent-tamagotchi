export type PaneState = "waiting" | "error" | "running" | "idle"
export type SessionKind = "root" | "delegated"
export type SessionStatus = "busy" | "retry" | "idle"

export type LifecycleEvent =
  | { type: "session-created"; sessionId: string; kind: SessionKind; parentId?: string; directory?: string }
  | {
    type: "session-deleted"
    sessionId: string
    kind: SessionKind
    parentId?: string
    directory?: string
  }
  | {
    type: "session-status"
    sessionId: string
    kind: SessionKind
    status: SessionStatus
    parentId?: string
    directory?: string
  }
  | { type: "execution-started"; sessionId: string; kind: SessionKind; parentId?: string; directory?: string }
  | { type: "user-message"; sessionId: string; kind: SessionKind; messageId: string; directory?: string }
  | {
    type: "session-error"
    sessionId: string
    kind: SessionKind
    message?: string
    parentId?: string
    directory?: string
  }
  | {
    type: "terminal-assistant-message"
    sessionId: string
    kind: SessionKind
    messageId: string
    finish?: string
    directory?: string
  }
  | {
    type: "permission-asked"
    requestId: string
    sessionId: string
    kind: SessionKind
    parentId?: string
    directory?: string
  }
  | { type: "permission-replied"; requestId: string; directory?: string }

// Per-agent reports. Every root session owns one agent entry, addressed by
// its session id; the core derives waiting/error/running/idle/background per
// entry and draws one icon each. The legacy pane-state aggregate is still
// emitted alongside, unchanged, because `tama list` rows are per pane.
export type StateMachineEffect =
  | { type: "pane-state"; state: PaneState }
  | { type: "agent-state"; agentId: string; state: PaneState }
  | { type: "agent-clear"; agentId: string }
  | { type: "agents-reconcile"; agentIds: string[] }
  | { type: "agent-error"; agentId: string; message?: string }
  | { type: "subagent-start"; sessionId: string }
  | { type: "subagent-stop"; sessionId: string }
  | { type: "agent-subagent-start"; agentId: string; subagentId: string }
  | { type: "agent-subagent-stop"; agentId: string; subagentId: string }
  | { type: "completion-eligible"; agentId: string; sessionId: string; messageId: string }

type RootState = "error" | "running" | "idle"

type PermissionRecord = Readonly<{ sessionId: string; rootId: string | undefined }>

export type LifecycleState = Readonly<{
  paneState: PaneState
  roots: ReadonlyMap<string, RootState>
  // Delegated sessions known to be busy, grouped by the root they belong to.
  // A delegated session whose parent could not be recovered lives only in
  // the global set below and falls back to pane-level tracking.
  rootDelegated: ReadonlyMap<string, ReadonlySet<string>>
  permissions: ReadonlyMap<string, PermissionRecord>
  activeDelegatedSessions: ReadonlySet<string>
  terminalAssistantMessages: ReadonlyMap<string, string>
  completedRootMessages: ReadonlyMap<string, string>
  rootUserMessages: ReadonlyMap<string, string>
  paneStatePublished: boolean
  emittedAgents: ReadonlyMap<string, PaneState>
}>

export type Reduction = Readonly<{
  state: LifecycleState
  effects: StateMachineEffect[]
}>

export function createLifecycleState(): LifecycleState {
  return {
    paneState: "idle",
    roots: new Map(),
    rootDelegated: new Map(),
    permissions: new Map(),
    activeDelegatedSessions: new Set(),
    terminalAssistantMessages: new Map(),
    completedRootMessages: new Map(),
    rootUserMessages: new Map(),
    paneStatePublished: false,
    emittedAgents: new Map(),
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
    case "execution-started":
    case "user-message":
      return event.kind === "root"
    case "permission-replied":
    case "terminal-assistant-message":
      return false
  }
}

// The root a delegated session belongs to, when the adapter recovered it.
function owningRoot(event: { kind: SessionKind; sessionId: string; parentId?: string }): string | undefined {
  if (event.kind === "root") return event.sessionId
  return event.parentId
}

function permissionsForRoot(
  permissions: ReadonlyMap<string, PermissionRecord>,
  rootId: string,
): boolean {
  let found = false
  permissions.forEach((record) => {
    if (record.rootId === rootId) found = true
  })
  return found
}

function delegatedForRoot(
  rootDelegated: ReadonlyMap<string, ReadonlySet<string>>,
  rootId: string,
): ReadonlySet<string> {
  return rootDelegated.get(rootId) ?? new Set<string>()
}

export function reduceLifecycle(state: LifecycleState, event: LifecycleEvent): Reduction {
  const roots = new Map(state.roots)
  const rootDelegated = new Map<string, Set<string>>()
  Array.from(state.rootDelegated).forEach(([rootId, subs]) => rootDelegated.set(rootId, new Set(subs)))
  const permissions = new Map(state.permissions)
  const activeDelegatedSessions = new Set(state.activeDelegatedSessions)
  const terminalAssistantMessages = new Map(state.terminalAssistantMessages)
  const completedRootMessages = new Map(state.completedRootMessages)
  const rootUserMessages = new Map(state.rootUserMessages)
  const emittedAgents = new Map(state.emittedAgents)
  // An agent-state effect is emitted at most once per reduction: several code
  // paths below may touch the same root, and the last computation wins.
  let agentEffect: Extract<StateMachineEffect, { type: "agent-state" }> | undefined
  let agentClear: Extract<StateMachineEffect, { type: "agent-clear" }> | undefined
  let legacyDelegatedEffect: Extract<StateMachineEffect, { type: "subagent-start" } | { type: "subagent-stop" }> | undefined
  let agentDelegatedEffect:
    | Extract<StateMachineEffect, { type: "agent-subagent-start" } | { type: "agent-subagent-stop" }>
    | undefined
  let completionEffect: Extract<StateMachineEffect, { type: "completion-eligible" }> | undefined
  let agentError: Extract<StateMachineEffect, { type: "agent-error" }> | undefined

  function trackDelegatedStart(sessionId: string, rootId: string | undefined): void {
    activeDelegatedSessions.add(sessionId)
    if (rootId === undefined) {
      legacyDelegatedEffect = { type: "subagent-start", sessionId }
      return
    }
    let subs = rootDelegated.get(rootId)
    if (!subs) {
      subs = new Set()
      rootDelegated.set(rootId, subs)
    }
    if (!subs.has(sessionId)) {
      subs.add(sessionId)
      agentDelegatedEffect = { type: "agent-subagent-start", agentId: rootId, subagentId: sessionId }
    }
  }

  function trackDelegatedStop(sessionId: string, rootId: string | undefined): void {
    const wasActive = activeDelegatedSessions.delete(sessionId)
    if (rootId !== undefined) {
      const subs = rootDelegated.get(rootId)
      if (subs?.delete(sessionId)) {
        agentDelegatedEffect = { type: "agent-subagent-stop", agentId: rootId, subagentId: sessionId }
        return
      }
    }
    if (wasActive) {
      legacyDelegatedEffect = { type: "subagent-stop", sessionId }
    }
  }

  // The owning root of the session this event belongs to. Root events own
  // themselves; delegated events own their recovered parent.
  let eventRoot: string | undefined
  if (event.type !== "permission-replied") {
    eventRoot = owningRoot(event)
  }

  if (event.type === "permission-asked") {
    if (!permissions.has(event.requestId)) {
      const rootId = owningRoot(event)
      permissions.set(event.requestId, { sessionId: event.sessionId, rootId })
      if (rootId !== undefined && !roots.has(rootId)) roots.set(rootId, "idle")
    }
  } else if (event.type === "permission-replied") {
    const record = permissions.get(event.requestId)
    // Recompute the owning root after the release: its waiting overlay may
    // have lifted back to running, idle, or a persistent error.
    if (record?.rootId !== undefined) eventRoot = record.rootId
    permissions.delete(event.requestId);
  } else if (event.type === "session-deleted") {
    if (event.kind === "root") {
      roots.delete(event.sessionId)
      rootDelegated.delete(event.sessionId)
      terminalAssistantMessages.delete(event.sessionId)
      completedRootMessages.delete(event.sessionId)
      rootUserMessages.delete(event.sessionId)
      agentClear = { type: "agent-clear", agentId: event.sessionId }
    } else {
      trackDelegatedStop(event.sessionId, owningRoot(event))
    }
    permissions.forEach((record, requestId) => {
      if (record.sessionId === event.sessionId) permissions.delete(requestId)
    })
  } else if (event.type === "execution-started") {
    // An explicit execution start is a definitive new turn, unlike trailing
    // step/tool busy noise after a completion. It must clear the previous
    // turn's completion guard so the second prompt reports running again.
    if (event.kind === "delegated") {
      if (!activeDelegatedSessions.has(event.sessionId)) {
        activeDelegatedSessions.add(event.sessionId)
        delegatedEffect = { type: "subagent-start", sessionId: event.sessionId }
      }
    } else {
      roots.set(event.sessionId, "running")
      terminalAssistantMessages.delete(event.sessionId)
      completedRootMessages.delete(event.sessionId)
    }
  } else if (event.kind === "delegated") {
    if (event.type === "session-status") {
      if (event.status === "idle") {
        trackDelegatedStop(event.sessionId, owningRoot(event))
      } else {
        // A delegated session first seen without a recoverable parent lives
        // in the global set; once the parent is known it moves under its
        // root, so the pane keeps one tracking per live subagent.
        const rootId = owningRoot(event)
        if (rootId === undefined) {
          if (!activeDelegatedSessions.has(event.sessionId)) trackDelegatedStart(event.sessionId, undefined)
        } else if (!delegatedForRoot(rootDelegated, rootId).has(event.sessionId)) {
          trackDelegatedStart(event.sessionId, rootId)
        } else if (!activeDelegatedSessions.has(event.sessionId)) {
          activeDelegatedSessions.add(event.sessionId)
        }
      }
    } else if (event.type === "session-error") {
      trackDelegatedStop(event.sessionId, owningRoot(event))
    }
  } else if (event.type === "user-message") {
    if (event.kind === "root") {
      const duplicate = rootUserMessages.get(event.sessionId) === event.messageId
      rootUserMessages.set(event.sessionId, event.messageId)
      if (!duplicate) {
        roots.set(event.sessionId, "running")
        terminalAssistantMessages.delete(event.sessionId)
        completedRootMessages.delete(event.sessionId)
      }
    }
  } else if (event.type === "terminal-assistant-message") {
    const current = roots.get(event.sessionId)
    if (
      event.kind === "root"
      && current === "running"
      && event.finish === "stop"
      && !permissionsForRoot(permissions, event.sessionId)
      && delegatedForRoot(rootDelegated, event.sessionId).size === 0
    ) {
      roots.set(event.sessionId, "idle")
      terminalAssistantMessages.delete(event.sessionId)
      completedRootMessages.set(event.sessionId, event.messageId)
      completionEffect = {
        type: "completion-eligible",
        agentId: event.sessionId,
        sessionId: event.sessionId,
        messageId: event.messageId,
      }
    } else {
      terminalAssistantMessages.set(event.sessionId, event.messageId)
    }
  } else if (event.type === "session-created") {
    // Only roots establish presence: a delegated creation names a session the
    // pane tracks only once it shows activity, an error, or a permission.
    if (event.kind === "root") {
      const current = roots.get(event.sessionId)
      if (current === undefined || current === "error") roots.set(event.sessionId, "idle")
    }
  } else if (event.type === "session-error") {
    roots.set(event.sessionId, "error")
    terminalAssistantMessages.delete(event.sessionId)
    completedRootMessages.delete(event.sessionId)
  } else {
    const completed = completedRootMessages.has(event.sessionId)
    if (!completed || event.status === "idle") {
      const current = roots.get(event.sessionId)
      roots.set(event.sessionId, event.status === "idle" ? "idle" : "running")
      if (event.status === "idle") {
        const messageId = terminalAssistantMessages.get(event.sessionId)
        if (
          current === "running"
          && messageId
          && !permissionsForRoot(permissions, event.sessionId)
          && delegatedForRoot(rootDelegated, event.sessionId).size === 0
        ) {
          completionEffect = {
            type: "completion-eligible",
            agentId: event.sessionId,
            sessionId: event.sessionId,
            messageId,
          }
        }
        completedRootMessages.delete(event.sessionId)
      }
      terminalAssistantMessages.delete(event.sessionId)
    }
  }

  // The per-agent report for the owning root, when this event names one.
  // Stateless entries (tracked subagents, pending permissions) still establish
  // the agent: presence without a completed state reads as idle. Events that
  // neither establish nor require presence (a deletion, a stored terminal
  // message, a replied permission) never resurrect a gone agent.
  // Events that neither establish presence nor require it (a deletion, a
  // stored terminal message, a replied permission) never resurrect a gone
  // agent: without a roots entry they report nothing.
  const establishes = event.type !== "session-deleted"
    && event.type !== "terminal-assistant-message"
    && event.type !== "permission-replied"
  if (agentClear) {
    emittedAgents.delete(agentClear.agentId)
  } else if (eventRoot !== undefined && (roots.has(eventRoot) || establishes)) {
    const base = roots.get(eventRoot) ?? "idle"
    const agentState: PaneState = permissionsForRoot(permissions, eventRoot)
      ? "waiting"
      : base === "error"
        ? "error"
        : base === "running"
          ? "running"
          : "idle"
    if (emittedAgents.get(eventRoot) !== agentState) {
      emittedAgents.set(eventRoot, agentState)
      agentEffect = { type: "agent-state", agentId: eventRoot, state: agentState }
    }
  }

  // The legacy aggregate is still reported alongside, unchanged: `tama list`
  // rows are per pane, and it is what keeps them working.
  const rootStates = Array.from(roots.values())
  const paneState = permissions.size > 0
    ? "waiting"
    : rootStates.includes("error")
    ? "error"
    : rootStates.includes("running")
      ? "running"
      : "idle"
  const shouldPublish =
    paneState !== state.paneState || (!state.paneStatePublished && establishesPaneState(event))
  const effects: StateMachineEffect[] = shouldPublish ? [{ type: "pane-state", state: paneState }] : []
  if (agentEffect) effects.push(agentEffect)
  if (agentClear) effects.push(agentClear)
  if (event.type === "session-error" && event.kind === "root") {
    effects.push({ type: "agent-error", agentId: event.sessionId, message: event.message })
  }
  if (legacyDelegatedEffect) effects.push(legacyDelegatedEffect)
  if (agentDelegatedEffect) effects.push(agentDelegatedEffect)
  if (completionEffect) {
    const rootId = completionEffect.sessionId
    const quiescent =
      !permissionsForRoot(permissions, rootId) && delegatedForRoot(rootDelegated, rootId).size === 0
    if (quiescent) effects.push(completionEffect)
  }
  return {
    state: {
      paneState,
      roots,
      rootDelegated,
      permissions,
      activeDelegatedSessions,
      terminalAssistantMessages,
      completedRootMessages,
      rootUserMessages,
      paneStatePublished: state.paneStatePublished || shouldPublish,
      emittedAgents,
    },
    effects,
  }
}
