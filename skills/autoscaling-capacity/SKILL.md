---
name: autoscaling-capacity
description: "Workload autoscaling and Capacity AI on Control Plane. Use when the user asks about scaling up/down, min/max replicas, scale-to-zero, concurrency/RPS/CPU/memory/latency scaling, KEDA, event-driven scaling, or right-sizing."
---

# Autoscaling & Capacity AI

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Deep skill for scaling and resource optimization. Everything scaling lives in **one block** — `spec.defaultOptions.autoscaling` (with `capacityAI` beside it); `spec.localOptions[]` overrides it per location. The platform keeps the chosen metric near but below `target`. For workload types, production defaults, and the spec shape, start with the **`workload`** skill.

## Picking a metric

| Metric | Scales on | Types | Notes |
|---|---|---|---|
| `concurrency` | avg in-flight requests per replica | **serverless only** (its default) | pair with `maxConcurrency` for a hard per-replica cap |
| `rps` | requests per second per replica | all three | consistent-response-time HTTP |
| `cpu` | % of allocated CPU | all three (standard/stateful default) | `target` ≤ 100; conflicts with Capacity AI (below) |
| `memory` | % of allocated memory | all three | `target` ≤ 100 |
| `latency` | response time in **ms** at `metricPercentile` | standard / stateful | `p50` (default) / `p75` / `p99`; `target` is ms, not % |
| `multi[]` | several metrics; highest replica count wins | standard / stateful | entries from `cpu` / `memory` / `rps` only, each at most once; **replaces** `metric` and top-level `target` |
| `keda` | external / event-driven triggers | standard / stateful | GVC must enable KEDA first; `target` is rejected |
| `disabled` | nothing — fixed at `minScale` | all | realized as min = max |

If `metric` is omitted, serverless defaults to `concurrency`; standard/stateful default to `cpu`. A metric invalid for the workload type is **rejected** (e.g. `concurrency` on standard).

**The metric constrains the type — decide them together.** Type is chosen at creation and is immutable, so a metric-type mismatch is a *type* problem, not a metric problem. The most common case: concurrency-style scaling on a standard workload — the fix is to create the workload as **serverless** (concurrency lives only there) or use **`rps`** on standard (the closest equivalent), not to retry with the same pairing.

**Don't silently downgrade.** If a type constraint blocks the user's stated intent (concurrency scaling on stateful, Capacity AI on a CPU-scaled workload), surface the conflict with realistic alternatives and a recommendation — per the constraint-conflicts rule in `cpln-guardrails.md`. `disabled` with `min=max=1` is sometimes right (single-writer app), but say so explicitly.

## The autoscaling block

Set with `mcp__cpln__create_workload` / `mcp__cpln__update_workload`, then verify with `mcp__cpln__list_deployments`. All fields:

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: rps
      target: 100             # default 95; integer 1-20000; ≤100 for cpu/memory; ms for latency
      minScale: 2             # default 1; must be ≤ maxScale; 0 = scale-to-zero (rules below)
      maxScale: 10            # default 5; no schema maximum
      scaleToZeroDelay: 300   # 30-3600s, default 300
      maxConcurrency: 0       # serverless only; 0-30000, default 0 = unlimited (excess queues)
      metricPercentile: p99   # latency only: p50 (default) / p75 / p99
    capacityAI: true
```

- **Per-location overrides:** `spec.localOptions[]` (same fields + `location`) via `mcp__cpln__configure_workload_local_options` — also the only MCP home of `capacityAIUpdateMinutes`, `spot`, and `multiZone`; it replaces the full list.
- **`scaleToZeroDelay` is dual-purpose:** on serverless it is the idle period before scaling to 0; on standard/stateful it sets the **scale-down stabilization window** (default 300s) — scale-up is immediate.

### Multi-metric (standard/stateful)

```yaml
autoscaling:
  minScale: 2
  maxScale: 10
  multi:
    - metric: cpu
      target: 80
    - metric: memory
      target: 80
