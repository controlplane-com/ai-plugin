---
name: logql-observability
description: "Queries workload logs with LogQL on Control Plane. Use to troubleshoot a workload from its logs, or for log search, access or egress logs, cron run logs, missing or truncated logs, retention, or logs in Grafana."
---

# LogQL & Log Observability

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Control Plane stores workload stdout/stderr in Loki and queries it with LogQL. The org is the Loki tenant — it comes from the endpoint path, so `org` is never a query label and queries cannot cross orgs. Reading logs requires the org-level `readLogs` permission, and the in-pod `CPLN_TOKEN` cannot authenticate to the logs endpoint — use a user or service-account token (see the `workload` skill). The recurring agent failure is passing a raw `query` to the MCP tool alongside structured params: a raw query replaces them entirely (the tool rejects the combination), so a raw query must embed every label itself.

## Two ways to query

- **MCP (primary for agents):** `mcp__cpln__get_workload_logs` — structured params `gvc` (required), `workload`, `container`, `location`, `filter` (literal substring, LogQL `|=`, not regex); window `since` (default `1h`) or `from`/`to` (ISO 8601, `from` inclusive, `to` exclusive); `limit` (default 30, max 999, single request — `truncated: true` means narrow the window or filter harder); `order` (`oldest_first` default, or `newest_first`). For regex, parsers, or the `replica`/`stream`/`version` labels, pass a raw `query` (max 500 chars) instead of the structured selectors.
- **CLI:** `cpln logs '<LOGQL>'` — interactive debugging (live `--tail`), scripts, CI.

```bash
# Defaults: --since 1h, --limit 30, --direction forward
cpln logs '{gvc="GVC", workload="WORKLOAD"}' --org ORG
cpln logs '{gvc="GVC", workload="WORKLOAD"} |= "error"' --limit 100
cpln logs '{gvc="GVC", workload="WORKLOAD", container="main"}' --since 7d
cpln logs '{gvc="GVC", workload="WORKLOAD"}' --tail              # live follow; the server ends a tail session after 30m
cpln logs '{gvc="GVC", workload="WORKLOAD"}' \
  --from 2026-06-01T00:00:00Z --to 2026-06-02T00:00:00Z          # ISO 8601 only; from inclusive, to exclusive
cpln logs '{gvc="GVC", workload="WORKLOAD"} |= "error"' --since 24h --limit 0   # 0 = unlimited, auto-paginates
cpln logs '{gvc="GVC", workload="WORKLOAD"}' -o jsonl            # one JSON object per line; -o raw = bare lines
```

- `--since` takes relative durations (`ms s m h d w mo y`, compound like `1h30m`). `--from`/`--to` take ISO 8601 timestamps **only** — `--from now-2d` and `--from 7d` fail with `Cannot parse ... into a valid date`.
- `cpln workload eventlog WORKLOAD` (alias `cpln workload log`) is resource event history, not container output — for application logs always use `cpln logs`.

## Labels

| Label | Value |
|:---|:---|
| `gvc` | GVC name |
| `workload` | Workload name |
| `container` | Container name, or a built-in stream below |
| `location` | Deployment location, e.g. `aws-us-east-1` |
| `provider` | Cloud provider |
| `replica` | Replica (pod) name — unique per cron execution |
| `stream` | `stdout` or `stderr` |
| `version` | Workload deployment version that wrote the line |

At least one non-empty matcher is required; regex matchers work — `{gvc=~".+"}` spans every GVC in the org.

## Filters and LogQL features

| Operator | Meaning | Example |
|:---|:---|:---|
| `\|= "text"` | contains | `\|= "error"` |
| `!= "text"` | does not contain | `!= "health"` |
| `\|~ "regex"` | matches regex | `\|~ "timeout\|crash"` |
| `!~ "regex"` | does not match | `!~ "debug\|trace"` |

Loki is current (3.x), so full LogQL works: parsers (`| json`, `| logfmt`, `| pattern`, `| regexp`), post-parse label filters (`| latency > 100`), `line_format`, and metric queries (`count_over_time`, `rate`, `sum ... by`). The CLI and MCP tool print log lines only — run metric queries in Grafana: the `Explore on Grafana` link on the console Logs page opens it with the query prefilled (the org `grafanaAdmin` permission grants the Grafana Admin role; everyone else is Viewer).

```logql
{gvc="GVC", workload="WORKLOAD"} |= "error" != "health"               # errors minus noise
{gvc="GVC", workload="WORKLOAD"} |~ "panic|fatal|exception"           # crashes and stack traces
{gvc="GVC", workload="WORKLOAD", container="_accesslog"} |= "\" 50"   # HTTP 5xx in access logs
sum(count_over_time({gvc="GVC", container="_accesslog"} |= "\" 50"[1m])) by (workload)   # 5xx rate (Grafana)
```

## Built-in log streams

| Selector | Contents |
|:---|:---|
| `container="_accesslog"` | Inbound requests (Envoy access-log format) on the workload's ports |
| `container="_requestlog"` | The workload's outbound (egress) requests through the sidecar, same format |
| `workload="_loadbalancer"` | Access logs of the GVC's dedicated load balancer |
| `container="_alerts"` | Threat-detection (Falco) alerts, with extra labels `rule`, `priority`, `source` |

