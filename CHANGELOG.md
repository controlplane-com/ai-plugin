# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/) and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

### Changed

### Fixed

### Removed

## [1.2.1] - 2026-05-11

### Added

- `plugins/cpln/hooks/inject-rules.sh` — a single bundled shell script that walks `plugins/cpln/rules/*.md`, filters by `alwaysApply: true` in frontmatter, and emits the `hookSpecificOutput.additionalContext` envelope. Called from all three SessionStart hooks (Claude, Codex, Gemini); uses `awk` for JSON escaping so the hook has zero optional runtime dependencies.

### Changed

- `SessionStart` hooks across Claude (`plugins/cpln/hooks/cpln-hooks.json`), Codex (same), and Gemini (`hooks/hooks.json`) now invoke `inject-rules.sh` instead of inlining a `jq`-based shell pipeline. Behavior is byte-for-byte identical to the previous `jq` output (verified against the same rule files) but no longer depends on `jq` being installed on the user's machine.
- README's Codex install section now explains the `plugin_hooks` feature flag (`UnderDevelopment, default_enabled: false` in `codex-rs/features/src/lib.rs`) and ships the `~/.codex/config.toml` snippet needed to enable plugin-bundled hook display and execution. Without the flag the Codex `/plugins` tab shows "No plugin hooks" and the SessionStart rule injector never fires.

### Fixed

- **Empty 1.2.0 install on Claude.** `.claude-plugin/marketplace.json` used `{source: "github", repo: …, path: "plugins/cpln"}`; Claude's `github` source schema doesn't accept a `path` field, so the entire repo was cloned to the cache and Claude looked for `plugin.json` at the cache root (where only `marketplace.json` exists), loading the plugin with zero skills, agents, commands, or hooks. Source switched to the documented relative-path form `"./plugins/cpln"`.
- **Empty Apps tab and parse warning on Codex.** `plugins/cpln/.app.json` shipped rich metadata (`name`, `description`, `apiBase`, `auth`, `docs`, …) but Codex's `PluginAppConfig` struct in `codex-rs/core-plugins/src/loader.rs` requires a single `id: String` field — an opaque `asdk_app_<hex>` identifier assigned by OpenAI's Apps SDK when Control Plane is registered as a ChatGPT App. Until that registration exists, the manifest's `apps: "./.app.json"` line and `.app.json` itself are removed; Codex no longer emits `missing field "id"` warnings on every session.

### Removed

- `plugins/cpln/.app.json` and the `apps` field in `plugins/cpln/.codex-plugin/plugin.json` (see Fixed above).

## [1.2.0] - 2026-05-11

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
