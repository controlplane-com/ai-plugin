---
name: troubleshoot
description: Diagnose and fix a Control Plane workload that is unhealthy or not working correctly
argument-hint: "[workload-name] [--gvc gvc-name]"
---

# Troubleshoot Workload

Diagnose why a Control Plane workload is unhealthy, crashing, or not starting.

## Usage

```
/cpln:troubleshoot WORKLOAD_NAME
/cpln:troubleshoot WORKLOAD_NAME --gvc GVC_NAME
```

## What It Does

Diagnosis is read-only and MCP-first. Lead with the MCP tools below; fall back to the `cpln` CLI (`cpln workload get`, `cpln logs`) only when the MCP server is unavailable, and use interactive `cpln workload exec` / `cpln connect` when you need a live shell rather than a single command.

1. Fetches workload status, events, and deployment history — `mcp__cpln__get_workload_deployments` is the PRIMARY readiness check across all locations; pair with `mcp__cpln__get_workload_events` and `mcp__cpln__get_workload_logs`. For a partial failure where one location is unhealthy, drill in with `mcp__cpln__list_deployments` / `mcp__cpln__get_deployment`. Capture the spec via `mcp__cpln__get_workload` (and `mcp__cpln__list_workloads` to confirm the target).
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
3. Drills deeper when needed: `mcp__cpln__list_metrics` then `mcp__cpln__query_metrics` for resource pressure (OOM, CPU, latency); `mcp__cpln__reveal_secret` to confirm a referenced secret value (requires reveal permission); and as a last resort `mcp__cpln__list_workload_replicas` then `mcp__cpln__workload_exec` to run a single command inside a live replica (highest-risk — it executes in a production container and is audit-logged).
4. Presents diagnosis with exact fix commands. When the fix needs a manifest, call `mcp__cpln__get_resource_schema` first, then apply with `cpln apply -f manifest`.
5. Offers to apply the fix

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
