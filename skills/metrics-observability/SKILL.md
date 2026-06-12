---
name: metrics-observability
description: "Configures workload metrics, Prometheus scraping, and Grafana dashboards on Control Plane. Use when the user asks about CPU/memory/request metrics, custom metrics endpoints, Prometheus federation, or centralized Grafana."
---

# Metrics & Observability Patterns

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

## Query metrics with the MCP tools

For programmatic / agent access, query metrics directly — no Grafana needed:

- **`mcp__cpln__query_metrics`** — run a PromQL query (Prometheus-compatible). Defaults to a range query over the last hour at 60s step; pass `resolution: "instant"` for a point value, or `since` / `from` / `to` / `step` to adjust. Use it to verify autoscaling signals **before** changing scaling settings — measure first, then change.
- **`mcp__cpln__list_metrics`** — discover the metric names and real label values present in the org right now (including CUSTOM metrics and `kube_`/`node_` families) before querying, so PromQL filters are grounded. Reach for it whenever a query returns no series or you're unsure of a name/label.

**PromQL query forms** — gauges (`cpu_used`, `memory_used`, `replica_count`) query bare; counters need `rate()` (e.g. `rate(egress[5m])`, `sum by (workload) (rate(container_restarts[5m]))`); latency is a histogram (`histogram_quantile(0.95, sum by (le) (rate(request_duration_ms_bucket[5m])))`).

Grafana (below) remains the path for dashboards, ad-hoc visual exploration, and alerting.

## Distributed Tracing

Tracing is **opt-in per GVC** and answers a different question than metrics: not "is latency high?" but "**where** inside the request path is it high, and which span failed?"

### Enable tracing on a GVC

Set `spec.tracing` via `mcp__cpln__update_gvc` (or at creation with `mcp__cpln__create_gvc`). Exactly ONE provider:

- **`controlplane`** — built-in backend; traces are stored by Control Plane and queryable with the MCP tools below. Zero extra infrastructure.
- **`otel`** — ship spans to your own OpenTelemetry collector (`endpoint`).
- **`lightstep`** — ship to Lightstep (`endpoint` + access-token secret).

`sampling` is a percentage (e.g. `10` = 10% of requests). `customTags` adds fixed key/values to every span. Only requests served **after** enablement produce traces, and only the sampled fraction.

### Query traces with the MCP tools

Works with the `controlplane` provider (the built-in backend):

- **`mcp__cpln__query_traces`** — search traces. Structured params (`gvc`, `workload`, `location`, `errorsOnly`, `minDuration`) or a raw `traceql` query (which REPLACES the structured params). Span attributes available: `resource.gvc`, `resource.workload`, `resource.location`. The two killer filters: `minDuration: "500ms"` (slow-request finder) and `errorsOnly: true` (failed-request finder).
- **`mcp__cpln__get_trace`** — fetch one trace by ID and read its span tree: per-span durations and services, error spans with status messages. This is the drill-down after `query_traces`.

**Empty results are usually configuration, not absence of a problem**: check tracing is enabled on the GVC (`mcp__cpln__get_resource` kind="gvc" → `spec.tracing`), sampling is high enough to catch traffic, and the workload received requests inside the time window.

**Triage flow**: `query_traces` (`minDuration` or `errorsOnly`) → `get_trace` on the worst trace → the slow/failed span names the culprit service → correlate with `mcp__cpln__get_workload_logs` (same time window) for the application-level error.

## Built-in Metrics

Collected automatically for all workloads, no configuration.

### Org Metrics

| Metric | Description |
|---|---|
| `logs_storage_mb` | Log storage used in megabytes |
| `tracing_storage_mb` | Tracing storage used in megabytes |
| `metrics_storage_mb` | Metrics storage used in megabytes |
| `agent_peers_count` | Number of agent peers |
| `agent_services_count` | Number of agent services |
| `agent_tx_bytes_total` | Total transmitted bytes by agents |
| `agent_rx_bytes_total` | Total received bytes by agents |
| `agent_tx_packets_total` | Total transmitted packets by agents |
| `agent_rx_packets_total` | Total received packets by agents |
| `threat_detection_forward_enabled` | 0 or 1: threat detection forwarding enabled (syslog) |
| `threat_detection_forward_total` | Total threat events forwarded to syslog target |
| `threat_detection_alerts` | Increments when a threat detection alert is generated |

