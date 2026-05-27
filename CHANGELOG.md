# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/) and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- MCP authentication moved to OAuth 2.1 — no `CPLN_TOKEN` env var required for the hosted MCP server. On first use, your AI client prompts you to sign in and pick which Control Plane organizations it may operate on.

## [1.3.2] - 2026-05-13

### Fixed

- Gemini CLI skills and agents missing since 1.2.0.

## [1.3.1] - 2026-05-13

### Fixed

- Gemini CLI slash commands missing since 1.2.0.

## [1.3.0] - 2026-05-12

### Added

- Cursor support. The plugin now installs into Cursor 2.6+ via Team Marketplaces (Teams and Enterprise plans). Public Cursor Marketplace listing is pending review.

## [1.2.1] - 2026-05-11

### Added

- Bundled SessionStart hook script that injects always-apply rules without requiring `jq` on the user's machine.

### Changed

- README documents the Codex `plugin_hooks` feature flag required for the SessionStart guardrail injector to run.

### Fixed

- Empty plugin on Claude install — 1.2.0 marketplace used an invalid `source` shape, so Claude loaded zero skills/agents/commands.
- Codex no longer emits a missing-`id` warning every session for an Apps SDK manifest that wasn't ready to ship.

### Removed

- Placeholder `.app.json` for OpenAI Apps SDK, until Control Plane is registered as a ChatGPT App.

## [1.2.0] - 2026-05-11

### Added

- Gemini `SessionStart` hook so guardrail rules are injected every session (matching Claude and Codex).
- `description` field on the Claude marketplace entry.

### Changed

- Repo restructured: plugin content moved into `plugins/cpln/`. End-user install commands unchanged.

### Fixed

- Codex plugin install failing silently due to an invalid `source.path` in the marketplace manifest.
- Codex `defaultPrompt` trimmed to 3 entries (Codex's max) so it's no longer ignored.

### Removed

- Claude and Codex `PreToolUse` Bash guards for `cpln secret create` and `cpln apply` — the CLI itself rejects these clearly and the SessionStart rules now carry the same guidance.

## [1.1.0] - 2026-05-11

### Added

- Three always-on guardrail rules: template catalog first; production-grade workload defaults (sizing, HA, probes); scale-to-zero forbidden unless explicitly opted in.
- Per-client "Update to a newer release" instructions in README, including auto-update opt-in flows.
- Per-client update commands in GitHub Release notes.

### Changed

- `cpln-workload-security` — added a Health Probes section (readiness vs. liveness, schema, production example).
- `cpln-autoscaling-capacity` — `minScale: 2+` as the production default; renamed the misleading scale-to-zero example.
- `cpln-template-catalog` — lead section reframes the catalog as the default, not the fallback.
- `cpln` and `GEMINI.md` — embedded the three new guardrail rules so Codex and Gemini sessions pick them up alongside Claude.

## [1.0.0] - 2026-04-27

### Added

- Initial public release. Skills, agents, commands, rules, hooks, and MCP configuration for Claude Code, Codex, and Gemini CLI, plus a generic MCP client configuration for the hosted Control Plane MCP Server.
- Workflow guidance for workloads, secrets, domains, cloud access, Kubernetes migration, access control, stateful workloads, and private-network agents.
- Security, privacy, troubleshooting, contribution, and release documentation.
