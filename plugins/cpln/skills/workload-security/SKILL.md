---
name: workload-security
description: "Production hardening for Control Plane workloads. Use when asked about JWT/Envoy auth, security context (runAsUser), health probe tuning, direct load balancers, geo-location headers, or graceful shutdown / termination."
---

# Workload Security & Production Hardening

Deep-dive companion to the `workload` skill, which owns workload types, the spec shape, and the readiness-vs-liveness model. Everything below is production-hardening detail for an existing workload.

**Where settings live.** Health probes go inline in `containers[]` via `create_workload` / `update_workload`. Every other block here — `sidecar.envoy`, `loadBalancer`, `securityOptions`, `rolloutOptions` — is set by its own `configure_workload_*` tool, a set-or-clear PATCH on that one field (`remove: true` clears it). Those tools live in the `full` toolset profile; if one isn't advertised, reconnect with `?toolsets=full` or use the CLI. Reads/deletes work on any profile (`list_resources` / `get_resource` / `delete_resource`).

## Health Probes

Define `readinessProbe` (gate traffic) and `livenessProbe` (restart on failure) as distinct probes in the container spec.

**Defaults by workload type:**
- **Serverless** — a TCP readiness probe on the listening port is injected by default (plus default startup and liveness probes). Adequate, but an `httpGet` against a real endpoint catches more failure modes (DB unreachable, dependency timeout, deadlock).
- **Standard / Stateful** — **no probes by default**; add them explicitly for any production workload.
- **Cron** — probes are stripped (ignored).

No HTTP healthcheck? Use `tcpSocket` on the listening port as a baseline — don't run a long-lived workload probe-less.

### Probe schema

Each probe takes exactly one of `exec` / `grpc` / `tcpSocket` / `httpGet`, plus these timing fields:

| Field | Range | Default |
|---|---|---|
| `initialDelaySeconds` | 0-600 | 10 (readiness) / 60 (liveness) |
| `periodSeconds` | 1-600 | 10 |
| `timeoutSeconds` | 1-600 | 1 |
| `successThreshold` | 1-20 | 1 |
| `failureThreshold` | 1-20 | 3 |

`httpGet` omitting `port` defaults to the first container port; `httpGet.scheme` defaults to `HTTP`. Keep liveness looser than readiness (e.g. `periodSeconds: 30`) — restarts are expensive.

```yaml
containers:
  - name: api
    image: //image/api:v1.0
    ports: [{ number: 8080, protocol: http }]
    readinessProbe:
      httpGet: { path: /healthz/ready, port: 8080 }
      initialDelaySeconds: 5
      failureThreshold: 3
    livenessProbe:
      httpGet: { path: /healthz/live, port: 8080 }
      initialDelaySeconds: 30
      periodSeconds: 30
```

## JWT Authentication

JWTs are validated at the Envoy sidecar before requests reach the workload, via the `jwt_authn` HTTP filter under `spec.sidecar.envoy`. Set it per-workload with `configure_workload_sidecar`, or org-wide-per-GVC by putting the same `sidecar.envoy` on the GVC (`update_gvc`) — it then applies to every workload in that GVC.

Must-know rules (the filter is strictly validated, not passthrough):
- The filter `name`, `typed_config."@type"`, and `priority` (0-100) must be exact — copy them from the example.
- Each provider needs a matching `clusters[]` entry (`STRICT_DNS` + TLS transport socket) so Envoy can fetch the JWKS over HTTPS. `remote_jwks.http_uri.cluster` must equal that cluster's `name`.
- `rules` are first-match-wins. A rule with no `requires` lets matching paths through **without** a token — use it to exempt health/metrics endpoints.
- `claim_to_headers` forwards JWT claims into request headers, so the workload gets identity context without re-parsing the token.
- Provider/cluster names starting with `cpln_` are UI-managed and restricted (no `async_fetch` / `retry_policy`, and `cache_duration` must equal `http_uri.timeout`). For hand-authored configs use a **non-`cpln_`** name for full Envoy flexibility.

```yaml
spec:
  sidecar:
    envoy:
      clusters:
        - name: auth0
          type: STRICT_DNS
          load_assignment:
            cluster_name: auth0
            endpoints:
              - lb_endpoints:
                  - endpoint:
                      address:
                        socket_address: { address: YOUR_TENANT.auth0.com, port_value: 443 }
          transport_socket:
            name: envoy.transport_sockets.tls
      http:
        - name: envoy.filters.http.jwt_authn
          priority: 50
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication
            providers:
              auth0:
                issuer: https://YOUR_TENANT.auth0.com/
                audiences: [https://api.example.com]
                remote_jwks:
                  http_uri: { uri: https://YOUR_TENANT.auth0.com/.well-known/jwks.json, cluster: auth0, timeout: 5s }
                  cache_duration: 300s
                claim_to_headers:
                  - { header_name: X-User-Sub, claim_name: sub }
            rules:
              - match: { prefix: /healthz }          # public, no token required
              - match: { prefix: / }
                requires: { provider_name: auth0 }    # everything else needs a valid JWT
```