### HTTP/gRPC Metrics

| Metric | Description |
|---|---|
| `requests_per_second` | HTTP/gRPC requests received per second |
| `requests_initiated_per_second` | HTTP/gRPC requests initiated per second |
| `request_duration_ms_bucket` | Latency histogram for HTTP/gRPC requests received |

### Volume Metrics

| Metric | Description |
|---|---|
| `volume_set_capacity_billable` | Billable capacity of volume sets |
| `volume_set_snapshots_billable` | Billable snapshot capacity of volume sets |
| `volume_set_free_bytes` | Free bytes available in volume sets |
| `volume_set_capacity_bytes` | Total capacity of volume sets in bytes |

### Resource Metrics

| Metric | Description |
|---|---|
| `cpu_reserved` | CPU resources reserved |
| `cpu_used` | CPU resources utilized |
| `cpu_billable` | Billable CPU resources |
| `memory_reserved` | Memory resources reserved (bytes) |
| `memory_used` | Memory resources utilized (bytes) |
| `memory_billable` | Billable memory resources (bytes) |

### Network Metrics

| Metric | Description |
|---|---|
| `egress` | Egress network traffic (bytes) |
| `cross_zone_traffic` | Cross-zone network traffic (bytes) |

### Workload Metrics

| Metric | Description |
|---|---|
| `replica_count` | Number of replicas |
| `container_restarts` | Number of container restarts |
| `load_balancer` | Number of load balancers |
| `cron_executions` | Number of cron job executions |
| `cron_execution_rate` | Rate of cron job executions |
| `workload_progress_failure` | Number of workload progress failures |
| `workload_ready_replicas` | Number of ready replicas |
| `workload_rescheduled_replicas` | Number of replicas rescheduled to other nodes |
| `capacity_ai_updates` | Number of times Capacity AI updated workload resources |

### Domain Metrics

| Metric | Description |
|---|---|
| `domain_warnings` | Number of domain warnings |

### MK8s Metrics

When MK8s has metrics enabled:
- **kube metrics**: `kube_` prefix — from kube-state-metrics
- **node metrics**: `node_` prefix — from node-exporter

## Grafana Access

Control Plane provides a managed Grafana instance per org, accessible via **Metrics** in the Console sidebar (and the `Metrics` link on any workload). Use **Explore** for ad-hoc PromQL queries. For LogQL queries against workload logs, see the **cpln-logql-observability** skill.

### Observability Settings

Configure retention and default alert recipients at the org level. No typed MCP tool edits the org `observability` block, so apply it via the CLI: call `mcp__cpln__get_resource_schema` for the `org` kind to confirm the shape, then `cpln apply -f org.yaml`.

```yaml
kind: org
spec:
  observability:
    logsRetentionDays: 30       # int, 0-3650, default 30 (0 disables collection)
    metricsRetentionDays: 30    # int, 0-3650, default 30
    tracesRetentionDays: 30     # int, 0-3650, default 30
    defaultAlertEmails:         # email[]; used by the grafana-default-email contact point
      - ops@example.com
```

Combined storage of logs, metrics, and traces is charged per GB-month over 100 GB.

### Built-in Alert Rules

The managed Grafana ships two provisioned alert rules. Notifications are **disabled by default** — add a Grafana contact point (or populate `defaultAlertEmails`) to receive them.

| Rule | Fires when |
|---|---|
| `container-restarts` | `container_restarts > 1` within the last 5 minutes |
| `stuck-deployments` | A gvc/workload group exceeds one restart within the last 15 minutes |

Edits to built-in rules persist; deletions are recreated on next Grafana login.

### PromQL Examples

Query in Grafana Explore using built-in metric names:

```promql
requests_per_second
cpu_used
memory_used
request_duration_ms_bucket
container_restarts
replica_count
```

## Exporting Metrics (Prometheus Federation)

Export metrics to external Prometheus via the `/federate` endpoint at `metrics.cpln.io`.

**Prerequisites:** superuser access to the source org; an external Prometheus with scrape job support.

