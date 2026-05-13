# Contributing

## Development Principles

- Keep wording precise and operational, not promotional.
- Do not invent unsupported client features, marketplace listings, commands, or URLs.
- Prefer least-privilege and explicit-confirmation guidance for write-capable workflows.
- Verify `cpln` CLI syntax against `plugins/cpln/rules/cli-conventions.md`, `plugins/cpln/skills/cpln/SKILL.md`, `cpln <command> --help`, or MCP suggestion tools.

## Local Checks

Run checks that match the files you changed:

```bash
jq empty \
  .claude-plugin/marketplace.json \
  .agents/plugins/marketplace.json \
  gemini-extension.json \
  hooks/hooks.json \
  plugins/cpln/.claude-plugin/plugin.json \
  plugins/cpln/.codex-plugin/plugin.json \
  plugins/cpln/.codex-plugin/mcp.json \
  plugins/cpln/.claude-mcp.json \
  plugins/cpln/hooks/cpln-hooks.json
scripts/sync-gemini-content.sh --check
gemini extensions validate .
```

When changing a slash command, edit both the `.md` under `plugins/cpln/commands/` (read by Claude / Codex / Cursor) and the matching `.toml` at the repo root `commands/` (read by Gemini). Keep their `description` field aligned.

Skills and agents live only at `plugins/cpln/skills/` and `plugins/cpln/agents/`. The `skills/` and `agents/` directories at the repo root are **generated mirrors for Gemini** — never edit them directly. The pre-commit hook in `.githooks/pre-commit` regenerates them whenever a source file is staged. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

If you ever need to refresh the mirrors manually, run `scripts/sync-gemini-content.sh`.

For Markdown-only changes, review links, tables, frontmatter, and command examples manually. This repository currently has no package manifest, build script, or test suite.

## Versioning

This repo follows [Semantic Versioning](https://semver.org/). The version lives in four manifests that must stay aligned:

| File                                          | Path                          |
| --------------------------------------------- | ----------------------------- |
| `plugins/cpln/.claude-plugin/plugin.json`     | `.version`                    |
| `.claude-plugin/marketplace.json`             | `.plugins[0].version`         |
| `plugins/cpln/.codex-plugin/plugin.json`      | `.version`                    |
| `gemini-extension.json`                       | `.version`                    |

Pick the bump based on what changed since the last tag:

- **Patch** (`1.0.0` → `1.0.1`) — bug fix in a skill, agent, hook, or rule that doesn't change behavior for existing users; doc or CHANGELOG-only changes; broken-link or typo fixes.
- **Minor** (`1.0.0` → `1.1.0`) — new skill, new agent, new slash command, new hook, new always-on rule, new MCP capability, or any other backward-compatible feature.
- **Major** (`1.0.0` → `2.0.0`) — removing or renaming a skill / agent / command, changing the MCP server URL or auth shape, breaking frontmatter schema, or any change that requires action from existing users.

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/). Land changes under the top-level `[Unreleased]` block as you merge them; the bump script promotes that block into the released section.

## Cutting a release

Maintainers cut a release by running the bump script, filling in CHANGELOG notes, and pushing a tag. CI does the rest.

1. **Make sure `main` is clean and up to date.**
   ```bash
   git checkout main && git pull --ff-only
   ```

2. **Run the bump script** with the new semver.
   ```bash
   ./scripts/bump-version.sh 1.1.0
   ```
   This updates the four manifests and rewrites `CHANGELOG.md` so `[Unreleased]` becomes `[1.1.0] - YYYY-MM-DD`, with a fresh empty `[Unreleased]` block above it. The script refuses to run on a dirty tree and verifies the four manifests agree on the new version after the bump.

3. **Fill in the release notes** under the new `## [1.1.0]` heading in `CHANGELOG.md`. Keep entries operational and user-facing — describe what changed for someone using the plugin, not what changed in the repo. Drop unused subsections (`Added` / `Changed` / `Fixed` / `Removed`).

4. **Run local checks** (the same ones in [Local Checks](#local-checks)).

5. **Commit and tag.**
   ```bash
   git add -A
   git commit -m "Bump version to 1.1.0"
   git tag v1.1.0
   git push origin main
   git push origin v1.1.0
   ```
   Optionally run `claude plugin tag .` instead of `git tag` — the Claude Code CLI tags the commit *and* validates that `plugin.json` and the marketplace entry agree before tagging.

6. **The release workflow takes over.** On the `v1.1.0` tag push, `.github/workflows/release.yml`:
   - Verifies all four manifests carry version `1.1.0` (catches drift if a manifest was hand-edited).
   - Validates every JSON file parses.
   - Extracts the `## [1.1.0]` section from `CHANGELOG.md`.
   - Creates a GitHub Release with the notes plus install/upgrade snippets for Claude Code, Codex, Gemini CLI, and generic MCP clients, and a compare-link to the previous tag.

   If any manifest is out of sync with the tag, the workflow fails and no release is published — fix the manifest, retag, and push again.

## Pre-release checks

Run before tagging:

- `CHANGELOG.md` `[Unreleased]` section is empty (everything moved into the new versioned section).
- `README.md` install instructions match the published marketplace IDs.
- No real secrets, service account tokens, or org-specific values in the diff.
- `plugins/cpln/.codex-plugin/mcp.json` uses Codex MCP fields (`url`, `bearer_token_env_var`) and not raw auth headers.
- `plugins/cpln/.claude-mcp.json` uses Claude Code MCP fields (`type`, `url`, `headers`) with environment interpolation.
- `gemini-extension.json` MCP block uses Gemini CLI fields (`httpUrl`, `headers`) and declares any required extension settings.
- `LICENSE`, `SECURITY.md`, `.env.example`, `.gitignore` are present.
- `gemini extensions validate .` is clean.
- `scripts/sync-gemini-content.sh --check` passes (root `skills/` and `agents/` match `plugins/cpln/`).
- `claude plugin validate .` is clean (or only the deliberate developer-CLAUDE.md warning).

## Pull Requests

Pull requests should explain:

- What user workflow changed.
- Which clients are affected.
- Whether MCP/write-capable behavior changed.
- Which validation commands were run.
