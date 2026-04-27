# External Logging — Per-Provider Reference

Companion to `skills/external-logging/SKILL.md`. Per-provider YAML manifests, prerequisites, field reference, and MCP example payloads.

## Amazon S3

**Prerequisites:**
- An S3 bucket in your AWS account.
- An IAM user with **programmatic access** and `s3:PutObject` permission on the target bucket.

**Minimum IAM policy** (substitute `S3_BUCKET_NAME`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VisualEditor0",
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::S3_BUCKET_NAME/*"
    }
  ]
}
```

**YAML manifest:**

```yaml
kind: org
name: ORG_NAME
spec:
  logging:
    s3:
      bucket: S3_BUCKET_NAME
      credentials: //secret/AWS_SECRET
      prefix: /
      region: AWS_REGION
```

| Field | Required | Default | Description |
|:---|:---:|:---:|:---|
| `bucket` | Yes | — | S3 bucket name |
| `region` | Yes | — | AWS region |
| `credentials` | Yes | — | Link to AWS secret (`//secret/NAME`) |
| `prefix` | No | `/` | Folder prefix for log files |

**Log file structure:** `PREFIX/ORG_NAME/YEAR/MONTH/DAY/HOUR/MINUTE/LOG_FILE.jsonl`.

## AWS CloudWatch

**Prerequisites:**
- An AWS IAM user with credentials stored as an AWS Secret.
- CloudWatch Logs permissions in your AWS account.

**YAML manifest:**

```yaml
kind: org
name: ORG_NAME
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
|:---|:---:|:---|
| `region` | Yes | AWS region — must be one of the valid AWS regions (e.g., `us-east-1`, `eu-west-1`) |
| `credentials` | Yes | Link to AWS secret (`//secret/NAME`) |
| `groupName` | Yes | CloudWatch log group name (supports Fluent Bit templating) |
| `streamName` | Yes | CloudWatch log stream name (supports Fluent Bit templating) |
| `retentionDays` | No | **Restricted values only:** 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653 |
| `extractFields` | No | Key-value pairs for field extraction |

**Template variables** (Fluent Bit): `$stream`, `$location`, `$provider`, `$replica`, `$workload`, `$gvc`, `$org`, `$container`, `$version`.

## Coralogix

**Prerequisites:**
- A Coralogix account.
- A "Send Your Data" API key from Coralogix Dashboard → Data Flow → API Keys.

**YAML manifest:**

```yaml
kind: org
name: ORG_NAME
spec:
  logging:
    coralogix:
      cluster: coralogix.com
      credentials: //secret/OPAQUE_SECRET
```

| Field | Required | Allowed Values |
|:---|:---:|:---|
| `cluster` | Yes | `coralogix.com`, `coralogix.us`, `app.coralogix.in`, `app.eu2.coralogix.com`, `app.coralogixsg.com` |
| `credentials` | Yes | Link to Opaque secret (`//secret/NAME`) |
| `app` | No | Application name — supports template variables: `{org}`, `{gvc}`, `{workload}`, `{location}` |
| `subsystem` | No | Subsystem name — supports same template variables as `app` |

## Datadog

**Prerequisites:**
- A Datadog account.
- An API key from Datadog → Organization Settings → API Keys → New Key.

**YAML manifest:**

```yaml
kind: org
name: ORG_NAME
spec:
  logging:
    datadog:
      host: http-intake.logs.us3.datadoghq.com
      credentials: //secret/OPAQUE_SECRET
```

| Field | Required | Allowed Values |
|:---|:---:|:---|
| `host` | Yes | `http-intake.logs.datadoghq.com`, `http-intake.logs.us3.datadoghq.com`, `http-intake.logs.us5.datadoghq.com`, `http-intake.logs.datadoghq.eu` |
| `credentials` | Yes | Link to Opaque secret (`//secret/NAME`) |

**Host mapping:** Dashboard `us3.datadoghq.com` → intake host `http-intake.logs.us3.datadoghq.com`.

**MCP payload:**

```json
{
  "org": "ORG_NAME",
  "provider": "datadog",
  "host": "http-intake.logs.us3.datadoghq.com",
  "credentials": "datadog-api-key"
}
```

## Logz.io

**Prerequisites:**
- A Logz.io account.
- A data shipping token from Logz.io → [Manage Tokens](https://app.logz.io/#/dashboard/settings/manage-tokens/data-shipping?product=logs).

**YAML manifest:**

```yaml
kind: org
name: ORG_NAME
spec:
  logging:
    logzio:
      credentials: //secret/OPAQUE_SECRET
      listenerHost: listener.logz.io
```

| Field | Required | Allowed Values |
|:---|:---:|:---|
| `listenerHost` | Yes | `listener.logz.io`, `listener-nl.logz.io` |
| `credentials` | Yes | Link to Opaque secret (`//secret/NAME`) |

## Google Stackdriver

**Prerequisites:**
- A GCP project with Cloud Logging enabled.
- A GCP service account with permissions to write logs (see [GCP Secret reference](https://docs.controlplane.com/reference/secret.md)).
- The service account key stored as a GCP Secret in Control Plane.

**YAML manifest:**

```yaml
kind: org
name: ORG_NAME
spec:
  logging:
    stackdriver:
      location: us-east1
      credentials: //secret/GCP_SECRET
```

| Field | Required | Description |
|:---|:---:|:---|
| `location` | Yes | A valid GCP region (e.g., `us-east1`, `europe-west1`) |
| `credentials` | Yes | Link to GCP secret (`//secret/NAME`) |

## Elastic

Elastic requires an `elasticVariant` discriminator plus variant-specific fields. Supports three variants: AWS-managed, Elastic Cloud, and self-hosted (`generic`).

| Variant | Required Fields | Secret Type |
|:---|:---|:---|
| `aws` | `host` (ends with `es.amazonaws.com`), `port`, `region`, `index`, `indexType`, `credentials` | AWS |
| `elasticCloud` | `cloudId`, `index`, `indexType`, `credentials` | Username/Password |
| `generic` | `host`, `index`, `indexType`, `credentials`; optional `port` (default 443), `path` (must start with `/`) | Username/Password |

**MCP payload (Elastic Cloud variant):**

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

## Fluentd

Fluentd forwarder. `host` required, `port` defaults to 24224. No credentials.

```yaml
spec:
  logging:
    fluentd:
      host: fluentd.example.com
      port: 24224
```

## Syslog

| Field | Allowed Values | Default |
|:---|:---|:---|
| `mode` | `tcp`, `udp`, `tls` | `tcp` |
| `format` | `rfc3164`, `rfc5424` | `rfc5424` |
| `severity` | 0–7 | 6 (Informational) |

Severity levels: `0` Emergency · `1` Alert · `2` Critical · `3` Error · `4` Warning · `5` Notice · `6` Informational · `7` Debug.

**MCP payload:**

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

## OpenTelemetry

OTLP `endpoint` required; optional `headers` and Opaque `credentials`.

**MCP payload:**

```json
{
  "org": "ORG_NAME",
  "provider": "opentelemetry",
  "endpoint": "https://otel.example.com:4318",
  "headers": {
    "Authorization": "Bearer TOKEN"
  }
}
```