**1. Create Service Account in source org** — `mcp__cpln__add_key_to_service_account` (creates the SA if needed, adds a key, returns the token):
- Name: `prometheus-federate`
- Save the returned key — it is shown only once

**2. Create Policy granting `readMetrics`** — `mcp__cpln__create_policy`:

```yaml
kind: policy
name: prometheus-federate
description: prometheus-federate
tags: {}
bindings:
  - permissions:
      - readMetrics
    principalLinks:
      - /org/SOURCE_ORG/serviceaccount/prometheus-federate
target: all
targetKind: org
```

**3. Configure Prometheus scrape job:**

```yaml
scrape_configs:
  - job_name: 'federate'
    scrape_interval: 1m
    honor_labels: true
    scheme: https
    metrics_path: '/metrics/org/SOURCE_ORG/api/v1/federate'
    params:
      'match[]':
        - '{__name__=~".+"}'    # Adjust matcher as needed
    authorization:
      type: Bearer
      credentials: "${CPLN_SERVICE_ACCOUNT_TOKEN}"
    static_configs:
      - targets:
          - 'metrics.cpln.io'
```

Notes: replace `SOURCE_ORG` with the actual org name; `match[]` filters which metrics are scraped; egress charges apply; repeat per org with separate service accounts/policies.

**Token trap:** `metrics.cpln.io` (and `logs.cpln.io`) authenticate **user and service-account tokens** — a workload's injected `CPLN_TOKEN` does **not** work there, even with `readMetrics` granted to its identity (it only authenticates against the in-mesh API at `CPLN_ENDPOINT`; see the `workload` skill). To query metrics from inside a workload, use a service-account key.

## Centralized Metrics (Multi-Org Grafana)

View metrics from multiple orgs in one Grafana by adding Prometheus data sources.

**In org-2 (source):**
1. Create Service Account `grafana-data-source` with a key — `mcp__cpln__add_key_to_service_account` (save the returned token; shown only once)
2. Create policy — `mcp__cpln__create_policy`:

```yaml
kind: policy
name: grafana-data-source
description: grafana-data-source
tags: {}
bindings:
  - permissions:
      - readMetrics
    principalLinks:
      - /org/org-2/serviceaccount/grafana-data-source
target: all
targetKind: org
```

**In org-1 (viewer) Grafana:**
1. **Metrics** > open Grafana > **Connections** > **Data Sources**
2. Add a **Prometheus** data source:
   - **Name**: `org-2` (descriptive)
   - **URL**: `https://metrics.cpln.io/metrics/org/org-2`
   - **Custom HTTP Header**: `authorization` = `Bearer <TOKEN>`
3. **Save & Test**

**Multi-source dashboard:** download Grafana dashboard ID `20378` (revision 1), import into org-1, select data sources per panel.

## Custom Metrics

Expose Prometheus-formatted metrics from workloads for monitoring and autoscaling. The container `metrics` block lives inside the workload spec — set it at creation with `mcp__cpln__create_workload` or add it later with `mcp__cpln__update_workload` (PATCH; call `mcp__cpln__get_resource` (kind="workload") first). If the typed tool doesn't surface the nested `metrics` field, fall back to the CLI: `mcp__cpln__get_resource_schema` for the `workload` kind, then `cpln apply -f workload.yaml`.

```yaml
kind: workload
spec:
  containers:
    - name: my-container
      metrics:
        path: /metrics         # Required, string, max 128 chars, default /metrics
        port: 9090             # Required, valid port; can differ from traffic port
        dropMetrics:           # Optional: regex patterns to filter out metrics
          - '^go_.*'           # Drop Go runtime metrics
          - '^process_.*'      # Drop process metrics
          - 'MY_UNWANTED_METRIC'
```

### Scraping Behavior

- Scrapes all replicas every **30 seconds**
- Metric names with prefix `cpln_` are ignored
- Expects Prometheus text format output

### Labels Added to Custom Metrics

| Label | Description |
|---|---|
| `org` | Organization name |
| `gvc` | GVC name |
| `location` | Deployment location |
| `provider` | Cloud provider |
| `region` | Cloud region |
| `cluster_id` | Cluster identifier |
| `replica` | Replica identifier |

