# Control Plane AI Plugin

This plugin provides domain knowledge, guided workflows, and validation guardrails for [Control Plane](https://controlplane.com) — a hybrid platform for deploying and managing containerized workloads across AWS, GCP, Azure, and private clouds from a unified interface.

## Architecture

- **skills/** — 23 domain knowledge modules covering workload types, autoscaling, networking, secrets, observability, etc. The core module is `skills/cpln/SKILL.md` — consult it before writing any `cpln` CLI command or workflow.
- **rules/** — Validation guardrails and manifest references. `rules/cli-conventions.md` defines the full CLI structure, shared flags, resource command map, and hallucination traps — read it whenever you are constructing a `cpln` command.
- **agents/** — 8 guided workflow agents (troubleshoot workloads, set up secrets, configure domains, migrate from Kubernetes, etc.)
- **commands/** — 8 slash commands that invoke agents (`/troubleshoot`, `/setup-secret`, etc.)
- **MCP Server** — Pre-configured connection with 80+ tools at `https://mcp.cpln.io/mcp`

## MCP Server

The plugin auto-configures the Control Plane MCP Server. Your `CPLN_TOKEN` (prompted during install) enables live infrastructure operations. Without a token, skills and agents still provide read-only platform knowledge.

## CLI Command Accuracy

**Never write a cpln command from memory.** Before constructing a command, consult `rules/cli-conventions.md` (command structure, shared flags, resource command map, hallucination traps) and `skills/cpln/SKILL.md` (setup, workflows, examples). Verify exact flag names with `cpln <command> --help` or the MCP suggest tool (`mcp__cpln__cpln_suggest`).

## CLI Guardrails

These commands do not exist — never generate them:

- `cpln secret create` → use type-specific: `cpln secret create-opaque`, `create-aws`, `create-tls`, etc.
- `cpln apply` without `--file` → always: `cpln apply --file manifest.yaml`
- `cpln <resource> list` → use `cpln <resource> get` (no args = list all)

These are too destructive to run without explicit user confirmation in the conversation:

- `cpln gvc delete-all-workloads` — destroys every workload in the GVC
- `cpln volumeset shrink` — permanent data loss on the old volume
- Any `cpln <resource> delete` — surface the org, GVC, resource name, and blast radius before proceeding

## Key Conventions

- CLI commands use `cpln` prefix (e.g., `cpln apply --file manifest.yaml`)
- YAML examples use uppercase placeholders: WORKLOAD, GVC, ORG

For platform rules (firewall defaults, workload-type constraints, secret access chain, etc.), see `rules/cpln-guardrails.md`. For CLI command shapes and hallucination traps, see `rules/cli-conventions.md`.
