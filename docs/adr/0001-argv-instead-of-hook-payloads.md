# The CLI takes arguments, not hook payloads

The system this plugin generalizes was built around Claude Code's hook format: commands read
JSON on stdin and pull `.message`, `.notification_type` and `.agent_id` out of it with `jq`.
Every other agent had to fake that shape to fit — Gemini's hooks echo a hand-written JSON
object, OpenCode assembles one in TypeScript, and one Claude Code hook pipes through
`jq -c '. + {message: ...}'` just to inject a string. Three of four callers were constructing
JSON to feed a JSON parser.

So the core CLI takes plain arguments (`tama notify <agent> <message>`,
`tama state subagent-start <id>`) and knows nothing about any agent's payload format.
Callers that receive JSON extract from it themselves. `jq` leaves the dependency list
entirely, the CLI is testable without fixtures, and no agent's schema is privileged.

## Consequences

Hook recipes get longer and less pretty — the `jq -r '.message'` that used to be hidden
inside the plugin is now visible in the user's config. That extraction is absorbed by the
per-agent adapters in `integrations/` (see ADR-0002), so it stays in one testable place
rather than being copy-pasted into everyone's `settings.json`.
