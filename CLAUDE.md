# Contributor context — Claude Code

End-user install and capability docs live in `README.md`. Development principles, validation, and release process live in `CONTRIBUTING.md`. This file is the working context for Claude Code sessions on this repo.

## Repo layout

| Path | Purpose |
| --- | --- |
| `plugins/cpln/` | The plugin itself. Claude, Codex, and Cursor all resolve this as their plugin root. |
| `plugins/cpln/skills/<name>/SKILL.md` | One domain skill per folder. Companion files (`*.md`) load on demand. Source of truth — mirrored to `skills/` at the repo root for Gemini by `scripts/sync-gemini-content.sh`. |
| `plugins/cpln/agents/<name>.md` | One guided workflow per file. Reference docs live under `plugins/cpln/references/<name>/`. Source of truth — mirrored to `agents/` at the repo root for Gemini by `scripts/sync-gemini-content.sh`. |
| `skills/`, `agents/` | **Generated mirrors. Do not edit.** Refreshed automatically by the pre-commit hook in `.githooks/pre-commit` whenever a file under `plugins/cpln/{skills,agents}/` is staged. Also refreshed by `scripts/bump-version.sh` and validated on CI. |
| `plugins/cpln/commands/<name>.md` | Slash command for Claude / Codex / Cursor. Each `.md` has a matching `.toml` at the repo root for Gemini — keep the pair aligned by name and description. |
| `commands/<name>.toml` | Slash command for Gemini. Gemini discovers commands at the extension root (the repo root), not under `plugins/cpln/`. Authored separately from the matching `.md` because the `.toml` `prompt` is a tight model instruction while the `.md` body is user docs. |
| `plugins/cpln/rules/*.md` | Guardrails and manifest references. Files with `alwaysApply: true` are injected into every session by the `SessionStart` hook in `plugins/cpln/hooks/cpln-hooks.json`. |
| `plugins/cpln/.claude-plugin/plugin.json` | Claude plugin manifest. |
| `plugins/cpln/.codex-plugin/plugin.json` + `mcp.json` | Codex manifest and MCP config. |
| `plugins/cpln/.cursor-plugin/plugin.json` + `mcp.json` | Cursor manifest and MCP config. |
| `plugins/cpln/.claude-mcp.json` | Claude MCP config. |
| `.claude-plugin/marketplace.json` | Claude marketplace entry. Source: `"./plugins/cpln"`. |
| `.agents/plugins/marketplace.json` | Codex marketplace entry. |
| `.cursor-plugin/marketplace.json` | Cursor marketplace entry. |
| `gemini-extension.json` + `GEMINI.md` + `hooks/hooks.json` | Gemini extension manifest, runtime guardrails, and SessionStart hook. Gemini treats the repo root as its extension dir. |

Each per-client MCP config (`.claude-mcp.json`, `.codex-plugin/mcp.json`, `.cursor-plugin/mcp.json`, MCP block in `gemini-extension.json`) points at the hosted server `https://mcp.cpln.io/mcp`. Keep them in sync when changing URL or auth shape.

## Plugin id vs display name

- Plugin id is **`cpln`** — `name:` field in every plugin manifest. Matches the CLI tool (`cpln login`) and env namespace (`CPLN_TOKEN`). Don't propose renaming it to `controlplane` / `control-plane` / similar — every slug across every client depends on it.
- Brand name is **"Control Plane"** — appears in Codex `interface.displayName` + `interface.developerName`, every manifest's `description`, every `author.name`, and the marketplace id (`controlplane`).
- The two are separate fields by design (like `aws` vs "Amazon Web Services").

## Naming conventions

| Component | Folder/file name | Frontmatter `name:` | Slug in clients |
| --- | --- | --- | --- |
| Skills | bare kebab-case (`image`, `access-control`) | **must match folder** (`name: image`) — Cursor enforces this | Claude/Codex: `cpln:image`; Cursor: `/image` |
| Commands | bare kebab-case (`troubleshoot.md` + `.toml`) | match file (`name: troubleshoot`) | Claude/Codex: `/cpln:troubleshoot`; Gemini/Cursor: `/troubleshoot` |
| Agents | bare kebab-case (`workload-troubleshooter.md`) | **prefixed** (`name: cpln-workload-troubleshooter`) — the model invokes by `name:` directly | n/a — invoked programmatically |

Skills and commands use bare names because the plugin namespace (`cpln:`) handles disambiguation in slug-invoking clients, matching the ecosystem convention (`everything-claude-code:e2e-testing`, `claude-mem:make-plan`). Agents are different — they're invoked via the Agent tool by raw `name:`, so the `cpln-` prefix prevents collisions with agents shipped by other plugins.

## Authoring rules

- **Never write a `cpln` command from memory.** Verify with `cpln <command> --help` or `mcp__cpln__cpln_suggest`. `plugins/cpln/rules/cli-conventions.md` is the canonical CLI reference.
- Frontmatter on skills, agents, commands: `name` and `description` only. Do not add `version:` — Claude/Codex/Gemini ignore it.
- YAML placeholders in examples use uppercase: `WORKLOAD`, `GVC`, `ORG`.
- MCP tool names in Claude examples use the `mcp__cpln__` prefix; Gemini/Codex use the bare name.

## Local development

```bash
claude --plugin-dir ./plugins/cpln
```

Loads the plugin from this working tree for one session. Edits to skills, agents, commands, rules pick up on `/reload-plugins`; edits to `plugin.json`, hooks, or MCP configs require restarting the session.

Enable the pre-commit hook once per clone so the Gemini-facing `skills/` and `agents/` mirrors stay in sync automatically:

```bash
git config core.hooksPath .githooks
```

## Validation

```bash
claude plugin validate .
gemini extensions validate .
jq empty \
  .claude-plugin/marketplace.json \
  .agents/plugins/marketplace.json \
  .cursor-plugin/marketplace.json \
  gemini-extension.json \
  hooks/hooks.json \
  plugins/cpln/.claude-plugin/plugin.json \
  plugins/cpln/.codex-plugin/plugin.json \
  plugins/cpln/.codex-plugin/mcp.json \
  plugins/cpln/.cursor-plugin/plugin.json \
  plugins/cpln/.cursor-plugin/mcp.json \
  plugins/cpln/.claude-mcp.json \
  plugins/cpln/hooks/cpln-hooks.json
```

Codex has no CLI validator; install the plugin and check `~/.codex/log/codex-tui.log` for `cpln`/`controlplane` warnings (there should be none).

## Knowledge map (tool → skill gate)

`plugins/cpln/knowledge-map.json` maps MCP tools to the skill an agent must read before calling them. The hosted MCP server fetches this file at runtime (with a bundled fallback), so gating a tool behind a skill is a one-line edit here — no server redeploy. Schema:

- `skills`: the valid skill names and each one's companion files.
- `toolSkills`: `"<tool_name>": "<skill-name>"` — the skill required before that tool runs (the skill must exist in `skills`).

To gate a tool behind a skill, add an entry to `toolSkills`. The server validates entries on load and drops any that reference an unknown skill or tool, so a typo can never lock a tool.

## Versioning

Driven by `scripts/bump-version.sh <X.Y.Z>`. It updates every plugin manifest and the marketplace entries in lockstep, then promotes the CHANGELOG `[Unreleased]` block. Don't edit version strings by hand.
