---
name: metrics-observability
description: "Workload metrics, PromQL, Grafana, and tracing on Control Plane. Use to observe or troubleshoot a workload via CPU/memory/request or custom metrics, traces, Prometheus federation, alerts, or metrics retention."
---

# Metrics, Tracing & Observability

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Control Plane stores every workload's metrics as Prometheus-compatible time series in a managed backend (Mimir), queryable in PromQL through the per-org managed Grafana or the MCP tools. The org is the tenant — it comes from the endpoint path, so there is no `org=` label and no cross-org queries. Two traps dominate. **Series names are short:** memory is `mem_used` / `mem_reserved` / `mem_billable`, not `memory_*` — a `memory_used` query returns nothing, so ground names with `list_metrics` first. **Rate-shaped metrics are pre-rated:** `egress`, `requests_per_second`, and the latency buckets are already rated by the platform's recording rules, so you query them bare — wrapping them in `rate()` again returns garbage. Finally, a workload's in-pod `CPLN_TOKEN` cannot authenticate to the metrics endpoint; querying from outside the mesh needs a user or service-account token.

## Two ways to query

- **MCP (primary for agents):** `mcp__cpln__query_metrics` runs a PromQL query — a range query over the last `1h` at `60s` step by default; pass `resolution: "instant"` for a single point, or `since` / `from` / `to` / `step` to adjust. `mcp__cpln__list_metrics` discovers the metric names and real label values present in the org right now (built-in, `kube_`/`node_`, and custom); pass `metric:` to ground one metric's live labels before filtering. Reach for it whenever a query returns no series. Measure first, then change scaling settings.
- **Grafana:** the managed per-org instance — open **Metrics** in the Console sidebar (or the **Metrics** link on any workload), use **Explore** for ad-hoc PromQL, and dashboards/alerting for the rest. The `grafanaAdmin` org permission grants the Grafana Admin role; everyone else is Viewer.

`list_metrics`' built-in catalog still spells memory `memory_*`; trust the live names it returns (and this skill) — the queryable series is `mem_*`.

## PromQL: query the right shape

The platform pre-computes rates, so the shape decides the query form:

- **Gauges — query bare:** `cpu_used`, `mem_used`, `replica_count`, `workload_ready_replicas`.
- **Pre-rated gauges — query bare, never `rate()`:** `egress` and `cross_zone_traffic` (bytes per minute), `requests_per_second`, `requests_initiated_per_second`, `cron_execution_rate`.
- **Histogram — `histogram_quantile`, no extra `rate()`:** `request_duration_ms_bucket` keeps its `le` label and is already rated.
- **Cumulative counters — wrap in `increase()` / `rate()` for velocity:** `container_restarts`, `cron_executions`, `workload_progress_failure`, `workload_rescheduled_replicas`, `domain_warnings`.

```promql
cpu_used                                              # cores in use, per replica (bare gauge)
sum by (workload) (mem_used)                          # memory bytes per workload — mem_, not memory_
egress                                                # outbound bytes/minute (already rated — no rate())
sum by (workload) (requests_per_second{response_class="500"})   # 5xx rate; response_class is "200".."500"
histogram_quantile(0.95, sum by (le) (request_duration_ms_bucket))   # p95 latency (ms); no rate() wrapper
sum by (gvc, workload) (increase(container_restarts[5m]))           # restarts in the last 5m
```

## Built-in metrics

Collected for every workload, no configuration. Names and types below are the recording-rule outputs (the queryable series). Call `list_metrics` for the complete live set, including your custom metrics.

**Resource & network** (per replica): `cpu_used` / `cpu_reserved` / `cpu_billable` (cores, gauge); `mem_used` / `mem_reserved` / `mem_billable` (bytes, gauge); `egress` / `cross_zone_traffic` (bytes/minute, pre-rated gauge); `replica_count` / `workload_ready_replicas` / `workload_desired_replicas` (gauge).

**Traffic** (per pod): `requests_per_second` and `requests_initiated_per_second` (pre-rated gauge, label `response_class`); `request_duration_ms_bucket` (latency histogram, keeps `le`).

**Stability**: `container_restarts`, `workload_progress_failure`, `workload_rescheduled_replicas`, `cron_executions`, `domain_warnings` (cumulative counters); `cron_execution_rate` (pre-rated); `capacity_ai_updates`, `load_balancer` (gauge).

**Volume** (per volume set): `volume_set_capacity_bytes`, `volume_set_used_bytes`, `volume_set_free_bytes`, `volume_set_billable_bytes`, `volume_set_capacity_billable`, `volume_set_snapshots_billable`.

**Org-wide** (no workload label): `logs_storage_mb` / `metrics_storage_mb` / `tracing_storage_mb`; `agent_peers_count` / `agent_services_count` (gauge) and `agent_{tx,rx}_{bytes,packets}_total` (counter) from wormhole agents; `threat_detection_alerts` / `threat_detection_forward_total` / `threat_detection_forward_enabled`.

