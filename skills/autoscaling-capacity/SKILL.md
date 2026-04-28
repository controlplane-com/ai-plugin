---
name: cpln-autoscaling-capacity
description: "Configures workload autoscaling and Capacity AI on Control Plane. Use when the user asks about scaling up/down, min/max replicas, concurrency or RPS scaling, CPU/memory/latency-based scaling, KEDA, Capacity AI optimization, scale-to-zero, or custom metrics scaling."
version: 1.0.0
---

# Autoscaling & Capacity AI

Strategy overview, picker, and the type-by-capability matrix. For per-metric YAML configuration (concurrency, rps, cpu, latency, memory, multi, KEDA), see `skills/autoscaling-capacity/metric-configs.md`. For custom Prometheus metrics, KEDA-via-Prometheus, and resource-allocation interactions, see `skills/autoscaling-capacity/custom-metrics.md`.

## Scaling Strategy Overview

All strategies are set via `spec.defaultOptions.autoscaling.metric`. The system scales to keep the chosen metric near but below the **target** value.

| Strategy | Metric Value | Best For | How It Works | Key Config |
|:---|:---|:---|:---|:---|
| Concurrency | `concurrency` | HTTP APIs with variable request duration | Tracks average concurrent requests across replicas: `(requests * duration) / (period * replicas)` | `target`, `maxConcurrency` |
| Requests Per Second | `rps` | HTTP services with consistent response times | Raw request count per second divided by replica count | `target` |
| CPU Utilization | `cpu` | Compute-heavy workloads (encoding, ML inference) | Percentage of CPU consumed vs allocated CPU | `target` (max 100) |
| Request Latency | `latency` | Latency-sensitive APIs with SLOs | Response time at a configurable percentile (p50/p75/p99) in ms | `target`, `metricPercentile` |
| Memory Utilization | `memory` | Memory-intensive workloads (caching, data processing) | Percentage of memory consumed vs allocated memory | `target` (max 100) |
| Multi Metric | `multi` | Complex workloads needing compound scaling signals | Multiple metrics evaluated independently; highest replica count wins | `multi[]` array |
| KEDA | `keda` | Event-driven scaling (queues, streams, external metrics) | KEDA triggers poll external sources; scales based on custom rules | `keda.triggers[]` |
| Disabled | `disabled` | Fixed replica count | No autoscaling; replicas stay at `minScale` | `minScale` |

## Strategy Selection Guide

```
Is your workload an HTTP service?
├── Yes → Do requests have variable duration (websockets, streaming)?
│   ├── Yes → concurrency (Serverless only)
│   └── No → Does response time matter most?
│       ├── Yes → latency (Standard/Stateful only)
│       └── No → rps
├── No → Is it compute-heavy (encoding, ML)?
│   ├── Yes → cpu
│   └── No → Is it memory-intensive?
│       ├── Yes → memory
│       └── No → Does it react to external events (queues, streams)?
│           ├── Yes → keda (Standard/Stateful only)
│           └── No → disabled (fixed replicas)
│
Need multiple scaling signals? → multi (Standard/Stateful only)
```

For the YAML config of each strategy, see `skills/autoscaling-capacity/metric-configs.md`.

**If a workload-type or compatibility constraint pushes the decision tree toward `disabled` against the user's stated intent** — e.g. the user asked for concurrency-based scaling but the workload turned out stateful, or the user asked for Capacity AI on a stateful or CPU-autoscaled workload — **do NOT silently downgrade.** Surface the conflict per the **"Constraint Conflicts — Surface, Don't Silently Default"** rule in `rules/cpln-guardrails.md`: enumerate the realistic alternatives that fit the user's goal, recommend one with project-grounded reasoning (e.g. single-writer SQLite-backed app → `disabled` with `min=max=1` is often correct, but **say so explicitly with that reasoning**), and let the user choose. The conservative default is sometimes the right answer, but it must never be silent.

## Capacity AI

Automatically optimizes container CPU and memory allocation using historical usage analysis. It adjusts resources **between** the configured `minCpu`/`minMemory` and `cpu`/`memory` values.

**Enabled by default** for Standard and Serverless workloads.

### How It Works

1. Analyzes historical resource usage patterns for the workload.
2. Adjusts CPU and memory allocations up/down within configured min/max bounds.
3. On **Standard** workloads, adjustments happen **in place** — no pod restart required.
4. Maintains a CPU-to-memory ratio to prevent divergence.

### Minimal config

