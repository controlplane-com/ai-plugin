# Contributor context — Claude Code

End-user install and capability docs live in `README.md`. Development principles, validation, and release process live in `CONTRIBUTING.md`. This file is the working context for Claude Code sessions on this repo.

## Repo layout

**Everything lives under `plugins/cpln/`.** All skills, rules, commands, agents, hooks, and per-client manifests are authored there, and every client (Claude Code, Codex, Cursor, Antigravity CLI) resolves that single directory as its plugin root.

| Path | Purpose |
| --- | --- |
| `plugins/cpln/` | The plugin itself. Claude, Codex, Cursor, and Antigravity CLI all resolve this as their plugin root. |
| `plugins/cpln/skills/<name>/SKILL.md` | One domain skill per folder. Companion files (`*.md`) load on demand. |
| `plugins/cpln/agents/<name>.md` | One self-contained guided workflow per file. |
| `plugins/cpln/commands/<name>.md` | Slash command for Claude / Codex / Cursor. |
| `plugins/cpln/rules/*.md` | Guardrails and manifest references. Files with `alwaysApply: true` are injected by the `SessionStart` hook in `plugins/cpln/hooks/cpln-hooks.json` (Claude / Codex) and read by Cursor as native rules. Antigravity has no SessionStart hook and does not load a plugin `rules/` dir (its rules live in `AGENTS.md`), so it gets the same guardrails via the MCP server (`get_cpln_rules`). |
| `plugins/cpln/.claude-plugin/plugin.json` | Claude plugin manifest. |
| `plugins/cpln/.codex-plugin/plugin.json` + `mcp.json` | Codex manifest and MCP config. |
| `plugins/cpln/.cursor-plugin/plugin.json` + `mcp.json` | Cursor manifest and MCP config. |
| `plugins/cpln/plugin.json` + `mcp_config.json` | Native Antigravity CLI (`agy`) manifest and MCP config (remote server uses `serverUrl`, not `httpUrl`). Antigravity has no `SessionStart` hook event (its hooks are PreToolUse/PostToolUse/PreInvocation/PostInvocation/Stop), so guardrails reach it through the MCP server (`get_cpln_rules` + server-side skill gate), not a hook. `agy plugin validate ./plugins/cpln` gates it; install with `agy plugin install https://github.com/controlplane-com/ai-plugin/plugins/cpln`. |
| `plugins/cpln/.claude-mcp.json` | Claude MCP config. |
| `.claude-plugin/marketplace.json` | Claude marketplace entry. Source: `"./plugins/cpln"`. |
| `.agents/plugins/marketplace.json` | Codex marketplace entry. |
| `.cursor-plugin/marketplace.json` | Cursor marketplace entry. |

Each per-client MCP config (`.claude-mcp.json`, `.codex-plugin/mcp.json`, `.cursor-plugin/mcp.json`, and `plugins/cpln/mcp_config.json` for Antigravity) points at the hosted server `https://mcp.cpln.io/mcp?toolsets=full` — every client uses the `?toolsets=full` profile so they all expose the same complete tool set. Keep them in sync when changing URL or auth shape. The remote-URL field name differs per client: Claude/Codex/Cursor/generic use `url`, Antigravity uses `serverUrl`.

## Plugin id vs display name

- Plugin id is **`cpln`** — `name:` field in every plugin manifest. Matches the CLI tool (`cpln login`) and env namespace (`CPLN_TOKEN`). Don't propose renaming it to `controlplane` / `control-plane` / similar — every slug across every client depends on it.
- Brand name is **"Control Plane"** — appears in Codex `interface.displayName` + `interface.developerName`, every manifest's `description`, every `author.name`, and the marketplace id (`controlplane`).
- The two are separate fields by design (like `aws` vs "Amazon Web Services").

## Naming conventions

| Component | Folder/file name | Frontmatter `name:` | Slug in clients |
| --- | --- | --- | --- |
| Skills | bare kebab-case (`image`, `access-control`) | **must match folder** (`name: image`) — Cursor enforces this | Claude/Codex: `cpln:image`; Cursor: `/image` |
| Commands | bare kebab-case (`troubleshoot.md`) | match file (`name: troubleshoot`) | Claude/Codex: `/cpln:troubleshoot`; Cursor: `/troubleshoot` |
| Agents | bare kebab-case (`workload-troubleshooter.md`) | **prefixed** (`name: cpln-workload-troubleshooter`) — the model invokes by `name:` directly | n/a — invoked programmatically |

Skills and commands use bare names because the plugin namespace (`cpln:`) handles disambiguation in slug-invoking clients, matching the ecosystem convention (`everything-claude-code:e2e-testing`, `claude-mem:make-plan`). Agents are different — they're invoked via the Agent tool by raw `name:`, so the `cpln-` prefix prevents collisions with agents shipped by other plugins.

## Authoring rules

- **Never write a `cpln` command from memory.** Verify with `cpln <command> --help`. The `cpln` skill (`plugins/cpln/skills/cpln/SKILL.md`) is the canonical CLI reference — command structure, the resource command map, and hallucination traps live there.
- Frontmatter on skills, agents, commands: `name` and `description` only. Do not add `version:` — Claude/Codex/Cursor/Antigravity ignore it.
- Skill `description` budget: ≤ ~220 characters (≤ ~270 for the primary `workload` skill). One "what it is" sentence plus a "Use when the user asks about…" trigger-keyword list — no trailing "Covers…" sentence, no MCP tool names. Clients cap the per-session skill listing (Claude Code: ~1% of context); over-budget descriptions get truncated to bare names, which kills intent routing.
- YAML placeholders in examples use uppercase: `WORKLOAD`, `GVC`, `ORG`.
- MCP tool names in Claude examples use the `mcp__cpln__` prefix; Codex/Antigravity use the bare name.

## Local development

```bash
claude --plugin-dir ./plugins/cpln
```

Loads the plugin from this working tree for one session. Edits to skills, agents, commands, rules pick up on `/reload-plugins`; edits to `plugin.json`, hooks, or MCP configs require restarting the session.

Enable the pre-commit hook once per clone so the tool-mention gate runs locally before each commit:

```bash
git config core.hooksPath .githooks
```

## Validation

```bash
claude plugin validate .
agy plugin validate ./plugins/cpln
jq empty \
  .claude-plugin/marketplace.json \
  .agents/plugins/marketplace.json \
  .cursor-plugin/marketplace.json \
  plugins/cpln/plugin.json \
  plugins/cpln/mcp_config.json \
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

- `skills`: the valid skill names.
- `toolSkills`: `"<tool_name>": "<skill-name>"` — the skill required before that tool runs (the skill must exist in `skills`).

To gate a tool behind a skill, add an entry to `toolSkills`. The server validates entries on load and drops any that reference an unknown skill or tool, so a typo can never lock a tool.

## Versioning

Driven by `scripts/bump-version.sh <X.Y.Z>`. It updates every plugin manifest and the marketplace entries in lockstep, then promotes the CHANGELOG `[Unreleased]` block. Don't edit version strings by hand.

In the CHANGELOG, keep only the headings that have entries — omit empty `Added` / `Changed` / `Fixed` / `Removed` sections (including under `[Unreleased]`). Keep each entry as short as possible — one customer-facing line that summarizes rather than enumerates; specifics and internal refactors live in git history, not the changelog. Avoid arrow characters like `→` — write `to`, `-`, or `/` instead.
