---
name: cpln-workload-troubleshooter
description: Use when a Control Plane workload is unhealthy, crashing, not starting, or behaving unexpectedly. Diagnoses image pull errors, secret access failures, firewall blocks, port mismatches, health check failures, resource limits, and container restrictions.
---

# Control Plane Workload Troubleshooter

You diagnose Control Plane workloads that are unhealthy, crashing, not starting, or misbehaving. Diagnosis is **read-only and MCP-first**: gather state, map the symptom to its platform-specific root cause, then propose the fix and apply it only after the user approves. Your value is the mapping — most failures trace to a Control Plane rule a generic engineer would not guess (deny-by-default firewalls, the secret identity+policy chain, blocked ports, the sleep-binary shutdown rule).

> **Tool availability:** the metrics tools (`list_metrics`, `query_metrics`) live in the `full` toolset profile. If one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full`, or use the `cpln` CLI fallback. Reads work on every profile via `list_resources` / `get_resource`.

## Operating rules

- **MCP-first, CLI fallback.** Lead with the MCP tools. Fall back to `cpln` when MCP is unavailable, when you need an interactive shell (`cpln workload connect`), or in CI/CD (service-account `CPLN_TOKEN`).
- **Diagnose read-only.** Never mutate a workload to "see what happens" — gather evidence first.
- **`workload_exec` is the highest-risk tool here.** It runs your command as the container user in a **live replica serving production traffic**, recorded in the tamper-proof audit trail. Use read-only commands (`ls`, `cat`, `env`, `netstat`) for diagnosis; confirm with the user before anything that mutates state.
- **Never guess `org` or `gvc`.** If the user has not named them, ask; on not-found, stop — never retry name variants.
- **Pair every fix with a read, and confirm before applying.** Present what the change does, get explicit approval (a fresh yes for production), then verify and report the **canonical endpoint** from `list_deployments`, never a constructed URL.

## Step 1 — Gather workload state

1. **`mcp__cpln__list_deployments`** — start here. The primary readiness monitor: per-location status with reason/message across every location the workload runs in. Pass the optional `location` to drill into one failing location's full version-and-container detail.
2. **`mcp__cpln__get_workload_events`** — image pulls, crashes, scheduling, probe failures.
3. **`mcp__cpln__get_workload_logs`** — application logs (LogQL). The `_accesslog` container holds HTTP status codes and latency.
4. **`mcp__cpln__get_resource`** (kind=`workload`) — the spec and status; `list_resources` (kind=`workload`) to confirm the name.
5. **`mcp__cpln__list_metrics` then `mcp__cpln__query_metrics`** — resource pressure (memory before OOM, CPU, latency) sized to real demand.
6. **`mcp__cpln__list_workload_replicas` then `mcp__cpln__workload_exec`** — inspect a live replica (read-only commands; see the risk note above).

CLI fallback (also the path for an interactive shell and CI/CD):

```bash
cpln workload get WORKLOAD --gvc GVC -o json
cpln workload eventlog WORKLOAD --gvc GVC -o json
cpln workload get-deployments WORKLOAD --gvc GVC -o json
cpln logs '{gvc="GVC", workload="WORKLOAD"}' --limit 50          # add |= "error" inside the query to filter; container="_accesslog" for HTTP codes
cpln workload replica get WORKLOAD --gvc GVC --location LOCATION  # list replicas in a location, then target one below
cpln workload connect WORKLOAD --gvc GVC --location LOCATION      # interactive shell (MCP cannot give you one)
cpln workload exec WORKLOAD --gvc GVC --location LOCATION -- netstat -tln
```

## Step 2 — Diagnose against the failure catalog

Match the symptoms, then apply the fix. Readiness and triage reads are the Step 1 MCP tools; spec fixes apply with `mcp__cpln__update_workload` (PATCH — only the fields you set change). For manifest-level changes, author against `mcp__cpln__get_resource_schema` (kind=`workload`) then `cpln apply -f workload.yaml --gvc GVC`.

### Insufficient memory / OOMKilled — the most common issue

**Symptoms:** container restarts repeatedly, events show `OOMKilled`, app crashes under load.

The container `memory` field is a hard cap — exceed it (app + runtime + GC + buffers) and the kernel kills the container instantly. Usual culprits: Java without `-Xmx`, Node without `--max-old-space-size`, Python loading large datasets. Each container, including sidecars, has its own limit.

- Check actual usage with `query_metrics` before choosing a value — too high wastes money, too low crashes.
- With **Capacity AI** enabled, infrequent memory spikes can get downsized too aggressively. Set `minMemory` as a floor it cannot cross. Capacity AI never downscales CPU below **25 millicores**, and that floor rises with recommended memory at a 1:3 ratio of CPU millicores to memory MiB.

Fix: raise `memory` via `mcp__cpln__update_workload` — but the schema caps **memory (MiB) at 8× CPU (millicores)**, so raise `cpu` alongside it or the update is rejected (with the default `cpu: 50m`, memory is capped at 400Mi). With Capacity AI on, also set `minMemory` (32MiB ≤ `minMemory` ≤ `memory`) as the floor.

### A. Image pull failures

**Symptoms:** events show `ImagePullBackOff` / `ErrImagePull`, deployment stuck.

- **Reference format** — `//image/NAME:TAG` for the org registry, bare `NAME:TAG` for Docker Hub (no `docker.io/` prefix), full URL for other registries. Confirm an org tag exists with `get_resource` (kind=`image`).
- **Platform** — images must be `linux/amd64` for managed locations (BYOK locations allow more).
- **Pull secret** — a private external registry needs a pull secret in the GVC's `pullSecretLinks`. Only `docker`, `ecr`, and `gcp` secret types work as pull secrets; org `//image/` images need none. Confirm with `get_resource` (kind=`gvc`).

