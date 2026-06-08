---
name: workload
description: "Primary skill for creating, updating, running, and debugging workloads on Control Plane — read this before create_workload / update_workload / configure_workload_* / workload_exec. Covers workload types, the spec shape, production-grade defaults, and the must-know rules across images, scaling, networking, storage, secrets, and metrics, then routes to a deeper skill for each subject. Use when the user asks to deploy/run a container, app, API, service, worker, or job, or to change/scale/expose/secure/diagnose one."
---

# Workloads — Primary Skill & Router

A **workload** is Control Plane's unit of deployment: one or more containers plus how they scale, get exposed, store data, and stay healthy. This skill carries the must-know primary rules for safely creating, updating, and running a workload.

**Need more detail on one subject?** This skill covers the common case; for depth on a single topic, load the matching skill from the **Deep-dive router** at the end — you may load one or several, as the task spans. If this plugin is installed in your agent, the skill files are already available — open the relevant skill(s) directly. If you are using the Control Plane MCP server without the plugin, call `get_cpln_skill` with the skill name instead.

## Workload type — the first decision (standard is the default)

`create_workload` defaults the type to **`standard`** when you don't specify one and covers **serverless / standard / stateful**; **cron** workloads are created with the dedicated **`create_cron_workload`** tool. Type is chosen at creation and is **immutable** (see Immutability below). Pick from:

| | **standard** (default) | serverless | stateful | cron |
|---|---|---|---|---|
| Use for | long-running services, APIs, workers | request/event-driven HTTP that scales on demand | databases & anything needing stable disk or per-replica identity | scheduled jobs |
| Autoscaling metrics | cpu, memory, latency, rps, multi, keda, disabled | concurrency, cpu, memory, rps, disabled | cpu, memory, latency, rps, multi, keda, disabled | n/a — runs on a `schedule` |
| Capacity AI | on by default | on by default | not applied | not applied |
| Probes | define readiness + liveness | define readiness + liveness | define readiness + liveness | ignored |
| `ext4`/`xfs` volumes | no | no | **yes (only here)** | no |
| `shared` volumes | yes | yes | yes | yes |
| Scale to zero | KEDA only | yes | KEDA only | n/a |
| Default `minScale` | 1 | 1 | 1 | n/a |

A workload has **1–8 containers**.

## The spec at a glance — which tool sets what

There is ONE way to express each concept. Containers always go in the typed `containers[]` array (there are no flat `image`/`cpu`/`port` fields), scaling always goes in the single `autoscaling` block, and cron has its **own pair of tools** so the common path never carries a `job`. `create_workload` handles **serverless / standard / stateful**; **`create_cron_workload`** handles scheduled jobs. The advanced blocks below were split into dedicated `configure_workload_*` tools to keep the common path lean.

| Spec block | What it controls | Set with |
|---|---|---|
| `containers[]` — `image`, `ports`, `cpu`/`memory`, `env`, `command`/`args`, probes, `metrics`, `volumes` | the container(s) — the only way to define them | `create_workload` / `create_cron_workload` / `update_workload` / `update_cron_workload` |
| `autoscaling` (→ `spec.defaultOptions.autoscaling`) + `capacityAI` / `timeoutSeconds` / `suspend` / `debug` scalars | scaling & resource optimization | `create_workload` / `update_workload` |
| `firewallConfig` (or the `public` shortcut) | inbound/outbound/internal exposure | `create_workload` / `create_cron_workload` / `update_workload` / `update_cron_workload` |
| `schedule` + cron policy (`concurrencyPolicy`, `historyLimit`, `restartPolicy`, `activeDeadlineSeconds`) | cron schedule & job policy | `create_cron_workload` / `update_cron_workload` |
| `loadBalancer` (direct / geo / replicaDirect) | custom ports, static IPs, geo headers | `configure_workload_load_balancer` |
| `sidecar.envoy` | Envoy filter chain (e.g. JWT auth) | `configure_workload_sidecar` |
| `extras` | BYOK-only affinity / tolerations / topology | `configure_workload_extras` |
| `localOptions` (incl. `spot`, `multiZone`, `capacityAIUpdateMinutes`) | per-location overrides of `defaultOptions` | `configure_workload_local_options` |
| `rolloutOptions` | graceful termination, surge/unavailable | `configure_workload_rollout` |
| `securityOptions` | `runAsUser`, `filesystemGroupId` | `configure_workload_security` |
| `requestRetryPolicy` | request retry attempts / conditions | `configure_workload_retry` |

