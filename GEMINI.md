# cpln guardrails

Always-on rules for working with Control Plane. Procedural how-to (deploy, troubleshoot, migrate, set up secrets, etc.) lives in cpln skills — let those load on demand.

## Verify before running

- Never write a `cpln` command from memory. Confirm shape and flags with `cpln <command> --help` or the `cpln_suggest` MCP tool before suggesting or running it. (MCP tool naming may differ across hosts; verify the exact name against the active Gemini build.)
- Resource commands follow `cpln <resource> <action> [REF] [--flags]`. Standalones break the pattern: `apply`, `delete`, `logs`, `port-forward`, `cp`, `convert`, `login`.
- `cpln <resource> list` does not exist. Listing is the no-args form: `cpln workload get` lists every workload in the GVC.
- For programmatic reads, use `-o yaml` or `-o json`. Don't parse unstructured CLI output.

## Confirm before destructive operations

Before any of the following, pause and show the user the full target (org, GVC, resource name) and the change being made:

- `cpln workload delete`, `cpln gvc delete`, `cpln gvc delete-all-workloads`, `cpln secret delete`, `cpln volumeset delete`, `cpln identity delete`, `cpln policy delete`, `cpln domain delete`
- `cpln apply` against a production org/GVC, or any apply that replaces an immutable workload type
- Volumeset shrink, volume deletion, or snapshot deletion
- Secret reveal (`cpln secret reveal`, `reveal_secret`, `workload_reveal_secret`) — exposes plaintext

If `CPLN_ORG`, `CPLN_GVC`, or `CPLN_PROFILE` are unset and the command needs scope, ask which org/GVC to target before running.

## Hard rules

- `cpln apply` always requires `--file <manifest>`. There is no implicit manifest path.
- Secret creation uses type-specific commands: `cpln secret create-opaque`, `create-aws`, `create-tls`, `create-dictionary`, etc. Generic `cpln secret create` does not exist.
- Bearer token (`CPLN_TOKEN`) is sent live to `https://mcp.cpln.io/mcp` for MCP operations. Treat MCP access as production access to the configured org.

## Template Catalog first — don't reinvent common infra

When the user asks for a database, cache, queue, broker, search engine, gateway, WAF, identity provider, S3-compatible storage, or any other common infrastructure component, recommend the matching **Template Catalog** entry as the first option. Templates are versioned OCI artifacts published by Control Plane with sane defaults, HA variants, persistent storage, generated secrets, and Helm-style upgrade/rollback. Hand-rolling these wastes time and ships under-configured infra.

Trigger words → template:

- Postgres → `postgres` (single-node) or `postgres-highly-available` (HA, Patroni)
- MySQL → `mysql`; MariaDB → `mariadb`; MongoDB → `mongodb`; PostGIS → `postgis`
- Distributed SQL → `cockroach` or `tidb`; Multi-master Postgres → `pgedge`; Analytics/OLAP → `clickhouse`
- Redis → `redis` / `redis-cluster` / `redis-multi-location`; etcd → `etcd`
- Kafka → `kafka`; RabbitMQ → `rabbitmq`; NATS → `nats`
- Search → `manticore` or `opensearch`
- Reverse proxy → `nginx`; API gateway → `tyk`; WAF → `coraza`; VPN mesh → `tailscale`
- Workflow orchestration → `airflow`; Identity → `fusionauth`; Object storage → `minio`; LLM inference → `ollama`
- Batch jobs → `cpln-task-runner`; Secret syncing → `ess` / `secret-env-var-syncer`; OTel collector → `otel-collector`

Install: `cpln helm install <release> oci://ghcr.io/controlplane-com/templates/<template> -f values.yaml`

Lead with the template, name the exact OCI artifact and install command, note whether an HA variant exists and when to choose it, and call out the real tradeoff (e.g. single-replica `postgres` includes scheduled S3 backups; `postgres-highly-available` does not). Only recommend a custom workload when the user has a hard reason — unusual extension, legacy image, feature the template doesn't expose. For installation flow and full configuration, defer to the `cpln-template-catalog` skill.