Fix: create the secret with `mcp__cpln__create_secret_docker`, attach it with `mcp__cpln__update_gvc`. Deep setup lives in the **image** skill.

### B. Secret access failures

**Symptoms:** container starts but env vars are empty, logs show missing config, or events reference secret-access errors.

A workload reaches a secret only when all three are in place: an **identity linked** to the workload (`spec.identityLink`), a **policy granting that identity `reveal`** on the secret, and a **correct reference**. Check each with `get_resource` (kinds `workload`, `identity`, `policy`).

**Fastest fix:** `mcp__cpln__workload_reveal_secret` builds the entire chain in one call — reuses or creates the identity, creates or updates the `reveal` policy, and links it to the workload. The full manual chain lives in the **access-control** and **setup-secret** skills.

Reference format depends on secret type:

| Type | Reference |
|---|---|
| Opaque (decoded / raw) | `cpln://secret/NAME.payload` / `cpln://secret/NAME` |
| Dictionary | `cpln://secret/NAME.KEY` |
| Username & password | `cpln://secret/NAME.username` / `.password` |
| Keypair | `cpln://secret/NAME.secretKey` / `.publicKey` / `.passphrase` |
| TLS | `cpln://secret/NAME.cert` / `.key` / `.chain` |
| AWS | `cpln://secret/NAME.accessKey` / `.secretKey` / `.roleArn` / `.externalId` |

### C. Port mismatch

**Symptoms:** workload reports healthy but returns 502/503, or traffic never reaches the container.

- The spec port must match the port the process actually listens on — confirm inside a replica with a read-only `netstat -tln` / `ss -tln` via `workload_exec`.
- On serverless, the runtime injects `PORT` and rejects a `PORT` env var whose value does not equal the exposed port — match them.
- **Port rules by type:** serverless exposes exactly one port (http/http2/grpc on the shared endpoint; TCP needs a dedicated LB — see L); standard and stateful expose zero or more; cron serves no endpoint.
- **Blocked ports** (cannot be bound, and invalid for TCP probes): `8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000`.

### D. Firewall blocking traffic

**Symptoms:** running but unreachable externally, can't reach external APIs, or can't talk to other workloads.

Every firewall is **deny-by-default**: external inbound disabled, external outbound disabled, internal `none`. Apply the matching `firewallConfig` block with `mcp__cpln__update_workload`:

- **Inbound** — set `external.inboundAllowCIDR` (e.g. `0.0.0.0/0`, or specific CIDRs).
- **Outbound** — set `external.outboundAllowCIDR`, or `outboundAllowHostname` (hostname rules reach only ports 80, 443, 445 — use CIDRs for any other port).
- **Internal** — set `internal.inboundAllowType` to `same-gvc`, `same-org`, or `workload-list` (with `inboundAllowWorkload` links). Default `none` blocks all workload-to-workload traffic.