For any OIDC provider (Auth0, Firebase, Cognito, Okta), set `issuer` to its issuer URL, `remote_jwks.http_uri.uri` to its JWKS endpoint (usually `/.well-known/jwks.json`), and `audiences` to your client ID or API identifier.

## Security Options

`spec.securityOptions` (set with `configure_workload_security`):

| Field | Range | Purpose |
|---|---|---|
| `runAsUser` | 1-65534 | UID for all container processes |
| `filesystemGroupId` | 1-65534 | GID applied to mounted volumes |

Neither has a schema default — unset means the image's user and root/GID 0 for volumes. Set `runAsUser` to a non-root UID for defense in depth; set `filesystemGroupId` so containers can share access to mounted volumes (e.g. volume sets). **Not valid for `type: vm`** (the guest OS owns its own security context).

**Trap — never `runAsUser: 1337`.** That is the mesh proxy's UID. A container running as 1337 is excluded from the Envoy redirect, so it bypasses the mesh entirely — losing mTLS and firewall enforcement and getting *unfiltered* egress.

### Workload permissions

Beyond standard `view` / `edit` (implies `view`) / `create` / `delete` / `manage`, the workload kind adds three non-obvious permissions: `connect` (interactive shell into a replica) and `configureLoadBalancer` (toggle direct/dedicated LBs) — **neither implied by `edit`** — plus `exec`, which implies `exec.runCronWorkload` + `exec.stopReplica`. Full policy and principal setup: `access-control` skill.

## Direct Load Balancers

`spec.loadBalancer.direct` exposes workload ports through a per-location cloud LB. Unlike the shared LB, it supports custom TCP/UDP ports and needs no domain registration — use it for non-HTTP protocols or custom ports. You are responsible for your own TLS certificates. Set with `configure_workload_load_balancer`.

- `enabled` (bool, required) — when `false`, the LB is stopped and accrues no charges.
- `ports[]` — each entry: `externalPort` (22-32768, required), `protocol` (`TCP`/`UDP`, required), `containerPort` (80-65535, excludes reserved ports), `scheme` (`http`/`tcp`/`https`/`ws`/`wss`, optional, sets the UI link scheme; default `https`).
- `ipSet` (optional) — link to an IP set for reserved static IPs.

**Reserved container ports (rejected):** 8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000.

```yaml
spec:
  loadBalancer:
    direct:
      enabled: true
      ports:
        - { externalPort: 5432, protocol: TCP, scheme: tcp, containerPort: 5432 }
```

Each direct-LB location also gets a public Geo DNS address with latency-based routing, usable as a CNAME target for custom domains.

### Geo location headers

`spec.loadBalancer.geoLocation` adds MaxMind GeoLite2 data to inbound HTTP requests under the header names you set in `headers.{asn,city,country,region}` (each max 128 chars; `enabled` defaults `false`). When enabled, at least one header is required, names must be unique, and existing same-named headers are replaced. HTTP-exposed workloads only. Pair with header-based firewall rules for geo-filtering (`firewall-networking` skill).

### Replica-direct endpoints

`spec.loadBalancer.replicaDirect: true` gives each replica its own stable hostname (default `false`, **stateful workloads only**):
- External: `WORKLOAD-GVCALIAS-INDEX.LOCATION.controlplane.us`
- Internal: `replica-INDEX.WORKLOAD.LOCATION.GVC.cpln.local:PORT`

## Graceful Termination

`spec.rolloutOptions` (set with `configure_workload_rollout`) governs how replicas are removed during scaling, version updates, Capacity AI rollouts, and maintenance.

| Field | Range / values | Default |
|---|---|---|
| `minReadySeconds` | integer ≥0 | 0 |
| `maxSurgeReplicas` | integer or percent | unset (not for `vm`) |
| `maxUnavailableReplicas` | integer or percent | unset (not for `stateful`) |
| `scalingPolicy` | `OrderedReady` / `Parallel` | `OrderedReady` (not for `vm`) |
| `terminationGracePeriodSeconds` | 0-900 (3600 with the `cpln/relaxGracePeriodMax` tag) | 90 |

`terminationGracePeriodSeconds` is the total budget for a replica to shut down before SIGKILL; raise it for long-running requests. Termination sequence:

