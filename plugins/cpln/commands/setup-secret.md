---
name: setup-secret
description: Set up complete secret access for a Control Plane workload (identity + policy + injection)
argument-hint: "[workload] needs [secret] [--gvc gvc-name]"
---

# Setup Secret Access

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Orchestrate the mandatory 3-step secret access chain for a workload.

## Usage

```
/cpln:setup-secret WORKLOAD_NAME needs SECRET_NAME
/cpln:setup-secret WORKLOAD_NAME needs SECRET_NAME --gvc GVC_NAME
```

## What It Does

Each step leads with the MCP tool; the CLI is the fallback when the MCP server is unavailable.

1. Creates the secret with the typed tool for its type (`mcp__cpln__create_secret_<type>`, e.g. `create_secret_opaque` / `create_secret_aws` / `create_secret_docker`) or identifies an existing one (`mcp__cpln__list_resources` (kind="secret") / `mcp__cpln__get_resource` (kind="secret"))
2. Grants the workload access — ensures an identity and a `reveal` policy in one call with `mcp__cpln__workload_reveal_secret` (the workload must already exist — for a new workload, create it first; its deployment pauses on the secret reference until granted). Or do it manually: `mcp__cpln__create_identity` + `mcp__cpln__create_policy`, refining with `mcp__cpln__update_identity` / `mcp__cpln__update_policy`
3. Injects the secret reference (`cpln://secret/NAME`) into the workload's env or volume mounts with `mcp__cpln__update_workload` (read current state first via `mcp__cpln__get_resource` (kind="workload"))
4. Verifies the complete chain — break-glass plaintext check with `mcp__cpln__reveal_secret` only when needed
5. Redeploys and confirms readiness (CLI fallback: `cpln apply --ready`)

## Why This Exists

Secret access is the #1 area where users make mistakes. Three mandatory steps must ALL be in place — missing any one causes a silent runtime failure. This command ensures nothing is skipped.

## Examples

```
/cpln:setup-secret my-api needs db-password
/cpln:setup-secret my-api needs aws-credentials --gvc production
```


## Framework-Specific Syntax

- **Claude Code**: `/cpln:setup-secret ARGS`
- **Gemini CLI**: `/setup-secret ARGS` (omit the `cpln:` prefix; on name conflict, use `/cpln.setup-secret`)
- **Codex**: commands not supported — invoke the matching agent skill or MCP tool directly

Invokes the **cpln-secret-setup-wizard** agent.
