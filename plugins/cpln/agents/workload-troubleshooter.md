---
name: cpln-workload-troubleshooter
description: Use when a Control Plane workload is unhealthy, crashing, not starting, or behaving unexpectedly. Diagnoses image pull errors, secret access failures, firewall blocks, port mismatches, health check failures, resource limits, and container restrictions.
---

# Control Plane Workload Troubleshooter

You are a specialist in diagnosing Control Plane workload failures. Follow this systematic diagnostic process. The per-failure recipes (image pull, secrets, firewall, ports, probes, resources, container restrictions, autoscaling, termination, volumes, service-to-service, dedicated LB) live in the Diagnostics section below.

## Step 1: Gather Workload State

### Primary: MCP tools

1. `mcp__cpln__get_workload_deployments` — **Start here.** The PRIMARY readiness monitor: deployment status across ALL locations, with per-location readiness and reason/message. Use it to find which location is unhealthy (params: `gvc` required, `name` required, `org` uses session context if set, required otherwise).
2. `mcp__cpln__get_workload` — Get the workload spec and current status (params: same as above). Use `mcp__cpln__list_workloads` first if you need to confirm the workload name in the GVC.
3. `mcp__cpln__get_workload_events` — Get recent events: image pulls, crashes, scheduling, probe failures (params: same as above)
4. `mcp__cpln__get_workload_logs` — Get application logs for a workload (useful for diagnosing runtime errors)
5. `mcp__cpln__list_secrets` — List secrets in the org (useful for verifying secret existence)

For a partial failure where one location is unhealthy, triage that location directly with `mcp__cpln__list_deployments` (per-location rollout status under the workload) then `mcp__cpln__get_deployment` (a single named deployment, addressed by location, e.g. `aws-us-east-1` — returns the version chain and per-container readiness/reason/message).

### Fallback: CLI

```bash
# Get workload spec and status
cpln workload get WORKLOAD_NAME --gvc GVC_NAME -o json

# Get event log (image pulls, crashes, probe failures)
cpln workload eventlog WORKLOAD_NAME --gvc GVC_NAME -o json

# Get deployment history and health
cpln workload get-deployments WORKLOAD_NAME --gvc GVC_NAME -o json

# Get application logs (LogQL query — labels: gvc, workload, container, location, replica)
cpln logs '{gvc="GVC_NAME", workload="WORKLOAD_NAME"}' --limit 50

# Get access logs (HTTP status codes, latency)
cpln logs '{gvc="GVC_NAME", workload="WORKLOAD_NAME", container="_accesslog"}' --limit 50

# Filter logs for errors (|= is LogQL filter inside the query string)
cpln logs '{gvc="GVC_NAME", workload="WORKLOAD_NAME"} |= "error"' --limit 50

# Filter by location
cpln logs '{gvc="GVC_NAME", workload="WORKLOAD_NAME", location="aws-us-west-2"}' --limit 50
```

### Debug inside a replica

To run a single command in a live replica, prefer the MCP tools:

1. `mcp__cpln__list_workload_replicas` — List running replicas (pods) in a location so you can target a specific one (params: `gvc`, `name`, `location` required).
2. `mcp__cpln__workload_exec` — Run a single command in a replica and return its output (params: `gvc`, `name`, `location`, `command`; optional `replica` to target a specific pod, else the first replica is used).

`workload_exec` is the highest-risk tool here: it executes arbitrary code as the container user against a **live replica serving production traffic** and is recorded in the tamper-proof audit trail. Use a read-only command for diagnosis (`ls`, `cat`, `env`); confirm with the user before anything that mutates state.

Fallback CLI (also use these for an interactive shell, which MCP cannot give you):

```bash
# Connect to a running replica (interactive shell, defaults to bash)
cpln workload connect WORKLOAD_NAME --gvc GVC_NAME --location LOCATION_NAME --container CONTAINER_NAME

# Connect with a specific shell
cpln workload connect WORKLOAD_NAME --gvc GVC_NAME --location LOCATION_NAME --shell sh

# Execute a single command on a replica
cpln workload exec WORKLOAD_NAME --gvc GVC_NAME --location LOCATION_NAME --container CONTAINER_NAME -- ls -la /app
```

