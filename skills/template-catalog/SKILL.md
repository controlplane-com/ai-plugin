---
name: cpln-template-catalog
description: "Recommends and installs production-ready templates from the Control Plane Template Catalog. Use when the user asks about deploying postgres, redis, kafka, rabbitmq, mysql, mongodb, elasticsearch, nginx, or any database/cache/queue/gateway. Also when asking what templates are available, how to install a template, or which infrastructure fits a use case. Covers 30+ templates with HA variants."
version: 1.0.0
---

# Template Catalog Guide

## Template Selection

### Databases

| Need | Template | HA Available |
|:---|:---|:---:|
| General-purpose relational | `postgres` | Yes (`postgres-highly-available`) |
| Geospatial data | `postgis` | No |
| MySQL compatibility | `mysql` or `mariadb` | No |
| Document store | `mongodb` | No |
| Distributed SQL | `cockroach` or `tidb` | Built-in |
| Analytics / OLAP | `clickhouse` | No |

### Caches & Key-Value

| Need | Template | Multi-Location |
|:---|:---|:---:|
| Simple caching | `redis` | No |
| Distributed cache | `redis-cluster` | No |
| Multi-region cache | `redis-multi-location` | Yes |
| Distributed KV store | `etcd` | No |

### Message Queues & Streaming

| Need | Template |
|:---|:---|
| Event streaming | `kafka` |
| Message broker | `rabbitmq` |
| High-performance messaging | `nats` |

### Search & Analytics

| Need | Template |
|:---|:---|
| Full-text search | `manticore` or `opensearch` |

### Gateways & Security

| Need | Template |
|:---|:---|
| Reverse proxy | `nginx` |
| API gateway | `tyk` |
| Web Application Firewall | `coraza` |
| VPN mesh | `tailscale` |

### Specialized

| Need | Template |
|:---|:---|
| Workflow orchestration | `airflow` |
| Identity management | `fusionauth` |
| S3-compatible storage | `minio` |
| LLM inference | `ollama` |
| Database management UI | `dbeaver` |
| Batch job runner | `cpln-task-runner` |
| External secret syncing | `ess` |
| Env-var secret syncing | `secret-env-var-syncer` |
| Metrics/traces/logs collection | `otel-collector` |
| Multi-master Postgres | `pgedge` |

## Installation Methods

### CLI (OCI)

Templates are published as OCI artifacts at `oci://ghcr.io/controlplane-com/templates/<TEMPLATE>`. The OCI slug matches the template name used in the tables above (e.g., `cockroach`, `ess`, `otel-collector`).

```bash
# Install a template (omit --version for latest)
cpln helm install my-postgres oci://ghcr.io/controlplane-com/templates/postgres \
  --version 3.2.0 \
  -f values.yaml

# Override individual values inline (merges with -f; --set wins on conflict)
cpln helm install my-redis oci://ghcr.io/controlplane-com/templates/redis \
  --set replicas=3
```

Each template has its own `values.yaml` schema — grab the reference values from the [templates repo](https://github.com/controlplane-com/templates) under `<template>/versions/<version>/values.yaml` and customize.

Manage installed releases:

```bash
cpln helm list                              # List releases in the org
cpln helm get all <RELEASE>                 # Full release details
cpln helm get values <RELEASE> --all        # Currently applied values
cpln helm template <RELEASE> oci://...      # Preview rendered resources
cpln helm upgrade <RELEASE> oci://... -f values.yaml
cpln helm rollback <RELEASE> [<REVISION>]   # Previous revision if omitted
cpln helm uninstall <RELEASE>               # Remove all resources
```

### Console UI

Open the Template Catalog in the Console, pick a template, configure via the form, and install.

## High Availability Recommendations

### PostgreSQL HA (Patroni)

The `postgres-highly-available` template uses Patroni for automatic failover:
- Multi-replica PostgreSQL managed by Patroni (3+ replicas recommended)
- Embedded etcd cluster (odd count: 3, 5, 7) for distributed consensus
- Automatic leader election and seamless failover on primary failure
- Per-replica persistent volume storage

For scheduled backups to S3/GCS, use the single-replica `postgres` template (the HA template does not include built-in backup).

### Redis Multi-Location

The `redis-multi-location` template deploys a master-replica Redis cluster with Redis Sentinel spanning multiple GVC locations for cross-location failover.

### CockroachDB / TiDB

These are natively distributed — the standard templates already provide HA through their built-in consensus protocols.

## Configuration

Templates are configured at install time via a `values.yaml` file (`-f`) and/or inline `--set key=value` overrides. To change configuration after install, run `cpln helm upgrade <RELEASE> oci://... -f values.yaml` with the updated values.

Common configuration points (vary per template):
- Credentials (username, password, initial database)
- Replica count (e.g., `replicas: 3`)
- Resource allocation (`resources.cpu`, `resources.memory`)
- Persistent volume storage size
- Access control (e.g., `internal_access.type`: `same-gvc`, `same-org`, or `workload-list`)
- Backup schedule and destination (where supported)

Operational secrets (credentials, startup scripts) created by the template are org-scoped. To edit one, pull it to a local file with `reveal -o yaml-slim`, edit, and re-apply:

```bash
cpln secret get                                        # List secrets in the org
cpln secret reveal <secret-name> -o yaml-slim > secret.yaml
# edit secret.yaml
cpln apply -f secret.yaml
```

## Post-Installation

After installing a template:
1. Verify all workloads are healthy: `cpln workload get --gvc my-gvc`
2. Check operational secrets were created: `cpln secret get`
3. Configure firewall rules if workloads need external access
4. Set up backup schedule for production databases
5. Monitor via Grafana dashboards

## Documentation

For the latest reference, see:

- [Template Catalog Overview](https://docs.controlplane.com/template-catalog/overview.md)
- [Install via CLI](https://docs.controlplane.com/template-catalog/install-manage/cli.md)
- [Install via Terraform](https://docs.controlplane.com/template-catalog/install-manage/terraform.md)
- [Install via Pulumi](https://docs.controlplane.com/template-catalog/install-manage/pulumi.md)
- [Install via UI](https://docs.controlplane.com/template-catalog/install-manage/ui.md)
