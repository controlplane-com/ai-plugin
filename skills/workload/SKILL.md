---
name: workload
description: "Primary skill for creating, updating, running, and debugging workloads on Control Plane; routes to a deeper skill per subject. Use when the user asks to deploy or run a container, app, API, service, worker, or job, or to change, scale, expose, secure, or diagnose one."
---

# Workloads — Primary Skill & Router

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

A **workload** is Control Plane's unit of deployment: one or more containers plus how they scale, get exposed, store data, and stay healthy. This skill carries the must-know primary rules for safely creating, updating, and running a workload.

**Need more detail on one subject?** This skill covers the common case; for depth on a single topic, load the matching skill from the **Deep-dive router** at the end — you may load one or several, as the task spans. If this plugin is installed in your agent, the skill files are already available — open the relevant skill(s) directly. If you are using the Control Plane MCP server without the plugin, call `get_cpln_skill` with the skill name instead.

## Workload type — the first decision (standard is the default)

`create_workload` defaults the type to **`standard`** when you don't specify one and covers all four types — **serverless / standard / stateful**, and **cron** by setting **`type: cron`** (which makes `schedule` required). Type is chosen at creation and is **immutable** (see Immutability below). Pick from:

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

The intended scaling metric can decide the type: `concurrency` scaling exists **only on serverless** — if that's the intent, create the workload as serverless (type is immutable); on standard/stateful the closest equivalent is `rps`. Never pair a metric with a type that rejects it.

A workload has **1–8 containers**.

## The spec at a glance — which tool sets what

There is ONE way to express each concept. Containers always go in the typed `containers[]` array (there are no flat `image`/`cpu`/`port` fields), scaling always goes in the single `autoscaling` block, and cron is **`create_workload` / `update_workload` with `type: cron`** — the `schedule` + job policy become available (and required), while autoscaling/`capacityAI`/`timeoutSeconds`/`debug` do not apply to cron and are rejected. The advanced blocks below were split into dedicated `configure_workload_*` tools to keep the common path lean.

| Spec block | What it controls | Set with |
|---|---|---|
| `containers[]` — `image`, `ports`, `cpu`/`memory`, `env`, `command`/`args`, probes, `metrics`, `volumes` | the container(s) — the only way to define them | `create_workload` / `update_workload` (all types, cron included) |
| `autoscaling` (→ `spec.defaultOptions.autoscaling`) + `capacityAI` / `timeoutSeconds` / `suspend` / `debug` scalars | scaling & resource optimization | `create_workload` / `update_workload` |
| `firewallConfig` (or the `public` shortcut) | inbound/outbound/internal exposure | `create_workload` / `update_workload` (all types, cron included) |
| `schedule` + cron policy (`concurrencyPolicy`, `historyLimit`, `restartPolicy`, `activeDeadlineSeconds`) | cron schedule & job policy | `create_workload` / `update_workload` **with `type: cron`** |
| `loadBalancer` (direct / geo / replicaDirect) | custom ports, static IPs, geo headers | `configure_workload_load_balancer` |
| `sidecar.envoy` | Envoy filter chain (e.g. JWT auth) | `configure_workload_sidecar` |
| `extras` | BYOK-only affinity / tolerations / topology | `configure_workload_extras` |
| `localOptions` (incl. `spot`, `multiZone`, `capacityAIUpdateMinutes`) | per-location overrides of `defaultOptions` | `configure_workload_local_options` |
| `rolloutOptions` | graceful termination, surge/unavailable | `configure_workload_rollout` |
| `securityOptions` | `runAsUser`, `filesystemGroupId` | `configure_workload_security` |
| `requestRetryPolicy` | request retry attempts / conditions | `configure_workload_retry` |

`update_workload` merges `containers[]` **by name** — send only the container(s) you want to change; others are preserved (an unknown name adds a container). On a cron workload, `update_workload` patches the `schedule` / job policy / `suspend` / containers (and rejects autoscaling/`capacityAI`/`timeoutSeconds`/`debug`); schedule/job fields are rejected against a non-cron workload. Always call `get_resource_schema` for the workload kind before authoring a spec — never hand-write fields from memory.

## Production-grade defaults

Platform defaults are not a production design. For any real workload:

