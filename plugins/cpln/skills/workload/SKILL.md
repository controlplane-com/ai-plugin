---
name: workload
description: "Primary skill for creating, updating, running, and debugging workloads on Control Plane; routes to a deeper skill per subject. Use when the user asks to deploy or run a container, app, API, service, worker, or job, or to change, scale, expose, secure, or diagnose one."
---

# Workloads

> **Tool availability:** the `configure_workload_*` tools need `?toolsets=full`; `create_workload`, `update_workload`, and the job tools are core.

A workload is the unit of deployment: one to eight containers plus how they scale, get exposed, store data, and stay healthy. `mcp__cpln__deploy_app` covers a single-container HTTP app, image, or repository on a standard workload, including a data directory (`storage`). `create_workload` and `update_workload` cover the rest: serverless, several containers, cron, non-HTTP ports, custom firewall rules, probes and scaling tuned in depth. `restart_workload`, `rollback_workload`, `promote_workload`, and `allow_workload_access` do those jobs in one call.

## Workload type (immutable, standard by default)

| | **standard** | serverless | stateful | cron |
|---|---|---|---|---|
| Use for | long-running services, APIs, workers | request-driven HTTP that scales on demand | databases, stable disk or per-replica identity | scheduled jobs |
| Autoscaling metrics | cpu, memory, latency, rps, multi, keda, disabled | concurrency, cpu, memory, rps, disabled | cpu, memory, latency, rps, multi, keda, disabled | none: runs on `schedule` |
| Capacity AI | on by default | on by default | supported | on by default; lands at the next run |
| Default probes | none | TCP readiness and liveness | none | ignored |
| `ext4`/`xfs` volumes | no | no | **only here** | no |
| `shared` volumes | yes | yes | yes | yes |
| Scale to zero | KEDA only | yes | KEDA only | no |

`concurrency` scaling exists only on serverless; on standard or stateful the closest is `rps`. Since type cannot change, pick it for the metric the user wants.

## Which tool sets what

| Spec block | Set with |
|---|---|
| `containers[]`: image, ports, cpu/memory, env, command/args, probes, metrics, volumes | `create_workload` / `update_workload` |
| `autoscaling`, `capacityAI`, `timeoutSeconds`, `suspend`, `debug` | `create_workload` / `update_workload` |
| `firewallConfig`, or the `public` shortcut | `create_workload` / `update_workload` |
| `schedule` and job policy (`concurrencyPolicy`, `historyLimit`, `restartPolicy`, `activeDeadlineSeconds`) | the same tools with `type: cron` |
| `loadBalancer` (direct, geo, replicaDirect) | `configure_workload_load_balancer` |
| `sidecar.envoy` (JWT auth, Envoy filters) | `configure_workload_sidecar` |
| `extras` (BYOK affinity, tolerations, topology) | `configure_workload_extras` |
| `localOptions` (per-location overrides, `multiZone`, `capacityAIUpdateMinutes`) | `configure_workload_local_options` |
| `rolloutOptions` (termination grace, surge) | `configure_workload_rollout` |
| `securityOptions` (`runAsUser`, `filesystemGroupId`) | `configure_workload_security` |
| `requestRetryPolicy` | `configure_workload_retry` |

`update_workload` merges `containers[]` by name: send only the containers that change; an unknown name adds a container. On cron it patches the schedule, job policy, `suspend`, `capacityAI`, and containers, and rejects autoscaling, `timeoutSeconds`, and `debug`; schedule and job fields are rejected on other types.

## Production defaults beyond the core rules

- `minScale: 1` only with a named reason: a single writer, leader election, dev or staging. Stateful is often right at 1.
- `maxScale` stays at its default of 5 unless the user names a maximum; then use exactly that number.
- Define `readinessProbe` and `livenessProbe` yourself on standard, stateful, and cron.
- Size CPU and memory to the runtime, not the platform defaults of `50m` and `128Mi`. Floors: `25m` and `32Mi`. Memory in MiB at most 8 times CPU in millicores; the tag `cpln/relaxMemoryToCpuRatio` raises that to 32.
- Never silently downgrade a request the type rejects to `disabled`, one replica, or a weaker firewall: say what conflicts and offer alternatives.

## Images

- Another Control Plane org's registry: `OTHER-ORG.registry.cpln.io/NAME:TAG` works in a spec for cross-org pulls. For your own org prefer `//image/NAME:TAG`; the hostname form is for `docker login` and `docker push`.
- A wrong-architecture image fails with `exec format error`.
- A private external registry needs a pull secret on the GVC (`spec.pullSecretLinks`); same-org `//image/...` needs none. Detail: `image` skill.
- An app you write for the user is built first (`create-app` skill); to change an existing app's code, `get_app_files` with its image NAME says where the code lives.