```

Each entry is evaluated independently; the highest replica count wins. Only `cpu` / `memory` / `rps`, each at most once; targets go inside the entries (`metric`/`target` at the top level are rejected alongside `multi`). With `multi`, Capacity AI defaults to off.

## minScale / maxScale & scale-to-zero

- **Production default is `minScale: 2`** for user-facing services; pick `1` only with a named reason (single-writer DB, leader election, dev/staging). `maxScale` stays at its default `5` unless the user names a maximum — set exactly what they name, never invent a cap.
- **Scale-to-zero (`minScale: 0`) by type:** serverless — allowed freely; standard/stateful — **only with `metric: keda`** (anything else is rejected); cron — never. On serverless it reaches zero with `concurrency`/`rps`; `cpu`/`memory` ride an HPA that won't drop to zero.
- **Never the AI's default** — even on serverless, even when the user said "auto-scale". Configure it only when the user asked for scale-to-zero by name; the next request after idle pays a cold start. Acceptable (still opt-in): rarely-used internal tools, dev/preview environments, KEDA workers behind a retry-tolerant queue. Full rule: `cpln-guardrails.md`.

## KEDA (event-driven, standard/stateful)

**1. Enable on the GVC first** — `mcp__cpln__update_gvc`:

```yaml
spec:
  keda:
    enabled: true                            # default false
    identityLink: //gvc/GVC/identity/NAME    # optional: cloud/network access for the KEDA operator
    secrets: [//secret/NAME]                 # optional: each becomes a TriggerAuthentication named after the secret
```

**2. Set the workload** — `metric: keda` plus raw [KEDA trigger specs](https://keda.sh/) (passed through as-is):

```yaml
autoscaling:
  metric: keda          # target is rejected with keda
  minScale: 0           # maps to KEDA minReplicaCount — this is how standard/stateful scale to zero
  maxScale: 10
  keda:
    triggers:
      - type: redis
        metadata:
          address: my-redis.my-gvc.cpln.local:6379
          queueLength: '5'
          passwordFromEnv: REDIS_PASSWORD
```

- Triggers needing auth reference a GVC-listed secret via `authenticationRef.name` (the TriggerAuthentication is named after the secret).
- If the trigger source is a Control Plane workload, allow KEDA in the source's firewall: `internal.inboundAllowWorkload: [cpln://internal/keda]`.
- Also supported: `keda.advanced.scalingModifiers` (custom formulas), `fallback`, `pollingInterval`, `cooldownPeriod`.
- **Prometheus trigger** — scale on any platform or custom metric: `type: prometheus` with `serverAddress: https://metrics.cpln.io:443/metrics/org/ORG`, a `query` (PromQL), `threshold`, and `customHeaders: Authorization=Bearer SERVICE_ACCOUNT_TOKEN` (service account needs `readMetrics`). **Before wiring any trigger, confirm the signal resolves:** `mcp__cpln__list_metrics` for real names/labels, then `mcp__cpln__query_metrics` to run the PromQL — a never-resolving signal pins the workload at `minScale`. Custom app metrics come from the container `metrics` block (see **metrics-observability**).

## Capacity AI

Right-sizes each container's **reserved** resources (what you're billed for) from usage history, between the `minCpu`/`minMemory` floor and the `cpu`/`memory` ceiling. **On by default for serverless and standard; stripped on stateful and cron.**

```yaml
spec:
  containers:
    - name: app
      cpu: '1000m'       # ceiling (and the fixed allocation when Capacity AI is off)
      memory: '1Gi'      # ceiling
      minCpu: '100m'     # floor
      minMemory: '256Mi' # floor
  defaultOptions:
    capacityAI: true
```

- **With `metric: cpu`:** explicitly enabling Capacity AI is **rejected** (dynamic CPU allocation fights CPU-based scaling); left unset with `cpu` or `multi`, it silently defaults to **off**.
- **GPU containers reject Capacity AI.**
- Adjustments land **in place** on standard when the cluster supports pod resize (no restart; otherwise a rolling update); on serverless they roll a new revision. Throttle frequency with `capacityAIUpdateMinutes` (min 2 — via `localOptions` or `cpln apply`; not on create/update tools).
- Idle floor is **25m** CPU, rising with memory at **1 millicore per 3 MiB**. A just-changed workload pauses adjustments while history rebuilds — apps that reserve resources at startup may not benefit.

### Resource bounds (all types)

- Floors: CPU ≥ `25m`, memory ≥ `32Mi`; `minCpu ≤ cpu`, `minMemory ≤ memory`; `memory(MiB) / cpu(millicores) ≤ 8` (32 with tag `cpln/relaxMemoryToCpuRatio`).
- **Without Capacity AI** (standard/serverless, explicit off): `cpu`/`memory` are the fixed allocation; `minCpu`/`minMemory` are ignored.
- **Stateful** has no Capacity AI, but `minCpu`/`minMemory` still work: they become the static **reserved** request while `cpu`/`memory` stay the burst ceiling. Constraints: max/min ratio ≤ **4** AND gap ≤ **4000m** CPU / **4096Mi** memory.
- **GPU:** `nvidia` model `t4` (quantity up to 4) or `a10g` (exactly 1); strict per-model CPU/memory minimums — fetch exact numbers with `mcp__cpln__get_resource_schema` (`kind: workload`).
- **Cost:** billing follows reserved resources, so Capacity AI (or stateful `minCpu`) directly lowers cost.

## Type × scaling matrix

| | standard | serverless | stateful | cron |
|---|---|---|---|---|
| Metrics | cpu, memory, latency, rps, multi, keda, disabled | concurrency, cpu, memory, rps, disabled | same as standard | none — autoscaling stripped |
| Capacity AI | default on | default on | stripped | stripped |
| Scale to zero | keda only | yes (concurrency/rps) | keda only | no |
| Resize without restart | yes | no (new revision) | — | — |

## Troubleshooting

| Symptom | Check |
|---|---|
| Not scaling up | Does the signal exist? `mcp__cpln__list_metrics` then `mcp__cpln__query_metrics`; check `maxScale`; check replica readiness via `mcp__cpln__list_deployments` |
| Not scaling down | Standard/stateful stabilization window = `scaleToZeroDelay` (default 300s); check `minScale` |
| Scale-to-zero not happening | Serverless needs `concurrency`/`rps`; standard/stateful need `metric: keda`; check `scaleToZeroDelay` |
| KEDA not triggering | KEDA enabled on the GVC? Trigger auth secret listed in `gvc.spec.keda.secrets`? Source firewall allows `cpln://internal/keda`? |
| Capacity AI not adjusting | Restrictions (cpu metric, stateful, GPU); recent spec change pauses it; `capacityAIUpdateMinutes` throttle |
| Replicas stuck at `minScale` | The scaling metric never resolves — verify the PromQL/trigger returns data |

## Quick reference — MCP tools

| Tool | Purpose |
|---|---|
| `mcp__cpln__create_workload` / `mcp__cpln__update_workload` | The `autoscaling` block (incl. `multi`, `keda`) and `capacityAI` |
| `mcp__cpln__configure_workload_local_options` | Per-location overrides; `capacityAIUpdateMinutes`, `spot`, `multiZone` |
| `mcp__cpln__update_gvc` | Enable KEDA on the GVC (`keda.enabled`, `identityLink`, `secrets`) |
| `mcp__cpln__list_deployments` | Replica counts and readiness per location |
| `mcp__cpln__get_workload_events` | Scaling/scheduling events and errors |
| `mcp__cpln__list_metrics` / `mcp__cpln__query_metrics` | Discover metric names/labels, then verify the scaling signal — never guess |

**CLI fallback** (read the `cpln` skill first): `cpln apply -f manifest.yaml` for the full spec incl. `capacityAIUpdateMinutes`; primary interface in CI/CD (`CPLN_TOKEN` + `cpln apply --ready`).

## Related skills

| Need | Skill |
|---|---|
| Workload types, production defaults, spec shape — start here | `workload` |
| Custom `metrics` block, built-in metrics, PromQL | `metrics-observability` |
| Scaling-event and per-execution cron logs | `logql-observability` |
| Stateful sizing and volume sets | `stateful-storage` |

## Documentation

- [Autoscaling Reference](https://docs.controlplane.com/reference/workload/autoscaling.md)
- [Capacity AI Reference](https://docs.controlplane.com/reference/workload/capacity.md)
- [Custom Metrics Reference](https://docs.controlplane.com/reference/workload/custom-metrics.md)
- [Export Metrics Guide](https://docs.controlplane.com/guides/export-metrics.md)
