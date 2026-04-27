---
name: setup-secret
description: Set up complete secret access for a Control Plane workload (identity + policy + injection)
argument-hint: "[workload] needs [secret] [--gvc gvc-name]"
version: 1.0.0
---

# Setup Secret Access

Orchestrate the mandatory 3-step secret access chain for a workload.

## Usage

```
/cpln:setup-secret WORKLOAD_NAME needs SECRET_NAME
/cpln:setup-secret WORKLOAD_NAME needs SECRET_NAME --gvc GVC_NAME
```

## What It Does

1. Creates the secret (or identifies an existing one)
2. Creates an identity and links it to the workload
3. Creates a policy granting `reveal` permission on the secret
4. Injects the secret as an environment variable or volume mount
5. Verifies the complete chain works
6. Redeploys the workload with `--ready`

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
