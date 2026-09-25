---
name: template-catalog
description: "Recommends and installs templates from the Control Plane Template Catalog. Use when the user wants postgres, redis, kafka, mongodb, mysql, or any database, cache, queue, or gateway, or asks what templates exist."
---

# Template Catalog

Production-tested charts (Helm under the hood) for databases, caches, queues, brokers, search, and gateways, with storage, firewall, and HA variants wired. A catalog template is the default for any common component; a custom workload needs a hard reason, such as an extension or image the template cannot take.

**Postgres, MySQL, MariaDB, MongoDB, or Redis: `add_database`,** not the steps below. Calling it again with a new `allowWorkloads` changes only who can connect; the password, version, and storage stay as installed. The HA and multi-location variants (`postgres-highly-available`, `mongodb-cluster`, and the rest) go through the install steps.

## Credentials: create the prerequisite secret first

- Most templates name a secret in their `values` that **must exist before the install**: `postgres`, `mongodb`, and `pgvector` read `config.credentialsSecretName` (a `dictionary` with `username`, `password`, and `database`); `mysql` and `mariadb` read `credentialsSecretName` (the same three keys) and `rootPasswordSecretName` (an `opaque` secret). The `get_template` example values mark each one.
- A missing secret does not fail the install: the release installs and the workload **wedges silently**, with no logs.
- `values` key names differ per template (secret names, resources, access scope): copy them from `get_template`, never from memory.
- Create it with `create_secret` before installing: `values: "generate"` for passwords nobody needs to know, `values: "user"` for a key the user already has (they type it into the Console). Then put its name in `values`.
- Never write a password or key into `values`: values pass through the chat and are stored in the release. A template that still takes a secret value directly in `values` is installed from the Console, or with `cpln helm install -f` and a values file the user fills in locally.

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

1. `get_template <name>`: copy the example `values.yaml`; set the prerequisite secret names, replica count, resources, storage size, and access scope.
2. `install_template` with `dryRun: true`: renders the resources the install would create, without applying anything.
3. `install_template` with a unique release `name` (immutable) and the `values` YAML (at most 128 KiB). **Omit `gvc` for templates that create their own** (the `createsGvc` flag: `cockroach`, `tidb`, `nats`, `clickhouse`, `airflow`, `mongodb-cluster`, `redis-multi-location`, `pgedge`); every other template needs an existing `gvc`.
4. Installs are asynchronous: wait with `get_installed_template` and `waitSeconds`. Its token needs `reveal` on the release's state secret.

## Configure and upgrade

Reconfigure with `upgrade_template`: pass `name` plus the new `version` and/or `values`. **`values` REPLACES the release's values entirely — there is no reuse-merge** — so start from the current values, never a partial. `template` and `gvc` are immutable and read from the installed release, so you don't pass them. Roll back with `rollback_template` (full profile) or `cpln helm rollback`.

Access scope lives in `values` under a per-template key (`internal_access.type`, `internalAccess.type`, `internalAllowType`, or `firewall.internal_inboundAllowType`), with values `same-gvc` (default), `same-org`, `workload-list` plus a `workloads:` list, and `none` on a few.

## CLI fallback (CI/CD)

When MCP is unavailable, or in pipelines with a service-account `CPLN_TOKEN`, use `cpln helm` against the OCI registry `oci://ghcr.io/controlplane-com/templates/<TEMPLATE>` (the slug is the template name):

```bash
cpln helm install my-pg oci://ghcr.io/controlplane-com/templates/postgres --version 3.4.1 -f values.yaml \
  --state-tag cpln/marketplace=true \
  --state-tag cpln/marketplace-template=postgres \
  --state-tag cpln/marketplace-template-version=3.4.1 \
  --state-tag cpln/marketplace-gvc=my-gvc
cpln helm template my-pg oci://ghcr.io/controlplane-com/templates/postgres -f values.yaml # preview rendered resources
cpln helm list                                  # releases in the org
cpln helm get values <RELEASE> --all            # currently applied values
cpln helm upgrade <RELEASE> oci://... -f values.yaml --state-tag cpln/marketplace-template-version=<NEW_VERSION>
cpln helm history <RELEASE>                      # revision numbers, for rollback
cpln helm rollback <RELEASE> [<REVISION>]        # previous revision if omitted
cpln helm uninstall <RELEASE>
```

**The four `--state-tag` flags are not optional.** `install_template` and the Console apply them; a raw `cpln helm install` does not. They go on the release state secret, and without them the release is an ordinary Helm release: the Console lists it under **Helm Releases** rather than the Template Catalog's **Releases** page, and neither the Terraform `cpln_catalog_template` resource nor the Pulumi `CatalogTemplate` resource will manage it (both require `cpln/marketplace`, `cpln/marketplace-template`, and `cpln/marketplace-template-version` to exist). Omit `cpln/marketplace-gvc` for a `createsGvc` template. State tags carry over between revisions, so an upgrade only needs to restate `cpln/marketplace-template-version`. Pin `--version` on a tagged install: omitting it resolves to latest, which leaves you with no version to put in `cpln/marketplace-template-version`.

Reference `values.yaml` for any template lives in the [templates repo](https://github.com/controlplane-com/templates) at `<template>/versions/<version>/values.yaml`.

## Connection details and backups

- An installed service is reachable in its GVC at `<release>-<component>.<gvc>.cpln.local:<port>`, for example `my-pg-postgres.<gvc>.cpln.local:5432`; the exact names are in the `get_installed_template` resources. Workloads read the credentials as `cpln://secret/NAME.KEY` from the prerequisite secret.
- Backups (`postgres`, `mongodb`) need a cloud account and a storage IAM policy first, referenced in the `values` backup block.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `rollback_template` (full profile) not found | core profile | reconnect `?toolsets=full` or use `cpln helm rollback` |
| Upgrade lost settings | `values` replaces, not merges | re-supply full values from `cpln helm get values --all` |
| Install failed / release stuck | partial apply, bad values, or unready workloads | inspect `get_installed_template` and `cpln helm history`; fix values and `upgrade_template`, or `uninstall` and reinstall |
| Workloads pending after install | image pull / firewall / resources | `diagnose_workload`, then the `workload-troubleshooting` skill |
| Install succeeded, database never starts, logs empty | the prerequisite secret did not exist at install | create it with `create_secret` (or use `add_database`), then `upgrade_template` or reinstall |
| CLI-installed release missing from the Console's Template Catalog | `cpln/marketplace*` state tags never set | re-run the upgrade with the chart and all four tags: `cpln helm upgrade <RELEASE> oci://ghcr.io/controlplane-com/templates/<T> --version <V> -f values.yaml --state-tag cpln/marketplace=true --state-tag cpln/marketplace-template=<T> --state-tag cpln/marketplace-template-version=<V> --state-tag cpln/marketplace-gvc=<GVC>` (the chart argument is mandatory; `cpln helm upgrade <RELEASE>` alone is rejected) |
