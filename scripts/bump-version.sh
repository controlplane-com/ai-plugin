#!/usr/bin/env bash
#
# Cut a release from develop: bump the plugin version across the manifests,
# promote the CHANGELOG [Unreleased] section, commit, tag, and push develop,
# main (fast-forwarded to the release commit), and the tag in one atomic push.
# The tag push triggers the release workflow.
#
# Usage: scripts/bump-version.sh <X.Y.Z> [--dry-run]
#
#   --dry-run   run every check and print what the release would do; changes nothing
#
# Run it on develop, clean and in sync with origin, with the release notes
# already under [Unreleased] in CHANGELOG.md. When the release names MCP tools
# that production does not serve yet, deploy the MCP to production first.
#
# Files updated (kept in lockstep):
#   - plugins/cpln/.claude-plugin/plugin.json   .version
#   - .claude-plugin/marketplace.json           .plugins[0].version
#   - plugins/cpln/.codex-plugin/plugin.json    .version
#   - plugins/cpln/.cursor-plugin/plugin.json   .version
#   - .cursor-plugin/marketplace.json           .metadata.version
#   - .cursor-plugin/marketplace.json           .plugins[0].version
#   - plugins/cpln/plugin.json                  .version
#   - CHANGELOG.md                       [Unreleased] -> [X.Y.Z] - YYYY-MM-DD,
#                                        plus a fresh empty [Unreleased] above it
#
# Dependencies: git, jq, node, awk (BSD or GNU), date.

set -euo pipefail

RELEASE_BRANCH="develop"
PRODUCTION_BRANCH="main"
REMOTE="origin"

MANIFESTS=(
  "plugins/cpln/.claude-plugin/plugin.json:.version"
  ".claude-plugin/marketplace.json:.plugins[0].version"
  "plugins/cpln/.codex-plugin/plugin.json:.version"
  "plugins/cpln/.cursor-plugin/plugin.json:.version"
  ".cursor-plugin/marketplace.json:.metadata.version"
  ".cursor-plugin/marketplace.json:.plugins[0].version"
  "plugins/cpln/plugin.json:.version"
)

usage() {
  echo "Usage: $0 <X.Y.Z> [--dry-run]" >&2
  echo "Example: $0 1.1.0" >&2
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

VERSION=""
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -*) usage ;;
    *) [ -z "$VERSION" ] || usage; VERSION="$arg" ;;
  esac
done

[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be semver X.Y.Z (got: $VERSION)"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

for tool in git jq node; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

TAG="v$VERSION"
TODAY="$(date +%Y-%m-%d)"

# Preflight: every check runs before anything changes.

branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "$RELEASE_BRANCH" ] || fail "releases are cut from $RELEASE_BRANCH (currently on $branch)"

git diff --quiet && git diff --cached --quiet || fail "working tree has uncommitted changes; commit or stash first"

git fetch --quiet --tags "$REMOTE" "$RELEASE_BRANCH" "$PRODUCTION_BRANCH"

[ "$(git rev-parse HEAD)" = "$(git rev-parse "$REMOTE/$RELEASE_BRANCH")" ] \
  || fail "$RELEASE_BRANCH is not in sync with $REMOTE/$RELEASE_BRANCH; pull or push first"

git merge-base --is-ancestor "$REMOTE/$PRODUCTION_BRANCH" HEAD \
  || fail "$REMOTE/$PRODUCTION_BRANCH has commits $RELEASE_BRANCH lacks, so it cannot fast-forward; merge it into $RELEASE_BRANCH first"

if git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
  fail "tag $TAG already exists"
fi

current="$(jq -r '.version' plugins/cpln/.claude-plugin/plugin.json)"
highest="$(printf '%s\n' "$current" "$VERSION" | sort -V | tail -n 1)"
[ "$VERSION" != "$current" ] && [ "$highest" = "$VERSION" ] || fail "$VERSION is not above the current version $current"

unreleased_entries="$(awk '/^## \[Unreleased\]/ { inside = 1; next } /^## \[/ { inside = 0 } inside && /^- / { count++ } END { print count + 0 }' CHANGELOG.md)"
[ "$unreleased_entries" -gt 0 ] || fail "CHANGELOG.md has no entries under [Unreleased]; add the release notes there first"

node scripts/check-tool-mentions.mjs >/dev/null || fail "scripts/check-tool-mentions.mjs failed; run it to see the stale tool mentions"

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
Dry run: every check passed. The release would:
  1. Bump $current to $VERSION in ${#MANIFESTS[@]} manifest fields and promote [Unreleased] ($unreleased_entries entries) to [$VERSION] - $TODAY.
  2. Commit "Bump version to $VERSION" on $RELEASE_BRANCH and tag it $TAG.
  3. Run: git push --atomic $REMOTE HEAD:refs/heads/$RELEASE_BRANCH HEAD:refs/heads/$PRODUCTION_BRANCH refs/tags/$TAG
EOF
  exit 0
fi

# Bump.

bump_json() {
  local file="$1" path="$2" tmp
  tmp="$(mktemp)"
  jq --arg v "$VERSION" "$path = \$v" "$file" > "$tmp"
  mv "$tmp" "$file"
}

files=()
for spec in "${MANIFESTS[@]}"; do
  bump_json "${spec%%:*}" "${spec#*:}"
  files+=("${spec%%:*}")
done

# Promote [Unreleased] to the release and open a fresh, empty [Unreleased] above it.
awk -v ver="$VERSION" -v date="$TODAY" '
  /^## \[Unreleased\]/ && !promoted {
    print "## [Unreleased]"
    print ""
    print "## [" ver "] - " date
    promoted = 1
    next
  }
  { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
files+=("CHANGELOG.md")

for spec in "${MANIFESTS[@]}"; do
  file="${spec%%:*}"
  path="${spec#*:}"
  actual="$(jq -r "$path" "$file")"
  [ "$actual" = "$VERSION" ] || fail "post-bump mismatch in $file ($path = $actual, expected $VERSION)"
done

# Commit, tag, and push.

git add "${files[@]}"
git commit --quiet -m "Bump version to $VERSION"
git tag "$TAG"

if ! git push --atomic "$REMOTE" "HEAD:refs/heads/$RELEASE_BRANCH" "HEAD:refs/heads/$PRODUCTION_BRANCH" "refs/tags/$TAG"; then
  cat >&2 <<EOF
Error: the push was rejected, so nothing changed on $REMOTE.
The release commit and tag $TAG exist only locally. To retry, fix the cause and run:
  git push --atomic $REMOTE HEAD:refs/heads/$RELEASE_BRANCH HEAD:refs/heads/$PRODUCTION_BRANCH refs/tags/$TAG
To abandon it instead:
  git tag -d $TAG && git reset --hard HEAD~1
EOF
  exit 1
fi

git fetch --quiet "$REMOTE" "$PRODUCTION_BRANCH:$PRODUCTION_BRANCH" \
  || echo "Note: local $PRODUCTION_BRANCH was not updated; run: git fetch $REMOTE $PRODUCTION_BRANCH:$PRODUCTION_BRANCH"

cat <<EOF
Released $VERSION: pushed $RELEASE_BRANCH, $PRODUCTION_BRANCH, and $TAG.
The release workflow now validates the manifests and publishes the GitHub Release from the [$VERSION] notes.
EOF
