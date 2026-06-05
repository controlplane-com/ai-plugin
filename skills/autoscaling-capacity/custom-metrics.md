# Custom Metrics & Resource Allocation

Companion to `skills/autoscaling-capacity/SKILL.md`. Read this when exposing custom Prometheus metrics from a workload, scaling on those metrics via KEDA, or working through the resource-allocation rules that interact with autoscaling.

## Custom Metrics (Prometheus)

Workloads can expose Prometheus-formatted metrics for monitoring and KEDA-based autoscaling.

### Exposing Custom Metrics

Your application must serve a Prometheus-formatted metrics endpoint:

```text
MY_COUNTER 788
NUM_ORDERS 91
queue_depth 42
```

### Configuration

The `metrics` block lives in the container spec. Apply it via MCP — `mcp__cpln__create_workload` for a new workload or `mcp__cpln__update_workload` to add scraping to an existing one — then confirm the spec took with `mcp__cpln__get_workload`. Because adding or changing the `metrics` block redeploys the workload, poll `mcp__cpln__get_workload_deployments` until every location reports ready. (Fallback when MCP is unavailable, or in CI/CD: `cpln apply -f manifest.yaml`.)

```yaml
spec:
  containers:
    - name: my-container
      metrics:
        path: /metrics     # convention, any path works
        port: 9090         # can differ from the traffic port
```

- Platform scrapes all replicas every **30 seconds** with a 5-second timeout.
- Metric names prefixed with `cpln_` are ignored by the scraper.
- Collected metrics include labels: `org`, `gvc`, `location`, `provider`, `region`, `cluster_id`, `replica`.

### Filtering Metrics

Drop unwanted metrics with regex patterns:

```yaml
spec:
  containers:
    - name: my-container
      metrics:
        path: /metrics
        port: 9090
        dropMetrics:
          - '^go_.*'        # Drop Go runtime metrics
          - '^process_.*'   # Drop process metrics
```

### Using Custom Metrics for Autoscaling

Custom metrics are available via the Control Plane Prometheus endpoint at `metrics.cpln.io`. Use them with KEDA's Prometheus trigger (see `skills/autoscaling-capacity/metric-configs.md` → KEDA with Prometheus). Replace the `query` with your custom metric, e.g.:

```promql
sum(my_app_queue_depth{gvc="GVC_NAME", workload="WORKLOAD_NAME"})
```

Before wiring a KEDA trigger to a custom metric, confirm the platform is actually scraping it: call `mcp__cpln__list_metrics` to see the metric name and labels the scraper picked up (custom metrics show up alongside the built-in defaults), then run `mcp__cpln__query_metrics` with your PromQL to verify the signal returns data. If the metric is missing, the `metrics` block above is misconfigured — scaling on a metric that never resolves keeps the workload pinned at `minScale`.

## Resource Allocation & Scaling Interaction

### CPU/Memory and Autoscaling

- **With Capacity AI enabled:** Set `cpu`/`memory` as upper bounds and `minCpu`/`minMemory` as lower bounds. Capacity AI adjusts within this range.
- **Without Capacity AI:** `cpu`/`memory` are the fixed allocation. `minCpu`/`minMemory` are ignored (except for Stateful workloads).
- **CPU metric + Capacity AI:** Mutually exclusive. Cannot scale by CPU utilization percentage if CPU allocation itself is dynamic.
- **Memory-to-CPU ratio constraint:** `memory(MiB) / cpu(millicores)` must be ≤ 8 (relaxed to 32 with the `cpln/relaxMemoryToCpuRatio` tag).

### GPU Constraints

- GPU workloads cannot use Capacity AI.
- GPU models: **Nvidia T4** (1–4 per replica), **Nvidia A10g** (1 per replica).
- GPU workloads have strict minimum CPU/memory requirements (fetch the exact constraints with `mcp__cpln__get_resource_schema`, `kind: workload`).
- No additional GPU charges — standard CPU/memory/egress billing applies.

### Stateful Resource Optimization

Stateful workloads do not support Capacity AI. Instead, optimize costs with `minCpu` and `minMemory`:

- `minCpu` and `cpu` can be at most **4000m** apart; ratio must be at least **1:4**.
- `minMemory` and `memory` can be at most **4096Mi** apart; ratio must be at least **1:4**.

### Cost Impact of Capacity AI

Capacity AI reduces costs by right-sizing containers based on actual usage. Billing is based on the **reserved** (allocated) resources, so lower allocations = lower cost. Changes to a workload **reset** historical usage and restart the analysis process. Applications that reserve resources at startup and do not scale dynamically may not benefit from Capacity AI.
