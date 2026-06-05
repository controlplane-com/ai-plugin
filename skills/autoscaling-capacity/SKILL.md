---
name: autoscaling-capacity
description: "Configures workload autoscaling and Capacity AI on Control Plane. Use when the user asks about scaling up/down, min/max replicas, concurrency or RPS scaling, CPU/memory/latency-based scaling, KEDA, Capacity AI optimization, scale-to-zero, or custom metrics scaling."
---

# Autoscaling & Capacity AI

Self-contained deep skill for scaling strategy, per-metric configuration, Capacity AI, custom-metric scaling, and resource allocation. For the cross-cutting basics (workload types, production defaults, spec shape), see the `workload` skill.

## Scaling Strategy Overview

Set via `spec.defaultOptions.autoscaling.metric`. The system scales to keep the chosen metric near but below the **target**. The metric must be valid for the workload type (see the matrix) or the spec is rejected.

| Strategy | Metric | Best For | How It Works | Key Config |
|---|---|---|---|---|
| Concurrency | `concurrency` | HTTP APIs with variable request duration (**Serverless only**) | Avg concurrent requests across replicas: `(requests * duration) / (period * replicas)` | `target`, `maxConcurrency` |
| Requests Per Second | `rps` | HTTP services with consistent response times | Raw request count per second / replica count | `target` |
| CPU Utilization | `cpu` | Compute-heavy work (encoding, ML inference) | % CPU consumed vs allocated | `target` (max 100) |
| Request Latency | `latency` | Latency-sensitive APIs with SLOs (**Standard/Stateful only**) | Response time at a configurable percentile (p50/p75/p99) in ms | `target`, `metricPercentile` |
| Memory Utilization | `memory` | Memory-intensive work (caching, data processing) | % memory consumed vs allocated | `target` (max 100) |
| Multi Metric | `multi` | Compound scaling signals (**Standard/Stateful only**) | Multiple metrics evaluated independently; highest replica count wins | `multi[]` array |
| KEDA | `keda` | Event-driven (queues, streams, external metrics) (**Standard/Stateful only**) | KEDA triggers poll external sources; scales on custom rules | `keda.triggers[]` |
| Disabled | `disabled` | Fixed replica count | No autoscaling; replicas stay at `minScale` | `minScale` |

**If a type/compatibility constraint pushes the decision toward `disabled` against the user's stated intent** (e.g. they asked for concurrency scaling but the workload is stateful, or for Capacity AI on a stateful/CPU-autoscaled workload), **do NOT silently downgrade.** Per the **"Constraint Conflicts — Surface, Don't Silently Default"** rule in `rules/cpln-guardrails.md`: enumerate the realistic alternatives that fit the goal, recommend one with project-grounded reasoning (e.g. a single-writer SQLite-backed app → `disabled` with `min=max=1` is often correct — but say so explicitly with that reasoning), and let the user choose. The conservative default is sometimes right, but never silent.

## Per-Metric Configuration

Set the `autoscaling` block with `mcp__cpln__create_workload` (new) or `mcp__cpln__update_workload` (existing — PATCH; call `mcp__cpln__get_workload` first), then poll `mcp__cpln__get_workload_deployments` until ready. CLI fallback / CI-CD: `cpln apply --file manifest.yaml`.

### Concurrency (Serverless only)

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: concurrency
      target: 100             # avg in-flight requests per replica
      maxConcurrency: 0       # 0 = unlimited; 1-30000 for a hard cap (excess queues)
      minScale: 1
      maxScale: 10
      scaleToZeroDelay: 300   # seconds (30-3600); only applies at minScale 0
```

Serverless evaluates capacity every ~2s (averaged over 60s; bursts trigger 6s averaging for 60s).

### Requests Per Second

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: rps
      target: 100
      minScale: 1
      maxScale: 10
```

Scales to zero on Serverless at `minScale: 0`.

### CPU Utilization

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: cpu
      target: 80              # percent, max 100
      minScale: 1
      maxScale: 5
