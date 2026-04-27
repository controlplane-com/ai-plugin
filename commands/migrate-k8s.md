---
name: migrate-k8s
description: Migrate Kubernetes manifests, Docker Compose projects, or Helm charts to Control Plane
argument-hint: "[path-to-manifest-or-directory] [--from k8s|compose|helm]"
version: 1.0.0
---

# Migrate to Control Plane

Convert and deploy workloads from Kubernetes, Docker Compose, or Helm.

## Usage

```
/cpln:migrate-k8s deployment.yaml
/cpln:migrate-k8s ./k8s-manifests/
/cpln:migrate-k8s --from compose
/cpln:migrate-k8s --from helm ./chart/
```

## What It Does

1. Analyzes source manifests and identifies resource types
2. Runs the appropriate conversion tool (`cpln convert`, `cpln stack`, or `cpln helm`)
3. Validates workload type detection (cron > stateful > standard)
4. Checks for known conversion issues (port inference, secret mapping, PVC sizing)
5. Reviews converted manifests for Control Plane best practices
6. Applies with correct dependency ordering

## Supported Sources

- **Kubernetes**: Deployments, StatefulSets, CronJobs, Jobs, DaemonSets, Services, Ingresses, Secrets, ConfigMaps, PVCs
- **Docker Compose**: Services, volumes, networks, secrets
- **Helm**: Charts from local path or OCI registry

## When to Use

- Migrating existing workloads to Control Plane
- Converting Kubernetes manifests for the first time
- Deploying Docker Compose projects to the cloud
- Installing Helm charts on Control Plane


## Framework-Specific Syntax

- **Claude Code**: `/cpln:migrate-k8s ARGS`
- **Gemini CLI**: `/migrate-k8s ARGS` (omit the `cpln:` prefix; on name conflict, use `/cpln.migrate-k8s`)
- **Codex**: commands not supported — invoke the matching agent skill or MCP tool directly

Invokes the **cpln-k8s-migrator** agent.
