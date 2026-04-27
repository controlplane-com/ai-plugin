---
name: cpln-external-logging
description: "Ships logs from Control Plane workloads to external providers. Use when the user asks about log export to S3, CloudWatch, Coralogix, Datadog, Logz.io, Stackdriver, or any external logging destination. Also when asking about log forwarding, centralized logging, or external log configuration."
version: 1.0.0
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

For the YAML manifest of each provider (S3, CloudWatch, Coralogix, Datadog, Logz.io, Stackdriver, Elastic, Fluentd, Syslog, OpenTelemetry), see `skills/external-logging/providers.md`.

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

## Configuration via CLI

**There is no dedicated CLI subcommand for external logging.** Use the get-edit-apply workflow:

```bash
# 1. Get current org config as YAML (slim output is designed for cpln apply)
cpln org get ORG_NAME -o yaml-slim > org.yaml

# 2. Edit org.yaml — add or modify the spec.logging section

# 3. Apply changes
cpln apply -f org.yaml --org ORG_NAME
```

## Credential Setup

Each provider requires a secret created **before** configuring logging.

| Provider | Secret Type | How to Create |
|:---|:---|:---|
| S3, CloudWatch | AWS | `cpln secret create-aws` or Console → Secrets → New → AWS |
| Coralogix, Datadog, Logz.io | Opaque | `cpln secret create-opaque` or Console → Secrets → New → Opaque |
| Stackdriver | GCP | `cpln secret create-gcp` or Console → Secrets → New → GCP |

Credentials are referenced in YAML as `//secret/SECRET_NAME`.

## Multiple Providers

Each `logging` block supports **exactly one provider** (`.xor()` constraint). To ship to multiple providers, use `spec.extraLogging`:

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

For per-provider MCP example payloads, see `skills/external-logging/providers.md`.

### Related Skills

- **cpln-logql-observability** — LogQL queries against shipped logs and Grafana dashboards.
- **cpln-metrics-observability** — Built-in metrics, Prometheus federation, custom metrics.
- **cpln-access-control** — Secrets used as logging credentials (AWS, opaque, GCP, userpass).

### Linked Reference Docs

- `skills/external-logging/providers.md` — Per-provider YAML manifests and MCP example payloads (S3, CloudWatch, Coralogix, Datadog, Logz.io, Stackdriver, Elastic variants, Fluentd, Syslog, OpenTelemetry).

## Documentation

For the latest reference, see:

- [External Logging Overview](https://docs.controlplane.com/external-logging/overview.md)
- [S3 Logging](https://docs.controlplane.com/external-logging/s3.md)
- [CloudWatch Logging](https://docs.controlplane.com/external-logging/cloudwatch.md)
- [Datadog Logging](https://docs.controlplane.com/external-logging/datadog.md)
- [Coralogix Logging](https://docs.controlplane.com/external-logging/coralogix.md)