```

**Capacity AI is NOT available with the `cpu` metric** — dynamic CPU allocation conflicts with CPU-based scaling.

### Request Latency (Standard/Stateful only)

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: latency
      target: 100            # milliseconds (not a percent)
      metricPercentile: p99  # p50 (default), p75, or p99
      minScale: 1
      maxScale: 5
```

Target is in milliseconds at the chosen percentile (not a percentage).

### Memory Utilization

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: memory
      target: 80              # percent, max 100
      minScale: 1
      maxScale: 5
```

### Multi Metric (Standard/Stateful only)

```yaml
spec:
  defaultOptions:
    autoscaling:
      minScale: 1
      maxScale: 5
      multi:
        - metric: cpu
          target: 80
        - metric: memory
          target: 80
```

Each metric in `multi[]` is evaluated independently; the highest resulting replica count applies. Each must be unique. `metric`/`multi` and `target`/`multi` are mutually exclusive (targets go inside each entry). Capacity AI is not available with `multi`.

### KEDA (Standard/Stateful only)

Event-driven autoscaling using [KEDA](https://keda.sh/) triggers (queue length, Kafka lag, Prometheus queries, …). **Enable KEDA on the GVC first:**

```yaml
# GVC spec
spec:
  keda:
    enabled: true
    identityLink: //identity/keda-identity   # optional, for cloud/network access
    secrets:                                  # optional, for TriggerAuthentication
      - //secret/keda-secret-1
```

```yaml
# Workload spec
spec:
  defaultOptions:
    autoscaling:
      metric: keda
      keda:
        triggers:
          - type: redis
            metadata:
              address: my-redis.my-gvc.cpln.local:6379
              queueLength: '5'
              passwordFromEnv: REDIS_PASSWORD