Platform health probes and unroutable-request noise are filtered out of `_accesslog` by design, so probe traffic never shows up there. Sidecar and system containers (`istio-init`, `istio-validation`, `cpln-*`, `debugger-*`) are never collected.

## Why logs go missing (pipeline limits)

- **Lines over 16 KiB are cut** at 16 KiB with a `... [truncated N bytes]` suffix; empty lines are dropped.
- **Per-replica rate limit:** each replica+container pair is capped (roughly 10,000 lines/s on managed clusters; effectively unlimited on BYOK). Excess lines are dropped, and when collection resumes one marker line appears: `#### Replica logs were rate-limited: N lines in the last Xs were not collected ####`.
- **Retention:** org spec `observability.logsRetentionDays`, default 30 (0 turns log collection off entirely; the `org-management` skill owns org spec edits). Queries beyond retention return nothing, not an error.
- **Server caps:** one query may span at most 31 days and times out after 2 minutes; tail sessions end after 30 minutes.

## Cron workloads: logs for one execution

`{gvc=, workload=}` on a cron workload interleaves every past run. Each execution runs in its own replica, so scope to one run with the `replica` label plus the execution's time window.

**1. List executions.** `mcp__cpln__list_deployments` **with** `location` returns the full deployment JSON; `status.jobExecutions[]` holds the per-execution metadata (without `location` the tool returns only a readiness summary). CLI:

```bash
cpln workload get-deployments WORKLOAD --gvc GVC -o json | jq '
  [(.items // .)[] as $d | $d.status.jobExecutions[]? | . + {location: $d.name}]
  | sort_by(.startTime)[] | {location, name, status, startTime, completionTime, replica}'
```

Schema facts (nodelibs `cronjob.ts`) that bite scripts:

- `status` is one of `successful | failed | active | pending | invalid | removed` (default `pending`). Running means `status == "active"` AND no `completionTime`; a missing `completionTime` alone proves nothing (the schema warns it is not an indication of success).
- `completionTime: null` is stripped server-side and `startTime` may be absent for never-started runs — each field is present-with-value or absent, so guard flags with `${VAR:+--from "$VAR"}` and jq `// empty`.
- `replica` is optional: when missing, the run never got a pod and there are **no logs** — diagnose with the execution's `containers` map and `message` field (aggregated pod events) and `mcp__cpln__get_workload_events`.

**2. Query that replica, time-bounded.** MCP: raw `query` embedding ALL labels (structured params must be omitted) plus `from`/`to`. CLI:

```bash
cpln logs '{gvc="GVC", workload="WORKLOAD", location="LOCATION", replica="REPLICA-ID"}' \
  --org ORG --from START_TIME --to COMPLETION_TIME
```

`jobExecutions` timestamps are ISO 8601 and pass straight through. Pad the window a minute or two on each side, and widen it before concluding logs do not exist. For a live run (`active`, no `completionTime`), drop `--to` and add `--tail`.

## Quick reference

| Tool | Use |
|:---|:---|
| `mcp__cpln__get_workload_logs` | LogQL queries — structured params or raw `query` |
| `mcp__cpln__list_deployments` | Deployment health; cron `status.jobExecutions` (pass `location`) |
| `mcp__cpln__get_workload_events` | Probe failures, scheduling, restarts — events, not app logs |

CI/CD and headless use: set `CPLN_TOKEN` and run `cpln logs` directly (no profile needed); the principal must hold org `readLogs`.

## Troubleshooting

| Symptom | Cause and fix |
|:---|:---|
| 403 `requires permission "readLogs" in org` | Grant `readLogs` on the org via policy (it implies `view`) |
| `Cannot parse now-2d into a valid date` | `--from`/`--to` are ISO 8601 only; relative lookback is `--since` |
| Empty result for known activity | Window outside retention (default 30d), span over 31 days, or filters too narrow; app may not write to stdout/stderr |
| `#### Replica logs were rate-limited ... ####` marker | Per-replica cap was hit; lines in that interval are gone — reduce log volume |
| Line ends with `... [truncated N bytes]` | 16 KiB per-line cap — emit smaller lines |
| Health checks absent from `_accesslog` | Filtered by design; probe failures surface in `mcp__cpln__get_workload_events` |
| MCP rejects raw `query` combined with `workload` etc. | A raw query replaces the structured params — embed all labels in the query itself |
| `cpln workload log` shows no app output | That is the eventlog alias; use `cpln logs` |

## Related skills

| Skill | Owns |
|:---|:---|
| `workload` | Deploy and diagnose flow, injected `CPLN_*` env vars, canonical URLs |
| `metrics-observability` | PromQL, default metrics, Grafana alert rules, Prometheus federation |
| `external-logging` | Shipping logs to S3, Datadog, Coralogix, and other providers |
| `mk8s-byok` | mk8s cluster logs add-on (`cluster_name` / `namespace` labels) |

## Documentation

- [Logs Reference](https://docs.controlplane.com/core/logs.md)
- [CLI logs Command](https://docs.controlplane.com/cli-reference/commands/logs.md)
- [External Logging Overview](https://docs.controlplane.com/external-logging/overview.md)
- [LogQL (upstream Grafana reference)](https://grafana.com/docs/loki/latest/query/)
