---
name: workload-troubleshooting
description: "Diagnoses unhealthy Control Plane workloads. Use when asked why a workload is crashing, not starting, OOMKilled, ImagePullBackOff, returning 502s, failing health checks, unreachable, or stuck deploying."
---

# Workload Troubleshooting

The symptom-first companion to the `workload` skill (which owns workload types, the spec shape, and the create/update tools). Given an unhealthy workload, map what you observe to its platform-specific root cause and a fix the schema will actually accept. Diagnosis is **read-only and MCP-first**; most failures trace to a Control Plane rule a generic engineer would not guess — deny-by-default firewalls, the secret identity+policy chain, blocked ports, the sleep-binary shutdown rule. The single most common is OOMKilled. Deep remediation for each area lives in the domain skill named in that section; this skill is the diagnostic map.

## Step 1 — Gather state (read-only)

| Tool | What it tells you |
|---|---|
| `mcp__cpln__list_deployments` | **Start here.** Per-location readiness with reason/message. Pass `location` to drill into one failing location. |
| `mcp__cpln__get_workload_events` | Image pulls, crashes, scheduling, probe failures, `OOMKilled`. |
| `mcp__cpln__get_workload_logs` | App logs (LogQL); the `_accesslog` container holds HTTP status codes and latency. |
| `mcp__cpln__get_resource` (kind=`workload`) | The spec and current status. |
| `mcp__cpln__list_metrics` then `mcp__cpln__query_metrics` | Resource pressure — memory before OOM, CPU, latency. |
| `mcp__cpln__list_workload_replicas` then `mcp__cpln__workload_exec` | Inspect a live replica. **`workload_exec` runs in a production container and is audit-logged — read-only commands only** (`ls`, `cat`, `env`, `netstat`); confirm before anything that mutates. |
| `mcp__cpln__query_traces` then `mcp__cpln__get_trace` | For a slow or intermittently failing request: which span in the path spent the time or errored. Requires tracing enabled on the GVC (opt-in); deep dive in `metrics-observability`. |

CLI fallback (MCP unavailable, interactive shell, or CI/CD):

```bash
cpln workload get WORKLOAD --gvc GVC -o json
cpln workload eventlog WORKLOAD --gvc GVC -o json
cpln logs '{gvc="GVC", workload="WORKLOAD"}' --limit 50          # |= "error" filters; container="_accesslog" for HTTP codes
cpln workload connect WORKLOAD --gvc GVC --location LOCATION      # interactive shell
```

## Failure catalog

### Out of memory (OOMKilled) — the most common issue

**Symptoms:** container restarts repeatedly, events show `OOMKilled`, crashes under load.

`memory` is a hard cap — exceed it (app + runtime + GC + buffers) and the kernel kills the container. Usual culprits: Java without `-Xmx`, Node without `--max-old-space-size`, Python loading large datasets. Each container, sidecars included, has its own limit. With **Capacity AI** on, spiky workloads can be downsized too aggressively — set `minMemory` as a floor (Capacity AI never downscales CPU below 25 millicores).

**Fix:** check real usage with `query_metrics`, then raise `memory` — but memory (MiB) must stay within **8× CPU (millicores)**, so raise `cpu` alongside it or the update is rejected (the default `cpu: 50m` caps memory at 400Mi). See *Apply fixes within the schema's limits*.

### Image pull failures

**Symptoms:** events show `ImagePullBackOff` / `ErrImagePull`, deployment stuck.

- **Reference format** — `//image/NAME:TAG` (org registry), bare `NAME:TAG` (Docker Hub, no `docker.io/`), full URL (other registries).
- **Platform** — images must be `linux/amd64` for managed locations (BYOK allows more).
- **Pull secret** — a private external registry needs a pull secret in the GVC's `pullSecretLinks`; only `docker`, `ecr`, `gcp` secret types work, and org `//image/` images need none.

Create with `create_secret_docker`, attach with `update_gvc`. Deep setup: `image` skill.

### Secret access failures

**Symptoms:** env vars empty, logs show missing config, secret-access errors in events.

