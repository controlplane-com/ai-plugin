# Per-Metric Autoscaling Configuration

Companion to `skills/autoscaling-capacity/SKILL.md`. Each section below shows the full YAML for one autoscaling metric. Read this when actually authoring `spec.defaultOptions.autoscaling`.

## Concurrency (Serverless Only)

Tracks average in-flight requests per replica. Best for workloads where request duration varies.

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: concurrency
      target: 100
      maxConcurrency: 0       # 0 = unlimited; 1-30000 for hard cap
      minScale: 1
      maxScale: 10
      scaleToZeroDelay: 300   # seconds (30-3600) before scaling to 0
```

- **`target`** — desired average concurrent requests per replica.
- **`maxConcurrency`** — hard limit; excess requests queue until capacity is available.
- **`scaleToZeroDelay`** — only applies when `minScale: 0`.
- Serverless evaluates capacity every **2 seconds**; averages over 60s, bursts trigger 6s averaging for 60s.

## Requests Per Second

Counts raw requests per second divided by replicas. Simpler than concurrency; ignores request duration.

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: rps
      target: 100
      minScale: 1
      maxScale: 10
```

- Standard workloads: metric calculated every **20 seconds**, averaged over 60s.
- Serverless workloads: evaluated every **2 seconds**.
- Supports scale to zero on Serverless when `minScale: 0`.

## CPU Utilization

Percentage of allocated CPU consumed. Target is a percentage (max 100).

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: cpu
      target: 80
      minScale: 1
      maxScale: 5
```

- Metric calculated every **15 seconds**, averaged over 15s.
- **Capacity AI is NOT available** with CPU metric — dynamic CPU allocation conflicts with CPU-based scaling.
- Use for compute-heavy, non-HTTP workloads.

## Request Latency (Standard/Stateful Only)

Scales based on response time at a chosen percentile. Not available for Serverless.

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: latency
      target: 100            # milliseconds
      metricPercentile: p99  # p50 (default), p75, or p99
      minScale: 1
      maxScale: 5
```

- Metric calculated every **20 seconds**, averaged over 60s at the specified percentile.
- Target is in **milliseconds**, not a percentage.

## Memory Utilization

Percentage of allocated memory consumed. Target is a percentage (max 100).

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: memory
      target: 80
      minScale: 1
      maxScale: 5
```

- Metric calculated every **15 seconds**, averaged over 15s.

## Multi Metric (Standard/Stateful Only)

Combine multiple metrics. Each metric is evaluated independently; the highest resulting replica count applies.

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

- Each metric in `multi[]` must be unique.
- **`metric` and `multi` are mutually exclusive** — use one or the other.
- **`target` and `multi` are mutually exclusive** — targets go inside each `multi` entry.
- Capacity AI is **NOT available** with multi metric.
- Not available for Serverless.

## KEDA (Standard/Stateful Only)

Event-driven autoscaling using [KEDA](https://keda.sh/) triggers. Scales based on external metrics like queue lengths, Kafka lag, or Prometheus queries.

**Prerequisite:** Enable KEDA on the GVC first:

```yaml
# GVC spec
spec:
  keda:
    enabled: true
    identityLink: //identity/keda-identity   # optional, for cloud/network access
    secrets:                                  # optional, for TriggerAuthentication
      - //secret/keda-secret-1
```

**Workload config:**

```yaml
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

- **Do NOT set `target`** when using `keda` metric — it is not allowed.
- If the trigger source is a Control Plane workload, allow KEDA access in the source's firewall:

  ```yaml
  firewallConfig:
    internal:
      inboundAllowWorkload:
        - cpln://internal/keda
  ```

- For triggers needing auth, reference a secret added to the GVC's keda config via `authenticationRef.name`.
- Advanced options support `scalingModifiers` with custom formulas.

### KEDA with Prometheus Metrics

Scale using PromQL queries against Control Plane's metrics endpoint:

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
                histogram_quantile(0.99,
                  sum(rate(request_duration_ms_bucket{
                    gvc="GVC_NAME", workload="WORKLOAD_NAME"
                  }[5m])) by (le))
              threshold: '1000'
              activationThreshold: '0'
            name: workload-latency
```

Requires a service account with `readMetrics` permission. See the [export metrics guide](https://docs.controlplane.com/guides/export-metrics.md).
