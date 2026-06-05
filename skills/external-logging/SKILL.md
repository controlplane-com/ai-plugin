---
name: external-logging
description: "Ships logs from Control Plane workloads to external providers. Use when the user asks about log export to S3, CloudWatch, Coralogix, Datadog, Logz.io, Stackdriver, or any external logging destination. Also when asking about log forwarding, centralized logging, or external log configuration."
---

# External Logging Configuration

## Overview

External logging ships all org logs to third-party providers for off-site storage, compliance, and analysis. Logs remain accessible through Control Plane's built-in LogQL regardless of external logging configuration.

**Key facts:**

- Configured at the **Org level** (not GVC).
- Primary provider in `spec.logging`, additional providers in `spec.extraLogging` (max 3).
- **Only one provider per logging block** — the schema enforces `.xor()` across providers.
- Maximum **4 total providers**: 1 primary + 3 extra.
- `extraLogging` requires `logging` to be set first; `.unique()` enforces distinct entries within the array.
- Credentials are stored as Control Plane **Secrets** (AWS, Opaque, or GCP type).
- Log entries appear at the external provider within a few minutes.

For each provider's config fields, allowed values, and one example, see [Providers](#providers) below.

## Provider Comparison

| Provider | Key | Secret Type | Required Fields | Best For |
|:---|:---|:---|:---|:---|
| Amazon S3 | `s3` | AWS | `bucket`, `region`, `credentials` | Archival, compliance |
| CloudWatch | `cloudWatch` | AWS | `region`, `credentials`, `groupName`, `streamName` | AWS-native monitoring |
| Coralogix | `coralogix` | Opaque | `cluster`, `credentials` | Log analytics |
| Datadog | `datadog` | Opaque | `host`, `credentials` | Full-stack observability |
| Logz.io | `logzio` | Opaque | `listenerHost`, `credentials` | ELK-based log analysis |
| Stackdriver | `stackdriver` | GCP | `location`, `credentials` | GCP-native monitoring |
| Elastic | `elastic` | AWS or Username/Password | `elasticVariant` + variant fields | Self-managed Elasticsearch |
| Fluentd | `fluentd` | None | `host` | Log forwarder/aggregator |
| Syslog | `syslog` | None | `host` | Standards-based syslog |
| OpenTelemetry | `opentelemetry` | Opaque (optional) | `endpoint` | OTLP-based pipelines |

## Configuration

**Preferred path — MCP tools.** External logging has dedicated MCP tools that handle primary vs extra placement for you:

- `mcp__cpln__get_external_logging` — inspect the current configuration first.
- `mcp__cpln__configure_external_logging` — add or update a provider (auto-places it as primary or extra).
- `mcp__cpln__remove_external_logging` — remove a provider (promotes the first extra to primary if you remove the primary).

**Fallback — CLI.** Use this only when the MCP server is unavailable or unauthenticated. **There is no dedicated CLI subcommand for external logging**, so use the get-edit-apply workflow against the org's `spec.logging` block:

```bash
# 1. Get current org config as YAML (slim output is designed for cpln apply)
cpln org get ORG_NAME -o yaml-slim > org.yaml

# 2. Edit org.yaml — add or modify the spec.logging section

# 3. Apply changes
cpln apply -f org.yaml --org ORG_NAME
```

## Credential Setup

Each provider requires a secret created **before** configuring logging. Create it with `mcp__cpln__create_secret` (CLI fallback: `cpln secret create-*` or the Console, when MCP is unavailable).

| Provider | Secret Type | MCP `create_secret` payload | CLI fallback |
|:---|:---|:---|:---|
| S3, CloudWatch | AWS | `{"accessKey": "...", "secretKey": "..."}` | `cpln secret create-aws` |
| Coralogix, Datadog, Logz.io | Opaque | `{"encoding": "plain", "payload": "API_KEY"}` | `cpln secret create-opaque` |
| Stackdriver | GCP | GCP service-account JSON key | `cpln secret create-gcp` |