A workload reaches a secret only with all three in place: an **identity linked** to it (`spec.identityLink`), a **policy granting that identity `reveal`** on the secret, and a **correct reference**. Fastest fix: `workload_reveal_secret` builds the whole chain in one call. Reference format by type:

| Type | Reference |
|---|---|
| Opaque (decoded / raw) | `cpln://secret/NAME.payload` / `cpln://secret/NAME` |
| Dictionary | `cpln://secret/NAME.KEY` |
| Username & password | `cpln://secret/NAME.username` / `.password` |
| Keypair | `cpln://secret/NAME.secretKey` / `.publicKey` / `.passphrase` |
| TLS | `cpln://secret/NAME.cert` / `.key` / `.chain` |
| AWS | `cpln://secret/NAME.accessKey` / `.secretKey` / `.roleArn` / `.externalId` |

The manual chain: `access-control` and `setup-secret` skills.

### Port mismatch — healthy but 502/503

- The spec port must match what the process listens on — confirm with `netstat -tln` via `workload_exec`.
- On serverless, the runtime injects `PORT` and rejects a `PORT` env var that doesn't equal the exposed port.
- **Type rules:** serverless exposes exactly one port (zero is rejected; TCP needs a dedicated LB — see *Dedicated load balancer & domain*); standard and stateful expose zero or more; cron serves no endpoint.
- **Blocked ports** (cannot bind, invalid for TCP probes): `8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000`.

### Firewall blocking traffic

**Symptoms:** unreachable externally, can't reach external APIs, or can't talk to other workloads.

Deny-by-default: external inbound disabled, external outbound disabled, internal `none`. Fix via `update_workload`:

- **Inbound** — `external.inboundAllowCIDR` (e.g. `0.0.0.0/0`, or specific CIDRs).
- **Outbound** — `external.outboundAllowCIDR`, or `outboundAllowHostname` (hostname rules reach only ports 80, 443, 445).
- **Internal** — `internal.inboundAllowType`: `same-gvc` / `same-org` / `workload-list` (default `none` blocks all workload-to-workload traffic).

Full model: `firewall-networking` skill.

### Health-check failures

**Symptoms:** events show probe failures, replicas unready, restarts.

Default probes: serverless gets readiness + liveness TCP on the container port; standard, stateful, and cron have none (cron strips them). Common fixes: raise `initialDelaySeconds` (0-600; default 10 readiness / 60 liveness) for slow starts; raise `periodSeconds` (1-600, default 10) or `timeoutSeconds` (1-600, default 1) for over-aggressive probes; ensure an HTTP path returns 200-399. **Readiness** failure removes the replica from the pool and pauses rollout; **liveness** failure restarts it. An autoscaled workload with no real readiness probe gets traffic before it's ready, causing 502s on scale-up — add an `httpGet` readiness probe (it needs a port; defaults to the container's). Probe tuning: `workload-security` skill.

### Resource limits & Capacity AI

**Symptoms:** won't schedule, throttled, or Capacity AI not adjusting.

- CPU/memory must fit org quota; `maxScale` × per-replica resources is enforced at scheduling.
- **Capacity AI** does not apply with CPU-utilization or multi-metric autoscaling, or on stateful workloads — use `minCpu` / `minMemory` instead (those persist; `capacityAI` is stripped on stateful).
- **Stateful sizing** — `minCpu`/`cpu` at most 4000m apart (ratio ≤ 4:1); `minMemory`/`memory` at most 4096Mi apart (ratio ≤ 4:1).
- **Ephemeral storage** — 1GB per CPU core (minimum 1GB); exceeding it replaces the replica.

Deep model: `autoscaling-capacity` skill.

### Container won't start (restrictions)

- **UID 1337** is the mesh proxy's UID — running as it excludes the container from the sidecar, disabling mesh communication and mTLS. Override `runAsUser` to another UID in 1-65534 (0/root is rejected).
- **Reserved container names** — not `istio-proxy` / `queue-proxy` / `istio-validation` (or other reserved names); cannot start with `cpln-` or `debugger-`.
- **Reserved env vars** — names starting `CPLN_`, plus `K_SERVICE` / `K_CONFIGURATION` / `K_REVISION`, are rejected; each value caps at 4096 characters.
- **Suspended** — `spec.defaultOptions.suspend: true` stops the workload (min/max scale 0). Clear it, or `cpln workload start WORKLOAD --gvc GVC`.

