#!/usr/bin/env bash
# SessionStart hook for the Control Plane plugin (Claude Code + Codex).
#
# Concatenates every `plugins/cpln/rules/*.md` whose YAML frontmatter sets
# `alwaysApply: true`, then emits the hook payload that both clients
# expect on stdout:
#
#   { "hookSpecificOutput": {
#       "hookEventName": "SessionStart",
#       "additionalContext": "<concatenated rules>"
#   } }
#
# Uses awk (POSIX-mandated) for JSON string escaping so the hook has zero
# optional runtime dependencies. Never exits non-zero: a failed inject
# must not block session startup.

set -u

R="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
rules_dir="$R/rules"
[ -d "$rules_dir" ] || exit 0

files=()
for f in "$rules_dir"/*.md; do
  [ -f "$f" ] || continue
  if sed -n '/^---$/,/^---$/p' "$f" \
      | grep -qE '^alwaysApply:[[:space:]]*true[[:space:]]*$'; then
    files+=("$f")
  fi
done

[ "${#files[@]}" -eq 0 ] && exit 0

cat "${files[@]}" | awk '
BEGIN {
  printf "{\"hookSpecificOutput\":{"
  printf "\"hookEventName\":\"SessionStart\","
  printf "\"additionalContext\":\""
  first = 1
}
{
  gsub(/\\/, "\\\\")
  gsub(/"/, "\\\"")
  gsub(/\t/, "\\t")
  gsub(/\r/, "\\r")
  if (first) { first = 0; printf "%s", $0 }
  else       { printf "\\n%s", $0 }
}
END {
  printf "\"}}\n"
}
'