Credentials are referenced in the `configure_external_logging` `credentials` field (or in YAML) as `//secret/SECRET_NAME`.

## Multiple Providers

Each `logging` block supports **exactly one provider** (`.xor()` constraint). To ship to multiple providers, add each one with a separate `mcp__cpln__configure_external_logging` call — it places the first as primary (`spec.logging`) and the rest as extras (`spec.extraLogging`) automatically. The equivalent manifest for the CLI fallback looks like:

```yaml
kind: org
name: ORG_NAME
spec:
  logging:
    s3:
      bucket: my-log-archive
      credentials: //secret/aws-logging
      prefix: /logs
      region: us-east-1
  extraLogging:
    - datadog:
        host: http-intake.logs.us3.datadoghq.com
        credentials: //secret/datadog-api-key
    - coralogix:
        cluster: coralogix.com
        credentials: //secret/coralogix-key
```

**Rules:**
- `logging` (primary) must be set before `extraLogging` can be used.
- `extraLogging` accepts up to **3** additional provider blocks.
- Each entry in the array has exactly one provider key (`.xor()` across all provider keys).
- `.unique()` is enforced within `extraLogging`, so identical blocks cannot repeat in the array.

## Providers

Per-provider config fields, allowed values, and one example each. Required fields are summarized in the [Provider Comparison](#provider-comparison) table; create the credential secret first (see [Credential Setup](#credential-setup)) and reference it as `//secret/NAME`. Prefer the MCP payload (`mcp__cpln__configure_external_logging`); the YAML blocks are the CLI fallback (apply with `cpln apply -f`).

### Amazon S3

Logs land at `PREFIX/ORG_NAME/YEAR/MONTH/DAY/HOUR/MINUTE/$UUID.jsonl.gz` (gzip-compressed JSONL). The AWS secret's IAM user needs `s3:PutObject` on the bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "VisualEditor0", "Effect": "Allow", "Action": "s3:PutObject", "Resource": "arn:aws:s3:::S3_BUCKET_NAME/*" }
  ]
}
```

```yaml
spec:
  logging:
    s3:
      bucket: S3_BUCKET_NAME
      credentials: //secret/AWS_SECRET
      prefix: /
      region: AWS_REGION
```

| Field | Required | Default | Description |
|---|---|---|---|
| `bucket` | Yes | — | S3 bucket name |
| `region` | Yes | — | AWS region |
| `credentials` | Yes | — | Link to AWS secret |
| `prefix` | No | `/` | Folder prefix for log files |

### AWS CloudWatch

```yaml
spec:
  logging:
    cloudWatch:
      region: us-east-1
      credentials: //secret/AWS_SECRET
      retentionDays: 7
      groupName: $gvc
      streamName: $workload
```

| Field | Required | Description |
|---|---|---|
| `region` | Yes | A valid AWS region (e.g., `us-east-1`, `eu-west-1`) |
| `credentials` | Yes | Link to AWS secret |
| `groupName` | Yes | Log group name (Fluent Bit templating) |
| `streamName` | Yes | Log stream name (Fluent Bit templating) |
| `retentionDays` | No | **Restricted values only:** 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653 |
| `extractFields` | No | Key-value pairs for field extraction |

Fluent Bit template variables: `$stream`, `$location`, `$provider`, `$replica`, `$workload`, `$gvc`, `$org`, `$container`, `$version`.

### Coralogix

```yaml
spec:
  logging:
    coralogix:
      cluster: coralogix.com
      credentials: //secret/OPAQUE_SECRET