## Autoscaling Metrics

Custom and built-in metrics can drive autoscaling decisions. This skill covers only **which metrics are available per workload type**; for scaling strategy, YAML config, percentiles, multi-metric, KEDA, and Capacity AI interactions, see the **cpln-autoscaling-capacity** skill.

### Available Autoscaling Metrics (by workload type)

| Metric | Serverless | Standard | Stateful |
|---|:---:|:---:|:---:|
| `concurrency` | Yes | No | No |
| `cpu` | Yes | Yes | Yes |
| `memory` | Yes | Yes | Yes |
| `rps` | Yes | Yes | Yes |
| `latency` | No | Yes | Yes |
| `keda` | No | Yes | Yes |
| `disabled` | Yes | Yes | Yes |

## Common Monitoring Patterns

Query built-in metrics in Grafana Explore. Key metrics to monitor:

- **CPU/Memory**: `cpu_used`, `memory_used`, `cpu_reserved`, `memory_reserved`
- **Traffic**: `requests_per_second`, `request_duration_ms_bucket`
- **Stability**: `container_restarts`, `workload_progress_failure`, `workload_ready_replicas`
- **Replicas**: `replica_count`, `workload_rescheduled_replicas`
- **Network**: `egress`, `cross_zone_traffic`

## Quick Reference

### MCP Tools

Query metrics with the typed MCP tools — no Grafana round-trip needed. Grafana stays the path for dashboards, visual exploration, and alerting.

| Tool | Use |
|---|---|
| `mcp__cpln__list_metrics` | Discover metric names and real label values (built-in + custom) before querying |
| `mcp__cpln__query_metrics` | Run a PromQL query (Prometheus-compatible) against Control Plane metrics |
| `mcp__cpln__query_traces` | Search distributed traces (TraceQL) — find slow (`minDuration`) or failed (`errorsOnly`) requests |
| `mcp__cpln__get_trace` | Fetch one trace's span tree to see where latency/failures sit inside the request path |
| `mcp__cpln__get_workload_logs` | Correlate a metric spike with workload logs (see **cpln-logql-observability**) |

No typed MCP tool edits the org `observability` block or a workload's `metrics` block. To change either, fall back to the CLI: `mcp__cpln__get_resource_schema` for the `org` (or `workload`) kind, author the manifest, then `cpln apply -f manifest`.

### Metrics Endpoint

```
https://metrics.cpln.io/metrics/org/{ORG}/api/v1/federate
```

### Grafana Access

Console sidebar > **Metrics** — authenticates automatically.

### Observability Defaults

| Setting | Default | Range |
|---|---|---|
| `metricsRetentionDays` | 30 | 0-3650 |
| `logsRetentionDays` | 30 | 0-3650 |
| `tracesRetentionDays` | 30 | 0-3650 |

### Required Permission

`readMetrics` — grants access to the federation endpoint and Grafana data source.

### Custom Metrics Config

```yaml
containers:
  - name: app
    metrics:
      port: 9090          # Required
      path: /metrics      # Required, max 128 chars
      dropMetrics:        # Optional regex filters
        - '^go_.*'
```

### Related Skills

- **cpln-workload** — Start here: the primary workload skill (types, defaults, spec shape) that routes here for metrics detail.
- **cpln-autoscaling-capacity** — Scaling strategy, per-metric YAML, multi-metric, latency percentiles, KEDA, Capacity AI, and scale-to-zero.
- **cpln-logql-observability** — LogQL query syntax, `cpln logs` CLI, and `mcp__cpln__get_workload_logs` for correlating metric spikes with log events.
- **cpln-external-logging** — Shipping logs to external destinations (retention beyond the `logsRetentionDays` cap).

## Documentation

- [Default Metrics Guide](https://docs.controlplane.com/guides/default-metrics.md)
- [Centralized Metrics Management](https://docs.controlplane.com/guides/centralized-metrics-management.md)
- [Export Metrics Guide](https://docs.controlplane.com/guides/export-metrics.md)
- [Custom Metrics Reference](https://docs.controlplane.com/reference/workload/custom-metrics.md)
- [Autoscaling Reference](https://docs.controlplane.com/reference/workload/autoscaling.md)
