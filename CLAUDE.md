# Contributor context — Claude Code

For end-user installation, capabilities, and supported clients, see `README.md`. For development principles, validation checks, and release process, see `CONTRIBUTING.md`. Don't duplicate either here.

## Repo layout

The repo is split into two zones: **repo root** holds marketplace manifests, the Gemini extension, and contributor docs; **`plugins/cpln/`** holds the actual Claude + Codex plugin content. Both Claude and Codex resolve their plugin root to `plugins/cpln/` via their marketplace manifests; Gemini uses the repo root as its extension dir. This split exists because Gemini, Claude, and Codex all auto-discover `hooks/hooks.json` at their respective roots with incompatible schemas — keeping their roots distinct lets each tool ship its own hook config without cross-tool warnings or load failures. The Apr 27, 2026 audit confirmed this layout against each CLI's source.

### Repo root (marketplace + Gemini)

- `.claude-plugin/marketplace.json` — Claude marketplace entry. `source.path` points at `plugins/cpln`.
- `.agents/plugins/marketplace.json` — Codex marketplace entry. `source` is `{local, path: "./plugins/cpln"}`.
- `gemini-extension.json` — Gemini CLI extension manifest. Declares the `cpln` MCP server and points `contextFileName` at `GEMINI.md`. Gemini treats this directory (the repo root) as the extension dir.
- `GEMINI.md` — Gemini runtime guardrails. Loaded for every Gemini session via `contextFileName`. Keep it short.
- `hooks/hooks.json` — **Gemini-only** hook config. Uses Gemini's schema (`BeforeTool`/`AfterTool`, matcher on `run_shell_command`, output `{decision:"deny", reason:"..."}`). Gemini auto-discovers this file from the extension dir; the path is hardcoded in `packages/cli/src/config/extension-manager.ts` and cannot be redirected via the manifest.
- `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `LICENSE`, `SECURITY.md`, `CLAUDE.md` — contributor and end-user docs.

### `plugins/cpln/` (Claude + Codex plugin content)

- `skills/` — Domain-knowledge skill modules. Each lives in its own subdirectory with a `SKILL.md` carrying frontmatter (`name`, `description`).
- `agents/` — Guided workflow agents. Each is a top-level `<agent>.md` with frontmatter. Companion reference docs that an agent loads on demand live under `references/<agent>/` (kept out of `agents/` so the loader doesn't try to register them as standalone agents).
- `references/` — On-demand reference docs cited by agents (e.g., `references/workload-troubleshooter/diagnostics.md`). Plain markdown, no frontmatter required.
- `commands/` — Slash commands. Each command has a paired `<command>.md` (Claude) and `<command>.toml` (Gemini-style prompt template); keep them aligned.
- `rules/` — Validation guardrails and manifest references. Files with `alwaysApply: true` in frontmatter (`cli-conventions.md`, `cpln-guardrails.md`) are concatenated and injected into every Claude **and Codex** session by the `SessionStart` entry in `hooks/cpln-hooks.json`. `alwaysApply` is not a native field — the hook is what gives it meaning. Codex works out of the box because it sets `CLAUDE_PLUGIN_ROOT` for OOTB compatibility (verified in `codex-rs/hooks/src/engine/discovery.rs`) and accepts the same `hookSpecificOutput.additionalContext` schema. Gemini gets the same rules content from `GEMINI.md` via `contextFileName`.
- `hooks/cpln-hooks.json` — Shared **Claude + Codex** hook config (`PreToolUse` Bash guards + `SessionStart` rule injector). Declared explicitly in `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` via the `hooks` field. Lives at a non-default name so neither tool's strict auto-discovery picks it up alongside the manifest declaration; Claude merges defaults with manifest hooks and Codex 0.x merges too in some paths, so an explicit path is the safest.
- `assets/` — Logos and icons referenced by plugin manifests.
- `.claude-plugin/plugin.json` — Claude plugin manifest. All paths in this file (`./skills/`, `./hooks/cpln-hooks.json`, etc.) are relative to `plugins/cpln/`.
- `.codex-plugin/plugin.json` — Codex plugin manifest. Same path conventions.
- `.codex-plugin/mcp.json` — Codex MCP config. Lives inside `.codex-plugin/` (rather than as a project-level `.mcp.json`) so Claude's cwd auto-discovery doesn't try to parse the Codex-format file as a project MCP config when developing.
- `.claude-mcp.json`, `.codex-plugin/mcp.json`, MCP block in `gemini-extension.json` — three per-client MCP configs pointing at the same hosted server (`https://mcp.cpln.io/mcp`). Keep them in sync when changing the server URL or auth shape.
- `.app.json` — Codex app-level metadata.