```

| Field | Required | Allowed Values |
|---|---|---|
| `cluster` | Yes | `coralogix.com`, `coralogix.us`, `app.coralogix.in`, `app.eu2.coralogix.com`, `app.coralogixsg.com` |
| `credentials` | Yes | Link to Opaque secret |
| `app` | No | Application name — template variables: `{org}`, `{gvc}`, `{workload}`, `{location}` |
| `subsystem` | No | Subsystem name — same template variables as `app` |

### Datadog

Dashboard host maps to an intake host (e.g. `us3.datadoghq.com` → `http-intake.logs.us3.datadoghq.com`).

```json
{
  "org": "ORG_NAME",
  "provider": "datadog",
  "host": "http-intake.logs.us3.datadoghq.com",
  "credentials": "datadog-api-key"
}
```

| Field | Required | Allowed Values |
|---|---|---|
| `host` | Yes | `http-intake.logs.datadoghq.com`, `http-intake.logs.us3.datadoghq.com`, `http-intake.logs.us5.datadoghq.com`, `http-intake.logs.datadoghq.eu` |
| `credentials` | Yes | Link to Opaque secret |

### Logz.io

```yaml
spec:
  logging:
    logzio:
      credentials: //secret/OPAQUE_SECRET
      listenerHost: listener.logz.io
```

| Field | Required | Allowed Values |
|---|---|---|
| `listenerHost` | Yes | `listener.logz.io`, `listener-nl.logz.io` |
| `credentials` | Yes | Link to Opaque secret |

### Google Stackdriver

Needs a GCP service account with Cloud Logging write permission, stored as a GCP secret.

```yaml
spec:
  logging:
    stackdriver:
      location: us-east1
      credentials: //secret/GCP_SECRET
```

| Field | Required | Description |
|---|---|---|
| `location` | Yes | A valid GCP region (e.g., `us-east1`, `europe-west1`) |
| `credentials` | Yes | Link to GCP secret |

### Elastic

Requires an `elasticVariant` discriminator plus variant-specific fields.

| Variant | Required Fields | Secret Type |
|---|---|---|
| `aws` | `host` (ends with `es.amazonaws.com`), `port`, `region`, `index`, `indexType`, `credentials` | AWS |
| `elasticCloud` | `cloudId`, `index`, `indexType`, `credentials` | Username/Password |
| `generic` | `host`, `index`, `indexType`, `credentials`; optional `port` (default 443), `path` (must start with `/`) | Username/Password |

```json
{
  "org": "ORG_NAME",
  "provider": "elastic",
  "elasticVariant": "elasticCloud",
  "cloudId": "my-deployment:BASE64_ENCODED",
  "index": "cpln-logs",
  "indexType": "logs",
  "credentials": "elastic-userpass"
}
```

### Fluentd

Forwarder, no credentials. `host` required; `port` defaults to 24224.

```yaml
spec:
  logging:
    fluentd:
      host: fluentd.example.com
      port: 24224
