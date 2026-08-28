---
name: diagnose-tamagotchi
description: Diagnose reported Tamagotchi bugs, intermittent lifecycle failures, incorrect event order, concurrency problems, or missing State and attention behavior from the lifecycle Log and responsible code. Use for investigation, not implementation.
---

# Diagnose Tamagotchi

Produce an evidence-backed diagnosis while preserving the repository, tmux runtime, agents, and
Log exactly as found. Read [`docs/log.md`](../../../docs/log.md) before interpreting records.

## Investigation

1. Establish the symptom, approximate time range, affected tmux pane/window IDs, integration,
   and whether `TAMA_LOG_FILE` was inherited by the relevant processes. Run `tama doctor` through
   the configured plugin when available; diagnostics are read-only.
2. Resolve the configured Log path from the reporting process or information the user supplied.
   Ask for the path or a collected copy when it cannot be observed. Keep the original untouched;
   place any filtered copies outside the repository.
3. Validate every selected line with `jq`. Narrow by time, tmux identity, integration, then
   `correlation_id`; retain line numbers from the original Log. Prefer the smallest evidence set
   that spans the symptom.
4. Reconstruct physical arrival order and causal order separately. Pair starts/completions by
   `operation_id`, follow nesting through `parent_operation_id`, compare state before/after, and
   account for every `skipped` or `failed` outcome. Treat a missing completion as evidence of a
   possible interruption, not proof of one.
5. Locate the behavior-owning boundary with repository search and compare the observations with
   current code and the recorded plugin `version`. Account for logging's synchronous timing cost
   before attributing a concurrency change to the uninstrumented system.
6. Report four clearly separated parts: observed evidence; hypothesis and confidence; evidence
   gaps or competing explanations; and the smallest next experiment. Cite Log line number,
   timestamp, event, and correlation ID for every important conclusion.

This workflow grants read-only investigation authority. Enabling logging, restarting tmux or an
agent, editing code, mutating the Log, or applying a fix requires a separate explicit request.