`update_workload` and `update_cron_workload` merge `containers[]` **by name** — send only the container(s) you want to change; others are preserved (an unknown name adds a container). Always call `get_resource_schema` for the workload kind before authoring a spec — never hand-write fields from memory.

## Production-grade defaults

Platform defaults are not a production design. For any real workload:

- **`minScale ≥ 2`** for user-facing services (HA — no single point of failure). The schema default is `1`; use `1` only with a named reason (single-writer DB, leader election, dev/staging). `stateful` is often correct at `1`.
- **`maxScale`**: leave it at the default of **5** unless the user gives an explicit maximum. If the user says "max 10 replicas" (or names any number), set exactly that. Do not invent a different cap.
- **Never set `minScale: 0` (scale-to-zero)** unless the user asks for it by name. `serverless` scales to zero directly; `standard`/`stateful` only with `metric: keda`; `cron` cannot.
- **Define both `readinessProbe` and `livenessProbe`** — none are configured by default.
- **Size `cpu`/`memory` to the runtime**, not the platform defaults (`50m` / `128Mi`). Floors: CPU ≥ `25m`, memory ≥ `32Mi`. Keep `memory(MiB) / cpu(millicore) ≤ 8` (raise to 32 with the tag `cpln/relaxMemoryToCpuRatio`).
- **Pick an autoscaling metric that fits the traffic shape** (see Autoscaling).
- **Set the firewall to match intended exposure** — it is deny-by-default (see Networking).
- **Never silently downgrade** an incompatible request to `disabled` / `none` / `1` / public — surface the conflict with realistic alternatives and a recommendation.

## Images

- Your org's private registry, in a spec: **`//image/NAME:TAG`** (e.g. `//image/api:v1.0`) — the preferred form.
- **Another Control Plane org's registry: `OTHER-ORG.registry.cpln.io/NAME:TAG`** — this hostname form is valid in a workload spec for cross-org pulls.
- Public images: the **exact string** (`nginx:latest`) — **never** add a `docker.io/` prefix. ECR/GCR/etc. use their full host path.
- The `<your-org>.registry.cpln.io/NAME:TAG` form also resolves, but for your own org prefer `//image/NAME:TAG`; the hostname form is mainly used by `docker login` / `docker push`.
- **All images must be `linux/amd64`** — a wrong-arch image fails with `exec format error`.
- **Private external registries need a pull secret on the GVC** (`spec.pullSecretLinks`); only `docker`, `ecr`, and `gcp` secret types work as pull secrets. Same-org `//image/...` needs none.
- Building and pushing is **CLI-only** (`cpln image build --push`); over MCP, images are read-only (`mcp__cpln__list_images` / `mcp__cpln__get_image`).

## Run real images

Run an actual container image — not an inline/base64/heredoc app on a generic base image. For databases, caches, queues, brokers, search, gateways, or other common infrastructure, install a Template Catalog entry first (`mcp__cpln__browse_templates` → `mcp__cpln__install_template`) rather than hand-building.

## Health, readiness & verification

- **`readinessProbe` gates traffic** — the load balancer only routes to a ready replica. It should check request-path dependencies (DB, auth, cache).
- **`livenessProbe` restarts a hung process** — it must check **only** the process itself, never downstream dependencies (a dependency outage must not cycle every replica).
- Each probe is exactly one of `exec` / `grpc` / `tcpSocket` / `httpGet`. Tune `initialDelaySeconds` to real cold-start time (readiness default 10s, liveness default 60s; `periodSeconds` default 10s).
- **Verify every create/update:** poll `mcp__cpln__get_workload_deployments` until all locations report ready — it surfaces per-location errors. On failure, diagnose with `mcp__cpln__get_workload_events` (probe/scheduling reasons) then `mcp__cpln__get_workload_logs` (app error); `mcp__cpln__list_deployments` / `mcp__cpln__get_deployment` give per-location triage. **Never re-apply an unchanged failing spec**, and don't poll in a tight loop.

