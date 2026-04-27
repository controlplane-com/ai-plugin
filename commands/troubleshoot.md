---
name: troubleshoot
description: Diagnose and fix a Control Plane workload that is unhealthy or not working correctly
argument-hint: [workload-name] [--gvc gvc-name]
version: 1.0.0
---

# Troubleshoot Workload

Diagnose why a Control Plane workload is unhealthy, crashing, or not starting.

## Usage

```
/cpln:troubleshoot WORKLOAD_NAME
/cpln:troubleshoot WORKLOAD_NAME --gvc GVC_NAME
```

## What It Does

1. Fetches workload status, events, and deployment history
2. Checks for common failure patterns (most common first):
   - Insufficient memory / OOMKilled (the #1 customer issue)
   - Image pull errors (wrong reference, missing pull secret, wrong platform)
   - Secret access failures (missing identity, policy, or reference)
   - Port mismatches (container port vs spec port, blocked ports)
   - Firewall blocking traffic (inbound/outbound/internal all disabled by default)
   - Health check failures (probe configuration, probe + autoscaling interaction)
   - Resource limit issues (CPU/memory, Capacity AI restrictions, memory-to-CPU ratio)
   - Container restrictions (UID 1337, reserved names, env var limits)
   - Autoscaling misconfiguration (wrong metric for workload type, scale-to-zero rules)
   - Termination / graceful shutdown failures (missing sleep binary, preStop errors)
   - Volume mount failures (identity, cloud access, reserved paths)
   - Service-to-service communication (internal firewall, endpoint format)
   - Dedicated load balancer and domain issues (TCP, Host header, DNS propagation)
3. Presents diagnosis with exact fix commands
4. Offers to apply the fix

## Examples

```
/cpln:troubleshoot my-api
/cpln:troubleshoot my-api --gvc production
```


## Framework-Specific Syntax

- **Claude Code**: `/cpln:troubleshoot ARGS`
- **Gemini CLI**: `/troubleshoot ARGS` (omit the `cpln:` prefix; on name conflict, use `/cpln.troubleshoot`)
- **Codex**: commands not supported — invoke the matching agent skill or MCP tool directly

Invokes the **cpln-workload-troubleshooter** agent.
