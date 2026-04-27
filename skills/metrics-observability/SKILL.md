---
name: cpln-metrics-observability
description: "Configures workload metrics, Prometheus scraping, and Grafana dashboards on Control Plane. Use when the user asks about CPU/memory/request metrics, custom metrics endpoints, Prometheus federation, centralized Grafana setup, or metric-driven autoscaling."
version: 1.0.0
---

# Metrics & Observability Patterns

## Built-in Metrics

Control Plane provides built-in metrics automatically collected for all workloads without configuration.

### Org Metrics

| Metric | Description |
|:---|:---|
| `logs_storage_mb` | Log storage used in megabytes |
| `tracing_storage_mb` | Tracing storage used in megabytes |
| `metrics_storage_mb` | Metrics storage used in megabytes |
| `agent_peers_count` | Number of agent peers |
| `agent_services_count` | Number of agent services |
| `agent_tx_bytes_total` | Total transmitted bytes by agents |
| `agent_rx_bytes_total` | Total received bytes by agents |
| `agent_tx_packets_total` | Total transmitted packets by agents |
| `agent_rx_packets_total` | Total received packets by agents |
| `threat_detection_forward_enabled` | 0 or 1 indicating if threat detection forwarding is enabled (syslog) |
| `threat_detection_forward_total` | Total threat events forwarded to syslog target |
| `threat_detection_alerts` | Increments when a threat detection alert is generated |

### HTTP/gRPC Metrics

| Metric | Description |
|:---|:---|
| `requests_per_second` | HTTP/gRPC requests received per second |
| `requests_initiated_per_second` | HTTP/gRPC requests initiated per second |
| `request_duration_ms_bucket` | Latency histogram for HTTP/gRPC requests received |

### Volume Metrics

| Metric | Description |
|:---|:---|
| `volume_set_capacity_billable` | Billable capacity of volume sets |
| `volume_set_snapshots_billable` | Billable snapshot capacity of volume sets |
| `volume_set_free_bytes` | Free bytes available in volume sets |
| `volume_set_capacity_bytes` | Total capacity of volume sets in bytes |

### Resource Metrics

| Metric | Description |
|:---|:---|
| `cpu_reserved` | CPU resources reserved |
| `cpu_used` | CPU resources utilized |
| `cpu_billable` | Billable CPU resources |
| `memory_reserved` | Memory resources reserved (bytes) |
| `memory_used` | Memory resources utilized (bytes) |
| `memory_billable` | Billable memory resources (bytes) |

### Network Metrics

| Metric | Description |
|:---|:---|
| `egress` | Egress network traffic (bytes) |
| `cross_zone_traffic` | Cross-zone network traffic (bytes) |

### Workload Metrics

| Metric | Description |
|:---|:---|
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
|:---|:---|
| `domain_warnings` | Number of domain warnings |

### MK8s Metrics

When MK8s has metrics enabled:
- **kube metrics**: `kube_` prefix — from kube-state-metrics
- **node metrics**: `node_` prefix — from node-exporter

## Grafana Access

Control Plane provides a managed Grafana instance per org, accessible via **Metrics** in the Console sidebar (and from the `Metrics` link on any workload). Use **Explore** for ad-hoc PromQL queries. For LogQL queries against workload logs, see the **cpln-logql-observability** skill.

### Observability Settings

Configure retention and default alert recipients at the org level:

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

The managed Grafana ships with two provisioned alert rules. Notifications are **disabled by default** — add a Grafana contact point (or populate `defaultAlertEmails`) to receive them.

| Rule | Fires when |
|:---|:---|
| `container-restarts` | `container_restarts > 1` within the last 5 minutes |
| `stuck-deployments` | A gvc/workload group exceeds one restart within the last 15 minutes |

Edits to built-in rules persist; deletions are recreated on next Grafana login.

### PromQL Examples

Query metrics in Grafana Explore using their names from the built-in metrics list:

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

### Prerequisites

- Superuser access to the source org
- External Prometheus instance with scrape job support

### Setup Steps

**1. Create Service Account in source org:**
- Name: `prometheus-federate`
- Generate a key and save the token

**2. Create Policy granting `readMetrics`:**

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

### Important Notes

- Replace `SOURCE_ORG` with actual org name
- `match[]` param filters which metrics are scraped
- Egress charges apply to scraped metrics
- Repeat for additional orgs with separate service accounts/policies

## Centralized Metrics (Multi-Org Grafana)

View metrics from multiple orgs in a single Grafana instance by adding Prometheus data sources.

### Setup: Add org-2 metrics to org-1 Grafana

**In org-2 (source):**
1. Create Service Account: `grafana-data-source`
2. Generate key and save token
3. Create policy:

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
1. Navigate to **Metrics** > open Grafana
2. Go to **Connections** > **Data Sources**
3. Add new **Prometheus** data source:
   - **Name**: `org-2` (descriptive name)
   - **URL**: `https://metrics.cpln.io/metrics/org/org-2`
   - **Custom HTTP Header**: `authorization` = `Bearer <TOKEN>`
4. Click **Save & Test**

### Multi-Source Dashboard

Import the pre-built multi-source dashboard:
- Download from Grafana dashboard ID `20378` (revision 1)
- Import into org-1 Grafana
- Select data sources per panel

## Custom Metrics

Expose Prometheus-formatted metrics from workloads for monitoring and autoscaling.

### Configuration

Each container can expose metrics at a custom path and port:

```yaml
kind: workload
spec:
  containers:
    - name: my-container
      metrics:
        path: /metrics         # Required, default convention
        port: 9090             # Required, can differ from traffic port
```

