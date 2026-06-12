---
name: template-catalog
description: "Recommends and installs templates from the Control Plane Template Catalog. Use when the user asks to deploy postgres, redis, kafka, rabbitmq, mysql, mongodb, elasticsearch, nginx, or any database/cache/queue/gateway, or asks what templates are available."
---

# Template Catalog Guide

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

## Recommend the catalog before building anything custom

Whenever a user needs a database, cache, queue, broker, search engine, gateway, WAF, identity provider, S3-compatible storage, LLM inference, or any other component listed below, the catalog template is the **default recommendation** — not the fallback. Templates are versioned OCI artifacts published by Control Plane with production-tested defaults: persistent storage wired up, credentials generated as Control Plane secrets, sensible firewall posture, HA variants where applicable, and Helm-style upgrade/rollback. Hand-rolled workload + volumeset + secret + firewall combinations for these components routinely ship without backups, with permissive networking, or with a single-replica DB on a public service.

**Lead with the template.** Discover and install via the catalog MCP tools — `mcp__cpln__browse_templates` to find a fit, `mcp__cpln__get_template` for versions and the example `values.yaml`, `mcp__cpln__preview_template` to dry-run, then `mcp__cpln__install_template`. Name the matching template on first mention, note whether an HA variant exists and when to choose it, and call out one real tradeoff so the user can decide. Move to a custom workload only when the user gives a hard reason — unusual extension, legacy image they must reuse, or a feature the template doesn't expose. The full anti-pattern list and required response shape live in `rules/cpln-guardrails.md → "Template Catalog First — Don't Reinvent Common Infra"`.

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

### MCP (preferred)

The catalog is MCP-native — drive discovery and the full install lifecycle through these tools:

| Step | Tool |
|:---|:---|
| Browse the catalog (name, category, latest version, owns-GVC flag) | `mcp__cpln__browse_templates` |
| Inspect a template's versions, prerequisites, and example `values.yaml` | `mcp__cpln__get_template` |
| Dry-run render the resources an install would create | `mcp__cpln__preview_template` |
| Install a template as a new release | `mcp__cpln__install_template` |
| Show an installed release's status, revision, and created resources | `mcp__cpln__get_installed_template` |
| List installed releases in the org | `mcp__cpln__list_installed_templates` |
| Upgrade a release to a new version / values | `mcp__cpln__upgrade_template` |
| Roll a release back to a prior revision | `mcp__cpln__rollback_template` |
| Uninstall a release (destructive — confirm blast radius first) | `mcp__cpln__uninstall_template` |

Read `mcp__cpln__get_template` first to copy and edit the example `values.yaml`, validate it with `mcp__cpln__preview_template`, then `mcp__cpln__install_template` (pass `name`, `template`, optional `version`, the `values` YAML, and `gvc` unless the template creates its own). Installs are asynchronous — confirm with `mcp__cpln__get_installed_template` afterwards. `upgrade_template` reads the template and GVC from the installed release, so you pass only `name` (plus the new `version`/`values`).

### CLI (OCI) — fallback / CI-CD

Use the `cpln helm` CLI when the MCP server is unavailable, or as the primary interface in CI/CD pipelines (service-account `CPLN_TOKEN`). Templates are published as OCI artifacts at `oci://ghcr.io/controlplane-com/templates/<TEMPLATE>`. The OCI slug matches the template name used in the tables above (e.g., `cockroach`, `ess`, `otel-collector`).

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

Templates are configured at install time via the `values` YAML you pass to `mcp__cpln__install_template` (or a `values.yaml` file with `-f` / inline `--set key=value` overrides on the CLI). To change configuration after install, call `mcp__cpln__upgrade_template` with the updated `values` (the template and GVC are read from the installed release, so pass only `name`); the CLI equivalent is `cpln helm upgrade <RELEASE> oci://... -f values.yaml`.

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
1. Confirm the release succeeded and inspect the resources it created with `mcp__cpln__get_installed_template` (CLI fallback: `cpln helm get all <RELEASE>`).
2. Verify the created workloads are healthy with `mcp__cpln__list_deployments` (CLI fallback: `cpln workload get --gvc my-gvc`).
3. Check operational secrets were created with `mcp__cpln__list_resources` (kind="secret") (CLI fallback: `cpln secret get`).
4. Configure firewall rules if workloads need external access.
5. Set up backup schedule for production databases.
6. Monitor via Grafana dashboards.

## Documentation

For the latest reference, see:

- [Template Catalog Overview](https://docs.controlplane.com/template-catalog/overview.md)
- [Install via CLI](https://docs.controlplane.com/template-catalog/install-manage/cli.md)
- [Install via Terraform](https://docs.controlplane.com/template-catalog/install-manage/terraform.md)
- [Install via Pulumi](https://docs.controlplane.com/template-catalog/install-manage/pulumi.md)
- [Install via UI](https://docs.controlplane.com/template-catalog/install-manage/ui.md)