```

### Syslog

No credentials. `host` required.

| Field | Allowed Values | Default |
|---|---|---|
| `mode` | `tcp`, `udp`, `tls` | `tcp` |
| `format` | `rfc3164`, `rfc5424` | `rfc5424` |
| `severity` | 0–7 | 6 (Informational) |

Severity levels: `0` Emergency · `1` Alert · `2` Critical · `3` Error · `4` Warning · `5` Notice · `6` Informational · `7` Debug.

```json
{
  "org": "ORG_NAME",
  "provider": "syslog",
  "host": "syslog.example.com",
  "port": 6514,
  "mode": "tls",
  "format": "rfc5424",
  "severity": 6
}
```

### OpenTelemetry

OTLP `endpoint` required; optional `headers` and optional Opaque `credentials`.

```json
{
  "org": "ORG_NAME",
  "provider": "opentelemetry",
  "endpoint": "https://otel.example.com:4318",
  "headers": { "Authorization": "Bearer TOKEN" }
}
```

## UI Console Configuration

1. Click **Org** in the left menu.
2. Click **External Logs** in the middle context menu.
3. Select the provider and fill out required fields.
4. Select the appropriate secret for authentication.
5. Click **Save**.

## Verification

After configuring any provider:

1. **Generate logs** — deploy or interact with a workload to produce log output.
2. **Wait 2–5 minutes** — log shipping is not instant.
3. **Check the provider dashboard** — verify log entries are arriving.
4. **Verify via LogQL** — logs should still be queryable locally:

   ```bash
   cpln logs '{gvc="GVC_NAME", workload="WORKLOAD_NAME"}' --org ORG_NAME
   ```

**If logs are not appearing:**

- Verify the secret credentials are correct and have necessary permissions.
- For S3: confirm the IAM user has `s3:PutObject` on the bucket.
- For CloudWatch: confirm the IAM user has CloudWatch Logs write permissions.
- For Coralogix/Datadog/Logz.io: confirm the API key/token is valid and not expired.
- For Stackdriver: confirm the service account has Logging write permissions.
- Check that the secret is in the same org as the logging configuration.

## Log Entry Schema

All shipped log entries contain these fields:

| Field | Description |
|:---|:---|
| `time` | Timestamp of the log entry |
| `log` | The log message content |
| `org` | Organization name |
| `gvc` | Global Virtual Cloud name |
| `workload` | Workload name |
| `container` | Container name |
| `replica` | Replica identifier |
| `location` | Deployment location (e.g., `aws-us-east-1`) |
| `provider` | Cloud provider |
| `version` | Version identifier |
| `stream` | `stdout` or `stderr` |

## Gotchas

- **Structured JSON logging** — emit logs as JSON from workloads for better parsing at the destination.
- **Use template variables** — CloudWatch supports `$gvc`/`$workload` in group/stream names; Coralogix supports `{org}`/`{gvc}`/`{workload}`/`{location}` in app/subsystem.
- **Multiple providers** — ship to S3 for archival + a real-time provider for monitoring.
- **Cost awareness** — high-volume logging incurs costs at the destination; control volume with log levels.
- **Retention alignment** — set external retention to match compliance; Control Plane's built-in retention is separate.
- **Secret rotation** — rotate API keys/tokens periodically; update the Control Plane secret when credentials change.
- **`.xor()` constraint spans all 10 providers**: `s3`, `coralogix`, `datadog`, `logzio`, `elastic`, `cloudWatch`, `fluentd`, `stackdriver`, `syslog`, `opentelemetry`. Only one provider is allowed per logging block.

## Quick Reference

### MCP Tools

| Tool | Action |
|:---|:---|
| `mcp__cpln__get_external_logging` | View current external logging configuration (primary + extra providers) |
| `mcp__cpln__configure_external_logging` | Add or update a logging provider (auto-handles primary vs extra placement) |
| `mcp__cpln__remove_external_logging` | Remove a logging provider (promotes first extra to primary if removing primary) |

Supported `provider` values: `s3`, `cloudWatch`, `coralogix`, `datadog`, `logzio`, `stackdriver`, `elastic`, `fluentd`, `syslog`, `opentelemetry`.

The `credentials` field accepts a bare secret name (`my-secret`) or a full link (`//secret/my-secret`). It is required for `s3`, `cloudWatch`, `coralogix`, `datadog`, `logzio`, `stackdriver`, and `elastic`; optional for `opentelemetry`; not used by `fluentd` or `syslog`.

### Related Skills

- **cpln-logql-observability** — LogQL queries against shipped logs and Grafana dashboards.
- **cpln-metrics-observability** — Built-in metrics, Prometheus federation, custom metrics.
- **cpln-access-control** — Secrets used as logging credentials (AWS, opaque, GCP, userpass).

## Documentation

For the latest reference, see:

- [External Logging Overview](https://docs.controlplane.com/external-logging/overview.md)
- [S3 Logging](https://docs.controlplane.com/external-logging/s3.md)
- [CloudWatch Logging](https://docs.controlplane.com/external-logging/cloudwatch.md)
- [Datadog Logging](https://docs.controlplane.com/external-logging/datadog.md)
- [Coralogix Logging](https://docs.controlplane.com/external-logging/coralogix.md)
