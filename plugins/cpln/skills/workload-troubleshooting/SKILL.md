---
name: workload-troubleshooting
description: "Diagnoses unhealthy Control Plane workloads. Use when asked why a workload is crashing, not starting, OOMKilled, ImagePullBackOff, returning 502s, failing health checks, unreachable, or stuck deploying."
---

# Workload Troubleshooting

Maps a symptom to its platform-specific cause and a fix the schema accepts. Diagnosis is read-only. Most failures trace to a Control Plane rule a generic engineer would not guess; the most common is OOMKilled.

## Gather state

`mcp__cpln__diagnose_workload` first: one call reads the deployments, events, and error log lines, matches them against this catalog, and returns the likely cause with its evidence. When it is not conclusive:

- `list_deployments`, with `location` for one location in full detail.
- `get_workload_events` for image pulls, crashes, scheduling, probe failures, and `OOMKilled`.
- `get_workload_logs`; the `_accesslog` container holds HTTP status codes and latency.
- `list_metrics`, then `query_metrics`, for memory, CPU, and latency pressure.
- `query_traces`, then `get_trace`, for a slow request; needs tracing on the GVC (`metrics-observability` skill).
- In-container inspection goes through the CLI (`cpln` skill).

## Failure catalog

### Out of memory (OOMKilled)

`memory` is a hard cap per container, sidecars included: app, runtime, GC, and buffers together. Usual culprits: Java without `-Xmx`, Node without `--max-old-space-size`, Python loading large datasets. Capacity AI can downsize a spiky workload too far; set `minMemory` as a floor.

**Fix:** measure with `query_metrics`, then raise `memory`, and raise `cpu` with it: memory in MiB stays within 8 times CPU in millicores, so the default `50m` caps memory at 400Mi.

### Image pull failures (`ImagePullBackOff`, `ErrImagePull`)

Check the reference form, the architecture (`linux/amd64` on managed locations; BYOK allows more), and the pull secret: a private external registry needs a secret of type `docker`, `ecr`, or `gcp` in the GVC's `pullSecretLinks`, created with `create_secret` and `values: "user"`, attached with `update_gvc`. Org `//image/` images need none. Detail: `image` skill.

### Secret access failures

Empty env vars or secret errors in events mean the identity, `reveal` policy, or reference is missing or wrong. `grant_workload_secret_access` fixes the identity and policy in one call; reference formats per type: `setup-secret` skill.

### Healthy but 502 or 503: port mismatch

- The spec port must match what the process listens on; compare the spec with the startup logs.
- On serverless the runtime injects `PORT` and rejects a `PORT` env var that differs from the exposed port.
- Serverless exposes exactly one port (TCP needs a dedicated load balancer); standard and stateful expose zero or more; cron serves nothing.
- Blocked ports cannot be bound and are invalid for TCP probes: 8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000.

### Firewall blocking traffic

Fix with `update_workload`: `external.inboundAllowCIDR` for inbound, `external.outboundAllowCIDR` or `outboundAllowHostname` for outbound (hostname rules reach only ports 80, 443, and 445), and `internal.inboundAllowType` or `allow_workload_access` for other workloads. Detail: `firewall-networking` skill.

### Health-check failures

Serverless gets TCP readiness and liveness on the container port; standard, stateful, and cron get none. For a slow start raise `initialDelaySeconds` (0 to 600); for an over-eager probe raise `periodSeconds` (1 to 600) or `timeoutSeconds` (1 to 600, default 1); an HTTP path must return 200 to 399. A readiness failure takes the replica out of rotation and pauses the rollout; a liveness failure restarts it. An autoscaled workload without a real readiness probe takes traffic before it is ready and returns 502 on scale-up: add an `httpGet` readiness probe. Detail: `workload-security` skill.

### Resources and Capacity AI

- CPU and memory must fit the org quota; `maxScale` times the per-replica resources is enforced at scheduling.
- Capacity AI is off with the `cpu` metric or multi-metric scaling; check the stored `spec.defaultOptions.capacityAI` first. On cron a new reservation lands at the next run.
- Stateful sizing: `minCpu` to `cpu` at most 4 to 1 and 4000m apart; `minMemory` to `memory` at most 4 to 1 and 4096Mi apart.
- Ephemeral storage is 1 GB per CPU core, at least 1 GB; exceeding it replaces the replica.