```yaml
spec:
  containers:
    - name: my-container
      cpu: '500m'        # max CPU (Capacity AI ceiling)
      memory: '512Mi'    # max memory (Capacity AI ceiling)
      minCpu: '50m'      # min CPU (Capacity AI floor)
      minMemory: '128Mi' # min memory (Capacity AI floor)
  defaultOptions:
    capacityAI: true     # default for standard/serverless
    capacityAIUpdateMinutes: 30   # optional throttle
```

### Restrictions

| Restriction | Reason |
|:---|:---|
| Not available with `cpu` autoscaling metric | Dynamic CPU allocation conflicts with CPU-based scaling |
| Not available with `multi` metric | Multi-metric requires stable resource baselines |
| Not supported for **Stateful** workloads | Stateful workloads need predictable resource allocation |
| Not available with **GPU** workloads | GPU workloads require fixed resource allocation |
| Cron workloads | Not applicable |

### Capacity AI floor

When idle, Capacity AI scales CPU down to a minimum of **25 millicores**. The floor scales up with memory using a **1:3 ratio** of CPU millicores to memory MiB.

For full details on resource allocation interactions, GPU constraints, and stateful sizing, see `skills/autoscaling-capacity/custom-metrics.md`.

## Workload Type × Scaling Capabilities

| Capability | Standard | Serverless | Stateful | Cron |
|:---|:---:|:---:|:---:|:---:|
| Capacity AI | Yes (default on) | Yes (default on) | No | N/A |
| Scale to zero | KEDA only | Yes (rps/concurrency) | KEDA only | No |
| Concurrency metric | No | Yes | No | N/A |
| RPS metric | Yes | Yes | Yes | N/A |
| CPU metric | Yes | Yes | Yes | N/A |
| Latency metric | Yes | No | Yes | N/A |
| Memory metric | Yes | Yes | Yes | N/A |
| Multi metric | Yes | No | Yes | N/A |
| KEDA metric | Yes | No | Yes | N/A |
| In-place resource sizing | Yes | No | No | Yes |
| Min replicas | 1 | 0 | 1 | N/A |

## MinScale / MaxScale Quick Picker

| Scenario | `minScale` | `maxScale` | Notes |
|:---|:---|:---|:---|
| Production API | 2+ | Based on load testing | Avoid cold starts; ensure HA |
| Dev/staging | 0-1 | 3-5 | Cost savings; accept cold starts |
| Scale-to-zero (Serverless) | 0 | Based on peak | Set `scaleToZeroDelay` (default 300s) |
| Fixed replicas | Same value | Same value | Set `metric: disabled` or set min=max |
| Background worker | 1 | Based on queue depth | Use KEDA for event-driven scaling |

## Common Patterns

### High-Traffic API (Serverless, Scale-to-Zero)

```yaml
kind: workload
name: api-gateway
spec:
  type: serverless
  containers:
    - name: api
      image: //image/api:latest
      cpu: '500m'
      memory: '512Mi'
      minCpu: '50m'
      minMemory: '128Mi'
      ports:
        - number: 8080
          protocol: http
  defaultOptions:
    capacityAI: true
    autoscaling:
      metric: concurrency
      target: 50
      maxConcurrency: 100
      minScale: 2
      maxScale: 50
      scaleToZeroDelay: 300
```

### Compute-Heavy Worker (Standard, CPU-Based)

```yaml
kind: workload
name: encoder
spec:
  type: standard
  containers:
    - name: encoder
      image: //image/encoder:latest
      cpu: '2000m'
      memory: '4096Mi'
  defaultOptions:
    capacityAI: false         # cannot use with cpu metric
    autoscaling:
      metric: cpu
      target: 70
      minScale: 1
      maxScale: 10
```

### Event-Driven KEDA (Standard, Redis Queue)

**Prerequisite:** KEDA must be enabled on the GVC before any workload can use `metric: keda`. Applying a workload with `metric: keda` to a GVC without KEDA enabled will silently not scale — no error event, the workload just ignores queue depth.

```yaml
# Step 1: Enable KEDA on the GVC (one-time setup)
kind: gvc
name: my-gvc
spec:
  keda:
    enabled: true
```

```yaml
# Step 2: Configure the workload
kind: workload
name: queue-processor
spec:
  type: standard
  containers:
    - name: worker
      image: //image/worker:latest
      cpu: '250m'
      memory: '256Mi'
  defaultOptions:
    autoscaling:
      metric: keda
      keda:
        triggers:
          - type: redis
            metadata:
              address: redis.my-gvc.cpln.local:6379
              queueLength: '5'
```

