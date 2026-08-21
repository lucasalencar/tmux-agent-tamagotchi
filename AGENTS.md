## Agent skills

### Commits

This is a personal project: commit directly to `main`. Changes do not require a branch or
code review before committing.

### CI

Run test targets outside the agent sandbox from the first attempt: the suite starts tmux
servers whose sockets under `/private/tmp` are rejected by the sandbox.

Before considering any task that changes tracked files complete, verify the CI run for the
resulting commit (or its pull request) has concluded successfully. Report a blocked or failed
run as unfinished work rather than declaring the task done.

### Issue tracker

Issues tracked as GitHub Issues via `gh` CLI, against `lucasalencar/tmux-agent-tamagotchi`. See `docs/agents/issue-tracker.md`.

When a commit fully resolves an issue, include `Closes #<number>` in its body so GitHub closes the issue when the commit reaches the default branch.

### Domain docs

Single-context — `CONTEXT.md` + `docs/adr/` at repo root. See `docs/agents/domain.md`.
