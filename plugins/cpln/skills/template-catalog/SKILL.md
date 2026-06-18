---
name: template-catalog
description: "Recommends and installs templates from the Control Plane Template Catalog. Use when the user wants postgres, redis, kafka, mongodb, mysql, or any database, cache, queue, or gateway, or asks what templates exist."
---

# Template Catalog

> **Tool availability:** `preview_template` (dry-run) and `rollback_template` are in the `full` MCP toolset; `browse_templates`, `get_template`, `install_template`, `upgrade_template`, `uninstall_template`, `list_installed_templates`, and `get_installed_template` are in `core`. If a `full` tool is not advertised, reconnect the MCP server with `?toolsets=full` or use the `cpln helm` CLI fallback.

The Template Catalog ships production-tested charts (Helm under the hood) for databases, caches, queues, brokers, search, gateways, and more — persistent storage wired up, credentials generated as Control Plane secrets, a sane firewall posture, and HA variants where they matter. For any common component the catalog template is the **default recommendation, not the fallback**: hand-rolled workload + volumeset + secret + firewall stacks routinely ship without backups, with a public database, or single-replica. Lead with the template, and move to a custom workload only when the user has a hard reason — an unusual extension, a legacy image they must reuse, or a feature the template doesn't expose. Template-first is also enforced by the operating guide's skill router.

## Find the right template

`browse_templates` returns the **live catalog** — name, category, latest version, a "creates its own GVC" flag, and description. It is the source of truth for what exists; the table below is only the common asks. Filter with a substring (e.g. `postgres`), then call `get_template <name>` for the version list, prerequisites, and an example `values.yaml` to copy.

| Need | Templates |
|---|---|
| PostgreSQL | `postgres` (single + backup), `postgres-highly-available` (Patroni failover), `pgedge` (active-active multi-master), `postgis` (geospatial) |
| MySQL-compatible | `mysql`, `mariadb`, `tidb` (distributed) |
| Distributed SQL | `cockroach`, `tidb` |
| Document / NoSQL | `mongodb` (single), `mongodb-cluster` (replica set), `cassandra` |
| Analytics / columnar | `clickhouse` |
| Cache / KV | `redis` (replica + Sentinel), `redis-cluster` (sharded), `redis-multi-location` (cross-GVC), `etcd` |
| Streaming / queues | `kafka`, `redpanda`, `rabbitmq`, `nats`, `cpln-task-runner` |
| Search / vector | `manticore`, `opensearch`, `elasticsearch`, `weaviate` |
| Gateway / WAF / VPN | `nginx`, `tyk`, `coraza`, `tailscale` |
| Storage / AI / LLM | `minio` (S3), `ollama`, `langfuse` |
| Auth / dev / ops | `fusionauth`, `dbeaver`, `airflow`, `ess`, `secret-env-var-syncer`, `otel-collector` |

## Choosing an HA / scaling variant

This is the choice the catalog can't make for you:

- **Postgres:** `postgres` is one instance with optional scheduled S3/GCS backups; `postgres-highly-available` adds Patroni leader election and an embedded etcd quorum (odd member count — 3/5/7) plus its own scheduled backups (logical or WAL-G mode); `pgedge` is active-active multi-master across regions. Pick HA when failover matters, pgEdge when you need multi-region writes.
- **MongoDB:** `mongodb` is single; `mongodb-cluster` is a replica set and creates its own GVC.
- **Redis:** `redis` (master-replica + Sentinel) for one location; `redis-cluster` (sharded, needs 6+ nodes) for horizontal scale; `redis-multi-location` (Valkey + Sentinel) for cross-location failover.
- **Distributed SQL:** `cockroach` and `tidb` are natively distributed — HA is built in through their consensus protocols, and they create their own multi-location GVCs.
- **Streaming:** `kafka` for the full Kafka ecosystem; `redpanda` is Kafka-API-compatible with a simpler single-binary footprint.

## Install (MCP)

1. `get_template <name>` — copy the example `values.yaml`; edit credentials, replica count, resources, storage size, and access scope.
2. `preview_template` (full profile) — dry-run render the resources the install would create, without applying anything.
3. `install_template` — pass `org`, a unique `name` (the release id, immutable), `template`, the `values` YAML (required, max 128 KiB), an optional `version` (latest if omitted), and `gvc`. **Omit `gvc` for templates that create their own** (the `createsGvc` flag in `browse_templates` / `get_template`; e.g. `cockroach`, `tidb`, `nats`, `clickhouse`, `airflow`, `mongodb-cluster`, `redis-multi-location`, `pgedge`).
4. Installs are asynchronous — confirm with `get_installed_template <name>`.

## Configure and upgrade

Reconfigure with `upgrade_template`: pass `name` plus the new `version` and/or `values`. **`values` REPLACES the release's values entirely — there is no reuse-merge** — so start from the current values, never a partial. `template` and `gvc` are immutable and read from the installed release, so you don't pass them. Roll back with `rollback_template` (full profile) or `cpln helm rollback`.

