# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/) and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Gemini `SessionStart` hook at repo-root `hooks/hooks.json` that injects the same `alwaysApply: true` rules every Claude and Codex session already receives. Uses Gemini's `${extensionPath}` config-time variable to reach `plugins/cpln/rules/`, and emits the standard `hookSpecificOutput.additionalContext` shape Gemini's hooks docs describe. All three runtimes now do rule injection from one source via one schema.
- Marketplace-level `description` field in `.claude-plugin/marketplace.json`.

### Changed

- **Repo restructured into `plugins/cpln/`.** All Claude + Codex plugin content (skills, agents, commands, rules, references, assets, hooks, plugin manifests, MCP configs) moved into `plugins/cpln/`; marketplaces, the Gemini extension manifest, and contributor docs stay at repo root. End-user install commands are unchanged — `/plugin upgrade` and `codex plugin marketplace upgrade` re-resolve automatically. Claude + Codex hooks now live in `plugins/cpln/hooks/cpln-hooks.json` and are declared via each plugin manifest's `hooks` field, freeing the default `hooks/hooks.json` path at the repo root for Gemini's auto-discovery.

### Fixed

- Codex plugin install failing silently with `"local plugin source path must not be empty"`. `.agents/plugins/marketplace.json` source previously declared `path: "./"`, which Codex's path validator rejects, causing the plugin to be dropped on every session so `/plugins` never listed it.
- Codex `defaultPrompt` warning. `interface.defaultPrompt` had 4 entries (Codex max is 3) and was being ignored wholesale; trimmed to 3.

### Removed

- Claude + Codex `PreToolUse` Bash guards that denied generic `cpln secret create` (no type-specific subcommand) and `cpln apply` without `--file`. They caught syntax mistakes the `cpln` CLI itself already rejects with clear errors, so the deny-message added little over the CLI's own output — and the same guidance is now injected upfront via the SessionStart rule content. No corresponding Gemini `BeforeTool` guards shipped (they were drafted then removed in the same release).

## [1.1.0] - 2026-05-11

### Added

- Always-on guardrail rule: Template Catalog first — recommend the matching catalog template (Postgres, Redis, Kafka, RabbitMQ, MongoDB, Nginx, etc.) before hand-rolling a workload, with HA variants noted where applicable.
- Always-on guardrail rule: production-grade workload defaults — explicit minimums for CPU/memory sizing, multi-replica HA, autoscaling strategy, and required readiness/liveness probes for any workload destined for prod-like use.
- Always-on guardrail rule: scale-to-zero is forbidden by default — only configured when the user explicitly opts in by name, never on customer-facing services.
- README "Update to a newer release" sections per client (Claude Code, Codex, Gemini CLI), including auto-update opt-in flows.
- GitHub Release notes now include per-client update commands alongside first-time install commands.

### Changed

- `skills/workload-security` — added a Health Probes section covering readiness vs. liveness, default-by-workload-type, schema, production probe example, and probe design rules.
- `skills/autoscaling-capacity` — bolded `minScale: 2+` as the production default; renamed the misleading "High-Traffic API (Serverless, Scale-to-Zero)" example to "Customer-Facing API (Serverless, Concurrency Autoscaling)" and removed the no-op `scaleToZeroDelay` line.
- `skills/template-catalog` — added a "Recommend the catalog before building anything custom" lead section that frames the catalog as the default, not the fallback.
- `skills/cpln` and `GEMINI.md` — embedded the three new guardrail rules in concise form so Codex and Gemini sessions pick them up alongside the Claude Code SessionStart hook.

## [1.0.0] - 2026-04-27

### Added

- Initial public release of the Control Plane AI Plugin.
- Added Claude Code plugin metadata, skills, agents, commands, rules, hooks, and MCP configuration.
- Added Codex plugin metadata and marketplace configuration.
- Added Gemini CLI extension metadata and command support.
- Added generic MCP client configuration for the hosted Control Plane MCP Server.
- Added Control Plane workflow guidance for workloads, secrets, domains, cloud access, Kubernetes migration, access control, stateful workloads, and private-network agents.
- Added security, privacy, troubleshooting, contribution, and release documentation.