## Gotchas

- **Capacity AI is incompatible with `cpu` autoscaling metric and with `multi` metric.** Use one or the other.
- **Capacity AI is not supported on Stateful or GPU workloads.** For Stateful, optimize with `minCpu`/`minMemory` instead.
- **`metric` and `multi` are mutually exclusive.** When using `multi`, omit the top-level `metric` and `target`.
- **Do NOT set `target` when using `metric: keda`.** It is rejected.
- **`memory(MiB) / cpu(millicores)` ratio must be ≤ 8** (relaxed to 32 with the `cpln/relaxMemoryToCpuRatio` tag).
- **Scale-to-zero on Serverless requires `metric: rps` or `concurrency`.** Other metrics on Serverless do not scale to zero natively — use KEDA.
- **Cron workloads cannot scale to zero** — they run on schedule and are not autoscaled.
- **KEDA must be enabled on the GVC first** (`spec.keda.enabled: true`) before workloads can use `metric: keda`.
- **Workload type is immutable.** Changing autoscaling strategies that require a different workload type means delete + recreate.

## Quick Reference

### MCP Tools

| Tool | Purpose |
|:---|:---|
| `mcp__cpln__create_workload` | Create a workload with autoscaling config |
| `mcp__cpln__update_workload` | Update autoscaling settings on existing workload |
| `mcp__cpln__get_workload` | Inspect current autoscaling configuration |
| `mcp__cpln__get_workload_deployments` | Check deployment status and replica counts |
| `mcp__cpln__get_workload_events` | View scaling events and errors |
| `mcp__cpln__get_workload_logs` | View workload logs to diagnose scaling issues |

### CLI Commands

| Command | Purpose |
|:---|:---|
| `cpln workload create` | Create workload from manifest |
| `cpln workload get WORKLOAD -o yaml` | Inspect autoscaling config |
| `cpln workload get-deployments WORKLOAD` | Check replica counts per location |
| `cpln workload eventlog WORKLOAD` | View scaling events |
| `cpln workload replica get WORKLOAD --location LOC` | List running replicas |
| `cpln apply --file manifest.yaml` | Apply autoscaling changes (idempotent) |

### Troubleshooting Scaling

| Symptom | Check |
|:---|:---|
| Not scaling up | Verify metric is being generated; check `maxScale` limit; check readiness probe |
| Not scaling down | Standard: 5-minute stabilization window; check `minScale` |
| Slow cold starts | Increase `minScale`; optimize container startup; use readiness probe |
| KEDA not triggering | Verify KEDA enabled on GVC; check trigger credentials; verify firewall allows KEDA access |
| Capacity AI not adjusting | Check restrictions (CPU metric, multi metric, stateful, GPU); changes reset history |
| Scale-to-zero not working | Only Serverless with rps/concurrency, or KEDA; check `scaleToZeroDelay` |
| Cron run failed and logs are noisy | Per-run logs are scoped by `replica` label, not just `workload` — use `cpln workload get-deployments` to enumerate `status.jobExecutions[]` (each with its own `replica`, `startTime`, `completionTime`), then query logs with the `replica` label and the execution's time window. See **`logql-observability` → "Cron Workloads — Per-Execution Logs"** for the exact pattern. |

### Related Skills

- **cpln-metrics-observability** — Built-in metrics, custom metrics endpoints, Prometheus federation.
- **cpln-workload-security** — Production hardening that pairs with autoscaling.
- **cpln-logql-observability** — LogQL syntax including the per-execution log query for cron workloads.
- **cpln-stateful-storage** — Stateful workloads have different sizing constraints.

### Linked Reference Docs

- `skills/autoscaling-capacity/metric-configs.md` — Per-metric YAML configuration (concurrency, rps, cpu, latency, memory, multi, KEDA, KEDA-with-Prometheus).
- `skills/autoscaling-capacity/custom-metrics.md` — Custom Prometheus metrics, scraping config, GPU/Stateful resource constraints.

## Documentation

For the latest reference, see:

- [Autoscaling Reference](https://docs.controlplane.com/reference/workload/autoscaling.md)
- [Capacity AI Reference](https://docs.controlplane.com/reference/workload/capacity.md)
- [Custom Metrics Reference](https://docs.controlplane.com/reference/workload/custom-metrics.md)
- [Export Metrics Guide](https://docs.controlplane.com/guides/export-metrics.md)
