#!/usr/bin/env bash
#
# Bump the plugin version across all four manifests and promote the
# CHANGELOG [Unreleased] section into a versioned release section.
#
# Usage: scripts/bump-version.sh <X.Y.Z>
#
# Files updated (kept in lockstep):
#   - plugins/cpln/.claude-plugin/plugin.json   .version
#   - .claude-plugin/marketplace.json           .plugins[0].version
#   - plugins/cpln/.codex-plugin/plugin.json    .version
#   - plugins/cpln/.cursor-plugin/plugin.json   .version
#   - .cursor-plugin/marketplace.json           .metadata.version
#   - .cursor-plugin/marketplace.json           .plugins[0].version
#   - gemini-extension.json                     .version
#   - CHANGELOG.md                       [Unreleased] -> [X.Y.Z] - YYYY-MM-DD,
#                                        plus a fresh empty [Unreleased] above it
#   - skills/, agents/                   regenerated from plugins/cpln/ via
#                                        scripts/sync-gemini-content.sh
#
# Dependencies: jq, awk (BSD or GNU), date.

set -euo pipefail

usage() {
  echo "Usage: $0 <X.Y.Z>" >&2
  echo "Example: $0 1.1.0" >&2
  exit 1
}

VERSION="${1:-}"
[ -n "$VERSION" ] || usage

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be semver X.Y.Z (got: $VERSION)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }

# Fail fast if the working tree is dirty so the bump produces a clean diff.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: working tree has uncommitted changes; commit or stash first" >&2
  exit 1
fi

TODAY="$(date +%Y-%m-%d)"

bump_json() {
  local file="$1" path="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg v "$VERSION" "$path = \$v" "$file" > "$tmp"
  mv "$tmp" "$file"
}

bump_json plugins/cpln/.claude-plugin/plugin.json '.version'
bump_json .claude-plugin/marketplace.json '.plugins[0].version'
bump_json plugins/cpln/.codex-plugin/plugin.json '.version'
bump_json plugins/cpln/.cursor-plugin/plugin.json '.version'
bump_json .cursor-plugin/marketplace.json '.metadata.version'
bump_json .cursor-plugin/marketplace.json '.plugins[0].version'
bump_json gemini-extension.json '.version'

# Refresh the Gemini-facing skills/ and agents/ mirrors at the repo root
# from plugins/cpln/. The pre-commit hook keeps these in sync during
# normal development; this is the belt-and-suspenders at release time.
"$REPO_ROOT/scripts/sync-gemini-content.sh"

# Promote the [Unreleased] section in CHANGELOG.md to [X.Y.Z] - DATE
# and seed a fresh empty [Unreleased] block above it.
awk -v ver="$VERSION" -v date="$TODAY" '
  BEGIN { promoted = 0 }
  /^## \[Unreleased\]/ && !promoted {
    print "## [Unreleased]"
    print ""
    print "### Added"
    print ""
    print "### Changed"
    print ""
    print "### Fixed"
    print ""
    print "### Removed"
    print ""
    print "## [" ver "] - " date
    promoted = 1
    next
  }
  { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

# Sanity-check: every manifest agrees on $VERSION.
for spec in \
  "plugins/cpln/.claude-plugin/plugin.json:.version" \
  ".claude-plugin/marketplace.json:.plugins[0].version" \
  "plugins/cpln/.codex-plugin/plugin.json:.version" \
  "plugins/cpln/.cursor-plugin/plugin.json:.version" \
  ".cursor-plugin/marketplace.json:.metadata.version" \
  ".cursor-plugin/marketplace.json:.plugins[0].version" \
  "gemini-extension.json:.version"; do
  file="${spec%%:*}"
  path="${spec#*:}"
  actual="$(jq -r "$path" "$file")"
  if [ "$actual" != "$VERSION" ]; then
    echo "Error: post-bump mismatch in $file ($path = $actual, expected $VERSION)" >&2
    exit 1
  fi
done

cat <<EOF
Bumped to $VERSION across:
  - plugins/cpln/.claude-plugin/plugin.json
  - .claude-plugin/marketplace.json
  - plugins/cpln/.codex-plugin/plugin.json
  - plugins/cpln/.cursor-plugin/plugin.json
  - .cursor-plugin/marketplace.json (metadata.version and plugins[0].version)
  - gemini-extension.json
  - CHANGELOG.md (Unreleased -> [$VERSION] - $TODAY)

Next steps:
  1. Review the diff:        git diff
  2. Edit CHANGELOG.md to fill in the release notes under [$VERSION].
  3. Stage and commit:       git add -A && git commit -m "Bump version to $VERSION"
  4. Tag and push:           git tag v$VERSION && git push && git push --tags
  5. The release workflow validates the manifests, runs plugin checks,
     and creates the GitHub Release using the matching CHANGELOG section.
EOF