mk8s clusters with metrics enabled also expose `kube_*` (kube-state-metrics) and `node_*` (node-exporter).

## Custom metrics

A container exposes Prometheus-format metrics by declaring a `metrics` block; the platform scrapes every replica every **30 seconds** (5s timeout). Set it at creation with `mcp__cpln__create_workload` or add it later with `mcp__cpln__update_workload`; if the typed tool doesn't surface the nested field, fall back to `mcp__cpln__get_resource_schema` for `workload` then `cpln apply -f workload.yaml`.

```yaml
spec:
  containers:
    - name: app
      metrics:
        port: 9100          # required; ≥80 and NOT a reserved port (see trap below)
        path: /metrics      # required; string, max 128, default /metrics
        dropMetrics:        # optional; RE2 regexes, dropped before scrape
          - '^go_.*'
          - '^process_.*'
```

- **Reserved-port trap:** `port` rejects the platform's sidecar ports — `9090`, `9091`, `8012`, `8022`, `15000`/`15001`/`15006`/`15020`/`15021`/`15090`, `41000`. The obvious Prometheus default `9090` fails; use `9100`, `2112`, etc.
- Metric names starting with `cpln_` are dropped (you cannot overwrite platform series).
- Scraped samples gain labels `org`, `gvc`, `workload`, `container`, `location`, `provider`, `region`, `cluster_id`, `replica`.

## Distributed tracing

Tracing answers a different question than metrics: not "is latency high?" but **where** in the request path. It is opt-in via `spec.tracing` on a **GVC** (or org-wide on the org spec) — set it with `mcp__cpln__update_gvc` / `mcp__cpln__create_gvc` or `cpln apply`. Exactly one provider (`.xor`), and `sampling` (a required `0`–`100` percentage):

- **`controlplane`** — built-in backend, queryable with the tools below; zero extra infrastructure.
- **`otel`** — ship spans to your own OpenTelemetry collector (`endpoint`).
- **`lightstep`** — ship to Lightstep (`endpoint` + an opaque `credentials` secret).

`customTags` adds fixed key/values to every span (each value max 50 chars). Only requests served after enablement, in the sampled fraction, produce traces. Apps wanting to emit their own spans to the `controlplane` provider send OTLP to `tracing.controlplane:80` (gRPC) or `tracing.controlplane:4318` (HTTP).

Query the built-in backend with `mcp__cpln__query_traces` — structured params (`gvc`, `workload`, `location`, `errorsOnly`, `minDuration: "500ms"`) or a raw `traceql` query that replaces them; span attributes are `resource.gvc` / `resource.workload` / `resource.location`. Then `mcp__cpln__get_trace` reads one trace's span tree to name the slow/failed span. **Empty results are usually configuration:** confirm tracing is enabled, sampling catches traffic, and the window saw requests. Triage flow: `query_traces` (`minDuration` or `errorsOnly`) to the worst trace, `get_trace` to the culprit span, then `mcp__cpln__get_workload_logs` over the same window for the application error.

## Built-in Grafana alert rules

The managed Grafana provisions five rules, all annotated to the `cpln-metrics-overview` dashboard. They evaluate on import but deliver nothing until a Grafana contact point exists — set `defaultAlertEmails` (below) or add a contact point. Deletions are recreated on next login.

| Rule | Fires when | Default |
|:---|:---|:---|
| `container-restarts` | `increase(container_restarts[5m]) > 0` per gvc/location/workload (any restart) | active |
| `stuck-deployments` | more than one deploy `version` of a workload is restarting (15m) | active |
| `workload-progress-failure` | `increase(workload_progress_failure[10m]) > 0` (15m) | active |
| `threat-detection-alerts` | `increase(threat_detection_alerts[15m]) > 0` per gvc/workload/priority/rule | active |
| `domain-warnings` | `increase(domain_warnings[60m]) > 5` per domain/type | **paused** |

## Retention & billing

Retention and default alert recipients live in the org `observability` block. No typed MCP tool edits it (the `org-management` skill owns org-spec edits) — apply via CLI: `mcp__cpln__get_resource_schema` for `org`, then `cpln apply -f org.yaml`.

```yaml
kind: org
spec:
  observability:
    logsRetentionDays: 30       # int 0-3650, default 30 (0 disables log collection)
    metricsRetentionDays: 30    # int 0-3650, default 30
    tracesRetentionDays: 30     # int 0-3650, default 30
    defaultAlertEmails:         # email[]; recipients for the grafana-default-email contact point
      - ops@example.com
```

Combined storage of logs, metrics, and traces is charged per GB-month over 100 GB.

## Export & centralize metrics

`readMetrics` (org permission, "access usage and performance metrics") gates both the federation endpoint and Grafana data sources. Create a service account and grant it `readMetrics` via policy — the `access-control` skill owns that; here is the metrics-specific wiring.

**Federate into your own Prometheus** — scrape the source org with the service-account token:

