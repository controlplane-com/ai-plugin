---
name: external-logging
description: "Ships Control Plane org logs to external providers. Use when the user asks about log export to S3, CloudWatch, Coralogix, Datadog, Logz.io, Stackdriver, Elastic, syslog, OpenTelemetry, or centralized log forwarding."
---

# External Logging

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

External logging lives on the **org** (`spec.logging` plus `spec.extraLogging`) and ships **every workload log in the org** — there is no per-GVC or per-workload filtering. One primary provider plus up to 3 extras (4 total); each logging block holds exactly one provider key. Logs stay queryable in built-in LogQL regardless (separate org retention, `spec.observability.logsRetentionDays`, default 30 days). The recurring failure is credentials: each provider needs a pre-created secret of the exact type below — a wrong-type secret passes configuration and the log router then **silently skips that provider**, so logs simply never arrive.

## Providers

| Key | Secret | Required fields | Worth knowing |
|---|---|---|---|
| `s3` | aws | `bucket`, `region`, `credentials` | `prefix` default `/`; region free-form; the IAM user needs `s3:PutObject` on the bucket |
| `cloudWatch` | aws | `region`, `credentials`, `groupName`, `streamName` | `region` is an 18-region allowlist (below); optional `retentionDays` enum and `extractFields` map |
| `coralogix` | opaque | `cluster`, `credentials` | `cluster`: `coralogix.com`, `coralogix.us`, `app.coralogix.in`, `app.eu2.coralogix.com`, or `app.coralogixsg.com`; optional `app`/`subsystem` |
| `datadog` | opaque | `host`, `credentials` | `host` enum: `http-intake.logs.datadoghq.com`, `http-intake.logs.us3.datadoghq.com`, `http-intake.logs.us5.datadoghq.com`, `http-intake.logs.datadoghq.eu` (dashboard `us3.datadoghq.com` pairs with the `us3` intake host) |
| `logzio` | opaque | `listenerHost`, `credentials` | `listenerHost`: `listener.logz.io` or `listener-nl.logz.io` |
| `stackdriver` | gcp | `location`, `credentials` | `location` is a 40-region GCP allowlist (a rejection lists it); the service account needs Logging write |
| `elastic` | aws or userpass | one variant block — see below | |
| `fluentd` | none | `host` | `port` default 24224; Fluent Bit forward protocol |
| `syslog` | none | `host`, `port`, `mode`, `format`, `severity` | `mode` tcp/udp/tls (tls enables TLS); `format` rfc3164/rfc5424; `severity` 0-7; the receiver sees gvc as hostname, workload as appname, replica as procid |
| `opentelemetry` | opaque (optional) | `endpoint` | OTLP over HTTP, not gRPC; an https endpoint turns TLS on; optional `headers` map; optional `credentials` becomes the Authorization header |

- CloudWatch `region` allowlist: us-east-1, us-east-2, us-west-1, us-west-2, ap-south-1, ap-northeast-1, ap-northeast-2, ap-southeast-1, ap-southeast-2, eu-central-1, eu-west-1, eu-west-2, eu-west-3, eu-south-1, eu-north-1, me-south-1, sa-east-1, af-south-1.
- CloudWatch `retentionDays`: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653.

### Elastic variants

In YAML the variant is a nested object under `elastic`; the MCP tool flattens it into `elasticVariant` + `indexType` (`indexType` maps to the schema field `type`):

| Variant | Required | Secret |
|---|---|---|
| `aws` | `host` (must end with `es.amazonaws.com`), `port`, `region`, `index`, `type`, `credentials` | aws |
| `elasticCloud` | `cloudId`, `index`, `type`, `credentials` | userpass |
| `generic` | `host`, `index`, `type`, `credentials`; optional `port` (default 443), `path` (must start with `/`) | userpass |

## Configure (MCP first)

1. **Ensure the credential secret exists — but do not pull its value into the chat.** The provider key is the user's own confidential credential: never ask them to paste it here, never pass it as a tool argument, and never invent a placeholder value. Have the user create the secret in the **console** (type per the table — usually opaque, `payload` = the raw API key, `encoding: plain`; AWS/GCP/userpass use `create_secret_aws` / `create_secret_gcp` / `create_secret_userpass`), then **confirm it exists with `mcp__cpln__get_resource` (kind `secret`) before wiring anything** — referencing a secret that does not exist makes the log router silently skip the provider. Only create it yourself with the typed tool when the value is non-confidential or one you generate. No workload identity or policy is needed — the 3-step secret flow applies to workloads consuming secrets, not to org logging.
2. `mcp__cpln__get_external_logging` — see what is already configured and where.
3. `mcp__cpln__configure_external_logging`, once per provider. Placement is automatic: with no primary it becomes `spec.logging`; additional providers append to `spec.extraLogging`; re-configuring a provider that is already present updates it in place; a 4th extra errors with "maximum 3 extra logging providers reached". `credentials` takes a bare secret name or `//secret/NAME`. Syslog `mode`/`format`/`severity` are optional here — the tool fills tcp / rfc5424 / 6.
4. `mcp__cpln__remove_external_logging` is **destructive — confirm first**: shipping to that destination stops immediately, a compliance/retention gap until reconfigured. Removing the primary promotes the first extra to primary.

