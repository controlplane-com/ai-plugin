# Control Plane AI Plugin

This is a **Claude Code plugin** providing domain knowledge, guided workflows, and validation guardrails for [Control Plane](https://controlplane.com) — a hybrid platform for deploying and managing containerized workloads across AWS, GCP, Azure, and private clouds from a unified interface.

## Architecture

- **skills/** — 23 domain knowledge modules that activate based on task context (workload types, autoscaling, networking, secrets, observability, etc.)
- **agents/** — 8 guided workflow agents (troubleshoot workloads, set up secrets, configure domains, migrate from Kubernetes, etc.)
- **commands/** — 8 slash commands that invoke agents (`/cpln:troubleshoot`, `/cpln:setup-secret`, etc.)
- **rules/** — 8 validation guardrails (manifest references for workloads, GVCs, policies, domains, identities, volumesets + always-on CLI conventions and platform guardrails)
- **hooks/** — Pre/post-tool hooks for manifest validation
- **.mcp.json** — Pre-configured MCP Server connection (80+ tools at `https://mcp.cpln.io/mcp`)

## MCP Server

The plugin auto-configures the Control Plane MCP Server. Set `CPLN_TOKEN` to a service account token to enable live infrastructure operations. Without a token, skills and agents still provide read-only platform knowledge.

## CLI Command Accuracy

**Never write a cpln command from memory.** See `rules/cli-conventions.md` for the full CLI structure, resource command map, and common hallucination traps (always-loaded), and `skills/cpln/SKILL.md` for setup, workflows, and examples. Always verify exact flags with `cpln <command> --help` or `mcp__cpln__cpln_suggest`.

## Key Conventions

- MCP tool names use `mcp__cpln__` prefix (e.g., `mcp__cpln__create_workload`)
- CLI commands use `cpln` prefix (e.g., `cpln apply --file manifest.yaml`)
- YAML examples use uppercase placeholders: WORKLOAD, GVC, ORG

For platform rules and CLI invariants, see `rules/cpln-guardrails.md` and `rules/cli-conventions.md` (both `alwaysApply: true`).