- **`minScale ≥ 2`** for user-facing services (HA — no single point of failure). The schema default is `1`; use `1` only with a named reason (single-writer DB, leader election, dev/staging). `stateful` is often correct at `1`.
- **`maxScale`**: leave it at the default of **5** unless the user gives an explicit maximum. If the user says "max 10 replicas" (or names any number), set exactly that. Do not invent a different cap.
- **Never set `minScale: 0` (scale-to-zero)** unless the user asks for it by name. `serverless` scales to zero directly; `standard`/`stateful` only with `metric: keda`; `cron` cannot.
- **Define both `readinessProbe` and `livenessProbe`** — none are configured by default.
- **Size `cpu`/`memory` to the runtime**, not the platform defaults (`50m` / `128Mi`). Floors: CPU ≥ `25m`, memory ≥ `32Mi`. Keep `memory(MiB) / cpu(millicore) ≤ 8` (raise to 32 with the tag `cpln/relaxMemoryToCpuRatio`).
- **Pick an autoscaling metric that fits the traffic shape** (see Autoscaling).
- **Set the firewall to match intended exposure IN THE CREATE CALL** — it is deny-by-default (see Networking). Decide reachability before creating (`public: true` or `firewallConfig`); creating closed and patching the firewall open afterward is a spec error, not a workflow.
- **Never silently downgrade** an incompatible request to `disabled` / `none` / `1` / public — surface the conflict with realistic alternatives and a recommendation.

## Images

- Your org's private registry, in a spec: **`//image/NAME:TAG`** (e.g. `//image/api:v1.0`) — the preferred form.
- **Another Control Plane org's registry: `OTHER-ORG.registry.cpln.io/NAME:TAG`** — this hostname form is valid in a workload spec for cross-org pulls.
- Public images: the **exact string** (`nginx:latest`) — **never** add a `docker.io/` prefix. ECR/GCR/etc. use their full host path.
- The `<your-org>.registry.cpln.io/NAME:TAG` form also resolves, but for your own org prefer `//image/NAME:TAG`; the hostname form is mainly used by `docker login` / `docker push`.
- **All images must be `linux/amd64`** — a wrong-arch image fails with `exec format error`.
- **Private external registries need a pull secret on the GVC** (`spec.pullSecretLinks`); only `docker`, `ecr`, and `gcp` secret types work as pull secrets. Same-org `//image/...` needs none.
- Building and pushing is **CLI-only** (`cpln image build --push`); over MCP, images are list/get/delete only (`mcp__cpln__list_resources` / `mcp__cpln__get_resource` / `mcp__cpln__delete_resource`, kind="image").

## Run real images

Run an actual container image — not an inline/base64/heredoc app on a generic base image. For databases, caches, queues, brokers, search, gateways, or other common infrastructure, install a Template Catalog entry first (`mcp__cpln__browse_templates` → `mcp__cpln__install_template`) rather than hand-building.

## Health, readiness & verification

- **`readinessProbe` gates traffic** — the load balancer only routes to a ready replica. It should check request-path dependencies (DB, auth, cache).
- **`livenessProbe` restarts a hung process** — it must check **only** the process itself, never downstream dependencies (a dependency outage must not cycle every replica).
- Each probe is exactly one of `exec` / `grpc` / `tcpSocket` / `httpGet`. Tune `initialDelaySeconds` to real cold-start time (readiness default 10s, liveness default 60s; `periodSeconds` default 10s).
- **Verify every create/update automatically — without asking:** poll `mcp__cpln__list_deployments` until all locations report ready (it surfaces per-location errors **and** the workload's canonical public URL). Then give the user that **canonical** URL — never construct one or report a per-location deployment URL as the address. **For a public workload, do not stop at "ready" — confirm it actually serves:** make a real HTTP GET of the canonical endpoint (when you have that capability) and read the result — never claim reachability without a real response you received; if you cannot make a request, report readiness confirmed but external reachability not independently verified. A ready deployment can still be unreachable — firewall inbound unset, or TLS/DNS still propagating. Treat 2xx/3xx/401/403 as serving; a timeout/refused points first at firewall inbound, a TLS/DNS error at propagation (wait, don't redeploy). On failure, diagnose with `mcp__cpln__get_workload_events` (probe/scheduling reasons) then `mcp__cpln__get_workload_logs` (app error); pass the optional `location` to `list_deployments` (e.g. `aws-us-east-1`) to inspect ONE location's deployment in full detail. **Never re-apply an unchanged failing spec**, and don't poll in a tight loop.

