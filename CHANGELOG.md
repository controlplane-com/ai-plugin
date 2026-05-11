# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/) and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