## Autoscaling & capacity

Set via `spec.defaultOptions.autoscaling.metric`; the system keeps the metric near but below `target` (default `95`; capped at 100 for cpu/memory). Picker:

- **concurrency** — HTTP with variable request duration (**serverless only**).
- **rps** — HTTP with consistent response times.
- **cpu** / **memory** — compute- or memory-bound work.
- **latency** — SLO-driven APIs (**standard / stateful**; set `metricPercentile`).
- **multi** — several signals, highest replica count wins (**standard / stateful**; mutually exclusive with `metric`/`target`).
- **keda** — event-driven (queues/streams; **standard / stateful**); requires `spec.keda.enabled: true` on the GVC; `target` is rejected with `keda`.
- **disabled** — fixed replicas at `minScale`.

The metric must be valid for the workload type (the matrix above) or the spec is rejected.

**Capacity AI** auto-tunes CPU/memory between `minCpu`/`minMemory` and `cpu`/`memory`. On by default for **standard** and **serverless**; **not applied** to stateful or cron. It is **rejected with the `cpu` metric** (when explicitly enabled) and **with GPUs**.

## Networking, firewall & exposure

- **Deny-by-default:** external inbound, external outbound, and internal (`inboundAllowType: none`) are all blocked until configured. Blocked CIDRs beat allowed; CIDR rules beat hostname rules.
- **Public exposure needs BOTH** an external inbound and an external outbound CIDR — one without the other ships a half-broken workload. Infer intent: a user-facing app/site/game → public; an internal API/DB/worker → restricted. Confirm when ambiguous or sensitive.
- Hostname outbound rules allow only ports **80/443/445** by default — widen with `outboundAllowPort`.
- **Internal service-to-service** uses plain HTTP over the internal hostname: `http://WORKLOAD.GVC.cpln.local:PORT` (the sidecar adds mTLS — never `https://`). Same-GVC is free; cross-GVC needs `inboundAllowType: same-org` (or an explicit `workload-list`) and incurs egress.
- **Load balancer picker:** shared (default, HTTP/HTTPS on 80/443, no config) · **direct** — per-workload custom TCP/UDP `externalPort` 22–32768, optional static IPs via an IP set, geo headers; set with `configure_workload_load_balancer` · **dedicated** — per-GVC custom domains and wildcard hosts; a GVC setting, enabled with `update_gvc`. `firewallConfig` stays on `create_workload` / `update_workload`.

## Persistent storage

- Need durable disk or stable per-replica identity → a **`stateful`** workload with a mounted **volume set**.
- A volume set's **filesystem** (`ext4` / `xfs` / `shared`) and **performance class** are **immutable** — set at creation.
- `ext4`/`xfs` mount on **stateful only**; `shared` mounts on any type. Up to **15 volumes per container**. Reserved mount paths (rejected): `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`.
- **Snapshot before any destructive volume op** (shrink/restore/delete); snapshots exist for `ext4`/`xfs` only.
- Attach with `mcp__cpln__mount_volumeset_to_workload`.

## Secrets, env vars & naming rules