## Autoscaling & capacity

Set via `spec.defaultOptions.autoscaling.metric`; the system keeps the metric near but below `target` (default `95`; capped at 100 for cpu/memory). If `metric` is omitted, serverless defaults to `concurrency` and standard/stateful default to `cpu`. Picker:

- **concurrency** — HTTP with variable request duration (**serverless only**).
- **rps** — HTTP with consistent response times.
- **cpu** / **memory** — compute- or memory-bound work.
- **latency** — SLO-driven APIs (**standard / stateful**; set `metricPercentile`).
- **multi** — several signals, highest replica count wins (**standard / stateful**; entries limited to `cpu`/`memory`/`rps`; mutually exclusive with `metric`/`target`).
- **keda** — event-driven (queues/streams; **standard / stateful**); requires `spec.keda.enabled: true` on the GVC; `target` is rejected with `keda`.
- **disabled** — fixed replicas at `minScale`.

The metric must be valid for the workload type (the matrix above) or the spec is rejected — e.g. `concurrency` on a `standard` workload is rejected (it is serverless-only). Match the metric to the workload's traffic shape: `rps`/`concurrency` for HTTP, `cpu`/`memory` for compute-bound work, `latency` for SLO-driven APIs. For tuning targets/percentiles, multi-metric, KEDA, scale-to-zero, or Capacity AI, load the `autoscaling-capacity` skill.

**Capacity AI** auto-tunes CPU/memory between `minCpu`/`minMemory` and `cpu`/`memory`. On by default for **standard** and **serverless**; **not applied** to stateful or cron. It is **rejected with the `cpu` metric** (when explicitly enabled) and **with GPUs**.

## Networking, firewall & exposure

- **Deny-by-default:** external inbound, external outbound, and internal (`inboundAllowType: none`) are all blocked until configured. Blocked CIDRs beat allowed; CIDR rules beat hostname rules.
- **Public exposure needs BOTH** an external inbound and an external outbound CIDR — one without the other ships a half-broken workload. Infer intent: a user-facing app/site/game → public; an internal API/DB/worker → restricted. Confirm when ambiguous or sensitive — and decide BEFORE creating: exposure belongs in the create call itself, never a follow-up firewall patch.
- Hostname outbound rules allow only ports **80/443/445** by default; `outboundAllowPort` **replaces** that set (re-list 80/443 if still needed). Private RFC1918/CGNAT ranges in `outboundAllowCIDR` are silently ignored on managed locations — reaching private networks takes a wormhole agent (`native-networking`).
- **Internal service-to-service** uses plain HTTP over the internal hostname: `http://WORKLOAD.GVC.cpln.local:PORT` (the sidecar adds mTLS — never `https://`). Same-GVC is free; cross-GVC needs `inboundAllowType: same-org` (or an explicit `workload-list`) and incurs egress.
- **One public canonical port.** `WORKLOAD.GVC.cpln.app` serves a **single** port — the first container port. `standard`/`stateful` may expose **more** ports across containers (unique numbers), reachable at `WORKLOAD.GVC.cpln.local:PORT` or via a **direct/dedicated load balancer**; `serverless` is limited to one container / one port. `WORKLOAD.GVC.cpln.app` is the URL *shape* only — always report the **actual** canonical URL from `list_deployments` / the workload's `status.canonicalEndpoint`; never construct or guess it (custom domains, BYOK, and alias suffixes make the literal form wrong).
- **Always declare ports with the `containers[].ports` array** — e.g. `ports: [{ number: 80, protocol: "http" }]`; for a single port use a one-element array. The legacy scalar `containers[].port` field is **deprecated — never use it**, even if `get_resource_schema` still lists it (the platform keeps it for backward compatibility, but new specs must use `ports[]`).
- **Load balancer picker:** shared (default, HTTP/HTTPS on 80/443, no config) · **direct** — per-workload custom TCP/UDP `externalPort` 22–32768, optional static IPs via an IP set, geo headers; set with `configure_workload_load_balancer` · **dedicated** — per-GVC custom domains and wildcard hosts; a GVC setting, enabled with `update_gvc`. `firewallConfig` stays on `create_workload` / `update_workload`. Toggling direct/dedicated needs the `configureLoadBalancer` permission — `edit` does not imply it (`ipset-load-balancing` skill).

