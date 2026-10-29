#!/usr/bin/env bash
#
# Cut a release from develop in two steps, since main takes changes only
# through an approved pull request:
#
#   1. scripts/bump-version.sh <X.Y.Z>
#      Bump the plugin version across the manifests, promote the CHANGELOG
#      [Unreleased] section, commit "Bump version to X.Y.Z" on develop, push
#      develop, and open the release pull request from develop to main.
#   2. scripts/bump-version.sh <X.Y.Z> --finish
#      Once that pull request merges (Squash and merge or Rebase and merge):
#      tag the release on main and push the tag, which triggers the release
#      workflow, then move develop onto main's new commits so the next release
#      pull request holds only new work.
#
# Usage: scripts/bump-version.sh <X.Y.Z> [--finish] [--dry-run]
#
#   --finish    run step 2
#   --dry-run   run every check and print what the step would do; changes nothing
#
# Run it on develop, clean and in sync with origin. Step 1 needs the release
# notes already under [Unreleased] in CHANGELOG.md. When the release names MCP
# tools that production does not serve yet, deploy the MCP to production first.
#
# Files updated by step 1 (kept in lockstep):
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
# Dependencies: git, gh (signed in, step 1 only), jq, node, awk (BSD or GNU), date.

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
  echo "Usage: $0 <X.Y.Z> [--finish] [--dry-run]" >&2
  echo "Example: $0 1.1.0, then after the release pull request merges: $0 1.1.0 --finish" >&2
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

VERSION=""
DRY_RUN=0
FINISH=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --finish) FINISH=1 ;;
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

# Preflight shared by both steps: every check runs before anything changes.

branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "$RELEASE_BRANCH" ] || fail "releases are cut from $RELEASE_BRANCH (currently on $branch)"

git diff --quiet && git diff --cached --quiet || fail "working tree has uncommitted changes; commit or stash first"

git ls-remote --exit-code --heads "$REMOTE" "$RELEASE_BRANCH" >/dev/null \
  || fail "$REMOTE has no $RELEASE_BRANCH branch; push yours back first: git push $REMOTE $RELEASE_BRANCH"

git fetch --quiet --tags "$REMOTE" "$RELEASE_BRANCH" "$PRODUCTION_BRANCH"

[ "$(git rev-parse HEAD)" = "$(git rev-parse "$REMOTE/$RELEASE_BRANCH")" ] \
  || fail "$RELEASE_BRANCH is not in sync with $REMOTE/$RELEASE_BRANCH; pull or push first"

if git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
  fail "tag $TAG already exists"
fi

# Step 2: tag the merged release on main and move develop onto main's commits.

if [ "$FINISH" -eq 1 ]; then
  released="$(git show "$REMOTE/$PRODUCTION_BRANCH:plugins/cpln/.claude-plugin/plugin.json" | jq -r '.version')"
  [ "$released" = "$VERSION" ] \
    || fail "$REMOTE/$PRODUCTION_BRANCH is at $released, not $VERSION; merge the release pull request first"

  release_commit="$(git rev-parse "$REMOTE/$PRODUCTION_BRANCH")"

  # Squash and Rebase and merge both write new commits on main, so develop still
  # holds the old ones. The newest develop commit with main's content is the one
  # that merged; only the commits after it move onto main.
  before="$(git rev-parse HEAD)"
  if git merge-base --is-ancestor "$release_commit" HEAD; then
    merged="$release_commit"
  else
    released_tree="$(git rev-parse "$release_commit^{tree}")"
    merged="$(git log --format='%H %T' "$release_commit..HEAD" | awk -v tree="$released_tree" '$2 == tree && !found { print $1; found = 1 }')"
  fi
  [ -n "$merged" ] \
    || fail "no $RELEASE_BRANCH commit has the content of $REMOTE/$PRODUCTION_BRANCH, so the merge changed something; nothing changed. Compare them: git diff $before $REMOTE/$PRODUCTION_BRANCH"
  later="$(git rev-list --count "$merged..HEAD")"

  if [ "$DRY_RUN" -eq 1 ]; then
    cat <<EOF
Dry run: every check passed. Finishing the release would:
  1. Tag $REMOTE/$PRODUCTION_BRANCH ($(git rev-parse --short "$release_commit")) as $TAG and push the tag, which triggers the release workflow.
  2. Move $RELEASE_BRANCH onto $REMOTE/$PRODUCTION_BRANCH: $(git rev-parse --short "$merged") is the commit that merged, and the $later after it are replayed. Then push $RELEASE_BRANCH with --force-with-lease.