## Authoring conventions

- File names: kebab-case (`workload-manifest-reference.md`, `setup-secret.md`).
- Frontmatter on skills, agents, and commands: `name` and `description`. Don't add a `version:` field — Claude, Codex, and Gemini all ignore it, and the only version users see comes from the per-client manifests (`plugins/cpln/.claude-plugin/plugin.json`, `plugins/cpln/.codex-plugin/plugin.json`, `gemini-extension.json`). Rules use `description` plus `alwaysApply` when applicable.
- Inside skill/rule examples, YAML uses uppercase placeholders: `WORKLOAD`, `GVC`, `ORG`.
- MCP tool names in Claude-side examples use the `mcp__cpln__` prefix (Claude Code's convention); Gemini and Codex use the bare tool name.
- **Never write a `cpln` command from memory** when authoring or editing examples in skills/agents/rules. Verify shape and flags with `cpln <command> --help` or `mcp__cpln__cpln_suggest`. `plugins/cpln/rules/cli-conventions.md` is the canonical CLI reference inside this repo; if you change CLI examples, cross-check against it.

## Local development

Two install paths — pick based on what you're doing.

**Fast iteration** — load the plugin directly from this working tree, no marketplace round-trip. The plugin lives in a subdirectory, so target it explicitly:

```bash
claude --plugin-dir ./plugins/cpln
```

`--plugin-dir` loads the plugin for that session only. Edits to skills, agents, commands, and rules pick up on `/reload-plugins`; edits to `plugin.json`, `hooks/cpln-hooks.json`, or MCP config files require restarting the session.

**Pre-release verification** — exercise the actual user-facing install path before tagging a release:

```bash
/plugin marketplace add /absolute/path/to/this/repo/.claude-plugin
/plugin install cpln@controlplane
```

Use this to catch install-time issues `--plugin-dir` skips: missing files in the install copy, marketplace metadata mistakes, version drift between manifests.

### Validation

```bash
claude plugin validate .                       # validates .claude-plugin/marketplace.json
gemini extensions validate .                   # validates gemini-extension.json + hooks/hooks.json
jq empty \
  .claude-plugin/marketplace.json \
  .agents/plugins/marketplace.json \
  gemini-extension.json \
  hooks/hooks.json \
  plugins/cpln/.claude-plugin/plugin.json \
  plugins/cpln/.codex-plugin/plugin.json \
  plugins/cpln/.codex-plugin/mcp.json \
  plugins/cpln/.claude-mcp.json \
  plugins/cpln/.app.json \
  plugins/cpln/hooks/cpln-hooks.json
```

Codex has no native validator on the CLI; it validates implicitly at install/load. After `codex plugin marketplace add "$(pwd)"`, start a session and check `~/.codex/log/codex-tui.log` for `cpln` or `controlplane` warnings — none should appear.

### Debug plugin loading

```bash
claude --plugin-dir ./plugins/cpln --debug hooks
```

Look for "loading plugin" messages and confirm each component directory (skills, agents, commands, hooks) appears. Use `--debug hooks` (or other category filters shown in `claude --help`) to narrow the output. To exercise a hook, trigger the matching tool call (Bash for the current hooks) and watch for the deny message — hook definitions for Claude/Codex live in `plugins/cpln/hooks/cpln-hooks.json` and the Gemini equivalents live in `hooks/hooks.json` at repo root.

## Versioning

Versions in `plugins/cpln/.claude-plugin/plugin.json`, `plugins/cpln/.codex-plugin/plugin.json`, and `gemini-extension.json` must stay aligned. See `CONTRIBUTING.md` for the full release checklist.
