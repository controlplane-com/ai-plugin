---
name: setup-stateful
description: Set up a stateful workload with persistent storage on Control Plane (volumeset + workload + mount)
argument-hint: "[workload-name] in [gvc-name] [--image image]"
---

# Setup Stateful Workload

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Create a workload with persistent storage — volumeset, stateful workload, and volume mount in one guided flow.

## Usage

```
/cpln:setup-stateful WORKLOAD_NAME in GVC_NAME
/cpln:setup-stateful WORKLOAD_NAME in GVC_NAME --image IMAGE
```

## What It Does

1. Determines filesystem type (ext4, xfs, or shared) based on use case
2. Redirects to template-catalog for common databases (`mcp__cpln__browse_templates`)
3. Creates the volumeset with appropriate settings (`mcp__cpln__create_volumeset`)
4. Creates a stateful workload (or any type for shared filesystem) (`mcp__cpln__create_workload`)
5. Mounts the volume to the workload (`mcp__cpln__mount_volumeset_to_workload`)
6. Configures snapshot schedule for backups (`mcp__cpln__create_volumeset_snapshot`)

The agent leads with these MCP tools and verifies readiness with `mcp__cpln__list_deployments`. The `cpln` CLI is the fallback when the MCP server is unavailable or in CI/CD (`cpln apply -f manifest`).

## Why This Exists

Stateful workload setup requires coordinated steps — wrong filesystem type or workload type causes deployment failures. Workload types are immutable, so mistakes require deletion and recreation.

## Examples

```
/cpln:setup-stateful my-database in production
/cpln:setup-stateful file-server in staging --image nginx:latest
```


## Framework-Specific Syntax

- **Claude Code**: `/cpln:setup-stateful ARGS`
- **Gemini CLI**: `/setup-stateful ARGS` (omit the `cpln:` prefix; on name conflict, use `/cpln.setup-stateful`)
- **Codex**: commands not supported — invoke the matching agent skill or MCP tool directly

Invokes the **cpln-stateful-workload-setup** agent.
