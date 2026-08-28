# The plugin does not make unrequested writes outside its own directory

Agent hooks are configured in files that live nowhere near the plugin, so they need an
absolute path to the CLI. The usual answer — and what the system this replaces effectively
did — is to symlink the binary into `~/.local/bin` on load. That means a tmux plugin performs
an unrequested write into `$HOME` every time the config is sourced, and it collides with the
already-taken binary name `tama` (npm `usik/tamagotchi`, crates.io `mlnja/tama`).

Instead the TPM entrypoint exports `@tama_bin`, and hook recipes ask tmux where the plugin
is. They invoke the discovered path directly and normalize a missing tmux server, an
unloaded plugin, or a hook failure to silent success. Nothing is installed, nothing is
shadowed, and the recipe works identically under TPM, a manual clone, a submodule, or a
symlinked worktree.

This restriction is about writes the plugin chooses on the user's behalf. It does not
prohibit writing diagnostic output to a destination the user explicitly configured: that
destination is an authorization to write there, not an installation side effect.

## Consequences

Every hook recipe still carries a tmux option lookup, because the plugin cannot centralize
the step needed to find its own executable without installing a stable launcher elsewhere.
The Claude Code integration, whose settings invoke the plugin's adapter rather than core
commands directly, keeps its operational guards out of user configuration: its recipe
attempts the quoted path, redirects errors, and falls back to success, while the discovered
plugin owns all behavior after dispatch. Recipes that call the core commands directly may
keep explicit guards so usage errors remain visible while those hooks are being authored.

The plugin still has nothing to offer someone who wants to type `tama` at a prompt. That is
acceptable: the CLI is an interface for hooks, not for humans, and the only human-facing
entry point (`doctor`) prints its own absolute path.

Runtime scratch data is not installation. The bounded label provider opens a private
temporary capture file and unlinks its name before running user code, so descendants
cannot retain the hook's output pipe. No named file survives the invocation.
