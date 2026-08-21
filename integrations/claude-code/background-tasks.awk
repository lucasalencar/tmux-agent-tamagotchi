# Accept only a complete Claude Code payload whose authoritative task registry
# proves that no subagent remains. Any ambiguity exits nonzero so tracked ids are
# preserved rather than hiding work that may still be running.

function fail() { bad = 1; return 0 }

function ws(    c) {
  while (pos <= size) {
    c = substr(json, pos, 1)
    if (c !~ /[ \t\r\n]/) break
    pos++
  }
}

function string(    c, out, esc, hex) {
  if (substr(json, pos, 1) != "\"") return fail()
  pos++
  out = ""
  string_plain = 1
  while (pos <= size) {
    c = substr(json, pos, 1)
    if (c == "\"") {
      pos++
      string_value = out
      return 1
    }
    if (c ~ /[[:cntrl:]]/) return fail()
    if (c != "\\") {
      out = out c
      pos++
      continue
    }
    pos++
    if (pos > size) return fail()
    esc = substr(json, pos, 1)
    if (esc == "u") {
      hex = substr(json, pos + 1, 4)
      if (length(hex) != 4 || hex !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/)
        return fail()
      out = out "?"
      pos += 5
      string_plain = 0
      continue
    }
    if (esc !~ /^[\"\\\/bfnrt]$/) return fail()
    out = out esc
    pos++
    string_plain = 0
  }
  return fail()
}

function number(    rest) {
  rest = substr(json, pos)
  if (!match(rest, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/))
    return fail()
  pos += RLENGTH
  return 1
}

function value(    c) {
  ws()
  c = substr(json, pos, 1)
  if (c == "{") return object()
  if (c == "[") return array()
  if (c == "\"") return string()
  if (substr(json, pos, 4) == "true") { pos += 4; return 1 }
  if (substr(json, pos, 5) == "false") { pos += 5; return 1 }
  if (substr(json, pos, 4) == "null") { pos += 4; return 1 }
  return number()
}

function object() {
  if (substr(json, pos, 1) != "{") return fail()
  pos++
  ws()
  if (substr(json, pos, 1) == "}") { pos++; return 1 }
  while (!bad) {
    if (!string()) return 0
    ws()
    if (substr(json, pos, 1) != ":") return fail()
    pos++
    if (!value()) return 0
    ws()
    if (substr(json, pos, 1) == "}") { pos++; return 1 }
    if (substr(json, pos, 1) != ",") return fail()
    pos++
    ws()
  }
  return 0
}

function array() {
  if (substr(json, pos, 1) != "[") return fail()
  pos++
  ws()
  if (substr(json, pos, 1) == "]") { pos++; return 1 }
  while (!bad) {
    if (!value()) return 0
    ws()
    if (substr(json, pos, 1) == "]") { pos++; return 1 }
    if (substr(json, pos, 1) != ",") return fail()
    pos++
    ws()
  }
  return 0
}

function task(    key, key_plain, saw_type) {
  if (substr(json, pos, 1) != "{") return fail()
  pos++
  ws()
  if (substr(json, pos, 1) == "}") return fail()
  while (!bad) {
    if (!string()) return 0
    key = string_value
    key_plain = string_plain
    ws()
    if (substr(json, pos, 1) != ":") return fail()
    pos++
    ws()
    if (key_plain && key == "type") {
      if (saw_type || !string() || !string_plain ||
          string_value !~ /^[A-Za-z0-9_-]+$/) return fail()
      saw_type = 1
      if (string_value == "subagent") has_subagent = 1
    } else if (!value()) {
      return 0
    }
    ws()
    if (substr(json, pos, 1) == "}") {
      pos++
      return saw_type ? 1 : fail()
    }
    if (substr(json, pos, 1) != ",") return fail()
    pos++
    ws()
  }
  return 0
}

function tasks() {
  if (substr(json, pos, 1) != "[") return fail()
  pos++
  ws()
  if (substr(json, pos, 1) == "]") { pos++; return 1 }
  while (!bad) {
    if (!task()) return 0
    ws()
    if (substr(json, pos, 1) == "]") { pos++; return 1 }
    if (substr(json, pos, 1) != ",") return fail()
    pos++
    ws()
  }
  return 0
}

function root(    key, key_plain) {
  ws()
  if (substr(json, pos, 1) != "{") return fail()
  pos++
  ws()
  if (substr(json, pos, 1) == "}") { pos++; return 1 }
  while (!bad) {
    if (!string()) return 0
    key = string_value
    key_plain = string_plain
    ws()
    if (substr(json, pos, 1) != ":") return fail()
    pos++
    ws()
    if (key_plain && key == "background_tasks") {
      if (saw_tasks) return fail()
      saw_tasks = 1
      if (!tasks()) return 0
    } else if (!value()) {
      return 0
    }
    ws()
    if (substr(json, pos, 1) == "}") { pos++; return 1 }
    if (substr(json, pos, 1) != ",") return fail()
    pos++
    ws()
  }
  return 0
}

{
  json = json (NR == 1 ? "" : "\n") $0
}

END {
  size = length(json)
  pos = 1
  valid = root()
  ws()
  exit !(valid && !bad && pos == size + 1 && saw_tasks && !has_subagent)
}