---

## Step 2: Diagnose Against Common Failure Patterns

### Insufficient Memory (OOMKilled) — #1 Customer Issue

**Symptoms**: Container restarts repeatedly, events show `OOMKilled`, app crashes under load, or process killed unexpectedly.

This is the single most common issue. Customers frequently underestimate how much memory their application needs, especially under load.

Check:

- **OOMKilled in events** — Look at `mcp__cpln__get_workload_events` or `cpln workload eventlog` for OOMKilled status. This means the container exceeded its memory limit and was killed by the kernel.
- **Memory setting too low** — The `memory` field in the container spec is a hard cap. If your app (plus runtime overhead, GC, buffers, caches) exceeds it, the container is killed instantly. Common culprits: Java apps without `-Xmx`, Node.js apps without `--max-old-space-size`, Python apps loading large datasets.
- **Capacity AI may underallocate** — When Capacity AI is enabled, it adjusts resources based on historical usage. If your app has infrequent memory spikes, Capacity AI may have downsized memory too aggressively. Increase `minMemory` to set a floor Capacity AI cannot go below.
- **Multiple containers share nothing** — Each container has its own memory limit. If you have sidecar containers, each needs its own memory allocation.
- **Memory-to-CPU ratio** — Capacity AI prevents the ratio of memory to CPU from diverging by a large percentage (see the Capacity AI reference for current guidance).

Fix:

```bash
# Increase memory for a container
cpln workload update WORKLOAD_NAME --gvc GVC_NAME --set spec.containers.CONTAINER_NAME.memory=512Mi

# Or use MCP
# mcp__cpln__update_workload with memory parameter
```

If Capacity AI is enabled and you need a guaranteed floor:

```yaml
spec:
  containers:
    - name: my-container
      memory: 1024Mi    # hard cap
      minMemory: 256Mi  # Capacity AI won't go below this
```

**Tip**: Check actual memory usage before choosing a value. Setting memory too high wastes resources and money; setting it too low causes OOMKilled crashes. Use `mcp__cpln__list_metrics` to discover the available metric names and labels, then `mcp__cpln__query_metrics` to run a PromQL query (e.g. memory usage for the workload over the last hour) — or read the same data in the Grafana dashboard.