- **Secrets** can be consumed two ways: as an **environment variable value** — `cpln://secret/NAME` (or `cpln://secret/NAME.key` for a keyed/dictionary secret) — or **mounted as a volume** with `uri: cpln://secret/NAME`. Either way the workload still needs **all three pieces**: an identity on the workload, a policy granting `reveal`, and the reference — or access fails silently. `mcp__cpln__workload_reveal_secret` sets the identity + policy but not the reference.
- **Environment variable names cannot start with `CPLN_`** (reserved for system use); `K_SERVICE` / `K_CONFIGURATION` / `K_REVISION` are also disallowed. Names match `^[-._a-zA-Z][-._a-zA-Z0-9]*$` (max 120 chars).
- **Container names cannot start with `cpln-` or `debugger-`** (and a few exact names like `istio-proxy` are reserved). Names are lowercase `^[a-z]([-a-z0-9])*[a-z0-9]$`, max 63.
- **Workload name** is max **49** characters, cannot end with `-headless`, and is immutable.

## Runtime traps

- **Graceful shutdown:** the default `preStop` runs `sh -c "sleep N"`. Minimal/distroless images often lack `sleep` — if it (or a custom `preStop`) fails in **any** container, **all** containers are SIGKILL'd immediately. Grace period is `spec.rolloutOptions.terminationGracePeriodSeconds` (0–900, default 90).
- **Reserved container ports** (rejected): `8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000`. Valid container port range is 80–65535.
- **Don't run as UID 1337** — that is the mesh proxy's UID. A container with `runAsUser: 1337` has its outbound traffic excluded from the Envoy sidecar redirect, so it bypasses the mesh — losing mTLS and firewall enforcement (it gets *unfiltered* egress, not "no networking").

## Immutability & destructive changes

- **Workload `type` and `name` are immutable.** Changing either = **delete + recreate**, which is **destructive**: it drops the public URL `WORKLOAD.GVC.cpln.app`, the internal DNS `WORKLOAD.GVC.cpln.local`, and policy `targetLinks` / identity bindings. Recreating with the **same name** preserves the URL/DNS; a different name silently breaks every external reference.
- The same applies to a volume set's filesystem and performance class.
- Before any delete or immutable-forcing change, present **Action · Affected · Blast radius · Data / Traffic / Access impact · Reversibility · Mitigation** and wait for explicit confirmation (see the root rules).

## Metrics & observability

- Built-in metrics (CPU/memory reserved-vs-used, request rate/latency, replica count, restarts) exist for every workload with no config.
- Custom Prometheus: add `spec.containers[].metrics` with `port` (required) and `path` (default `/metrics`).
- Query with `mcp__cpln__list_metrics` (discover real names/labels) → `mcp__cpln__query_metrics` (PromQL). Confirm a signal exists before changing scaling.

## Running commands in a live replica

`mcp__cpln__list_workload_replicas` → `mcp__cpln__workload_exec` runs ONE command in a replica. It is the **highest-risk** tool: audited, and it hits a replica **serving live traffic**.

- Read-only diagnostics (`ls`, `cat`, `env`, `df`, `curl localhost`) are fine.
- **Any state-changing command** (writes, restarts, signals, installs, migrations) needs **explicit user confirmation first** — state the exact command, what it changes, and the risk.
- One-shot only — no interactive shells/TTYs/REPLs (use the CLI `cpln workload exec` for those).

## Standard create / update flow

1. `mcp__cpln__get_cpln_rules` (once per mutating session) and read this skill.
2. Confirm the target **org / GVC** — never guess; on not-found, stop and ask.
3. `mcp__cpln__get_resource_schema` for the workload kind before authoring.
4. Discover current state: `mcp__cpln__list_workloads` / `mcp__cpln__get_workload`.
5. Prepare the smallest valid change; if destructive, confirm.
6. `mcp__cpln__create_workload` / `mcp__cpln__update_workload` (or `mcp__cpln__create_cron_workload` / `mcp__cpln__update_cron_workload` for scheduled jobs; PATCH — only sent fields change, containers merged by name), plus `configure_workload_*` for load balancer / sidecar / extras / local options / rollout / security / retry.
7. Verify: poll `mcp__cpln__get_workload_deployments`; on failure use events → logs.
8. Report exactly what changed and the resulting status.

## Quick reference — MCP tools

