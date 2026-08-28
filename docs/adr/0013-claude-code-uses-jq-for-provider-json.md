# The Claude Code integration uses jq for provider JSON

Claude Code sends hook payloads as JSON, including the complete `background_tasks` snapshot
used to reconcile leaked subagent ids. Proving that a snapshot is present, complete, correctly
typed and free of live subagents requires understanding JSON rather than scanning for a token.
A purpose-built POSIX awk recognizer provided that proof but introduced roughly two hundred
lines of parser implementation for one predicate.

The Claude Code integration therefore requires `jq` and expresses the predicate as a jq query.
This is an integration dependency, not an unconditional core dependency: the stable CLI still
accepts plain arguments and never reads provider payloads (ADR-0001), while Codex, OpenCode and
hand-wired integrations continue to work without jq unless logging is explicitly enabled as
described by ADR-0015. TPM and the plugin do not install system packages; the integration
documentation gives platform package-manager commands, and `tama doctor` checks jq when a
configured capability requires it.

## Consequences

Malformed, truncated or ambiguous snapshots still fail conservatively and preserve tracked
ids, now using a maintained JSON implementation instead of one embedded in the adapter. A
Claude Code setup must install jq separately, and a missing binary disables snapshot
reconciliation until fixed; other Claude events remain hook-safe, and doctor reports the
incomplete integration. CI installs jq explicitly on both supported platforms so the runtime
dependency cannot be supplied accidentally by a runner image.