## Health

- `readinessProbe` gates traffic: it may check request-path dependencies (database, auth, cache).
- `livenessProbe` restarts a hung process: it checks only the process itself, never a dependency, or one outage restarts every replica.
- Each probe uses exactly one handler: `exec`, `grpc`, `tcpSocket`, or `httpGet`. Defaults: readiness `initialDelaySeconds` 10, liveness 60, `periodSeconds` 10. Tune the delay to the real cold start.
- `list_deployments` with `location` shows one location's deployment in full detail.

## Autoscaling

Match the metric to the traffic: `rps` or `concurrency` for HTTP, `cpu` or `memory` for compute, `latency` for SLO-driven APIs, `keda` for queues. On standard with Capacity AI on, an omitted metric resolves to `disabled`, so name it. Capacity AI is rejected with the `cpu` metric and with GPUs. The metric table, KEDA, and Capacity AI: `autoscaling-capacity` skill.

## Networking

- Blocked CIDRs beat allowed ones, and CIDR rules beat hostname rules.
- Hostname outbound rules allow ports 80, 443, and 445 by default; `outboundAllowPort` replaces that set. Private RFC1918 and CGNAT ranges in `outboundAllowCIDR` are ignored on managed locations; reaching a private network takes an agent (`native-networking` skill).
- Same-GVC internal traffic is free; cross-GVC traffic needs the caller admitted (`allow_workload_access`) and pays egress.
- The canonical URL serves one port: the first container port. Standard and stateful may expose more ports across containers, reachable internally or through a direct or dedicated load balancer; serverless allows one container with one port.
- Load balancers: shared is the default (HTTP and HTTPS on 80 and 443). **Direct** gives a workload custom TCP or UDP ports 22 to 32768, optional static IPs, and geo headers (`configure_workload_load_balancer`). **Dedicated** is a GVC setting for custom domains and wildcard hosts (`update_gvc`). Toggling either needs the `configureLoadBalancer` permission, which `edit` does not include. Detail: `ipset-load-balancing` and `firewall-networking` skills.

## Storage

- Durable disk or a stable per-replica identity means a stateful workload with a volume set. A volume set's filesystem and performance class cannot change.
- `ext4` and `xfs` mount on stateful only; `shared` mounts on any type. At most 15 volumes per container; no two mounts may share or nest a path; `/dev`, `/dev/log`, `/tmp`, `/var`, and `/var/log` are rejected.
- Snapshot before a shrink, restore, or delete; snapshots exist for `ext4` and `xfs` only. Detail: `stateful-storage` skill.

## Env, names, and the workload's own API access

- Env names cannot start with `CPLN_` or be `K_SERVICE`, `K_CONFIGURATION`, or `K_REVISION`; they match `^[-._a-zA-Z][-._a-zA-Z0-9]*$`, at most 120 characters. The platform injects `CPLN_TOKEN`, `CPLN_ENDPOINT`, `CPLN_GLOBAL_ENDPOINT`, `CPLN_ORG`, `CPLN_GVC`, `CPLN_GVC_ALIAS`, `CPLN_LOCATION`, `CPLN_PROVIDER`, `CPLN_WORKLOAD`, `CPLN_WORKLOAD_VERSION`, `CPLN_IMAGE`, `CPLN_NAME`, `CPLN_MAIN` on the first container, and `PORT` on standard when unset.
- A workload calls the Control Plane API as its identity: `curl -H "Authorization: Bearer $CPLN_TOKEN" $CPLN_ENDPOINT/org/$CPLN_ORG/...`. `CPLN_ENDPOINT` is plain HTTP, and a call succeeds only where a policy grants the attached identity the permission; otherwise it returns 403.
- Container names are lowercase `^[a-z]([-a-z0-9])*[a-z0-9]$`, at most 64 characters, and cannot start with `cpln-` or `debugger-`. A workload name is at most 49 characters and cannot end with `-headless`.

## Ports and runtime traps

- Reserved container ports: 8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000. Valid ports run from 80 to 65535 and must be unique across containers.
- Termination grace is `spec.rolloutOptions.terminationGracePeriodSeconds`, 0 to 900, default 90. The shutdown sequence and its traps: `workload-security` skill.

## Renames and recreates

Changing a workload's type or name means delete and recreate. Recreating under the same name keeps its public URL and internal DNS name; a new name breaks every domain route, policy link, internal caller, and external client that used the old one.

## Metrics and live replicas

- Custom Prometheus metrics: `containers[].metrics` with `port` and `path` (default `/metrics`). Query with `list_metrics`, then `query_metrics`; measure before changing scaling.
- `list_workload_replicas` lists replicas; a command inside one goes through the CLI (`cpln` skill), with confirmation for anything that changes state.
