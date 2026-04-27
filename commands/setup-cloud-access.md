---
name: setup-cloud-access
description: Set up credential-free cloud access (AWS, GCP, Azure, or NATS NGS) for a Control Plane workload via Universal Cloud Identity
argument-hint: "[aws|gcp|azure|ngs] --workload [workload-name] [--gvc gvc-name]"
version: 1.0.0
---

# Setup Cloud Access

Configure credential-free access to cloud resources for a workload using Control Plane's Universal Cloud Identity.

## Usage

```
/cpln:setup-cloud-access aws --workload my-app
/cpln:setup-cloud-access gcp --workload my-app --gvc production
/cpln:setup-cloud-access azure --workload my-app
```

## What It Does

1. Guides through cloud-provider-side IAM setup (role, service account, or connector)
2. Registers the cloud account in Control Plane
3. Creates an identity with cloud access for the specified provider
4. Links the identity to the workload
5. Verifies cloud resource access from within the workload

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
