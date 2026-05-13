#!/usr/bin/env bash
#
# Mirror plugins/cpln/{skills,agents}/ into skills/ and agents/ at the
# repo root for Gemini.
#
# Why this exists:
#   Claude, Codex, and Cursor read their plugin root at plugins/cpln/, so
#   plugins/cpln/skills/ and plugins/cpln/agents/ work for them. Gemini
#   hardcodes <extension-root>/skills/ and <extension-root>/agents/ to
#   the repo root, and a flat-layout retry isn't viable because Claude
#   and Codex also auto-discover hooks/hooks.json there and choke on
#   Gemini's format. So we keep two roots and mirror the shared content
#   at build time. Slash commands take a different shape: .md files live
#   under plugins/cpln/commands/ for Claude/Codex/Cursor while .toml
#   files live under commands/ at the repo root for Gemini.
#
# Usage:
#   scripts/sync-gemini-content.sh           # rewrite skills/ and agents/
#   scripts/sync-gemini-content.sh --check   # fail if mirrors are stale
#
# Called by the pre-commit hook, scripts/bump-version.sh, and the CI
# release workflow (--check). Treat skills/ and agents/ at the repo root
# as generated artifacts: never edit them directly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MODE="${1:-sync}"
case "$MODE" in
  sync|--check) ;;
  *) echo "Usage: $0 [--check]" >&2; exit 1 ;;
esac

MIRRORS=(skills agents)

sync_one() {
  local name="$1"
  local src="$REPO_ROOT/plugins/cpln/$name"
  local dest="$REPO_ROOT/$name"

  [ -d "$src" ] || { echo "Error: source directory missing: $src" >&2; exit 1; }

  rm -rf "$dest"
  mkdir -p "$dest"
  # Copy the directory tree contents (subdirs + files) preserving structure.
  # Use a portable approach that works on BSD cp (macOS) and GNU cp (Linux).
  (cd "$src" && find . -mindepth 1 -print0 | while IFS= read -r -d '' entry; do
    target="$dest/${entry#./}"
    if [ -d "$entry" ]; then
      mkdir -p "$target"
    else
      cp "$entry" "$target"
    fi
  done)

  local count
  count="$(find "$dest" -type f | wc -l | tr -d ' ')"
  echo "Mirrored $count file(s) into $dest"
}

check_one() {
  local name="$1"
  local src="$REPO_ROOT/plugins/cpln/$name"
  local dest="$REPO_ROOT/$name"
  local tmp

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  (cd "$src" && find . -mindepth 1 -print0 | while IFS= read -r -d '' entry; do
    target="$tmp/${entry#./}"
    if [ -d "$entry" ]; then
      mkdir -p "$target"
    else
      cp "$entry" "$target"
    fi
  done)

  if ! diff -r "$dest" "$tmp" >/dev/null 2>&1; then
    echo "Error: $name/ at repo root is out of sync with plugins/cpln/$name/" >&2
    echo "       Run: scripts/sync-gemini-content.sh" >&2
    diff -rq "$dest" "$tmp" >&2 || true
    return 1
  fi
  echo "✓ $name/ mirror is in sync"
}

if [ "$MODE" = "--check" ]; then
  rc=0
  for name in "${MIRRORS[@]}"; do
    check_one "$name" || rc=1
  done
  exit "$rc"
fi

for name in "${MIRRORS[@]}"; do
  sync_one "$name"
done