```

**Do NOT set `target` with `keda`** (rejected). If the trigger source is a Control Plane workload, allow KEDA in that source's firewall (`internal.inboundAllowWorkload: [cpln://internal/keda]`). For triggers needing auth, reference a secret on the GVC's keda config via `authenticationRef.name`. Advanced options support `scalingModifiers` with custom formulas.

### KEDA with Prometheus

Scale on a PromQL query against Control Plane's metrics endpoint:

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: keda
      keda:
        triggers:
          - type: prometheus
            metadata:
              serverAddress: https://metrics.cpln.io:443/metrics/org/ORG_NAME
              customHeaders: >-
                Authorization=Bearer SERVICE_ACCOUNT_TOKEN
              query: >
                histogram_quantile(0.99, sum(rate(request_duration_ms_bucket{
                  gvc="GVC_NAME", workload="WORKLOAD_NAME"
                }[5m])) by (le))
              threshold: '1000'
              activationThreshold: '0'
            name: workload-latency
```

Requires a service account with `readMetrics` permission (see the [export metrics guide](https://docs.controlplane.com/guides/export-metrics.md)). Before wiring the trigger, confirm the query returns a signal: `mcp__cpln__list_metrics` to find the metric name/labels, then `mcp__cpln__query_metrics` to run the PromQL.

## Capacity AI

Optimizes container CPU/memory using historical usage, adjusting **between** the configured `minCpu`/`minMemory` (floor) and `cpu`/`memory` (ceiling). **Enabled by default for Standard and Serverless.** On **Standard**, adjustments happen **in place** — no pod restart. It maintains a CPU-to-memory ratio to prevent divergence.

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
|---|---|
| Not available with `cpu` autoscaling metric | Dynamic CPU allocation conflicts with CPU-based scaling |
| Not available with `multi` metric | Multi-metric requires stable resource baselines |
| Not supported for **Stateful** workloads | Stateful workloads need predictable resource allocation |
| Not available with **GPU** workloads | GPU workloads require fixed resource allocation |
| Cron workloads | Not applicable |

When idle, Capacity AI scales CPU down to a minimum of **25 millicores**; the floor scales up with memory using a **1:3 ratio** of CPU millicores to memory MiB.

### Resource allocation & scaling interaction

- **With Capacity AI:** `cpu`/`memory` are upper bounds and `minCpu`/`minMemory` lower bounds — it adjusts within the range.
- **Without Capacity AI:** `cpu`/`memory` are the fixed allocation; `minCpu`/`minMemory` are ignored (except for Stateful).
- **`memory(MiB) / cpu(millicores)` ratio must be ≤ 8** (relaxed to 32 with the `cpln/relaxMemoryToCpuRatio` tag).
- **GPU:** cannot use Capacity AI. Models — **Nvidia T4** (1–4 per replica), **Nvidia A10g** (1 per replica) — have strict minimum CPU/memory (fetch exact constraints with `mcp__cpln__get_resource_schema`, `kind: workload`). Standard CPU/memory/egress billing applies (no extra GPU charge).
- **Stateful (no Capacity AI):** optimize with `minCpu`/`minMemory` — `minCpu`↔`cpu` at most **4000m** apart (ratio ≥ 1:4); `minMemory`↔`memory` at most **4096Mi** apart (ratio ≥ 1:4).
- **Cost:** billing is on **reserved** resources, so Capacity AI right-sizing lowers cost. Any workload change resets usage history and restarts analysis; apps that reserve resources at startup may not benefit.

## Workload Type × Scaling Capabilities

| Capability | Standard | Serverless | Stateful | Cron |
|---|:---:|:---:|:---:|:---:|
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

## MinScale / MaxScale

| Scenario | `minScale` | `maxScale` | Notes |
|---|---|---|---|
| Production API | **2+** | `5` (default) or as specified | Avoid cold starts; ensure HA. `1` is a single point of failure. |
| Dev/staging | 0-1 | `5` (default) or as specified | Cost savings; accept cold starts. Flag as dev-only when proposing. |
| Scale-to-zero (Serverless) | 0 | `5` (default) or as specified | Set `scaleToZeroDelay` (default 300s). **Only when the user asked for scale-to-zero by name.** |
| Fixed replicas | Same value | Same value | Set `metric: disabled` or set min=max |
| Background worker | 1 | `5` (default) or as specified | Use KEDA for event-driven scaling |

**Production default is `minScale: 2`** (see the `workload` skill). Pick `1` only with a named reason (single-writer DB, leader-election service, single-owner worker, or a dev/staging workload). **`maxScale` keeps its default of `5` unless the user gives an explicit maximum** — if they name a number, set exactly that; otherwise leave it at `5` rather than inventing a cap.

### Scale-to-zero is NOT the production default

`minScale: 0` (true scale-to-zero) is a separate, more aggressive choice and is **never** the AI's default — even on Serverless, even when the user said "auto-scale." Configure it only when the user explicitly asked for scale-to-zero by name. When a workload scales to 0, the next request waits for a cold replica to schedule, pull, and start; after `scaleToZeroDelay` (default 300s) of idle, the next user pays that latency again.

Acceptable cases (still require opt-in by name): internal admin tools used rarely; dev/staging/preview environments; event-driven KEDA workers behind a retry-tolerant queue; background batch jobs ("scale up only when there's work"). Never default to it for customer-facing HTTP APIs, websites, login/auth, payments, B2B endpoints, or anything behind a public domain. Do not set `scaleToZeroDelay` on a workload with `minScale ≥ 1` — it has no effect there. Full rule: `rules/cpln-guardrails.md → "Scale-to-Zero — Never the Default for Production"`.

## Custom Metrics for Autoscaling

To scale on an application metric: expose a Prometheus-formatted endpoint and configure the container `metrics` block (`port` required; `path` default `/metrics`; `dropMetrics` regex to drop noise) — full config in the **`metrics-observability`** skill. The platform scrapes all replicas every **30s**; names prefixed `cpln_` are ignored. Then scale on the metric with the **KEDA Prometheus trigger** above (`sum(my_app_queue_depth{gvc="…", workload="…"})`, etc.).

Before wiring the trigger, confirm the platform is scraping the metric: `mcp__cpln__list_metrics` to see it alongside the built-ins, then `mcp__cpln__query_metrics` to verify the PromQL returns data. Scaling on a metric that never resolves keeps the workload pinned at `minScale`.

## Gotchas

- **KEDA must be enabled on the GVC first** (`spec.keda.enabled: true`) before any workload can use `metric: keda`.
- **Scale-to-zero on Serverless requires `metric: rps` or `concurrency`** — other Serverless metrics don't scale to zero natively (use KEDA). **Cron cannot scale to zero.**
- **Workload type is immutable** — switching to a strategy that needs a different type means delete + recreate (destructive; see the `workload` skill).

## Quick Reference

### MCP Tools

| Tool | Purpose |
|---|---|
| `mcp__cpln__create_workload` | Create a workload with autoscaling config |
| `mcp__cpln__update_workload` | Update autoscaling settings on existing workload |
| `mcp__cpln__get_workload` | Inspect current autoscaling configuration |
| `mcp__cpln__get_workload_deployments` | Check deployment status and replica counts |
| `mcp__cpln__get_workload_events` | View scaling events and errors |
| `mcp__cpln__get_workload_logs` | View workload logs to diagnose scaling issues |
| `mcp__cpln__list_metrics` | Discover metric names/labels (default + custom) before `query_metrics` — never guess |
| `mcp__cpln__query_metrics` | Run a PromQL query to confirm a scaling signal exists before/while debugging |

### CLI Commands

Prefer the MCP tools above. Reach for the CLI when the MCP server is unavailable/unauthenticated, and as the primary interface in CI/CD (service-account `CPLN_TOKEN` + `cpln apply --ready`).

| Command | Purpose |
|---|---|
| `cpln workload create` | Create workload from manifest |
| `cpln workload get WORKLOAD -o yaml` | Inspect autoscaling config |
| `cpln workload get-deployments WORKLOAD` | Check replica counts per location |
| `cpln workload eventlog WORKLOAD` | View scaling events |
| `cpln apply --file manifest.yaml` | Apply autoscaling changes (idempotent) |

### Troubleshooting Scaling

| Symptom | Check |
|---|---|
| Not scaling up | Verify the signal exists (`mcp__cpln__list_metrics` then `mcp__cpln__query_metrics`); check `maxScale`; check readiness probe via `mcp__cpln__get_workload_deployments` |
| Not scaling down | Standard: 5-minute stabilization window; check `minScale` |
| Slow cold starts | Increase `minScale`; optimize container startup; use readiness probe |
| KEDA not triggering | Verify KEDA enabled on GVC; check trigger credentials; verify firewall allows KEDA access |
| Capacity AI not adjusting | Check restrictions (CPU metric, multi metric, stateful, GPU); changes reset history |
| Scale-to-zero not working | Only Serverless with rps/concurrency, or KEDA; check `scaleToZeroDelay` |
| Cron run failed, logs noisy | Per-run logs are scoped by the `replica` label, not just `workload` — use `cpln workload get-deployments` to enumerate `status.jobExecutions[]` (each with its own `replica`, `startTime`, `completionTime`), then query logs with the `replica` label and the execution's time window. See **`logql-observability` → "Cron Workloads — Per-Execution Logs"**. |

### Related Skills

- **cpln-workload** — Start here: the primary workload skill (types, defaults, spec shape) that routes here for scaling & Capacity AI.
- **cpln-metrics-observability** — Built-in metrics, the custom-metrics `metrics` block, Prometheus federation.
- **cpln-workload-security** — Production hardening that pairs with autoscaling.
- **cpln-logql-observability** — LogQL syntax including the per-execution log query for cron workloads.
- **cpln-stateful-storage** — Stateful workloads have different sizing constraints.

## Documentation

- [Autoscaling Reference](https://docs.controlplane.com/reference/workload/autoscaling.md)
- [Capacity AI Reference](https://docs.controlplane.com/reference/workload/capacity.md)
- [Custom Metrics Reference](https://docs.controlplane.com/reference/workload/custom-metrics.md)
- [Export Metrics Guide](https://docs.controlplane.com/guides/export-metrics.md)
