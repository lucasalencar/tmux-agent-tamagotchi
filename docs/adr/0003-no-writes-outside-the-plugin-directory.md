# The plugin never writes outside its own directory

Agent hooks are configured in files that live nowhere near the plugin, so they need an
absolute path to the CLI. The usual answer — and what the system this replaces effectively
did — is to symlink the binary into `~/.local/bin` on load. That means a tmux plugin performs
an unrequested write into `$HOME` every time the config is sourced, and it collides with the
already-taken binary name `tama` (npm `usik/tamagotchi`, crates.io `mlnja/tama`).

Instead the TPM entrypoint exports `@tama_bin`, and hook recipes ask tmux where the plugin
is: `[ -n "$TMUX" ] || exit 0` followed by `"$(tmux show -gv @tama_bin)" state running …`.
Nothing is installed, nothing is shadowed, and the recipe works identically under TPM, a
manual clone, a submodule, or a symlinked worktree.

## Consequences

Every hook recipe carries a guard line and a subshell, and the plugin has nothing to offer
someone who wants to type `tama` at a prompt. That is acceptable: the CLI is an interface for
hooks, not for humans, and the only human-facing entry point (`doctor`) prints its own
absolute path.