1. The load balancer removes the replica from the pool (up to ~10s) so new requests route elsewhere.
2. The Control Plane sidecar drains in parallel: it holds for `grace - 10` seconds (default 80), then waits for in-flight connections to complete before shutting down.
3. Containers run their `preStop` hook. With no custom hook, a default `sh -c "sleep N"` runs where `N` = half the grace period (45s at the 90s default), giving the LB time to stop routing.
4. After `preStop`, the container receives **SIGINT** and has the remaining grace to exit, then **SIGKILL**. Handle the termination signal to drain cleanly.

**Trap — immediate SIGKILL of *all* containers** if `sleep`/`sh` is missing in *any* container (common with distroless/minimal images) or a custom `preStop` errors in *any* container. A custom `preStop` must include a delay or connection check, and must be tested — an error there force-kills the whole replica.

## Verify

- After any change, poll `mcp__cpln__list_deployments` until each location reports ready — it surfaces probe failures per location.
- `mcp__cpln__get_workload_events` gives the probe/liveness failure reason and message; `mcp__cpln__get_workload_logs` shows app-side errors.
- For JWT, send a request with and without a valid token (expect 401 without) and confirm the `claim_to_headers` header arrives at the workload.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Deploy never ready; events show probe failures | wrong `httpGet` path/port, or app slow to start | fix path/port; raise `initialDelaySeconds` / `failureThreshold` |
| All requests 401 after adding JWT | no public-exemption rule, or `provider_name` mismatch | add a no-`requires` rule for health paths; match the rule's `provider_name` to a provider key |
| JWT always rejected / JWKS fetch fails | cluster missing or `remote_jwks.http_uri.cluster` doesn't match a `clusters[].name` | add the `STRICT_DNS` + TLS cluster and align the names |
| Replica SIGKILL'd instantly on rollout | `sleep`/`sh` missing, or custom `preStop` errors | use a `sleep`-capable image, or a native-sleep `preStop`; test the hook |
| Direct LB port rejected | `containerPort` is reserved, or `externalPort` outside 22-32768 | pick a non-reserved container port; keep `externalPort` in range |
| `securityOptions` / `replicaDirect` rejected | `type: vm` (securityOptions) or non-stateful (replicaDirect) | remove the field or change the workload type |

## Quick reference

### MCP tools

All `configure_workload_*` tools are `full`-profile, set-or-clear PATCH (`remove: true` clears).

| Tool | Purpose |
|---|---|
| `mcp__cpln__configure_workload_sidecar` | Set/clear `spec.sidecar.envoy` — JWT / Envoy filter chain |
| `mcp__cpln__configure_workload_load_balancer` | Set/clear `spec.loadBalancer` — direct LB, geo headers, replicaDirect |
| `mcp__cpln__configure_workload_security` | Set/clear `spec.securityOptions` — `runAsUser`, `filesystemGroupId` |
| `mcp__cpln__configure_workload_rollout` | Set/clear `spec.rolloutOptions` — termination grace, surge/unavailable |
| `mcp__cpln__create_workload` / `mcp__cpln__update_workload` | Probes go inline in `containers[]` (update is PATCH, merges containers by name) |
| `mcp__cpln__list_deployments` | Poll per-location readiness; surfaces probe failures |
| `mcp__cpln__get_workload_events` | Probe / liveness failure reason + message |
| `mcp__cpln__get_workload_logs` | App-side logs for security / probe issues |
| `mcp__cpln__workload_exec` | One-off command in a live replica (audited) |

### CLI (fallback)

Use the CLI when the MCP server is unavailable or unauthenticated, or in CI/CD (service-account `CPLN_TOKEN`).

```bash
cpln workload get WORKLOAD --gvc GVC -o yaml-slim > workload.yaml
# edit, then apply (CI/CD: add --ready to block until deployed)
cpln apply -f workload.yaml --gvc GVC
```

### Related skills

- `workload` — primary skill (types, defaults, spec shape, tool division); start here.
- `firewall-networking` — CIDR / header rules, geo-filtering, LB types.
- `access-control` — policies, principals, the full permission model.
- `autoscaling-capacity` — scaling and Capacity AI settings.
- `stateful-storage` — volume sets (pair with `filesystemGroupId`).

## Documentation

- [Workload Security](https://docs.controlplane.com/reference/workload/security.md)
- [JWT Auth](https://docs.controlplane.com/reference/workload/jwt-auth.md)
- [Termination](https://docs.controlplane.com/reference/workload/termination.md)
- [Load Balancing](https://docs.controlplane.com/reference/workload/load-balancing.md)