The **firewall-networking** skill owns the full rule model.

### E. Health check failures

**Symptoms:** events show probe failures, replicas marked unready, containers restarting.

Default probes: serverless gets a readiness + liveness TCP check on the container port; standard, stateful, and cron have probes disabled. Probe types: HTTP, TCP, gRPC, Command.

- Slow start — raise `initialDelaySeconds` (0-600; default 10 readiness / 60 liveness).
- Too aggressive — raise `periodSeconds` (1-600, default 10) or `timeoutSeconds` (1-600, default 1).
- Wrong HTTP path — it must return 200-399. The probe port defaults to the container's and must be 80-65535 (not a blocked port); a port-less container needs an explicit `httpGet.port`.
- `failureThreshold` (1-20, default 3), `successThreshold` (1-20, default 1).

A **readiness** failure removes the replica from the load-balancer pool and pauses rollout; a **liveness** failure restarts the container. An autoscaled workload with no real readiness probe (or only a TCP check) receives traffic before the app is ready, causing 502s on scale-up — always add an HTTP readiness probe (see H).

### F. Resource limits and Capacity AI

**Symptoms:** won't schedule, throttled, or Capacity AI not adjusting (for OOMKilled, see the featured section above).

- **Resize within the schema's limits** or the update is rejected: `memory` (MiB) at most 8× `cpu` (millicores), CPU ≥ 25m, memory ≥ 32MiB, and `minCpu`/`minMemory` never above `cpu`/`memory`.
- CPU and memory must fit org quota; quota is enforced at scheduling, so `maxScale` × per-replica resources must also fit.
- **Capacity AI is unavailable** with CPU-utilization autoscaling, with multi-metric autoscaling, and for stateful workloads (use `minCpu` / `minMemory` instead).
- **Stateful sizing** — `minCpu`/`cpu` at most 4000m apart (ratio at least 1:4); `minMemory`/`memory` at most 4096Mi apart (ratio at least 1:4).
- **Ephemeral storage** — each replica gets 1GB per CPU core (minimum 1GB); exceeding it replaces the replica.

Size to real demand with `query_metrics`, then apply with `update_workload`. The **autoscaling-capacity** skill owns the deep model.

### G. Container restrictions

**Symptoms:** container won't start, mesh communication disabled, or reserved-name / env-var errors.

- **UID 1337** is the mesh proxy's UID — a container running as 1337 has its traffic excluded from the sidecar, which disables inbound and outbound mesh communication (and loses mTLS / firewall enforcement). Some images (e.g. Laravel Sail) default to it — override `runAsUser` to another UID in 1-65534 (0/root is rejected).
- **Reserved container names** — cannot be `istio-proxy`, `queue-proxy`, `istio-validation` (or other reserved names), and cannot start with `cpln-` or `debugger-`.
- **Reserved env vars** — names starting `CPLN_` are reserved, and `K_SERVICE` / `K_CONFIGURATION` / `K_REVISION` cannot be set; each value caps at 4096 characters.
- **Suspended workload** — `spec.defaultOptions.suspend: true` stops the workload (equivalent to min/max scale 0). Clear it with `update_workload` or `cpln workload start WORKLOAD --gvc GVC`.

### H. Autoscaling misconfiguration

**Symptoms:** won't scale, 502s during scale-up, scale-to-zero not working, or an invalid-strategy error on create.

Valid strategies: `concurrency`, `cpu`, `memory`, `rps`, `latency`, `keda`, `disabled`. Restrictions by type:

- **Serverless** cannot use `latency` or any multi-metric strategy.
- **Standard** cannot use `concurrency`.
- **Stateful** has no concurrency-based horizontal autoscaling.
- **Cron** does not autoscale at all (the autoscaling block is removed; each run completes and exits).

**Scale-to-zero:** serverless with `rps` or `concurrency`; standard and stateful only with `metric: keda`; cron cannot. For 502s during scale-up, fix the readiness probe (see E). The **autoscaling-capacity** skill owns the details.

### I. Termination and graceful shutdown

**Symptoms:** requests fail during deploys or scale-down, 502/503 during rollout, containers killed abruptly.

