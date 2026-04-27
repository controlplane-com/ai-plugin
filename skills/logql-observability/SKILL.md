---
name: cpln-logql-observability
description: "Queries workload logs and builds log dashboards on Control Plane. Use when the user asks about LogQL syntax, log search, viewing logs in Grafana, log stream selectors, log filtering, log patterns, log metrics extraction, or setting up log-based dashboards."
version: 1.0.0
---

# LogQL & Observability Patterns

Control Plane uses LogQL (Grafana Loki query language) for log queries. Two ways to run queries:

- **MCP tool (agents):** `mcp__cpln__get_workload_logs` — structured params (`gvc`, `workload`, `container`, `location`, `filter`, `since`, `from`, `to`, `limit`, `order`) or a raw `query`. Default limit 100, max 500.
- **CLI (humans/scripts):** `cpln logs <query>` — see examples below.

## Log Query Syntax

### CLI Usage

```bash
# Basic query (defaults: --since 1h, --limit 30, --direction forward)
cpln logs '{gvc="my-gvc", workload="my-app"}' --org my-org

# With filters
cpln logs '{gvc="my-gvc", workload="my-app"} |= "error"' --limit 100

# Specific container
cpln logs '{gvc="my-gvc", workload="my-app", container="main"}' --limit 50

# Location-specific
cpln logs '{gvc="my-gvc", workload="my-app", location="aws-us-east-1"}'

# Follow (live streaming) — aliases: -t, -f
cpln logs '{gvc="my-gvc", workload="my-app"}' --tail

# Relative lookback window (default "1h"); supports ms/s/m/h/d/w/mo/y, e.g. 30m, 24h, 7d
cpln logs '{gvc="GVC", workload="WL"}' --since 24h
cpln logs '{gvc="GVC", workload="WL"}' --since 7d

# Absolute time range — --from is inclusive, --to is exclusive (ISO 8601)
cpln logs '{gvc="GVC", workload="WL"}' \
  --from 2026-04-23T00:00:00Z --to 2026-04-24T00:00:00Z

# Relative time range — --from/--to also accept "now-<duration>" (e.g., yesterday's window)
cpln logs '{gvc="GVC", workload="WL"}' --from now-2d --to now-1d

# Unlimited: --limit 0 auto-paginates through the full time range
cpln logs '{gvc="GVC", workload="WL"} |= "error"' --since 24h --limit 0

# Machine-readable output for scripts (jsonl = one JSON object per line)
cpln logs '{gvc="GVC", workload="WL"}' --output jsonl
```

**NOTE:** For application logs, always use `cpln logs`. The `cpln workload eventlog` command (alias `cpln workload log`) shows resource event/audit history for a workload — it does not return container stdout/stderr.

### Available Labels

| Label | Description |
|:---|:---|
| `gvc` | Global Virtual Cloud name |
| `workload` | Workload name |
| `container` | Container name within workload |
| `location` | Deployment location (e.g., `aws-us-east-1`) |
| `provider` | Cloud provider |
| `replica` | Replica identifier |
| `stream` | Log stream (`stdout` or `stderr`) |

### Filter Operators

| Operator | Meaning | Example |
|:---|:---|:---|
| `\|= "text"` | Contains | `\|= "error"` |
| `!= "text"` | Does not contain | `!= "health"` |
| `\|~ "regex"` | Matches regex | `\|~ "timeout\|crash"` |
| `!~ "regex"` | Does not match regex | `!~ "debug\|trace"` |

### Common Query Patterns

```bash
# Errors only
cpln logs '{gvc="GVC", workload="WL"} |= "error" != "health"'

# Stack traces
cpln logs '{gvc="GVC", workload="WL"} |~ "panic|fatal|exception"'

# Specific HTTP status codes
cpln logs '{gvc="GVC", workload="WL"} |~ "HTTP/[12].[01]\" 5[0-9]{2}"'

# Container restarts (stderr)
cpln logs '{gvc="GVC", workload="WL", stream="stderr"}'
```