### Autoscaling misconfiguration

**Symptoms:** won't scale, 502s on scale-up, scale-to-zero not working, or an invalid-strategy error on create.

Strategies: `concurrency`, `cpu`, `memory`, `rps`, `latency`, `keda`, `disabled`. Per type: **serverless** has no `latency` or multi-metric; **standard** has no `concurrency`; **stateful** has no `concurrency`; **cron** has no autoscaling at all (the block is removed). **Scale-to-zero:** serverless with `rps` or `concurrency`; standard and stateful only with `metric: keda` (otherwise the update is rejected); cron cannot. For 502s on scale-up, fix the readiness probe (above). Details: `autoscaling-capacity` skill.

### Termination / graceful shutdown

**Symptoms:** requests fail during deploys or scale-down, 502/503 on rollout, containers killed abruptly.

- **Missing `sleep`** — if `sleep` is absent from **any** container, **all** containers get SIGKILL immediately (no drain). Many distroless/minimal images lack it; confirm with `which sleep`. Fix: include `sleep` or add a custom `preStop`.
- **preStop error** — a failing custom `preStop` in any container SIGKILLs all of them.
- **Ignores SIGTERM** — after the preStop (default `sleep 45`) the container gets the termination signal, then SIGKILL once `terminationGracePeriodSeconds` (default 90; max 900 without the `cpln/relaxGracePeriodMax` tag) elapses.

Sequence and rollout options: `workload-security` skill.

### Volume mount failures

**Symptoms:** can't read mounted files, permission denied, empty cloud volume.

- **Secret volumes** need the identity + `reveal` policy chain (as *Secret access failures*).
- **Cloud volumes** (S3, GCS, Azure Blob/Files) need an identity, a cloud-access policy, and outbound firewall to the provider hosts (`*.amazonaws.com`, `*.googleapis.com`, `*.blob.core.windows.net` / `*.file.core.windows.net` plus `*.azure.com`); auth is identity-only — embedded keys do not work. Read-only except Azure Files.
- **Reserved mount paths**: `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`. Max 15 volumes; no path may be a parent of another.
- `filesystemGroupId` defaults to 0 (root) when unset — set it (1-65534) for a non-root app.

Volume sets: `stateful-storage` skill.

### Service-to-service failures

**Symptoms:** a workload can't reach another internally (connection refused or timeout).

- **Target's internal firewall** must allow the caller — `same-gvc` / `same-org` / `workload-list` (default `none`); listing a workload needs `view` on it.
- **Endpoint** — `http://WORKLOAD.GVC.cpln.local:PORT` (use `http://`; the sidecar adds mTLS). An omitted port defaults to the target's first container port; only listed ports are reachable.
- **Cross-GVC** — the target must allow `same-org` or list the caller; traffic may span locations and incur egress charges.

### Dedicated load balancer & domain

**Symptoms:** unreachable after enabling a dedicated LB, TCP broken, wrong Host header.

- **TCP** needs a dedicated LB on the GVC plus a custom Domain with a TCP port — not on default endpoints (HTTP/HTTP2/gRPC only).
- Enabling/disabling a dedicated LB causes brief DNS-propagation downtime and per-location charges.
- **Serverless Host header** — a custom domain delivers the canonical endpoint as `Host` (the custom domain moves to `X-Forwarded-Host`); standard and stateful workloads get the custom domain as `Host`.
- **Protocol compatibility** — the domain port protocol must match the container's: HTTP2 fronts HTTP2 or gRPC, HTTP fronts HTTP.

Routing, TLS, and LBs: `domain` and `ipset-load-balancing` skills.

## Apply fixes within the schema's limits

A fix the Joi schema rejects at `update_workload` time is worse than none. Before applying a resource or option change, confirm it stays within these (the validator names the violated rule):

