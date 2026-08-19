# Integrations may use a native entrypoint

Integrations live outside the stable core contract, but they do not have to be shell adapters
invoked through `tama hook`. When an agent's native plugin runtime provides materially more
reliable lifecycle tracking, an integration may use that runtime and call the public `tama`
commands directly. OpenCode therefore keeps its TypeScript plugin, in-process state machine,
and debounce under `integrations/opencode/`. Its Bun test runtime, TypeScript configuration,
dependencies, and lockfile remain inside that directory; its additional toolchain and upstream
compatibility remain isolated to that best-effort integration and do not change the core.
This replaces only ADR-0002's shell-only restriction; integrations remain outside the stable
contract and all agent-specific behavior remains under `integrations/`.