### Cron Workloads — Per-Execution Logs

For a cron workload, querying `{gvc=, workload=}` returns logs from **every** execution mixed together — useless when you want to know why one specific run failed. Each cron execution runs in a **separate replica with a unique replica ID**, so you can scope logs to a single execution by adding the `replica` label and bounding by the execution's start/completion time.

**Schema reference** (from the canonical Joi validator at `controlplane/nodelibs/schema/src/cronjob.ts`):

```
DeploymentStatus.jobExecutions[]: JobExecutionStatus
JobExecutionStatus = {
  workloadVersion: number  (required)
  status:          'successful' | 'failed' | 'active' | 'pending' | 'invalid' | 'removed' | ''  (default: 'pending')
  startTime:       Date     (optional — may be absent if execution never moved out of 'pending')
  completionTime:  Date     (optional — null is server-stripped, so field is either present-with-value or absent)
  name:            string   (required — kubernetes Job name)
  replica:         string   (optional — REPLICA ID; the key for per-execution log scoping)
  containers:      { [name]: ContainerStatus }   (per-container exit info, error messages)
  conditions:      JobExecutionCondition[]
}
```

**Important nuances from the schema:**

- **"Still running"** is `status === "active" && !completionTime` — *both* conditions. Don't infer "still running" from missing `completionTime` alone; the schema description explicitly warns *"This should not be interpreted as an indication of success. Please refer to the status field instead."* A failed-and-removed execution may also have no `completionTime`.
- **`startTime` can be absent** for a never-started (always-pending) execution. Defend against this in scripts (`// "now-1h"` fallback).
- **`replica` is `optional()`** in the schema. In practice it's set for any execution that actually got a pod; if it's missing, the run never reached the running phase and there are no logs to fetch — diagnose via `containers[].message` and the parent workload events instead.
- **`completionTime: null` is server-stripped** by a custom Joi transform (`if (value.completionTime == null) delete value.completionTime`). So in the wire JSON the field is either present with a real timestamp or absent — never literal `null`. `jq` filters using `// empty` handle this correctly.

**Step 1 — list executions and pick one.** `cpln workload get-deployments` returns deployments per location, each with `status.jobExecutions[]`:

```bash
# Per-execution metadata for a cron workload (defensive against list-envelope vs bare-array response shapes)
cpln workload get-deployments WL --gvc GVC -o json \
  | jq '(.items // .)[] | {location: .name, executions: [.status.jobExecutions[]? | {name, status, startTime, completionTime, replica}]}'
```

Pick the execution whose logs you want — usually the most recent failed one, or one identified by the user as misbehaving. Filter with `select(.status == "failed")` etc.

**Step 2 — pull logs for just that execution.** Use the `replica` label and time-bound the query to the execution window. Add a small buffer on each side so log indexing slack doesn't truncate the result:

```bash
cpln logs \
  '{gvc="GVC", workload="WL", location="LOCATION", replica="REPLICA-ID"}' \
  --org ORG \
  --from "<startTime - 1m>" \
  --to "<completionTime + 1m>"
```

For a live execution (`status == "active"` AND no `completionTime`), omit `--to` and add `--tail` to follow live output:

```bash
cpln logs \
  '{gvc="GVC", workload="WL", location="LOCATION", replica="REPLICA-ID"}' \
  --org ORG --tail
```

`--from` / `--to` accept ISO 8601, durations (`7d`), or `now-<duration>` (e.g. `--from now-2h`). The execution's `startTime` from `get-deployments` is ISO 8601, so it's safe to pass directly.

**Concrete example** — cron workload `shorty-purge` in GVC `majid-testing-02`, debugging the most recent failed run. Single jq pass extracts location alongside the execution fields so the LogQL labels are co-located:

