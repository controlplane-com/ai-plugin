---
name: setup-stateful
description: Set up a stateful workload with persistent storage on Control Plane (volumeset + workload + mount)
argument-hint: [workload-name] in [gvc-name] [--image image]
version: 1.0.0
---

# Setup Stateful Workload

Create a workload with persistent storage — volumeset, stateful workload, and volume mount in one guided flow.

## Usage

```
/cpln:setup-stateful WORKLOAD_NAME in GVC_NAME
/cpln:setup-stateful WORKLOAD_NAME in GVC_NAME --image IMAGE
```

## What It Does

1. Determines filesystem type (ext4, xfs, or shared) based on use case
2. Redirects to template-catalog for common databases
3. Creates the volumeset with appropriate settings
4. Creates a stateful workload (or any type for shared filesystem)
5. Mounts the volume to the workload
6. Configures snapshot schedule for backups

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