```yaml
scrape_configs:
  - job_name: cpln-federate
    scheme: https
    honor_labels: true
    metrics_path: '/metrics/org/SOURCE_ORG/api/v1/federate'
    params:
      'match[]': ['{__name__=~".+"}']     # narrow the matcher to limit egress
    authorization: { type: Bearer, credentials: "${CPLN_SERVICE_ACCOUNT_TOKEN}" }
    static_configs:
      - targets: ['metrics.cpln.io']
```

**Cross-org Grafana** — in a viewer org's Grafana, add a Prometheus data source with URL `https://metrics.cpln.io/metrics/org/SOURCE_ORG` and a custom HTTP header `authorization` = `Bearer <SOURCE_ORG_SA_TOKEN>`, then **Save & Test**. The community dashboard `grafana.com/dashboards/20378` (Multi-Source Metrics Overview) visualizes several at once.

**Token trap:** `metrics.cpln.io` authenticates user and service-account tokens only. A workload's injected `CPLN_TOKEN` does **not** work there even with `readMetrics` on its identity — the metrics proxy forwards only the link headers, never the signed header the in-mesh API path injects (see the `workload` skill). Query from inside a workload with a service-account key.

## Autoscaling metric availability

This skill covers only which scaling metrics each workload type allows; for strategy, YAML, percentiles, multi-metric, KEDA, and Capacity AI, see the `autoscaling-capacity` skill.

| Metric | Serverless | Standard | Stateful |
|:---|:---:|:---:|:---:|
| `concurrency` | yes | no | no |
| `cpu` / `memory` / `rps` | yes | yes | yes |
| `latency` / `keda` | no | yes | yes |
| `disabled` | yes | yes | yes |

`vm` workloads allow only `disabled`; `cron` has no autoscaling. (`memory` here is the scaling keyword — distinct from the `mem_used` series.)

## Quick reference

| Tool | Use |
|:---|:---|
| `mcp__cpln__list_metrics` | Discover real metric names and label values (built-in + custom) before querying |
| `mcp__cpln__query_metrics` | Run a PromQL query against the org's metrics |
| `mcp__cpln__query_traces` | Search traces (TraceQL) — slow (`minDuration`) or failed (`errorsOnly`) requests |
| `mcp__cpln__get_trace` | Read one trace's span tree to locate the slow/failed span |
| `mcp__cpln__get_workload_logs` | Correlate a metric spike with logs (see `logql-observability`) |

- **Metrics endpoint:** `https://metrics.cpln.io/metrics/org/{ORG}` (federation adds `/api/v1/federate`).
- **Permission:** `readMetrics` (federation endpoint + Grafana data source).
- No typed tool edits the org `observability` block, the GVC `tracing` block, or a container `metrics` block — fall back to `get_resource_schema` + `cpln apply`.

## Troubleshooting

| Symptom | Cause and fix |
|:---|:---|
| Query returns no series | Wrong name — memory is `mem_used`, not `memory_used`; run `list_metrics` to confirm live names |
| `egress`/latency values look tiny or wrong | Pre-rated series wrapped in `rate()` — query `egress` bare, latency via `histogram_quantile(..., request_duration_ms_bucket)` |
| Custom `metrics` block rejected | `port` is reserved (`9090`/`9091`/`15000`+) or below 80 — use `9100`/`2112` |
| Custom metrics never appear | Names prefixed `cpln_` are dropped; scrape runs every 30s — allow a cycle |
| 403 at `metrics.cpln.io` | Principal lacks `readMetrics`, or an in-pod `CPLN_TOKEN` was used — use a user/SA token |
| `query_traces` empty | Tracing not enabled on the GVC, sampling too low, or no traffic in the window |
| Alert never notifies | Rules evaluate but need a contact point — set `defaultAlertEmails` or add one in Grafana (`domain-warnings` also ships paused) |

## Related skills

| Skill | Owns |
|:---|:---|
| `workload` | Deploy/diagnose flow, injected `CPLN_*` env vars, the spec that holds `metrics` |
| `autoscaling-capacity` | Scaling strategy, per-metric YAML, percentiles, KEDA, Capacity AI |
| `logql-observability` | Log queries (LogQL), `cpln logs`, correlating spikes with log events |
| `org-management` | Org-spec edits — the `observability` retention block |
| `external-logging` | Shipping logs to S3, Datadog, Coralogix, and other providers |

## Documentation

- [Default Metrics](https://docs.controlplane.com/guides/default-metrics.md)
- [Custom Metrics](https://docs.controlplane.com/reference/workload/custom-metrics.md)
- [Export Metrics (federation)](https://docs.controlplane.com/guides/export-metrics.md)
- [Centralized Metrics](https://docs.controlplane.com/guides/centralized-metrics-management.md)
- [Autoscaling](https://docs.controlplane.com/reference/workload/autoscaling.md)
- [PromQL (upstream Prometheus reference)](https://prometheus.io/docs/prometheus/latest/querying/basics/)