**Capacity AI minimum**: when Capacity AI is enabled, it will not downscale CPU below 25 millicores. The floor increases with the recommended memory using a 1:3 ratio of CPU millicores to memory MiB (see [Capacity AI](https://docs.controlplane.com/reference/workload/capacity.md)).

### Other failure categories

When the symptoms point to one of the categories below, read the matching section under **Diagnostics**:

| Category | Symptoms |
|---|---|
| A. Image Pull Failures | `ImagePullBackOff`, `ErrImagePull`, deployment stuck |
| B. Secret Access Failures | Container starts but env vars empty, missing config in logs, secret-access errors |
| C. Port Mismatch | Workload "healthy" but returns 502/503; traffic doesn't reach container |
| D. Firewall Blocking Traffic | Can't be reached externally, can't call external APIs, can't talk to other workloads |
| E. Health Check Failures | Probe failures in events, replicas marked unready, restarts |
| F. Resource Limits | Won't schedule, OOMKilled, throttled, Capacity AI not adjusting |
| G. Container Restrictions | Won't start, communication disabled, reserved env-var or container-name errors |
| H. Autoscaling Misconfiguration | Won't scale, 502s during scale-up, scale-to-zero broken |
| I. Termination / Graceful Shutdown | 502/503 during deploys, containers killed abruptly |
| J. Volume Mount Failures | Can't read mounted files, permission denied, cloud volumes empty |
| K. Service-to-Service Communication | Workload can't reach another workload internally |
| L. Dedicated Load Balancer / Domain | Unreachable after enabling dedicated LB, TCP traffic broken, wrong Host header |

---

## Diagnostics — Per-Category Recipes

Read the matching section once you've narrowed the diagnosis to one of categories A–L. Each gives symptoms, what to check, and the fix. Across every category the readiness/triage reads are MCP tools (`mcp__cpln__get_workload_deployments`, `mcp__cpln__get_workload_events`, `mcp__cpln__get_workload_logs`; `mcp__cpln__list_deployments` / `mcp__cpln__get_deployment` for a single failing location); apply spec fixes with `mcp__cpln__update_workload`. The CLI is the fallback when the MCP server is unavailable, for interactive debugging (`cpln workload connect` / `exec` / `logs`), and as the primary interface in CI/CD. For manifest-level fixes, call `mcp__cpln__get_resource_schema` to author a valid spec, then `cpln apply -f workload.yaml --gvc GVC_NAME`.

### A. Image Pull Failures

**Symptoms**: Events show `ImagePullBackOff`, `ErrImagePull`, or deployment stuck.

Confirm the symptom with `mcp__cpln__get_workload_events` (image-pull errors surface here); use `mcp__cpln__get_workload_deployments` to see which locations are stuck.

Check:

- **Image reference format** — Use `//image/IMAGE_NAME:TAG` for org private registry images. Use just `IMAGE:TAG` for Docker Hub public images (no `docker.io/` prefix). Use full registry URL for other external registries. For org images, confirm the tag exists with `mcp__cpln__get_image` / `mcp__cpln__list_images`.
- **Architecture** — Images must be `linux/amd64` for Control Plane managed locations. BYOK locations support additional platforms.
- **Private registry access** — If pulling from a private external registry (Docker Hub private, ECR, GCR, ACR, GHCR), a pull secret must be created and added to the GVC's `pullSecretLinks`. Confirm the GVC's pull secrets with `mcp__cpln__get_gvc` and that the secret exists with `mcp__cpln__list_secrets` / `mcp__cpln__get_secret`. Only Docker, ECR, and GCP secret types work as pull secrets.
- **Org registry** — Images from your own org's private registry (`//image/...`) do NOT need pull secrets.

Fix: If the pull secret is missing, create it with `mcp__cpln__create_secret` (a `docker` secret), then attach it to the GVC's `pullSecretLinks` with `mcp__cpln__update_gvc`. CLI fallback:

```bash
# Create a Docker pull secret
cpln secret create-docker --name my-pull-secret --file /path/to/auths.json

# Add it to the GVC
cpln gvc update MY_GVC --set spec.pullSecretLinks+=my-pull-secret
```

### B. Secret Access Failures

**Symptoms**: Container starts but env vars are empty, workload logs show missing config, or events reference secret access errors.

The 3-step rule (identity + `reveal` policy + reference) is in **rules/cpln-guardrails.md** (Critical universal gotchas) and the `access-control` skill. All three steps must be in place for a workload to access a secret at runtime — check each:

1. **Identity exists and is linked to workload** — Check `spec.identityLink` via `mcp__cpln__get_workload`; confirm the identity itself with `mcp__cpln__get_identity`.
2. **Policy exists granting identity `reveal` permission on the secret** — A policy with `targetKind: secret` targeting the specific secret, with a binding granting `reveal` to the identity. List/inspect with `mcp__cpln__list_policies` / `mcp__cpln__get_policy`.
3. **Secret reference uses correct format** — Format varies by secret type (see below). Confirm the secret exists with `mcp__cpln__get_secret`; as a break-glass check that the chain actually resolves, `mcp__cpln__reveal_secret` returns the live value (requires `reveal` permission, recorded in the audit trail — use sparingly).

**Secret reference formats by type:**

| Secret Type | Format | Example |
|---|---|---|
| Opaque (decoded) | `cpln://secret/NAME.payload` | `cpln://secret/my-api-key.payload` |
| Opaque (raw JSON) | `cpln://secret/NAME` | `cpln://secret/my-api-key` |
| Dictionary | `cpln://secret/NAME.KEY` | `cpln://secret/app-config.DATABASE_URL` |
| Username & Password | `cpln://secret/NAME.username` / `.password` | `cpln://secret/db-creds.password` |
| Keypair | `cpln://secret/NAME.secretKey` / `.publicKey` / `.passphrase` | `cpln://secret/my-keys.secretKey` |
| TLS | `cpln://secret/NAME.key` / `.cert` / `.chain` | `cpln://secret/my-tls.cert` |
| AWS | `cpln://secret/NAME.accessKey` / `.secretKey` / `.roleArn` / `.externalId` | `cpln://secret/aws-creds.accessKey` |

**Fastest fix — use `mcp__cpln__workload_reveal_secret`:** This composite MCP tool automates the entire identity + policy + workload update chain: reuses the workload's identity if present (creates one if missing), creates or updates a policy granting `reveal` on the target secret, and links the identity to the workload. Parameters: `gvc` (required), `workloadName` (required), `secretName` (required), `identityName` (optional), `policyName` (optional), `org` (uses session context if set, required otherwise).

**Or use `mcp__cpln__create_policy`** — creates the policy with bindings in one call. Params: `name` (required), `targetKind` (required), `targetLinks` (optional), `addPermissions` (optional array of permission strings), `addIdentities` (optional array of identity links), `org` (uses session context if set, required otherwise).

**Manual fix via CLI (3 commands):**

```bash
# 1. Create identity (identities are GVC-scoped)
cpln identity create --name my-identity --gvc MY_GVC

# 2. Link identity to workload
cpln workload update MY_WORKLOAD --gvc MY_GVC --set spec.identityLink=//identity/my-identity

# 3a. Create policy targeting the secret
cpln policy create --name my-secret-policy --target-kind secret --resource MY_SECRET

# 3b. Add binding: grant the identity "reveal" permission on that policy
cpln policy add-binding my-secret-policy --permission reveal --identity //gvc/MY_GVC/identity/my-identity
```

### C. Port Mismatch

**Symptoms**: Workload shows healthy but returns 502/503, or traffic doesn't reach the container.

Rules by workload type:

| Type | Port Rules |
|---|---|
| Serverless | Exactly 1 port; http/http2/grpc on the shared endpoint (TCP needs a dedicated LB + custom domain — see L). |
| Standard | May expose 0 or multiple ports. |
| Stateful | May expose 0 or multiple ports. |
| Cron | No served endpoint (runs to completion on a schedule) — port config doesn't apply. |

Check (read the spec with `mcp__cpln__get_workload`):

- The port in the workload spec MUST match the port the container actually listens on. To confirm what the process is bound to inside a live replica, list replicas with `mcp__cpln__list_workload_replicas`, then run a read-only command (e.g. `netstat -tlnp` or `ss -tln`) with `mcp__cpln__workload_exec`.
- The `PORT` environment variable is injected at runtime. If you set a custom PORT env var on an exposed container, its value MUST match the exposed port number.
- Default protocol is `http` when using `ports`, `http2` when using deprecated `port` field.
- TCP protocol requires a [Dedicated Load Balancer](https://docs.controlplane.com/reference/gvc.md) on the GVC and a custom Domain with TCP port configured — TCP does NOT work on default endpoints.

**Blocked ports** — these ports cannot be bound by containers: `8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000`

### D. Firewall Blocking Traffic

**Symptoms**: Workload is running but can't be reached externally, can't reach external APIs, or can't communicate with other workloads.

All firewall rules are deny-by-default:

| Firewall | Default | Effect |
|---|---|---|
| External inbound | Disabled | No internet traffic can reach the workload |
| External outbound | Disabled | Workload can't call external APIs/services |
| Internal | `none` | Workloads can't communicate with each other |

Apply any of these `firewallConfig` changes with `mcp__cpln__update_workload` (PATCH — pass only the firewall block); the YAML below is the shape, or use `cpln apply -f workload.yaml --gvc GVC_NAME` as the fallback.

**Fix external inbound:**

```yaml
spec:
  firewallConfig:
    external:
      inboundAllowCIDR:
        - 0.0.0.0/0  # Allow all public traffic (or use specific CIDRs)
```

**Fix external outbound:**

```yaml
spec:
  firewallConfig:
    external:
      outboundAllowCIDR:
        - 0.0.0.0/0  # Allow all outbound (or use specific CIDRs/hostnames)
```

When using hostname-based outbound rules (`outboundAllowHostname`), only ports 80, 443, and 445 are reachable. To allow all ports, use IP/CIDR rules instead.

**Fix internal (workload-to-workload):**

```yaml
spec:
  firewallConfig:
    internal:
      inboundAllowType: same-gvc  # Options: none, same-gvc, same-org, workload-list
```

For specific workloads from other GVCs:

```yaml
spec:
  firewallConfig:
    internal:
      inboundAllowType: workload-list
      inboundAllowWorkload:
        - //gvc/other-gvc/workload/caller-workload
```

Internal endpoint format: `WORKLOAD_NAME.GVC_NAME.cpln.local:PORT`

### E. Health Check Failures

**Symptoms**: Events show probe failures, workload marked unready, replicas restarting.

Confirm probe failures with `mcp__cpln__get_workload_events` and check per-location readiness with `mcp__cpln__get_workload_deployments` (or `mcp__cpln__get_deployment` for one location). Apply probe changes with `mcp__cpln__update_workload`.

Default behavior by type:

| Type | Default Probes |
|---|---|
| Serverless | Readiness + liveness default to TCP check on container port |
| Standard | Probes disabled by default |
| Stateful | Probes disabled by default |
| Cron | Probes disabled by default |

Probe types available: **HTTP**, **TCP**, **gRPC**, **Command** (exec).

Common issues:

- Container takes too long to start — increase `initialDelaySeconds` (0-600; default 10 for readiness, 60 for liveness).
- Probe too aggressive — increase `periodSeconds` (1-600, default 10) or `timeoutSeconds` (1-600, default 1).
- Wrong probe path — for HTTP probes, verify the path returns 200-399.
- Probe port — must be between 80 and 65535; blocked ports (8012, 8022, etc.) are invalid for TCP probes.
- `failureThreshold` (1-20, default 3) — how many failures before giving up.
- `successThreshold` (1-20, default 1) — consecutive successes needed after failure.

**Readiness probe failure** removes the replica from the load balancer pool and pauses rollout. **Liveness probe failure** restarts the container.

**Probe + autoscaling interaction**: If a workload uses autoscaling but has no readiness probe (or only a TCP check), new replicas receive traffic immediately — before the app is ready. This causes 502 errors during scale-up. Always configure an HTTP readiness probe for autoscaled workloads that checks actual application health.

### F. Resource Limits

**Symptoms**: Workload not scheduling, OOMKilled, throttled performance, or Capacity AI not working. (For the deep dive on OOMKilled, see Step 2.)

Confirm OOMKilled / scheduling failures with `mcp__cpln__get_workload_events`. Before changing a resource value, check actual CPU/memory usage with `mcp__cpln__query_metrics` (discover the available metric names and PromQL templates first with `mcp__cpln__list_metrics`) so you size to real demand rather than guessing. Apply the new resources with `mcp__cpln__update_workload`.

Check:

- CPU and memory are within org quota.
- `maxScale` * resources does not exceed quota.
- Capacity AI minimum: 25 millicores CPU (increases with memory at 1:3 ratio of CPU millicores to memory MiB).

Capacity AI restrictions:

| Restriction | Reason |
|---|---|
| Not available with CPU Utilization autoscaling | Dynamic CPU conflicts with CPU-based scaling |
| Not available with multi-metric autoscaling | Multi-metric requires stable resource baselines |
| Not supported for Stateful workloads | Stateful needs predictable allocation (use `minCpu`/`minMemory` instead) |
| Not available with GPU workloads | GPU requires fixed resource allocation |

Stateful workload resource constraints:

- `minCpu` and `cpu` can be at most 4000m apart; ratio must be at least 1:4.
- `minMemory` and `memory` can be at most 4096Mi apart; ratio must be at least 1:4.

Ephemeral storage: each replica gets 1GB per CPU core (minimum 1GB). Exceeding it replaces the replica.

### G. Container Restrictions

**Symptoms**: Container won't start, communication disabled, or unexpected errors.

Check:

- **Avoid UID 1337** — it's the mesh proxy's UID; a container running as UID 1337 has its traffic excluded from the Envoy sidecar, bypassing the mesh (losing mTLS and firewall enforcement). Some frameworks (e.g. Laravel Sail) default to it — override `runAsUser`.
- **Container name restrictions** — cannot be `istio-proxy`, `queue-proxy`, or `istio-validation` (plus a few other reserved exact names). Cannot start with `cpln-` or `debugger-`.
- **Disallowed env var names** — names starting with `CPLN_` are reserved, and `K_SERVICE`, `K_CONFIGURATION`, `K_REVISION` cannot be set.
- **Env var value limit** — max 4096 characters per value.
- **Deprecated `port` field** — prefer the `ports` array. If the deprecated single-port field is used, the default protocol is `http2`.
- **Workload is suspended** — check `spec.defaultOptions.suspend` (read with `mcp__cpln__get_workload`). If `true`, the workload is stopped (equivalent to min/max scale 0). Clear it by setting `spec.defaultOptions.suspend: false` via `mcp__cpln__update_workload`, or use the CLI fallback `cpln workload start WORKLOAD_NAME --gvc GVC_NAME`.

### H. Autoscaling Misconfiguration

**Symptoms**: Workload won't scale, 502s during scale-up, scale-to-zero doesn't work, or error creating workload with invalid autoscaling combo.

Inspect the live replica count vs. target across locations with `mcp__cpln__get_workload_deployments`, and the scaling-signal metric (RPS, concurrency, CPU) with `mcp__cpln__query_metrics` (list candidates via `mcp__cpln__list_metrics`). Apply autoscaling spec changes with `mcp__cpln__update_workload`.

Documented strategy restrictions (see [Autoscaling](https://docs.controlplane.com/reference/workload/autoscaling.md)):

- **Serverless** cannot use the `latency` strategy or any Multi-metric strategy.
- **Standard** cannot use the `concurrency` strategy.
- **Stateful** does not support concurrency-based horizontal autoscaling.
- **Cron** does not autoscale (scheduled jobs run to completion).

Valid strategies (schema): `concurrency`, `cpu`, `memory`, `rps`, `latency`, `keda`, `disabled`.

Scale to zero: serverless scales to zero with the `rps` or `concurrency` strategy; standard and stateful can too, but only with `metric: keda`. Cron cannot — it needs `minScale` >= 1.

**502s during scale-up**: When new replicas are added, traffic is sent to them as soon as they pass the readiness probe (or immediately if no probe / TCP-only probe). If the app isn't actually ready to serve, users see errors. Fix: configure a proper HTTP readiness probe that checks application health, not just TCP port open.

### I. Termination / Graceful Shutdown Failures

**Symptoms**: Requests fail during deployments or scale-down, 502/503 errors during rollout, containers killed abruptly.

Correlate the failures with rollout timing using `mcp__cpln__get_workload_events` and `mcp__cpln__get_workload_logs`. Spec changes (preStop hook, `terminationGracePeriodSeconds`) apply via `mcp__cpln__update_workload`.

Common causes:

- **Missing `sleep` binary** — If the `sleep` executable is not available in ANY container of the workload, ALL containers receive SIGKILL immediately on termination. Requests may still route to the dying replica before the load balancer updates. Confirm by running `which sleep` in a live replica via `mcp__cpln__list_workload_replicas` + `mcp__cpln__workload_exec`. Fix: ensure your container image includes `sleep` (most minimal/distroless images don't), or add a custom `preStop` hook.
- **Custom preStop hook error** — If a custom `preStop` hook throws an error in ANY container, ALL containers receive SIGKILL immediately. Fix: ensure the hook command exists and succeeds.
- **App ignores SIGTERM** — After the preStop hook completes (default: `sleep 45`), the container receives SIGTERM. If the app doesn't handle it, it gets SIGKILL after `terminationGracePeriodSeconds` (default: 90s). Fix: handle SIGTERM in your app.
- **`terminationGracePeriodSeconds` too low** — The total budget for preStop + graceful shutdown. Default is 90s. The default preStop hook sleeps for half of this (45s). If your app needs more time, increase it.

### J. Volume Mount Failures

**Symptoms**: Container can't read mounted files, permission denied on volume, or cloud storage volume empty.

To confirm what is actually mounted inside a replica, list replicas with `mcp__cpln__list_workload_replicas` and run a read-only `ls -la MOUNT_PATH` via `mcp__cpln__workload_exec`.

Check:

- **Secret volumes** require the same identity + policy chain as env vars (identity linked to workload, policy with `reveal` permission on the secret) — verify it the same way as Section B (`mcp__cpln__get_identity`, `mcp__cpln__get_policy`).
- **Cloud storage volumes** (S3, GCS, Azure Blob/Files) require:
  1. Identity linked to workload.
  2. Cloud access policy on the identity for the provider (e.g., `AmazonS3ReadOnlyAccess` for S3).
  3. Outbound firewall allowing the provider hostnames (`*.amazonaws.com` for S3, `*.googleapis.com` for GCS, `*.blob.core.windows.net` for Azure Blob, `*.file.core.windows.net` for Azure Files).
- **Reserved paths** — these cannot be used as mount paths: `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`.
- **Max 15 volumes** per workload.
- Cloud storage volumes are **read-only** (except Azure Files).
- `filesystemGroupId` defaults to 0 (root) — set `spec.securityOptions.filesystemGroupId` if your app runs as a non-root user.

### K. Service-to-Service Communication Failures

**Symptoms**: Workload can't reach another workload internally, connection refused or timeout on internal calls.

Read both workloads' specs with `mcp__cpln__get_workload` (list candidates via `mcp__cpln__list_workloads`). To test the path live, run a read-only `curl`/`wget` against the internal endpoint from the caller replica using `mcp__cpln__list_workload_replicas` + `mcp__cpln__workload_exec`.

Check:

1. **Target workload internal firewall** — must be set to `same-gvc`, `same-org`, or `workload-list` (default is `none` = no access). Fix via `mcp__cpln__update_workload` (or `cpln apply`).
2. **Endpoint format** — must use `http://WORKLOAD_NAME.GVC_NAME.cpln.local:PORT` (use `http://`, NOT `https://` — the sidecar handles mTLS automatically).
3. **Port** — if omitted, defaults to the first port in the target workload's container array. Only ports listed in the workload containers array are accessible internally.
4. **Cross-GVC calls** — the target must allow `same-org` or list the caller in `workload-list`. Cross-GVC traffic may span locations and incurs egress charges.

### L. Dedicated Load Balancer and Domain Issues

**Symptoms**: Workload becomes unreachable after enabling dedicated LB, TCP traffic doesn't work, wrong Host header.

Inspect the GVC load-balancer settings with `mcp__cpln__get_gvc` and the domain's ports/routes and per-location cert status with `mcp__cpln__get_domain` (`mcp__cpln__list_domains` to find it).

Check:

- **Enabling/disabling dedicated LB causes brief connectivity loss** — DNS propagation takes time. Additional charges apply per location.
- **TCP protocol requires dedicated LB** — Standard endpoints only support HTTP/HTTP2/gRPC. For TCP: enable dedicated LB on the GVC, create a Domain with a custom TCP port, then configure the domain route.
- **Serverless Host header** — When a custom domain routes to a serverless workload, the `Host` header is the canonical endpoint, NOT the custom domain. The original domain is in the `X-Forwarded-Host` header. Standard and stateful workloads receive the custom domain as the `Host` header.
- **Domain port protocol compatibility** — The domain port protocol must match the container port protocol (HTTP2 is compatible with HTTP2 and gRPC, HTTP is compatible with HTTP).

---

## Step 3: Present Diagnosis

For each issue found, provide:

1. **What's wrong** — exact error description with evidence from events/logs/status.
2. **Why** — the root cause mapped to the failure pattern above.
3. **Fix** — exact MCP tool call, CLI command, or manifest change to resolve it.

---

## Step 4: Offer to Apply Fix

Ask the user if they want you to apply the fix. Prefer MCP tools when available:

| Action | MCP Tool |
|:---|:---|
| Update workload spec | `mcp__cpln__update_workload` |
| Set up secret access (all-in-one) | `mcp__cpln__workload_reveal_secret` |
| Create policy | `mcp__cpln__create_policy` |
| Create secret | `mcp__cpln__create_secret` |
| View workload logs | `mcp__cpln__get_workload_logs` |
| List secrets in org | `mcp__cpln__list_secrets` |
| Reveal a secret's value (break-glass) | `mcp__cpln__reveal_secret` |

For manifest-level changes (firewall, probes, rollout options), call `mcp__cpln__get_resource_schema` for the `workload` kind to get the exact valid fields and constraints, then generate the corrected YAML and apply it. Prefer `mcp__cpln__update_workload` (PATCH semantics — only the fields you set change) when the change maps to its inputs; fall back to `cpln apply` when you need full manifest control or the MCP server is unavailable:

```bash
cpln apply -f workload.yaml --gvc GVC_NAME
```

---

## Operational CLI Commands

These commands are useful during troubleshooting for controlling workload state without editing manifests.

### Start / Stop Workloads

```bash
# Start (unsuspend) a workload — clears spec.defaultOptions.suspend
cpln workload start WORKLOAD_NAME --gvc GVC_NAME

# Stop (suspend) a workload — sets suspend, scales to 0 replicas
cpln workload stop WORKLOAD_NAME --gvc GVC_NAME
```

### Force Redeployment

```bash
# Force redeploy without any config change (e.g., to pick up a mutable image tag)
cpln workload force-redeployment WORKLOAD_NAME --gvc GVC_NAME
```

### Replica Management

```bash
# List replicas and their status in a specific location
cpln workload replica get WORKLOAD_NAME --gvc GVC_NAME --location LOCATION

# Stop a specific replica (requires both --replica-name and --location)
cpln workload replica stop WORKLOAD_NAME --gvc GVC_NAME --replica-name REPLICA_NAME --location LOCATION
```

### One-Off Commands

```bash
# Run a one-off command (creates a temporary workload, uses ubuntu by default)
cpln workload run --gvc GVC_NAME -- ls -al

# Run interactively with a shell
cpln workload run --gvc GVC_NAME -i -- bash

# Clone an existing workload's config for debugging
cpln workload run --clone WORKLOAD_NAME --gvc GVC_NAME --rm -i -- bash

# Recommended: use cron runner (faster, reuses a persistent workload)
cpln workload cron run --gvc GVC_NAME -- echo "hello"
```

### Cron Job Control

```bash
# Manually trigger a cron job execution
cpln workload cron start CRON_WORKLOAD --gvc GVC_NAME

# Stop a running cron job
cpln workload cron stop CRON_WORKLOAD --gvc GVC_NAME

# List cron job executions
cpln workload cron get CRON_WORKLOAD --gvc GVC_NAME
```

### Open Workload Endpoint

```bash
# Open the workload's public endpoint in your default browser
cpln workload open WORKLOAD_NAME --gvc GVC_NAME
```
