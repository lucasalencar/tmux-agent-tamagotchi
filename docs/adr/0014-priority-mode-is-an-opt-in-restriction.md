# Priority mode is an opt-in restriction

With no priority assigned, every tmux window remains eligible to request attention, preserving
the plugin's existing behaviour. Assigning priority to at least one tmux window activates
Priority mode: Notifications become selective, while configuration independently chooses
whether Flags are selective or ambient. The mode is derived from the per-window priorities
rather than stored separately.

Treating an empty priority set as a strict allowlist would silently disable attention before
the user opted into the workflow. Coupling Flag and Notification would avoid that ambiguity
but remove the useful middle ground where secondary work stays visible inside tmux without
interrupting the user outside it.