**Schema (from Joi):**
- `port`: required, valid port number
- `path`: required, string, max 128 chars, default `/metrics`
- `dropMetrics`: optional array of regex patterns to filter out metrics

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
          - '^go_.*'           # Drop Go runtime metrics
          - '^process_.*'      # Drop process metrics
          - 'MY_UNWANTED_METRIC'
```

### Scraping Behavior

- Scrapes all replicas every **30 seconds** with a **5 second timeout**
- Metric names with prefix `cpln_` are ignored
- Expects Prometheus text format output

### Labels Added to Custom Metrics

| Label | Description |
|:---|:---|
| `org` | Organization name |
| `gvc` | GVC name |
| `location` | Deployment location |
| `provider` | Cloud provider |
| `region` | Cloud region |
| `cluster_id` | Cluster identifier |
| `replica` | Replica identifier |

## Autoscaling Metrics

Custom metrics can drive autoscaling decisions.

### Available Autoscaling Metrics (by workload type)

| Metric | Serverless | Standard | Stateful |
|:---|:---:|:---:|:---:|
| `concurrency` | Yes | No | No |
| `cpu` | Yes | Yes | Yes |
| `memory` | Yes | Yes | Yes |
| `rps` | Yes | Yes | Yes |
| `latency` | No | Yes | Yes |
| `keda` | No | Yes | Yes |
| `disabled` | Yes | Yes | Yes |

### Multi-Target Autoscaling

Standard and stateful workloads support multi-metric scaling (cannot combine with single `metric`):

```yaml
spec:
  defaultOptions:
    autoscaling:
      multi:
        - metric: cpu
          target: 80
        - metric: memory
          target: 70
```

Valid multi-metrics: `cpu`, `memory`, `rps`.

### Metric Percentiles (Latency)

When using `latency` metric, a percentile must be chosen:

```yaml
spec:
  defaultOptions:
    autoscaling:
      metric: latency
      metricPercentile: p50    # Valid: p50, p75, p99
      target: 200              # milliseconds
```

### Constraints

- `metric` and `multi` are mutually exclusive (Joi `.nand()`)
- `target` and `multi` are mutually exclusive
- `target` max 100 when metric is `cpu` or `memory`
- `target` not allowed when metric is `keda`
- Capacity AI cannot be enabled when metric is `cpu` or when `multi` is set; it is not supported for stateful workloads (see the **cpln-autoscaling-capacity** skill)
- Scale-to-zero on standard/stateful workloads requires `metric: keda` (set `minScale: 0` together with a KEDA trigger)
- Serverless scale-to-zero is native but only with `metric: rps` or `concurrency`

## Common Monitoring Patterns

Query built-in metrics in Grafana Explore. Key metrics to monitor:

- **CPU/Memory**: `cpu_used`, `memory_used`, `cpu_reserved`, `memory_reserved`
- **Traffic**: `requests_per_second`, `request_duration_ms_bucket`
- **Stability**: `container_restarts`, `workload_progress_failure`, `workload_ready_replicas`
- **Replicas**: `replica_count`, `workload_rescheduled_replicas`
- **Network**: `egress`, `cross_zone_traffic`

## Quick Reference

### MCP Tools

There is no first-party MCP tool for metric queries — run PromQL via Grafana (Console > Metrics) or against `metrics.cpln.io` with a `readMetrics` service-account token.

| Tool | Use |
|:---|:---|
| `mcp__cpln__get_workload_logs` | Correlate a metric spike with workload logs (see **cpln-logql-observability**) |
| `mcp__cpln__cpln_resource_operation` | Read/update the org `observability` block or workload `metrics` block via generic passthrough |

### Metrics Endpoint

```
https://metrics.cpln.io/metrics/org/{ORG}/api/v1/federate
```

### Grafana Access

Console sidebar > **Metrics** — authenticates automatically.

### Observability Defaults

| Setting | Default | Range |
|:---|:---|:---|
| `metricsRetentionDays` | 30 | 0-3650 |
| `logsRetentionDays` | 30 | 0-3650 |
| `tracesRetentionDays` | 30 | 0-3650 |

### Required Permission

`readMetrics` — grants access to federation endpoint and Grafana data source.

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

### Autoscaling Metrics Quick Ref

| Workload Type | Default Metric | Supports Multi | Scale-to-Zero |
|:---|:---|:---:|:---|
| Serverless | `concurrency` | No | Native (only with `rps` or `concurrency`) |
| Standard | `cpu` | Yes | KEDA only |
| Stateful | `cpu` | Yes | KEDA only |

### Related Skills

- **cpln-logql-observability** — LogQL query syntax, `cpln logs` CLI, and `mcp__cpln__get_workload_logs` tool for correlating metric spikes with log events
- **cpln-autoscaling-capacity** — End-to-end autoscaling configuration including Capacity AI interactions and KEDA trigger setup
- **cpln-external-logging** — Shipping logs to external destinations (retention beyond the `logsRetentionDays` cap)

## Documentation

For the latest reference, see:

- [Default Metrics Guide](https://docs.controlplane.com/guides/default-metrics.md)
- [Centralized Metrics Management](https://docs.controlplane.com/guides/centralized-metrics-management.md)
- [Export Metrics Guide](https://docs.controlplane.com/guides/export-metrics.md)
- [Custom Metrics Reference](https://docs.controlplane.com/reference/workload/custom-metrics.md)
- [Autoscaling Reference](https://docs.controlplane.com/reference/workload/autoscaling.md)