## CLI fallback (manifest shape)

There is no `cpln` logging subcommand (`cpln org update --set` covers only description and tags). Get, edit, apply — or `cpln org edit ORG`:

```bash
cpln org get ORG -o yaml-slim > org.yaml    # edit spec.logging / spec.extraLogging
cpln apply -f org.yaml --org ORG
```

```yaml
kind: org
name: ORG
spec:
  logging:
    s3:
      bucket: MY_LOG_BUCKET
      region: us-east-1
      prefix: /
      credentials: //secret/AWS_SECRET
  extraLogging:              # forbidden unless logging is set; max 3
    - datadog:
        host: http-intake.logs.us3.datadoghq.com
        credentials: //secret/DATADOG_KEY
    - elastic:
        elasticCloud:        # variant nests in YAML
          cloudId: DEPLOYMENT:BASE64_ID
          index: cpln-logs
          type: logs         # the MCP tool calls this indexType
          credentials: //secret/ELASTIC_USERPASS
```

In raw YAML, `syslog` requires all five fields — the documented defaults do not satisfy the required check, and the API rejects an omitted `mode`/`format`/`severity` (the MCP tool fills them for you).

## Template variables

- **CloudWatch** `groupName`/`streamName` accept Fluent Bit record accessors over the shipped fields: `$org`, `$gvc`, `$workload`, `$container`, `$replica`, `$location`, `$provider`, `$version`, `$stream` (e.g. `groupName: $gvc`, `streamName: $workload`). Adjacent variables must be separated by `.` or `,`.
- **Coralogix** `app`/`subsystem` accept only `{org}`, `{gvc}`, `{workload}`, `{location}` — any other `{var}` is rejected at validation.

## What ships

Every entry carries `time` and `log` plus the labels `org`, `gvc`, `workload`, `container`, `replica`, `location`, `provider`, `version`, `stream`. S3 receives gzip-compressed JSONL objects at `PREFIX/ORG/YYYY/MM/DD/HH/MM/UUID.jsonl.gz` (~1 MB chunks). The shipper flushes every 5 seconds; entries appear at the provider within a few minutes.

## Verify

1. `mcp__cpln__get_external_logging` — primary and extras placed as intended.
2. Generate some traffic, wait 2-5 minutes, check the provider dashboard or bucket.
3. Built-in access is unaffected: `cpln logs '{gvc="GVC", workload="WORKLOAD"}' --org ORG`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Logs never arrive, no error anywhere | Credential secret has the wrong type — the log router silently skips the provider. Recreate it with the type from the table. |
| S3 stays empty with valid keys | The IAM user lacks `s3:PutObject` on the bucket |
| region/location "must be one of" rejection | CloudWatch and Stackdriver take fixed allowlists, not arbitrary regions |
| `extraLogging` rejected | A primary `spec.logging` must exist first |
| "maximum 3 extra logging providers reached" | 4 providers total is the cap — remove one first |
| xor validation error on a logging block | Exactly one provider key per block — extra providers are separate `extraLogging` entries |
| Datadog/Coralogix/Logz.io value rejected | `host`/`cluster`/`listenerHost` are fixed enums — see the table |

## Quick reference — MCP tools

| Tool | Action |
|---|---|
| `mcp__cpln__get_external_logging` | Show primary + extra providers |
| `mcp__cpln__configure_external_logging` | Add or update one provider (automatic primary/extra placement) |
| `mcp__cpln__remove_external_logging` | Remove a provider (destructive; removing the primary promotes the first extra) |

CLI fallback (CI/CD: `CPLN_TOKEN` + `cpln apply` — read the `cpln` skill first): edit the org manifest as shown above.

## Related skills

| Need | Skill |
|---|---|
| Query logs inside Control Plane (LogQL, Grafana) | `logql-observability` |
| Metrics and tracing export | `metrics-observability` |
| Creating credential secrets, RBAC | `access-control` |
| Org settings: retention, tracing, auth | `org-management` |

## Documentation

- [External Logging Overview](https://docs.controlplane.com/external-logging/overview.md)
- Per provider: [S3](https://docs.controlplane.com/external-logging/s3.md), [CloudWatch](https://docs.controlplane.com/external-logging/cloudwatch.md), [Coralogix](https://docs.controlplane.com/external-logging/coralogix.md), [Datadog](https://docs.controlplane.com/external-logging/datadog.md), [Logz.io](https://docs.controlplane.com/external-logging/logz-io.md), [Stackdriver](https://docs.controlplane.com/external-logging/stackdriver.md), [Syslog](https://docs.controlplane.com/external-logging/syslog.md)
- Elastic, Fluentd, and OpenTelemetry have no docs pages — the MCP tool description is the reference.
