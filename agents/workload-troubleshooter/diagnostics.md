# Workload Troubleshooter — Per-Category Diagnostic Recipes

Companion to `agents/workload-troubleshooter.md`. Read this when you've narrowed the diagnosis to one of categories A–L. Each section gives symptoms, what to check, and the fix.

## A. Image Pull Failures

**Symptoms**: Events show `ImagePullBackOff`, `ErrImagePull`, or deployment stuck.

Check:

- **Image reference format** — Use `//image/IMAGE_NAME:TAG` for org private registry images. Use just `IMAGE:TAG` for Docker Hub public images (no `docker.io/` prefix). Use full registry URL for other external registries.
- **Architecture** — Images must be `linux/amd64` for Control Plane managed locations. BYOK locations support additional platforms.
- **Private registry access** — If pulling from a private external registry (Docker Hub private, ECR, GCR, ACR, GHCR), a pull secret must be created and added to the GVC's `pullSecretLinks`. Only Docker, ECR, and GCP secret types work as pull secrets.
- **Org registry** — Images from your own org's private registry (`//image/...`) do NOT need pull secrets.

Fix: If pull secret is missing:

```bash
# Create a Docker pull secret
cpln secret create-docker --name my-pull-secret --file /path/to/auths.json

# Add it to the GVC
cpln gvc update MY_GVC --set spec.pullSecretLinks+=my-pull-secret
```

## B. Secret Access Failures

**Symptoms**: Container starts but env vars are empty, workload logs show missing config, or events reference secret access errors.

The 3-step rule is defined in **rules/cpln-guardrails.md → Secret Access**. All three steps must be in place for a workload to access a secret at runtime — check each:

1. **Identity exists and is linked to workload** — Check `spec.identityLink` in workload spec.
2. **Policy exists granting identity `reveal` permission on the secret** — A policy with `targetKind: secret` targeting the specific secret, with a binding granting `reveal` to the identity.
3. **Secret reference uses correct format** — Format varies by secret type (see below).

**Secret reference formats by type:**

| Secret Type | Format | Example |
|:---|:---|:---|
| Opaque (decoded) | `cpln://secret/NAME.payload` | `cpln://secret/my-api-key.payload` |
| Opaque (raw JSON) | `cpln://secret/NAME` | `cpln://secret/my-api-key` |
| Dictionary | `cpln://secret/NAME.KEY` | `cpln://secret/app-config.DATABASE_URL` |
| Username & Password | `cpln://secret/NAME.username` / `.password` | `cpln://secret/db-creds.password` |
| Keypair | `cpln://secret/NAME.secretKey` / `.publicKey` / `.passphrase` | `cpln://secret/my-keys.secretKey` |
| TLS | `cpln://secret/NAME.key` / `.cert` / `.chain` | `cpln://secret/my-tls.cert` |
| AWS | `cpln://secret/NAME.accessKey` / `.secretKey` / `.roleArn` / `.externalId` | `cpln://secret/aws-creds.accessKey` |

**Fastest fix — use `mcp__cpln__workload_reveal_secret`:**

This composite MCP tool automates the entire identity + policy + workload update chain. It will:
- Check if the workload already has an identity (reuses it if so).
- Create an identity if missing.
- Create or update a policy granting `reveal` on the target secret.
- Link the identity to the workload.

Parameters: `gvc` (required), `workloadName` (required), `secretName` (required), `identityName` (optional), `policyName` (optional), `org` (uses session context if set, required otherwise).

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

**Or use `mcp__cpln__create_policy`** — creates the policy with bindings in one call. Params: `name` (required), `targetKind` (required), `targetLinks` (optional), `addPermissions` (optional array of permission strings), `addIdentities` (optional array of identity links), `org` (uses session context if set, required otherwise).

**If `cpln apply` fails on a policy manifest with a validation error and the YAML looks correct:** check that `targetKind` is a valid resource kind, all `principalLinks` use full resource paths (`//gvc/GVC/identity/NAME`), and `permissions` values are valid for the target kind. The API auto-sorts permissions alphabetically — ordering is not a cause of validation errors.

## C. Port Mismatch

**Symptoms**: Workload shows healthy but returns 502/503, or traffic doesn't reach the container.

Rules by workload type:

| Type | Port Rules |
|:---|:---|
| Serverless | MUST expose exactly 1 port. Protocol: http, http2, or grpc (not tcp). |
| Standard | May expose 0 or multiple ports. |
| Stateful | May expose 0 or multiple ports. |
| Cron | MUST NOT expose any ports. |

Check:

- The port in the workload spec MUST match the port the container actually listens on.
- The `PORT` environment variable is injected at runtime. If you set a custom PORT env var on an exposed container, its value MUST match the exposed port number.
- Default protocol is `http` when using `ports`, `http2` when using deprecated `port` field.
- TCP protocol requires a [Dedicated Load Balancer](https://docs.controlplane.com/reference/gvc.md) on the GVC and a custom Domain with TCP port configured — TCP does NOT work on default endpoints.

**Blocked ports** — these ports cannot be bound by containers:

`8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000`

## D. Firewall Blocking Traffic

**Symptoms**: Workload is running but can't be reached externally, can't reach external APIs, or can't communicate with other workloads.

All firewall rules are deny-by-default:

| Firewall | Default | Effect |
|:---|:---|:---|
| External inbound | Disabled | No internet traffic can reach the workload |
| External outbound | Disabled | Workload can't call external APIs/services |
| Internal | `none` | Workloads can't communicate with each other |

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

## E. Health Check Failures

**Symptoms**: Events show probe failures, workload marked unready, replicas restarting.

Default behavior by type:

| Type | Default Probes |
|:---|:---|
| Serverless | Readiness + liveness default to TCP check on container port |
| Standard | Probes disabled by default |
| Stateful | Probes disabled by default |
| Cron | Probes disabled by default |

Probe types available: **HTTP**, **TCP**, **gRPC**, **Command** (exec).

Common issues:

- Container takes too long to start — increase `initialDelaySeconds` (0-120, default 0).
- Probe too aggressive — increase `periodSeconds` (1-60, default 10) or `timeoutSeconds` (1-60, default 1).
- Wrong probe path — for HTTP probes, verify the path returns 200-399.
- Probe port — must be between 80 and 65535; blocked ports (8012, 8022, etc.) are invalid for TCP probes.
- `failureThreshold` (1-20, default 3) — how many failures before giving up.
- `successThreshold` (1-20, default 1) — consecutive successes needed after failure.

**Readiness probe failure** removes the replica from the load balancer pool and pauses rollout.
**Liveness probe failure** restarts the container.

**Probe + autoscaling interaction**: If a workload uses autoscaling but has no readiness probe (or only a TCP check), new replicas receive traffic immediately — before the app is ready. This causes 502 errors during scale-up. Always configure an HTTP readiness probe for autoscaled workloads that checks actual application health.

## F. Resource Limits

**Symptoms**: Workload not scheduling, OOMKilled, throttled performance, or Capacity AI not working.

Check:

- CPU and memory are within org quota.
- `maxScale` * resources does not exceed quota.
- Capacity AI minimum: 25 millicores CPU (increases with memory at 1:3 ratio of CPU millicores to memory MiB).

Capacity AI restrictions:

| Restriction | Reason |
|:---|:---|
| Not available with CPU Utilization autoscaling | Dynamic CPU conflicts with CPU-based scaling |
| Not available with multi-metric autoscaling | Multi-metric requires stable resource baselines |
| Not supported for Stateful workloads | Stateful needs predictable allocation (use `minCpu`/`minMemory` instead) |
| Not available with GPU workloads | GPU requires fixed resource allocation |

Stateful workload resource constraints:
- `minCpu` and `cpu` can be at most 4000m apart; ratio must be at least 1:4.
- `minMemory` and `memory` can be at most 4096Mi apart; ratio must be at least 1:4.

Ephemeral storage: each replica gets 1GB per CPU core (minimum 1GB). Exceeding it replaces the replica.

## G. Container Restrictions

**Symptoms**: Container won't start, communication disabled, or unexpected errors.

Check:

- **UserID 1337 is restricted** — if the container runs as UID 1337, all inbound and outbound communication is disabled. Laravel Sail uses this by default.
- **Container name restrictions** — cannot be `istio-proxy`, `queue-proxy`, or `istio-validation`. Cannot start with `cpln_`.
- **Disallowed env var names** — `K_SERVICE`, `K_CONFIGURATION`, `K_REVISION` are reserved and cannot be set.
- **Env var value limit** — max 4096 characters per value.
- **Deprecated `port` field** — prefer the `ports` array. If the deprecated single-port field is used, the default protocol is `http2`.
- **Workload is suspended** — check `spec.defaultOptions.suspend`. If `true`, the workload is stopped (equivalent to min/max scale 0).

```bash
# Unsuspend a workload
cpln workload start WORKLOAD_NAME --gvc GVC_NAME
```

## H. Autoscaling Misconfiguration

**Symptoms**: Workload won't scale, 502s during scale-up, scale-to-zero doesn't work, or error creating workload with invalid autoscaling combo.

Documented strategy restrictions (see [Autoscaling](https://docs.controlplane.com/reference/workload/autoscaling.md)):

- **Serverless** cannot use the `latency` strategy or any Multi-metric strategy.
- **Standard** cannot use the `concurrency` strategy.
- **Stateful** does not support concurrency-based horizontal autoscaling.
- **Cron** does not autoscale (scheduled jobs run to completion).

Valid strategies (schema): `concurrency`, `cpu`, `memory`, `rps`, `latency`, `keda`, `disabled`.

Scale to zero: only serverless workloads can scale to zero, and only with the `rps` or `concurrency` strategies. All other types must have `minScale` >= 1.

**502s during scale-up**: When new replicas are added, traffic is sent to them as soon as they pass the readiness probe (or immediately if no probe / TCP-only probe). If the app isn't actually ready to serve, users see errors. Fix: configure a proper HTTP readiness probe that checks application health, not just TCP port open.

## I. Termination / Graceful Shutdown Failures

**Symptoms**: Requests fail during deployments or scale-down, 502/503 errors during rollout, containers killed abruptly.

Common causes:

- **Missing `sleep` binary** — If the `sleep` executable is not available in ANY container of the workload, ALL containers receive SIGKILL immediately on termination. Requests may still route to the dying replica before the load balancer updates. Fix: ensure your container image includes `sleep` (most minimal/distroless images don't), or add a custom `preStop` hook.
- **Custom preStop hook error** — If a custom `preStop` hook throws an error in ANY container, ALL containers receive SIGKILL immediately. Fix: ensure the hook command exists and succeeds.
- **App ignores SIGINT/SIGTERM** — After the preStop hook completes (default: `sleep 45`), the container receives SIGINT. If the app doesn't handle it, it gets SIGKILL after `terminationGracePeriodSeconds` (default: 90s). Fix: handle SIGINT/SIGTERM in your app.
- **`terminationGracePeriodSeconds` too low** — The total budget for preStop + graceful shutdown. Default is 90s. The default preStop hook sleeps for half of this (45s). If your app needs more time, increase it.

## J. Volume Mount Failures

**Symptoms**: Container can't read mounted files, permission denied on volume, or cloud storage volume empty.

Check:

- **Secret volumes** require the same identity + policy chain as env vars (identity linked to workload, policy with `reveal` permission on the secret).
- **Cloud storage volumes** (S3, GCS, Azure Blob/Files) require:
  1. Identity linked to workload.
  2. Cloud access policy on the identity for the provider (e.g., `AmazonS3ReadOnlyAccess` for S3).
  3. Outbound firewall allowing the provider hostnames (`*.amazonaws.com` for S3, `*.googleapis.com` for GCS, `*.blob.core.windows.net` for Azure Blob, `*.file.core.windows.net` for Azure Files).
- **Reserved paths** — these cannot be used as mount paths: `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`.
- **Max 15 volumes** per workload.
- Cloud storage volumes are **read-only** (except Azure Files).
- `filesystemGroupId` defaults to 0 (root) — set `spec.securityOptions.filesystemGroupId` if your app runs as a non-root user.

## K. Service-to-Service Communication Failures

**Symptoms**: Workload can't reach another workload internally, connection refused or timeout on internal calls.

Check:

1. **Target workload internal firewall** — must be set to `same-gvc`, `same-org`, or `workload-list` (default is `none` = no access).
2. **Endpoint format** — must use `http://WORKLOAD_NAME.GVC_NAME.cpln.local:PORT` (use `http://`, NOT `https://` — the sidecar handles mTLS automatically).
3. **Port** — if omitted, defaults to the first port in the target workload's container array. Only ports listed in the workload containers array are accessible internally.
4. **Cross-GVC calls** — the target must allow `same-org` or list the caller in `workload-list`. Cross-GVC traffic may span locations and incurs egress charges.

## L. Dedicated Load Balancer and Domain Issues

**Symptoms**: Workload becomes unreachable after enabling dedicated LB, TCP traffic doesn't work, wrong Host header.

Check:

- **Enabling/disabling dedicated LB causes brief connectivity loss** — DNS propagation takes time. Additional charges apply per location.
- **TCP protocol requires dedicated LB** — Standard endpoints only support HTTP/HTTP2/gRPC. For TCP: enable dedicated LB on the GVC, create a Domain with a custom TCP port, then configure the domain route.
- **Serverless Host header** — When a custom domain routes to a serverless workload, the `Host` header is the canonical endpoint, NOT the custom domain. The original domain is in the `X-Forwarded-Host` header. Standard and stateful workloads receive the custom domain as the `Host` header.
- **Domain port protocol compatibility** — The domain port protocol must match the container port protocol (HTTP2 is compatible with HTTP2 and gRPC, HTTP is compatible with HTTP).
