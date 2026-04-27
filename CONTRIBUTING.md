# Contributing

## Development Principles

- Keep wording precise and operational, not promotional.
- Do not invent unsupported client features, marketplace listings, commands, or URLs.
- Prefer least-privilege and explicit-confirmation guidance for write-capable workflows.
- Verify `cpln` CLI syntax against `rules/cli-conventions.md`, `skills/cpln/SKILL.md`, `cpln <command> --help`, or MCP suggestion tools.

## Local Checks

Run checks that match the files you changed:

```bash
jq empty .mcp.json .app.json .claude-plugin/plugin.json .claude-plugin/marketplace.json .codex-plugin/plugin.json gemini-extension.json hooks/hooks.json .agents/plugins/marketplace.json
gemini extensions validate .
```

For Markdown-only changes, review links, tables, frontmatter, and command examples manually. This repository currently has no package manifest, build script, or test suite.

## Release Checks

Before a public release:

- Update `CHANGELOG.md`.
- Keep `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, and `gemini-extension.json` versions aligned.
- Review `README.md` for current install instructions and unsupported marketplace claims.
- Confirm no real secrets or service account tokens are committed.
- Confirm `.mcp.json` uses environment substitution for `CPLN_TOKEN`.
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