Access scope lives in the template's `values` — but the **key name varies per template** (e.g. `internal_access.type`, `internalAccess.type`, `internalAllowType`, or `firewall.internal_inboundAllowType`). Values are `same-gvc` (default), `same-org`, `workload-list` (with an explicit `workloads:` list), and `none` on a few. Copy the example from `get_template` rather than writing keys from memory.

## CLI fallback (CI/CD)

When MCP is unavailable, or in pipelines with a service-account `CPLN_TOKEN`, use `cpln helm` against the OCI registry `oci://ghcr.io/controlplane-com/templates/<TEMPLATE>` (the slug is the template name):

```bash
cpln helm install my-pg oci://ghcr.io/controlplane-com/templates/postgres -f values.yaml  # omit --version for latest
cpln helm template my-pg oci://ghcr.io/controlplane-com/templates/postgres -f values.yaml # preview rendered resources
cpln helm list                                  # releases in the org
cpln helm get values <RELEASE> --all            # currently applied values
cpln helm upgrade <RELEASE> oci://... -f values.yaml
cpln helm history <RELEASE>                      # revision numbers, for rollback
cpln helm rollback <RELEASE> [<REVISION>]        # previous revision if omitted
cpln helm uninstall <RELEASE>
```

Reference `values.yaml` for any template lives in the [templates repo](https://github.com/controlplane-com/templates) at `<template>/versions/<version>/values.yaml`.

## Verify

After install, `get_installed_template <name>` shows the release status, revision, and every resource it created (it decodes the release secret, so the token needs secret **reveal** permission). Then confirm the workloads are healthy with `list_deployments`, and check the generated secrets with `list_resources` (kind `secret`). Add firewall rules or a domain for any workload that needs external access.

**Connection details:** an installed service is reachable inside its GVC at `<release>-<component>.<gvc>.cpln.local:<port>` (e.g. `my-pg-postgres.<gvc>.cpln.local:5432`); credentials live in the generated dictionary secret — reveal it to read them. The exact workload name, port, and secret keys are in `get_installed_template` (created resources) and the `get_template` example values.

## Traps

- `upgrade_template` **replaces** values — there is no partial merge, so start from the current values, not a fragment.
- Templates with `createsGvc` make their own GVC — **omit `gvc`** on install; others require an existing `gvc`.
- Uninstall removes the resources the release created, **including volume data** — confirm the blast radius first.
- `values` key names (credentials, resources, access scope) differ across templates — copy from `get_template`, don't hand-write from memory.
- Backups (e.g. `postgres`, `mongodb`) need a **Cloud Account + storage IAM policy** to exist first, referenced in the `values` backup block — see the `get_template` prerequisites.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `preview_template` / `rollback_template` not found | core profile | reconnect `?toolsets=full` or use the `cpln helm` equivalent |
| Install fails: GVC required | template installs into an existing GVC | pass `gvc` (or check `createsGvc` — self-GVC templates omit it) |
| Upgrade lost settings | `values` replaces, not merges | re-supply full values from `get_template` / `cpln helm get values --all` |
| `get_installed_template` permission denied | token lacks secret reveal | grant `reveal` on the release secret via a policy |
| Install failed / release stuck | partial apply, bad values, or unready workloads | inspect `get_installed_template` and `cpln helm history`; fix values and `upgrade_template`, or `uninstall` and reinstall |
| Workloads pending after install | image pull / firewall / resources | see the `workload` skill's troubleshooting |

## Quick reference

| Tool | Purpose | Tier |
|---|---|---|
| `mcp__cpln__browse_templates` | Live catalog (filter by substring) | core |
| `mcp__cpln__get_template` | Versions, prerequisites, example values | core |
| `mcp__cpln__preview_template` | Dry-run render, no apply | full |
| `mcp__cpln__install_template` | Install a release | core |
| `mcp__cpln__upgrade_template` | Change version/values (replaces values) | core |
| `mcp__cpln__rollback_template` | Roll back to a prior revision | full |
| `mcp__cpln__uninstall_template` | Remove a release and its resources | core |
| `mcp__cpln__list_installed_templates` | Inventory of releases in the org | core |
| `mcp__cpln__get_installed_template` | One release's status + created resources | core |

CLI fallback (CI/CD via a service-account `CPLN_TOKEN`): `cpln helm install|template|list|get|upgrade|rollback|uninstall|history` against `oci://ghcr.io/controlplane-com/templates/<TEMPLATE>`.

## Related skills

| Skill | For |
|---|---|
| `workload` | Custom workloads when no template fits; deploy-and-verify; pending-replica troubleshooting |
| `stateful-storage` | Volumesets the database templates provision; snapshots and expansion |
| `firewall-networking` | Exposing an installed service; outbound rules |
| `access-control` | Identities and policies for backup cloud accounts and secret reveal |
| `iac-terraform-pulumi` | Installing templates through Terraform or Pulumi |

## Documentation

- [Template Catalog Overview](https://docs.controlplane.com/template-catalog/overview.md)
- [Install via CLI](https://docs.controlplane.com/template-catalog/install-manage/cli.md) · [Terraform](https://docs.controlplane.com/template-catalog/install-manage/terraform.md) · [Pulumi](https://docs.controlplane.com/template-catalog/install-manage/pulumi.md) · [UI](https://docs.controlplane.com/template-catalog/install-manage/ui.md)
