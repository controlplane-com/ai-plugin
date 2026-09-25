# Contributing

## Development Principles

- Keep wording precise and operational, not promotional.
- Do not invent unsupported client features, marketplace listings, commands, or URLs.
- Prefer least-privilege and explicit-confirmation guidance for write-capable workflows.
- Verify `cpln` CLI syntax against `plugins/cpln/skills/cpln/SKILL.md` (the canonical CLI reference), `cpln <command> --help`, or MCP suggestion tools.

## Local Checks

Run checks that match the files you changed:

```bash
jq empty \
  .claude-plugin/marketplace.json \
  .agents/plugins/marketplace.json \
  .cursor-plugin/marketplace.json \
  plugins/cpln/plugin.json \
  plugins/cpln/mcp_config.json \
  plugins/cpln/.claude-plugin/plugin.json \
  plugins/cpln/.codex-plugin/plugin.json \
  plugins/cpln/.mcp.json \
  plugins/cpln/.cursor-plugin/plugin.json \
  plugins/cpln/.cursor-plugin/mcp.json \
  plugins/cpln/.claude-mcp.json \
  plugins/cpln/hooks/hooks.json
claude plugin validate .
agy plugin validate ./plugins/cpln
```

When changing a slash command, edit the `.md` under `plugins/cpln/commands/` (read by Claude / Codex / Cursor).

Skills, agents, commands, rules, and hooks live only under `plugins/cpln/` — every client (Claude Code, Codex, Cursor, Antigravity CLI) resolves that one directory. Enable the pre-commit hook once per clone so the tool-mention gate runs locally:

```bash
git config core.hooksPath .githooks
```

For Markdown-only changes, review links, tables, frontmatter, and command examples manually. This repository currently has no package manifest, build script, or test suite.

## Branches

- `develop` is where work lands: open pull requests against it. The test MCP server reads it, so a merged change reaches the test environment within the hour.
- `main` is the released line. Installs, the marketplaces, and the production MCP server read it, and only the release script updates it.

A fix that must ship fast is a normal pull request to `develop` plus a patch release, so `main` never diverges from `develop`.

## Versioning

This repo follows [Semantic Versioning](https://semver.org/). The version lives in several manifests that must stay aligned (the release script updates them all):

| File                                          | Path                                          |
| --------------------------------------------- | --------------------------------------------- |
| `plugins/cpln/.claude-plugin/plugin.json`     | `.version`                                    |
| `.claude-plugin/marketplace.json`             | `.plugins[0].version`                         |
| `plugins/cpln/.codex-plugin/plugin.json`      | `.version`                                    |
| `plugins/cpln/.cursor-plugin/plugin.json`     | `.version`                                    |
| `.cursor-plugin/marketplace.json`             | `.metadata.version` and `.plugins[0].version` |
| `plugins/cpln/plugin.json` (Antigravity CLI)  | `.version`                                    |

Pick the bump based on what changed since the last tag:

- **Patch** (`1.0.0` to `1.0.1`): a bug fix in a skill, agent, hook, or rule that doesn't change behavior for existing users; doc or CHANGELOG-only changes; broken-link or typo fixes.
- **Minor** (`1.0.0` to `1.1.0`): a new skill, agent, slash command, hook, always-on rule, or MCP capability, or any other backward-compatible feature.
- **Major** (`1.0.0` to `2.0.0`): removing or renaming a skill, agent, or command, changing the MCP server URL or auth shape, breaking the frontmatter schema, or any change that requires action from existing users.

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/). Land changes under the top-level `[Unreleased]` block as you merge them; the release script promotes that block into the released section.

## Cutting a release

Maintainers release from `develop` with one script; CI does the rest.

1. **Write the release notes as changes merge**, under `[Unreleased]` in `CHANGELOG.md`. Keep entries operational and user-facing: describe what changed for someone using the plugin, not what changed in the repo. Keep only the subsections that have entries.

2. **Deploy the MCP server to production first** when the release names MCP tools production does not serve yet. The server refuses fetched content that names a tool it lacks and keeps its bundled copy, so the wrong order degrades instead of breaking, but the new content waits for the deploy.

3. **Update `develop` and run the [local checks](#local-checks).**
   ```bash
   git switch develop && git pull --ff-only
   ```

4. **Rehearse, then release.**
   ```bash
   ./scripts/bump-version.sh 1.1.0 --dry-run
   ./scripts/bump-version.sh 1.1.0
   ```
   The script stops before changing anything when it is not on `develop`, the tree is dirty, `develop` is out of sync with `origin`, `main` cannot fast-forward, the tag exists, `[Unreleased]` is empty, or the tool-mention check fails. Otherwise it bumps every manifest, promotes `[Unreleased]` to `[1.1.0] - YYYY-MM-DD`, commits `Bump version to 1.1.0`, tags `v1.1.0`, and pushes `develop`, `main` (fast-forwarded to the release commit), and the tag in one atomic push. If the push is rejected, nothing changes on `origin`, and the script prints how to retry or undo.

5. **The release workflow takes over.** On the `v1.1.0` tag push, `.github/workflows/release.yml`:
   - Verifies all manifests carry version `1.1.0`, which catches drift if a manifest was hand-edited.
   - Validates every JSON file parses.
   - Extracts the `## [1.1.0]` section from `CHANGELOG.md`.
   - Creates a GitHub Release with the notes plus install and upgrade snippets for Claude Code, Codex, Antigravity CLI, and generic MCP clients, and a compare link to the previous tag.

   If any manifest is out of sync with the tag, the workflow fails and no release is published: fix the manifest on `develop` and release the next patch version.

## Pre-release checks

Run before releasing:

- `CHANGELOG.md` `[Unreleased]` holds the release notes; the release script moves them into the versioned section.
- `README.md` install instructions match the published marketplace IDs.
- No real secrets, service account tokens, or org-specific values in the diff.
- `plugins/cpln/.mcp.json` uses Codex MCP fields (`url`, `bearer_token_env_var`) and not raw auth headers.
- `plugins/cpln/.claude-mcp.json` uses Claude Code MCP fields (`type`, `url`, `headers`) with environment interpolation.
- `plugins/cpln/mcp_config.json` (Antigravity CLI) uses `serverUrl` for the remote MCP server — not `httpUrl` or `url`.
- `LICENSE`, `SECURITY.md`, `.env.example`, `.gitignore` are present.
- `agy plugin validate ./plugins/cpln` is clean (native Antigravity plugin manifest).
- `claude plugin validate .` is clean (or only the deliberate developer-CLAUDE.md warning).

## Pull Requests

Pull requests should explain:

- What user workflow changed.
- Which clients are affected.
- Whether MCP/write-capable behavior changed.
- Which validation commands were run.
