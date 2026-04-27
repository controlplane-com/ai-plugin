# Contributing

## Development Principles

- Keep wording precise and operational, not promotional.
- Do not invent unsupported client features, marketplace listings, commands, or URLs.
- Prefer least-privilege and explicit-confirmation guidance for write-capable workflows.
- Verify `cpln` CLI syntax against `rules/cli-conventions.md`, `skills/cpln/SKILL.md`, `cpln <command> --help`, or MCP suggestion tools.

## Local Checks

Run checks that match the files you changed:

```bash
jq empty .mcp.json .claude-mcp.json .app.json .claude-plugin/plugin.json .claude-plugin/marketplace.json .codex-plugin/plugin.json gemini-extension.json hooks/hooks.json .agents/plugins/marketplace.json
gemini extensions validate .
```

For Markdown-only changes, review links, tables, frontmatter, and command examples manually. This repository currently has no package manifest, build script, or test suite.

## Release Checks

Before a public release:

- Update `CHANGELOG.md`.
- Keep `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, and `gemini-extension.json` versions aligned.
- Review `README.md` for current install instructions and unsupported marketplace claims.
- Confirm no real secrets or service account tokens are committed.
- Confirm `.mcp.json` uses Codex MCP fields (`url` and `bearer_token_env_var`) and does not use raw authorization headers.
- Confirm `.claude-mcp.json` uses Claude Code MCP fields (`type`, `url`, and `headers`) with environment interpolation.
- Confirm `gemini-extension.json` uses Gemini CLI MCP fields (`httpUrl` and `headers`) and declares any required extension settings.
- Confirm `LICENSE`, `SECURITY.md`, `.env.example`, and `.gitignore` are present.
- Verify the exact Claude Code install command before publishing it.
- Run `gemini extensions validate .`.
- Test Codex marketplace loading locally where supported: `codex plugin marketplace add /absolute/path/to/ai-plugin/.agents/plugins`.
- State clearly that no standalone OpenAI Apps SDK server is included unless one is later added.
- Do not create a tag until the final public release version is confirmed.

## Pull Requests

Pull requests should explain:

- What user workflow changed.
- Which clients are affected.
- Whether MCP/write-capable behavior changed.
- Which validation commands were run.
