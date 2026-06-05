# cpln guardrails

Always-on rules for working with Control Plane. Procedural how-to (deploy, troubleshoot, migrate, set up secrets, etc.) lives in cpln skills — let those load on demand.

## Verify before running

- Never write a `cpln` command from memory. Confirm shape and flags with `cpln <command> --help` before suggesting or running it.
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
- MCP calls to `https://mcp.cpln.io/mcp` are authorized by an OAuth 2.1 access token scoped to the orgs the user granted at sign-in. Treat MCP access as production access to those orgs.

## Scale-to-zero — never the default for production

Scale-to-zero is a real Control Plane capability. Explain how it works when asked. **Do not** recommend it, default to it, or configure it unless the user has explicitly asked for it by name (synonyms like "save costs" or "auto-scale" are NOT enough — the user must say "scale to zero" or "scale to 0 replicas").

When a serverless workload scales to 0, the next request waits for a cold replica to schedule, pull, and start — multi-second latency directly on a real user. After idle (`scaleToZeroDelay`, default 300s), the next user pays it again. For customer-facing services this is a recurring foot-gun.

Production default is `minScale ≥ 1` (usually `≥ 2`).

Scale-to-zero IS appropriate **only** when the user explicitly opted in AND the workload fits one of:

- Internal admin tools / dashboards used by humans, very rarely
- Dev / staging / preview environments
- Event-driven workers behind a queue with retry semantics (KEDA-driven, queue absorbs the latency)
- Background batch jobs the user framed as "scale up only when there's work"

Never use scale-to-zero for customer-facing HTTP APIs, websites, login/auth, payments, B2B endpoints called by paying customers, or anything behind a public domain. If the user asks the AI to enable scale-to-zero on such a workload, name the cold-start tradeoff before configuring. Do not include `scaleToZeroDelay` on any workload with `minScale ≥ 1` — it has no effect there.

## Production-grade workload defaults

When proposing or editing any workload, configure it for production from the outset — not the Control Plane platform defaults (`cpu: 50m`, `memory: 128Mi`, `minScale: 1`, no probes), which exist to make first-deploy frictionless, not to ship production. Inheriting them silently is the most common way to ship under-provisioned, single-point-of-failure infra.

Required minimums for production-like workloads:

- **Sizing**: `cpu: 250m`+ for typical HTTP API (`500m`+ moderate compute, `1000m`+ heavy); `memory: 256Mi`+ for tiny services (`512Mi`–`1Gi` typical APIs). Memory:CPU ratio must stay ≤ 8 (relaxed to 32 with `cpln/relaxMemoryToCpuRatio` tag). Set `minCpu` / `minMemory` so Capacity AI has a floor.
- **Replicas**: `minScale: 2`+ for any user-facing service. `minScale: 1` only when explicitly justified (single-writer DB, leader-election service, dev workload) — and say so.
- **Autoscaling**: pick `metric` by traffic shape per the `cpln-autoscaling-capacity` decision tree. Never silently `disabled`. Size `maxScale` to expected peak × headroom — default `5` is rarely right.
- **Readiness probe**: explicit `httpGet` against a real health endpoint (`/healthz`, `/ready`); `periodSeconds: 10`, `failureThreshold: 3`. On Standard/Stateful workloads, probes are **disabled by default** and must be added explicitly.
- **Liveness probe**: explicit `httpGet` (or `tcpSocket` if no HTTP healthcheck), looser cadence than readiness (`periodSeconds: 30`, `failureThreshold: 3`). Must NOT be the same probe as readiness.
- **Firewall**: set explicitly per workload purpose; never inherit defaults blindly.

When proposing a workload, output sizing + replicas + readiness + liveness + termination together with the reasoning. If a value cannot be inferred (expected RPS, real health endpoint), ask — never guess. Cron workloads are exempt from probes/minScale (use `schedule`, `concurrencyPolicy`, `activeDeadlineSeconds` instead).

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