| Tool | Purpose |
|---|---|
| `mcp__cpln__create_workload` | Create a serverless/standard/stateful workload (typed `containers[]`, single `autoscaling` block). |
| `mcp__cpln__update_workload` | Update a workload (PATCH; containers merged by name). |
| `mcp__cpln__create_cron_workload` | Create a scheduled (cron) workload (`schedule` + job policy). |
| `mcp__cpln__update_cron_workload` | Update a cron workload (PATCH; schedule/job/containers). |
| `mcp__cpln__get_workload` / `mcp__cpln__list_workloads` | Read one / list in a GVC (capture state before changes). |
| `mcp__cpln__delete_workload` | Delete a workload (destructive — confirm blast radius first). |
| `mcp__cpln__configure_workload_load_balancer` | Set/clear `spec.loadBalancer` (direct, geo headers, replicaDirect). |
| `mcp__cpln__configure_workload_sidecar` | Set/clear `spec.sidecar.envoy` (Envoy filters, JWT auth). |
| `mcp__cpln__configure_workload_extras` | Set/clear `spec.extras` (BYOK affinity/tolerations/topology). |
| `mcp__cpln__configure_workload_local_options` | Set/clear `spec.localOptions` (per-location overrides). |
| `mcp__cpln__configure_workload_rollout` | Set/clear `spec.rolloutOptions` (graceful termination, surge/unavailable). |
| `mcp__cpln__configure_workload_security` | Set/clear `spec.securityOptions` (`runAsUser`, `filesystemGroupId`). |
| `mcp__cpln__configure_workload_retry` | Set/clear `spec.requestRetryPolicy` (retry attempts/conditions). |
| `mcp__cpln__get_workload_deployments` | PRIMARY post-deploy readiness monitor; per-location errors. |
| `mcp__cpln__get_workload_events` | Probe/scheduling failures after a bad deploy. |
| `mcp__cpln__get_workload_logs` | App-side logs (LogQL) for runtime/startup errors. |
| `mcp__cpln__list_deployments` / `mcp__cpln__get_deployment` | Per-location deployment triage. |
| `mcp__cpln__list_workload_replicas` → `mcp__cpln__workload_exec` | List replicas, then run one command in one. |
| `mcp__cpln__workload_start_cron` | Trigger an out-of-band run of a cron workload. |
| `mcp__cpln__workload_reveal_secret` | Grant a workload secret access (identity + reveal policy; you still add the reference). |
| `mcp__cpln__mount_volumeset_to_workload` | Attach a volume set to a stateful workload. |

**CLI fallback** (read the `cpln` skill first): use when MCP is unavailable/unauthenticated, for interactive work (`cpln workload exec`, `cpln workload connect`, `port-forward`), image build/copy, or as the primary interface in CI/CD (`CPLN_TOKEN` + `cpln apply --ready`).

## Deep-dive router

Load the matching skill (one or several) when you need more than the primary rules above — open it directly if this plugin is installed, otherwise fetch it with `get_cpln_skill`:

| Need | Skill |
|---|---|
| Image refs, builds, buildpacks, registries, pull secrets, cross-org sharing | `image` |
| Autoscaling, Capacity AI, scale-to-zero, KEDA, custom-metric scaling | `autoscaling-capacity` |
| Probes in depth, JWT/Envoy auth, security options, graceful termination | `workload-security` |
| Firewall rules, inbound/outbound, header & geo filtering | `firewall-networking` |
| Static IPs, direct & dedicated load balancers, custom ports | `ipset-load-balancing` |
| CDN caching, request rate limiting, DDoS protection | `cdn-rate-limiting` |
| Volumes, volume sets, snapshots, persistence, expansion | `stateful-storage` |
| Metrics, PromQL, Grafana, Prometheus federation | `metrics-observability` |
| Logs, LogQL, events, per-execution cron logs | `logql-observability` |
| Private networking, agents, VPC, on-prem connectivity | `native-networking` |
| Databases, caches, queues, brokers, common infra | `template-catalog` |
| Secrets, identities, policies, RBAC, service accounts | `access-control` |

## Documentation

- [Workload Reference](https://docs.controlplane.com/reference/workload/general.md)
