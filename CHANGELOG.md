# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/) and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

### Changed

### Fixed

### Removed

## [2.1.1] - 2026-07-30

### Changed

- GVC and IP set locations are validated against the organization's own location list, so any location it has is usable.
- The guardrails and the Kubernetes migration agent state that the organization's location list is the authority on which locations exist.

### Fixed

- The GVC and IP set location tools no longer reject BYOK or built-in Oracle Cloud (`oci-*`) locations as unknown.
- A BYOK location whose name matches a built-in region's friendly name is no longer swapped for that region.

## [2.1.0] - 2026-07-28

### Added

- When a task needs a secret that does not exist, the plugin now offers a placeholder manifest for the user to fill in and apply, documenting every secret type's accepted `data` shape, including the JSON string forms for `docker`, `gcp`, and `azure-sdk`.
- `build_image` and `get_image_build` build a container image from a GitHub or GitLab repository and report its progress.
- Remote image builds with `cpln image build --remote`, which run on Control Plane instead of local Docker.

### Changed

- The OpenTelemetry logging workflow accepts an existing Control Plane credentials-secret reference but no longer accepts raw authentication headers.
- Credential-bearing prompts are refused without an MCP, skill, or CLI call; credential operations may resume only by referencing a secret created outside the conversation.
- CI/CD guidance now offers remote builds as an option for runners without a Docker daemon.

### Fixed

- The skills and guardrails no longer claim that every image build needs a local Docker daemon.

## [2.0.0] - 2026-07-20

### Added

- Listed on the official MCP registry as `io.cpln/control-plane` (`server.json`).

### Changed

- Secrets are now read-only for AI: listing and reading return metadata only, and no tool or skill creates, edits, deletes, or reveals a secret — manage secret data in the Console, CLI, Terraform, Pulumi, or the API.
- `workload_reveal_secret` is now `grant_workload_secret_access` — the same one-call workload access grant; it never returns secret values.
- The `core` toolset grew to 54 tools, adding distributed traces, cron run trigger, replica stop, async command status, and quota listing.

### Fixed

- Corrected Antigravity command notes and stale component counts.
- `logql-observability`: `--from`/`--to` accept relative durations (`7d`, `now-1M`) in addition to ISO 8601 timestamps.
- `audit-compliance`: clarified that billing is processed externally by Stripe and Control Plane stores no cardholder data.

### Removed

- All secret create/update tools, `reveal_secret`, and the Terraform export option that embedded secret values.

## [1.6.0] - 2026-06-23

### Added

- Antigravity CLI (`agy`) support.

### Changed

- Every client now connects to the MCP server with the full toolset.

### Removed

- Gemini CLI support — use Antigravity CLI (`agy`) instead.

## [1.5.1] - 2026-06-22

### Fixed

- Plugin hooks config now loads in Codex; its strict parser rejected the editor-only `$schema` hint.

## [1.5.0] - 2026-06-21

### Added

- New `tag` skill for resource tagging and tag-based selection.
- New `workload-troubleshooting` skill, loaded on demand by the troubleshooter agent.

### Changed

- Continued the accuracy and token-efficiency pass across the remaining skills and agents.
- Setup workflows (secret, cloud access, agent) are now on-demand skills instead of standalone agents and commands.
- Destructive operations are now single-call with explicit approval, replacing the two-phase preview.
- Hardened the operating guardrails around secrets, fabricated commands, placeholder resources, and public-workload checks.
- Cron config folded back into `create_workload` / `update_workload`.

### Fixed

- Corrected stale documentation and policy links.

## [1.4.4] - 2026-06-12

### Added

- New `domain` skill (custom domains, TLS, DNS, routing) plus a rewritten domain-configurator workflow.
- Distributed tracing guidance (`query_traces` / `get_trace`) in the `metrics-observability` skill.

### Changed

- `workload` skill and tool-to-skill map updated for the leaner workload tools: cron now has dedicated `create_cron_workload` / `update_cron_workload` tools, and rollout, security, and request-retry settings each move to their own `configure_workload_*` tool.
- Operating rules now create directly without a pre-existence check — current-state reads are reserved for updates and deletes.
- Workload guidance now declares ports with the `containers[].ports` array; the scalar `containers[].port` is deprecated.
- After a workload create/update, agents now fetch the `workload` skill up front, auto-verify readiness, and report the workload's canonical URL instead of guessing one or returning a per-location URL.
- Revisited the skill set for accuracy and token efficiency — verified each skill against the live platform, tightened the writing, and filled in missing guidance.
- Aligned MCP tool mentions across skills, agents, and commands with the current toolset profiles, marking full-profile-only tools and their core alternatives.
- Reworked the operating guide around the MCP server's server-side enforcement: destructive actions now use a two-phase impact-preview/confirm (pre-approved actions confirmed in one turn), and firewall exposure plus GVC locations are decided at create time.
- Custom domains now route through the Domain resource; the GVC `spec.domain` field is deprecated.

### Fixed

- `workload` skill: corrected and expanded its constraint and exposure rules.
- `access-control` skill: corrected and tightened its permission, principal, and policy rules.

## [1.4.3] - 2026-06-05

### Added

- New `workload` skill: a single, token-efficient primer the AI reads before creating or updating a workload, with on-demand routing to the deep skills (images, scaling, networking, storage, security, metrics).

### Changed

- Consolidated each skill's companion files and each agent's reference docs into the main file, so every skill and agent is self-contained and fully available to MCP-only clients.
- Made the operating rules and every skill, agent, and command MCP-first — slimmer, leading with the MCP tools (CLI as the fallback), with clearer tool/skill routing and corrected outdated MCP tool names.
- Reworked and slimmed the `cpln` CLI skill, now the single home for CLI command reference.

### Removed

- Retired the standalone CLI conventions and per-resource manifest-reference rule files (folded into the relevant skills).

## [1.4.2] - 2026-05-29

### Fixed

- Gemini CLI extension MCP URL: restore the trailing `/mcp` suffix (`https://mcp.cpln.io/mcp`), reverting the 1.4.1 change.

## [1.4.1] - 2026-05-28

### Fixed

- Gemini CLI extension MCP URL: drop trailing `/mcp` so Gemini's transport (which appends the path itself) reaches the server instead of `/mcp/mcp`.

## [1.4.0] - 2026-05-27

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
