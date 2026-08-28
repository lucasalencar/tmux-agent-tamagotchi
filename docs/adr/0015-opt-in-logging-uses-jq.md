# Opt-in logging uses jq

When `TAMA_LOG_FILE` enables logging, the core uses `jq` to produce valid newline-delimited
JSON and obtain subsecond timestamps. This makes `jq` a dependency of the optional diagnostic
capability, not of normal plugin operation: without logging, commands incur no lookup or
formatting cost and continue to work without it. A maintained, widely used JSON tool is
preferred over adding a language runtime or implementing a custom JSON formatter.