### Container will not start

- UID 1337 is the mesh proxy's: a container running as it bypasses the sidecar. Set `runAsUser` to another UID from 1 to 65534; root is rejected.
- Reserved container names: `istio-proxy`, `queue-proxy`, `istio-validation`, and any starting with `cpln-` or `debugger-`.
- Env names starting with `CPLN_`, and `K_SERVICE`, `K_CONFIGURATION`, `K_REVISION`, are rejected; each value is at most 4096 characters.
- `spec.defaultOptions.suspend: true` stops the workload: clear it, or `cpln workload start WORKLOAD --gvc GVC`.

### Autoscaling misconfiguration

Serverless has no `latency` or multi-metric scaling; standard and stateful have no `concurrency`; cron has no autoscaling. Scale to zero: serverless with `rps` or `concurrency`; standard and stateful only with `metric: keda`; never cron. 502 on scale-up is the readiness probe above. Detail: `autoscaling-capacity` skill.

### Failures during deploys or scale-down

- If `sleep` is missing from any container, every container is killed at once with no drain; distroless images often lack it (`which sleep`). Add `sleep` or a custom `preStop`.
- A failing custom `preStop` in any container kills all of them.
- After the preStop (default `sleep 45`) the container gets SIGTERM, then SIGKILL once `terminationGracePeriodSeconds` (default 90; at most 900 without the `cpln/relaxGracePeriodMax` tag) elapses. An app that ignores SIGTERM drops requests.

Sequence and rollout options: `workload-security` skill.

### Volume mount failures

- Secret volumes need the identity and `reveal` policy.
- Cloud volumes (S3, GCS, Azure Blob and Files) need an identity with cloud access and outbound firewall to the provider hosts (`*.amazonaws.com`, `*.googleapis.com`, `*.blob.core.windows.net`, `*.file.core.windows.net`, `*.azure.com`). Only identity auth works; embedded keys do not. Read-only except Azure Files.
- `filesystemGroupId` defaults to 0 (root) when unset: set it from 1 to 65534 for a non-root app.

Volume sets: `stateful-storage` skill.

### Service-to-service failures

- The target's internal firewall must admit the caller (`allow_workload_access`); listing a workload needs `view` on it.
- Call `http://WORKLOAD.GVC.cpln.local:PORT` over plain HTTP. An omitted port means the target's first container port; only listed ports are reachable.
- Cross-GVC calls may span locations and pay egress.

### Dedicated load balancer and domains

- TCP needs a dedicated load balancer on the GVC plus a Domain with a TCP port; default endpoints serve HTTP, HTTP2, and gRPC only.
- Enabling or disabling a dedicated load balancer causes a brief DNS propagation outage and per-location charges.
- Behind a custom domain, a serverless workload receives the canonical endpoint as `Host` (the custom domain arrives in `X-Forwarded-Host`); standard and stateful receive the custom domain.
- The domain port protocol must match the container's: HTTP2 fronts HTTP2 or gRPC, HTTP fronts HTTP.

Detail: `domain` and `ipset-load-balancing` skills.

## Fix within the schema's limits

A fix the validator rejects wastes a round trip. Before a resource or option change, check:

- Memory in MiB at most 8 times CPU in millicores; CPU at least 25m; memory at least 32Mi; `minCpu` and `minMemory` never above `cpu` and `memory`.
- `runAsUser` and `filesystemGroupId` from 1 to 65534.
- `terminationGracePeriodSeconds` at most 900, unless the `cpln/relaxGracePeriodMax` tag is set.
- `capacityAI` is rejected with `metric: cpu` and with a GPU container.
- Standard and stateful `minScale: 0` needs `metric: keda`; cron and vm cannot scale to zero.
- A metric outside the type's list is rejected.

A restart without a spec change (fresh secret values, wedged replicas) is `restart_workload`. After a fix, `diagnose_workload` confirms the symptom cleared.