```bash
RESULT=$(cpln workload get-deployments shorty-purge --gvc majid-testing-02 -o json \
  | jq -r '[(.items // .)[] as $d | $d.status.jobExecutions[]? | select(.status == "failed") | . + {location: $d.name}] | sort_by(.startTime) | last')

LOC=$(echo "$RESULT"     | jq -r .location)
REPLICA=$(echo "$RESULT" | jq -r .replica)
START=$(echo "$RESULT"   | jq -r '.startTime // empty')
END=$(echo "$RESULT"     | jq -r '.completionTime // empty')

# Pull logs for exactly that execution
cpln logs \
  "{gvc=\"majid-testing-02\", workload=\"shorty-purge\", location=\"$LOC\", replica=\"$REPLICA\"}" \
  --org epoch \
  ${START:+--from "$START"} \
  ${END:+--to "$END"}
```

The `${VAR:+--flag "$VAR"}` form drops the flag entirely if the timestamp is absent — handles the schema's optional `startTime` / `completionTime` correctly.

**Why this beats `{gvc=, workload=}` alone for cron:**

- Without `replica`, you get logs from every past run interleaved — the failed-run signal is buried in a sea of successful ones.
- Time bounds prevent fetching unrelated noise from before/after the run.
- Each execution's container errors (exit code, fatal message) are *also* visible in `status.jobExecutions[].containers[].message` from the same `get-deployments` JSON, so log scoping plus that field gives you the full picture often without ever fetching logs.

**If `replica` is missing on the execution** (rare — happens when the run never reached the running phase): there are no per-replica logs to fetch. Diagnose via `containers[].message`, the parent workload's events, and the cron `command` resource if the run was triggered manually. Falling back to `{gvc=, workload=}` with a tight time window around `startTime` is the next-best option.

**Time-window note.** The console UI buffers ±1 day on each side as conservative slack for log indexing; for CLI use, ±1–2 minutes is usually enough since the execution itself is short. If logs come back empty for a known-failed run, widen the window before assuming logs don't exist.

## Grafana Integration

Run LogQL visually via the `Explore on Grafana` link in the logs UI. The same managed Grafana instance also hosts workload metrics and built-in alert rules — for default metrics, PromQL, and the `container-restarts` / `stuck-deployments` alert rules, see the **cpln-metrics-observability** skill.

## Metrics Export

Prometheus `/federate` scraping and centralized Grafana setup live in the **cpln-metrics-observability** skill — use that skill for federation endpoints, `readMetrics` policy YAML, and multi-org Grafana data sources.

## External Log Shipping

Ship logs to external providers for long-term retention or compliance:

| Provider | Type |
|:---|:---|
| Amazon S3 | Object storage |
| AWS CloudWatch | AWS native logging |
| Coralogix | Observability platform |
| Datadog | Monitoring and logging |
| Logz.io | ELK-based logging |
| Google Stackdriver | GCP native logging |

Configure at the org level. Default retention is 30 days (adjustable per org).

## Quick Reference

### CLI Commands

- `cpln logs '{gvc="GVC", workload="WORKLOAD"}' --tail` — Stream logs from a workload.
- `cpln logs '{gvc="GVC", workload="WORKLOAD", container="_accesslog"}'` — HTTP access logs.
- `cpln logs '{gvc="GVC", workload="WORKLOAD"} |= "error"'` — Filter for errors.

### Related Skills

- **cpln-external-logging** — Configuring external log shipping destinations (S3, CloudWatch, Datadog, Coralogix, Logz.io, Stackdriver) and retention policies
- **cpln-metrics-observability** — Default metrics, PromQL, built-in Grafana alerts, custom metrics scraping, Prometheus `/federate` export, and metric-driven autoscaling

## Documentation

For the latest reference, see:

- [Logs Reference](https://docs.controlplane.com/core/logs.md)
- [Query Reference (LogQL)](https://docs.controlplane.com/core/query.md)
- [External Logging Overview](https://docs.controlplane.com/external-logging/overview.md)
- [CLI logs Command](https://docs.controlplane.com/cli-reference/commands/logs.md)