- `memory` (MiB) at most 8× `cpu` (millicores); CPU ≥ 25m; memory ≥ 32MiB; `minCpu`/`minMemory` never above `cpu`/`memory`.
- `runAsUser` / `filesystemGroupId`: 1-65534 (0/root rejected).
- `terminationGracePeriodSeconds`: ≤ 900 (higher only with the `cpln/relaxGracePeriodMax` tag).
- `capacityAI` with `metric: cpu` is rejected; `capacityAI` is stripped on stateful, cron, and vm.
- Standard/stateful `minScale: 0` requires `metric: keda`; cron and vm cannot scale to zero.
- A metric outside the workload type's allow-list is rejected.

Prefer `update_workload` (PATCH — only the fields you set change). For full manifest control, author against `get_resource_schema` then `cpln apply -f workload.yaml --gvc GVC`.

## Verify

After applying, poll `mcp__cpln__list_deployments` until every location reports ready, confirm the original symptom cleared (events/logs), and report the **canonical endpoint** `list_deployments` returns — never a constructed URL. For a public workload, confirm it actually responds, not just that it is ready.

## Troubleshooting

| Symptom | Likely cause | First check |
|---|---|---|
| Restarts; `OOMKilled` in events | memory cap too low (or Capacity AI downsized) | `query_metrics` memory; raise `memory` + `cpu` |
| `ImagePullBackOff` / stuck | bad image ref, wrong platform, missing pull secret | events; GVC `pullSecretLinks` |
| Env vars empty | broken identity + `reveal` chain or wrong reference | `workload_reveal_secret` |
| Healthy but 502/503 | spec port ≠ listening port, or a blocked port | `netstat` via `workload_exec` |
| Unreachable / can't call out | deny-by-default firewall | `firewallConfig` |
| Won't become ready | probe path/port wrong or too aggressive | events; probe config |
| Can't reach another workload | target internal firewall `none`, or `https://` used | target `inboundAllowType`; use `http://` |
| 502/503 during deploys | missing `sleep`, or app ignores SIGTERM | `which sleep`; SIGTERM handling |
| `update_workload` rejected | the fix violates a schema limit | *Apply fixes within the schema's limits* |

## Quick reference

### MCP tools

| Tool | Purpose |
|---|---|
| `mcp__cpln__list_deployments` | Primary per-location readiness monitor |
| `mcp__cpln__get_workload_events` | Image / crash / probe / schedule events |
| `mcp__cpln__get_workload_logs` | App and `_accesslog` logs |
| `mcp__cpln__list_workload_replicas` / `mcp__cpln__workload_exec` | Target and inspect a live replica (audited) |
| `mcp__cpln__query_metrics` (after `mcp__cpln__list_metrics`) | Memory / CPU / latency pressure |
| `mcp__cpln__update_workload` | Apply a spec fix (PATCH) |
| `mcp__cpln__workload_reveal_secret` | Build the identity + `reveal` chain in one call |
| `mcp__cpln__get_resource_schema` | Exact fields before a manifest-level fix |

### CLI (fallback)

Use when MCP is unavailable, for an interactive shell, or in CI/CD (service-account `CPLN_TOKEN`).

```bash
cpln workload get WORKLOAD --gvc GVC -o json
cpln workload eventlog WORKLOAD --gvc GVC -o json
cpln workload connect WORKLOAD --gvc GVC --location LOCATION
cpln apply -f workload.yaml --gvc GVC
```

### Related skills

- `workload` — primary skill (types, spec shape, tool division); start here.
- `workload-security` — probe tuning, termination, `securityOptions`, direct LBs.
- `firewall-networking` — inbound / outbound / internal rules.
- `autoscaling-capacity` — scaling strategies and Capacity AI.
- `access-control` / `setup-secret` — the identity + `reveal` chain.
- `stateful-storage` — volume sets; `domain` / `ipset-load-balancing` — routing and LBs; `image` — registries and pull secrets.

## Documentation

- [Workload Types](https://docs.controlplane.com/reference/workload/types.md)
- [Containers](https://docs.controlplane.com/reference/workload/containers.md)
- [Capacity AI](https://docs.controlplane.com/reference/workload/capacity.md)
- [Firewall](https://docs.controlplane.com/reference/workload/firewall.md)
- [Termination](https://docs.controlplane.com/reference/workload/termination.md)
