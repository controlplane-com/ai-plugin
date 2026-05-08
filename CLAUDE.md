# Contributor context — Claude Code

For end-user installation, capabilities, and supported clients, see `README.md`. For development principles, validation checks, and release process, see `CONTRIBUTING.md`. Don't duplicate either here.

## Repo layout

- `skills/` — Domain-knowledge skill modules. Each lives in its own subdirectory with a `SKILL.md` carrying frontmatter (`name`, `description`, `version`).
- `agents/` — Guided workflow agents. Each is a top-level `<agent>.md` with frontmatter; longer agents may have a sibling `<agent>/` directory with extra reference docs the agent loads on demand (e.g., `agents/workload-troubleshooter/diagnostics.md`).
- `commands/` — Slash commands. Each command has a paired `<command>.md` (Claude) and `<command>.toml` (Gemini-style prompt template); keep them aligned.
- `rules/` — Validation guardrails and manifest references. Files with `alwaysApply: true` in frontmatter (`cli-conventions.md`, `cpln-guardrails.md`) are loaded into every session; treat changes to them as broad-impact.
- `hooks/hooks.json` — Pre/post-tool hooks. **Claude-specific**; Gemini and Codex ignore this file. The Gemini-side equivalents of these guardrails live in `GEMINI.md`.
- `assets/` — Logos and icons referenced by plugin/marketplace manifests.
- `.claude-plugin/` — Claude plugin manifest (`plugin.json`) and marketplace entry (`marketplace.json`).
- `.codex-plugin/plugin.json` — Codex plugin manifest.
- `.agents/plugins/marketplace.json` — Codex marketplace entry.
- `gemini-extension.json` — Gemini CLI extension manifest. Declares the `cpln` MCP server and points `contextFileName` at `GEMINI.md` (loaded for end users every session — keep it short).
- `.claude-mcp.json`, `.mcp.json`, MCP block in `gemini-extension.json` — three per-client MCP configs pointing at the same hosted server (`https://mcp.cpln.io/mcp`). Keep all three in sync when changing the server URL or auth shape.

## Authoring conventions

- File names: kebab-case (`workload-manifest-reference.md`, `setup-secret.md`).
- Frontmatter on skills, agents, and commands: `name`, `description`, `version` at minimum. Rules use `description` plus `alwaysApply` when applicable.
- Inside skill/rule examples, YAML uses uppercase placeholders: `WORKLOAD`, `GVC`, `ORG`.
- MCP tool names in Claude-side examples use the `mcp__cpln__` prefix (Claude Code's convention); Gemini and Codex use the bare tool name.
- **Never write a `cpln` command from memory** when authoring or editing examples in skills/agents/rules. Verify shape and flags with `cpln <command> --help` or `mcp__cpln__cpln_suggest`. `rules/cli-conventions.md` is the canonical CLI reference inside this repo; if you change CLI examples, cross-check against it.

## Local development

Two install paths — pick based on what you're doing.

**Fast iteration** — load the plugin directly from this working tree, no marketplace round-trip. This is the inner-loop workflow most edits use:

```bash
claude --plugin-dir .
```

`--plugin-dir` loads the plugin for that session only. Edits to skills, agents, commands, and rules pick up on `/reload-plugins`; edits to `plugin.json`, `hooks/hooks.json`, or MCP config files require restarting the session.

**Pre-release verification** — exercise the actual user-facing install path before tagging a release:

```bash
/plugin marketplace add /absolute/path/to/this/repo/.claude-plugin
/plugin install cpln@controlplane
```

Use this to catch install-time issues `--plugin-dir` skips: missing files in the install copy, marketplace metadata mistakes, version drift between manifests.

### Validation

```bash
claude plugin validate .                       # validates .claude-plugin/* manifests
jq empty .mcp.json .claude-mcp.json .app.json \
  .claude-plugin/plugin.json .claude-plugin/marketplace.json \
  .codex-plugin/plugin.json gemini-extension.json \
  hooks/hooks.json .agents/plugins/marketplace.json
```

### Debug plugin loading

```bash
claude --debug
```

Look for "loading plugin" messages and confirm each component directory (skills, agents, commands, hooks) appears. Use `--debug hooks` (or other category filters shown in `claude --help`) to narrow the output.

To exercise a hook, trigger the matching tool call (Bash for the current hooks) and watch for the `BLOCK:` stderr message; hook definitions live in `hooks/hooks.json`.

## Versioning

Versions in `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, and `gemini-extension.json` must stay aligned. See `CONTRIBUTING.md` for the full release checklist.
