---
name: setup-cloud-access
description: Set up credential-free cloud access (AWS, GCP, Azure, or NATS NGS) for a Control Plane workload via Universal Cloud Identity
argument-hint: "[aws|gcp|azure|ngs] --workload [workload-name] [--gvc gvc-name]"
---

# Setup Cloud Access

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Configure credential-free access to cloud resources for a workload using Control Plane's Universal Cloud Identity.

## Usage

```
/cpln:setup-cloud-access aws --workload my-app
/cpln:setup-cloud-access gcp --workload my-app --gvc production
/cpln:setup-cloud-access azure --workload my-app
```

## What It Does

This command delegates to the **cpln-cloud-identity-setup** agent. The underlying flow is MCP-first (the `cpln` CLI is the fallback when the MCP server is unavailable):

1. Guides through cloud-provider-side IAM setup (role, service account, or connector) — `mcp__cpln__how_to_create_aws_cloud_account` / `how_to_create_gcp_cloud_account` / `how_to_create_azure_cloud_account` / `how_to_create_ngs_cloud_account` (pick by provider)
2. Registers the cloud account in Control Plane — `mcp__cpln__create_cloud_account` (verify with `mcp__cpln__get_resource` (kind="cloud_account") / `mcp__cpln__list_resources` (kind="cloud_account"))
3. Creates an identity (`mcp__cpln__create_identity`) and applies the cloud-access block. Neither `create_identity` nor `mcp__cpln__update_identity` accepts the `aws` / `gcp` / `azure` / `ngs` cloud-access spec — for that block use the CLI fallback: `mcp__cpln__get_resource_schema` (kind `identity`) then `cpln apply -f identity.yaml`
4. Links the identity to the workload — `mcp__cpln__update_workload` (sets `spec.identityLink`)
5. Verifies cloud resource access — `mcp__cpln__get_resource` (kind="identity") (check `status.<provider>.usable`)

## Supported Providers

- **AWS**: IAM role with trust policy + attached policies
- **GCP**: Service account with IAM bindings
- **Azure**: Function App with Control Plane connector
- **NGS** (NATS NGS): Scoped NATS credentials via nats-account secret

## When to Use

- Workload needs to access cloud services (S3, DynamoDB, Cloud SQL, etc.) without embedded credentials
- Setting up Universal Cloud Identity for the first time
- Configuring private network access via Agents/Cloud Wormholes


## Framework-Specific Syntax

- **Claude Code**: `/cpln:setup-cloud-access ARGS`
- **Gemini CLI**: `/setup-cloud-access ARGS` (omit the `cpln:` prefix; on name conflict, use `/cpln.setup-cloud-access`)
- **Codex**: commands not supported — invoke the matching agent skill or MCP tool directly

Invokes the **cpln-cloud-identity-setup** agent.