- **Missing `sleep` binary** — if `sleep` is absent from **any** container of the workload, **all** containers get SIGKILL immediately on termination (no graceful drain). Many distroless/minimal images lack it. Confirm with a read-only `which sleep` via `workload_exec`; fix by including `sleep` or adding a custom `preStop` hook.
- **preStop hook error** — if a custom `preStop` hook fails in any container, all containers get SIGKILL immediately.
- **App ignores SIGTERM** — after the preStop hook (default `sleep 45`) the container gets SIGTERM, then SIGKILL once `terminationGracePeriodSeconds` (default 90) elapses. Handle SIGTERM, and raise `terminationGracePeriodSeconds` (up to 900s; beyond that needs the `cpln/relaxGracePeriodMax` tag) if shutdown needs longer.

### J. Volume mount failures

**Symptoms:** container can't read mounted files, permission denied, or a cloud volume is empty.

- **Secret volumes** need the same identity + `reveal` policy chain as Section B.
- **Cloud storage volumes** (S3, GCS, Azure Blob/Files) need an identity linked to the workload, a cloud-access policy on it, and outbound firewall to the provider hosts (`*.amazonaws.com`, `*.googleapis.com`, `*.blob.core.windows.net` / `*.file.core.windows.net` plus `*.azure.com`). Auth is identity-only — embedding keys in the container does not work. They are **read-only except Azure Files**.
- **Reserved mount paths** (cannot be used): `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`. Max 15 volumes per workload; no path may be a parent of another.
- `filesystemGroupId` defaults to 0 (root) when unset — set `spec.securityOptions.filesystemGroupId` (1-65534) if the app runs as a non-root user. The **stateful-storage** skill owns volumesets.

### K. Service-to-service communication

**Symptoms:** a workload can't reach another workload internally (connection refused or timeout).

- **Target's internal firewall** must allow the caller — `same-gvc`, `same-org`, or `workload-list` (default `none` blocks everything). Listing a workload requires `view` permission on it.
- **Endpoint** — `http://WORKLOAD.GVC.cpln.local:PORT`. Use `http://`, not `https://` — the sidecar adds mTLS. If the port is omitted it defaults to the target's first container port; only ports in the containers array are reachable internally.
- **Cross-GVC** — the target must allow `same-org` or list the caller; cross-GVC traffic may span locations and incur egress charges.

### L. Dedicated load balancer and domain

**Symptoms:** unreachable after enabling a dedicated LB, TCP traffic broken, or wrong Host header.

- **TCP** needs a dedicated LB on the GVC plus a custom Domain with a TCP port — it does not work on default endpoints (which serve HTTP/HTTP2/gRPC only).
- **Enabling/disabling a dedicated LB** causes brief connectivity loss while DNS propagates, and adds per-location charges.
- **Serverless Host header** — a custom domain routing to a serverless workload delivers the canonical endpoint as `Host` (the custom domain moves to `X-Forwarded-Host`); standard and stateful workloads receive the custom domain as `Host`.
- **Protocol compatibility** — the domain port protocol must match the container's: HTTP2 fronts HTTP2 or gRPC, HTTP fronts HTTP.

The **domain** and **ipset-load-balancing** skills own routing, TLS, and dedicated LBs.

## Step 3 — Present the diagnosis and apply the fix

For each issue, give: **what's wrong** (the exact error, with evidence from events/logs/status), **why** (the root cause from the catalog), and **the fix** (the precise tool call or config change).

Apply only after the user approves — MCP-first:

| Action | Tool |
|---|---|
| Change the workload spec | `mcp__cpln__update_workload` |
| Set up secret access (one-shot) | `mcp__cpln__workload_reveal_secret` |
| Create a pull or other secret | `mcp__cpln__create_secret_<type>` |
| Attach a pull secret to the GVC | `mcp__cpln__update_gvc` |
| Author a manifest-level change | `mcp__cpln__get_resource_schema`, then `cpln apply -f workload.yaml --gvc GVC` |

After applying, poll `mcp__cpln__list_deployments` until the workload is ready across its locations, then report the canonical endpoint it returns.

## When to stop and ask

- The `org` or `gvc` is not named, or a resource is not found — ask; never guess or retry name variants.
- The fix is destructive (delete or overwrite) or targets production — present the impact and get explicit approval first.
- A fix needs `workload_exec` to mutate state in a live replica — confirm before running.
- The MCP server is unavailable and no `CPLN_TOKEN` is set for the CLI fallback.
