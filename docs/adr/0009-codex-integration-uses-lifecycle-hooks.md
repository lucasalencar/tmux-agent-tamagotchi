# The Codex integration uses lifecycle hooks

The Codex integration observes only official lifecycle hooks. The app server exposes richer
turn status, including failures, but is experimental and would require the plugin to control
how Codex is launched; `notify` is limited to completed turns, while transcripts and logs are
not stable interfaces. Consequently, the integration accepts that it cannot report `error`
until Codex exposes a reliable hook for it rather than inferring failures from internal state.