EOF
    exit 0
  fi

  git tag "$TAG" "$release_commit"
  if ! git push --quiet "$REMOTE" "refs/tags/$TAG"; then
    git tag -d "$TAG" >/dev/null
    fail "the tag push was rejected, so nothing changed on $REMOTE"
  fi
  echo "Pushed $TAG on $(git rev-parse --short "$release_commit"); the release workflow now publishes the GitHub Release."

  realign_by_hand="git rebase --onto $REMOTE/$PRODUCTION_BRANCH $merged && git push --force-with-lease=$RELEASE_BRANCH:$before $REMOTE HEAD:refs/heads/$RELEASE_BRANCH"
  if ! git rebase --quiet --onto "$REMOTE/$PRODUCTION_BRANCH" "$merged"; then
    git rebase --abort
    fail "the $later $RELEASE_BRANCH commits after the merge do not replay cleanly onto $REMOTE/$PRODUCTION_BRANCH; $TAG is released, and $RELEASE_BRANCH is unchanged. Realign it by hand: $realign_by_hand"
  fi
  if ! git diff --quiet "$before" HEAD; then
    git reset --quiet --hard "$before"
    fail "moving $RELEASE_BRANCH onto $REMOTE/$PRODUCTION_BRANCH would change its content, so it is unchanged; $TAG is released. Compare them before realigning: git diff $before $REMOTE/$PRODUCTION_BRANCH"
  fi
  git push --quiet --force-with-lease="$RELEASE_BRANCH:$before" "$REMOTE" "HEAD:refs/heads/$RELEASE_BRANCH" \
    || fail "the $RELEASE_BRANCH push was rejected; $TAG is released. Realign by hand: $realign_by_hand"

  git fetch --quiet "$REMOTE" "$PRODUCTION_BRANCH:$PRODUCTION_BRANCH" \
    || echo "Note: local $PRODUCTION_BRANCH was not updated; run: git fetch $REMOTE $PRODUCTION_BRANCH:$PRODUCTION_BRANCH"

  echo "Released $VERSION: $RELEASE_BRANCH now builds on $REMOTE/$PRODUCTION_BRANCH."
  exit 0
fi

# Step 1 preflight.

command -v gh >/dev/null 2>&1 || fail "gh is required to open the release pull request"
gh auth status >/dev/null 2>&1 || fail "gh is not signed in; run: gh auth login"

git merge-base --is-ancestor "$REMOTE/$PRODUCTION_BRANCH" HEAD \
  || fail "$REMOTE/$PRODUCTION_BRANCH has commits $RELEASE_BRANCH lacks; finish the previous release first: $0 $(git show "$REMOTE/$PRODUCTION_BRANCH:plugins/cpln/.claude-plugin/plugin.json" | jq -r '.version') --finish"

open_pr="$(gh pr list --base "$PRODUCTION_BRANCH" --head "$RELEASE_BRANCH" --state open --json number --jq '.[0].number // empty')"
[ -z "$open_pr" ] || fail "release pull request #$open_pr is already open; merge it and run --finish, or close it first"

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
  2. Commit "Bump version to $VERSION" on $RELEASE_BRANCH and push it.
  3. Open the pull request "Release $VERSION" from $RELEASE_BRANCH to $PRODUCTION_BRANCH with the [$VERSION] notes.
After it merges, run: $0 $VERSION --finish
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

# Commit, push develop, and open the release pull request.

git add "${files[@]}"
git commit --quiet -m "Bump version to $VERSION"

if ! git push --quiet "$REMOTE" "HEAD:refs/heads/$RELEASE_BRANCH"; then
  cat >&2 <<EOF
Error: the push was rejected, so nothing changed on $REMOTE.
The release commit exists only locally. To retry, fix the cause and run:
  git push $REMOTE HEAD:refs/heads/$RELEASE_BRANCH
To abandon it instead:
  git reset --hard HEAD~1
EOF
  exit 1
fi

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
awk -v heading="## [$VERSION]" '
  index($0, heading) == 1 { inside = 1; next }
  inside && /^## \[/ { exit }
  inside { print }
' CHANGELOG.md > "$notes"
printf '\nMerge with **Squash and merge** or **Rebase and merge**, then run `scripts/bump-version.sh %s --finish` on %s to tag the release and realign %s.\n' \
  "$VERSION" "$RELEASE_BRANCH" "$RELEASE_BRANCH" >> "$notes"

if ! pr_url="$(gh pr create --base "$PRODUCTION_BRANCH" --head "$RELEASE_BRANCH" --title "Release $VERSION" --body-file "$notes")"; then
  fail "pushed $RELEASE_BRANCH, but the pull request was not opened; open it with: gh pr create --base $PRODUCTION_BRANCH --head $RELEASE_BRANCH --title \"Release $VERSION\""
fi

cat <<EOF
Opened $pr_url
Once it is approved and merged, run: $0 $VERSION --finish
EOF