## Persistent storage

- Need durable disk or stable per-replica identity → a **`stateful`** workload with a mounted **volume set**.
- A volume set's **filesystem** (`ext4` / `xfs` / `shared`) and **performance class** are **immutable** — set at creation.
- `ext4`/`xfs` mount on **stateful only**; `shared` mounts on any type. Up to **15 volumes per container**, and no two mounts in a container may share a path or nest (one mount path cannot be a parent of another). Reserved mount paths (rejected): `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`.
- **Snapshot before any destructive volume op** (shrink/restore/delete); snapshots exist for `ext4`/`xfs` only.
- Attach with `mcp__cpln__mount_volumeset_to_workload`.

## Secrets, env vars & naming rules

- **Secrets** can be consumed two ways: as an **environment variable value** — `cpln://secret/NAME` (or `cpln://secret/NAME.key` for a keyed/dictionary secret) — or **mounted as a volume** with `uri: cpln://secret/NAME`. Either way the workload still needs **all three pieces**: an identity on the workload, a policy granting `reveal`, and the reference — or access fails silently. `mcp__cpln__workload_reveal_secret` sets the identity + policy but not the reference, and it requires the workload to **already exist** — for a new workload, `create_workload` first (its deployment pauses on the secret reference until access is granted, then resumes); never call `workload_reveal_secret` before the workload exists.
- **Environment variable names cannot start with `CPLN_`** (reserved). The platform injects these at runtime: `CPLN_TOKEN`, `CPLN_ENDPOINT`, `CPLN_GLOBAL_ENDPOINT`, `CPLN_ORG`, `CPLN_GVC`, `CPLN_GVC_ALIAS`, `CPLN_LOCATION`, `CPLN_PROVIDER`, `CPLN_WORKLOAD`, `CPLN_WORKLOAD_VERSION`, `CPLN_IMAGE`, `CPLN_NAME` (plus `CPLN_MAIN` on the first container, and `PORT` on standard when unset). `K_SERVICE` / `K_CONFIGURATION` / `K_REVISION` are also disallowed. Names match `^[-._a-zA-Z][-._a-zA-Z0-9]*$` (max 120 chars).
- **A workload can call the Control Plane API as its identity:** `curl -H "Authorization: Bearer $CPLN_TOKEN" $CPLN_ENDPOINT/org/$CPLN_ORG/...` — `CPLN_ENDPOINT` is plain **http** (the sidecar secures and signs it in transit). Requests act as the attached `spec.identityLink` identity and succeed only where a policy grants that identity the permission — no identity attached or no policy means 403. The token works **only from inside that workload, against `CPLN_ENDPOINT`**: it does not authenticate to `api.cpln.io`, `metrics.cpln.io`, or `logs.cpln.io` (use a service-account key there).
- **Container names cannot start with `cpln-` or `debugger-`** (and a few exact names like `istio-proxy` are reserved). Names are lowercase `^[a-z]([-a-z0-9])*[a-z0-9]$`, max 64.
- **Workload name** is max **49** characters, cannot end with `-headless`, and is immutable.

## Runtime traps

- **Graceful shutdown:** the default `preStop` runs `sh -c "sleep N"`. Minimal/distroless images often lack `sleep` — if it (or a custom `preStop`) fails in **any** container, **all** containers are SIGKILL'd immediately. Grace period is `spec.rolloutOptions.terminationGracePeriodSeconds` (0–900, default 90).
- **Reserved container ports** (rejected): `8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000`. Valid container port range is 80–65535; **port numbers must be unique across all containers**. A **serverless** workload must expose **exactly one port, on exactly one container**. Declare every port in the `containers[].ports` array (`[{ number, protocol }]`) — the scalar `containers[].port` field is deprecated; do not use it.
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

1. Read this skill once per session before authoring (you are doing that now); `mcp__cpln__get_cpln_rules` has the cross-cutting operating guide if you have not read it this session.
2. Confirm the target **org / GVC** — never guess; on not-found, stop and ask.
3. `mcp__cpln__get_resource_schema` for the workload kind before authoring.
4. Discover current state: `mcp__cpln__list_resources` (kind="workload") / `mcp__cpln__get_resource` (kind="workload").
5. Prepare the smallest valid change; if destructive, confirm.
6. `mcp__cpln__create_workload` / `mcp__cpln__update_workload` (for a scheduled job, pass `type: cron` with a `schedule`; PATCH — only sent fields change, containers merged by name), plus `configure_workload_*` for load balancer / sidecar / extras / local options / rollout / security / retry.
7. Verify automatically — do not ask permission: poll `mcp__cpln__list_deployments` until every location is ready; on failure diagnose with events → logs and fix.
8. Report exactly what changed and the resulting status — and for an exposed workload, give the user its **canonical** public URL (read from `list_deployments` or the workload's `status.canonicalEndpoint`; never construct/guess it or report a per-location URL as the address).

## Quick reference — MCP tools

| Tool | Purpose |
|---|---|
| `mcp__cpln__create_workload` | Create any workload (typed `containers[]`, single `autoscaling` block) — including a scheduled job with `type: cron` + a required `schedule`. |
| `mcp__cpln__update_workload` | Update a workload (PATCH; containers merged by name) — on a cron workload, patches `schedule` / job policy / `suspend`. |
| `mcp__cpln__get_resource` (kind="workload") / `mcp__cpln__list_resources` (kind="workload") | Read one / list in a GVC (capture state before changes). |
| `mcp__cpln__delete_resource` (kind="workload") | Delete a workload (destructive — confirm blast radius first). |
| `mcp__cpln__configure_workload_load_balancer` | Set/clear `spec.loadBalancer` (direct, geo headers, replicaDirect). |
| `mcp__cpln__configure_workload_sidecar` | Set/clear `spec.sidecar.envoy` (Envoy filters, JWT auth). |
| `mcp__cpln__configure_workload_extras` | Set/clear `spec.extras` (BYOK affinity/tolerations/topology). |
| `mcp__cpln__configure_workload_local_options` | Set/clear `spec.localOptions` (per-location overrides). |
| `mcp__cpln__configure_workload_rollout` | Set/clear `spec.rolloutOptions` (graceful termination, surge/unavailable). |
| `mcp__cpln__configure_workload_security` | Set/clear `spec.securityOptions` (`runAsUser`, `filesystemGroupId`). |
| `mcp__cpln__configure_workload_retry` | Set/clear `spec.requestRetryPolicy` (retry attempts/conditions). |
| `mcp__cpln__list_deployments` | PRIMARY post-deploy readiness monitor (all locations); per-location errors **and** the canonical public URL to report. Pass the optional `location` (e.g. `aws-us-east-1`) for ONE deployment's full detail — version chain, per-container readiness, full JSON. |
| `mcp__cpln__get_workload_events` | Probe/scheduling failures after a bad deploy. |
| `mcp__cpln__get_workload_logs` | App-side logs (LogQL) for runtime/startup errors. |
| `mcp__cpln__list_workload_replicas` → `mcp__cpln__workload_exec` | List replicas, then run one command in one. |
| `mcp__cpln__workload_start_cron` | Trigger an out-of-band run of a cron workload. |
| `mcp__cpln__workload_reveal_secret` | Grant an **existing** workload secret access (identity + reveal policy; you still add the reference — create the workload first). |
| `mcp__cpln__mount_volumeset_to_workload` | Attach a volume set to a stateful workload. |

**CLI fallback** (read the `cpln` skill first): use when MCP is unavailable/unauthenticated, for interactive work (`cpln workload exec`, `cpln workload connect`, `port-forward`), image build/copy, or as the primary interface in CI/CD (`CPLN_TOKEN` + `cpln apply --ready`).

**Raw API escape hatch:** for a spec field no typed `create_workload` / `update_workload` / `configure_workload_*` tool exposes, use `mcp__cpln__cpln_api_request` (raw GET/POST/PATCH/DELETE; disabled by default — only when advertised) — call `mcp__cpln__get_resource_schema` first for the exact path and body, and prefer the typed tools whenever they cover the field. If it is not advertised, apply the full manifest with the `cpln` CLI instead.

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
