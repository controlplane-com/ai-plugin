---
name: workload-security
description: "Hardens workloads for production on Control Plane. Use when the user asks about JWT authentication, workload security options, TLS configuration, geo-location headers, graceful shutdown, readiness/liveness probes, or securing public-facing workloads. Covers JWT validation via Envoy sidecar, security options, geo headers, and graceful termination."
---

# Workload Security & Production Hardening

Deep hardening detail. Probe basics, the readiness-vs-liveness model, the LB picker, and post-deploy verification live in the `workload` skill — this skill carries the full probe timing/defaults, JWT/Envoy, security, direct-LB, geo, and graceful-termination detail.

## Health Probes

Define both `readinessProbe` and `livenessProbe` as distinct probes (the readiness-vs-liveness model is in the `workload` skill).

**Defaults by workload type:**

- **Serverless** — a TCP probe on the listening port is enabled by default. Better than nothing, but a real `httpGet` against an app endpoint catches more failure modes (DB unreachable, dependency timeout, deadlock).
- **Standard / Stateful** — probes are **disabled by default**; add them explicitly for any production workload.
- **Cron** — probes are ignored.

If a workload genuinely has no HTTP healthcheck, use `tcpSocket` against the listening port as a baseline — never ship without probes.

### Probe schema

Each probe takes exactly one of `exec`, `grpc`, `tcpSocket`, `httpGet` (xor). Timing fields and ranges:

| Field | Range | Default |
|---|---|---|
| `initialDelaySeconds` | 0-600 | 10 (readiness) / 60 (liveness) |
| `periodSeconds` | 1-600 | 10 |
| `timeoutSeconds` | 1-600 | 1 |
| `successThreshold` | 1-20 | 1 |
| `failureThreshold` | 1-20 | 3 |

Liveness is typically looser than readiness (e.g. `periodSeconds: 30`) — restarts are expensive.

### Production-grade probe example

```yaml
spec:
  containers:
    - name: api
      image: //image/api:v1.0
      ports:
        - number: 8080
          protocol: http
      readinessProbe:
        httpGet:
          path: /healthz/ready
          port: 8080
        initialDelaySeconds: 5
        periodSeconds: 10
        timeoutSeconds: 2
        failureThreshold: 3
      livenessProbe:
        httpGet:
          path: /healthz/live
          port: 8080
        initialDelaySeconds: 30
        periodSeconds: 30
        timeoutSeconds: 3
        failureThreshold: 3
```

## JWT Authentication

JWT Authentication validates JSON Web Tokens at the infrastructure level (Envoy sidecar) before requests reach the workload. Configured under `sidecar.envoy` — set it on a workload with `mcp__cpln__configure_workload_sidecar` (or on a GVC by editing the GVC spec, where it applies to all workloads in that GVC).

### Configuration Structure

JWT auth uses the Envoy `jwt_authn` HTTP filter:

| Field | Value |
|---|---|
| `name` | `envoy.filters.http.jwt_authn` |
| `typed_config."@type"` | `type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication` |
| `priority` | Integer for ordering multiple filters |
| `typed_config.providers` | Map of provider name to provider config |
| `typed_config.rules` | Array of rules controlling which requests require valid JWTs |

### Provider Configuration

Each provider is a key in `typed_config.providers`:

| Field | Type | Description |
|---|---|---|
| `issuer` | string | URL of the domain that issued the JWT |
| `audiences` | string[] | Accepted audiences for the JWT |
| `claim_to_headers` | object[] | Maps JWT claims to request headers forwarded to the workload |
| `remote_jwks` | object | JWKS public key resolution and caching |

**Provider naming:** Names starting with `cpln_` are configured through the UI and have restricted settings (e.g., `cache_duration` must equal `http_uri.timeout`). Non-`cpln_` prefixed names allow full Envoy JWT configuration.

### Claim-to-Header Mapping

Extract JWT claims into headers forwarded to the workload:

| Field | Type | Description |
|---|---|---|
| `header_name` | string | Header name added to the forwarded request |
| `claim_name` | string | Claim extracted from the JWT |

### Remote JWKS

Public key resolution for JWT verification:

| Field | Type | Description |
|---|---|---|
| `http_uri.uri` | string | Endpoint for JWKS public key lookup |
| `http_uri.cluster` | string | Must match the cluster name for this provider |
| `http_uri.timeout` | string | Timeout in `Ns` format (e.g., `10s`) |
| `cache_duration` | string | JWKS cache duration in `Ns` format (e.g., `300s`) |

### Rules

Rules evaluated in order; the first matching rule applies:

| Field | Type | Description |
|---|---|---|
| `match.prefix` | string | URI prefix for this match |
| `match.headers` | string[] | Optional headers that must exist in the request |
| `requires.provider_name` | string | Provider for JWT verification; omit to allow all requests |

### Clusters

Each provider requires a cluster definition for HTTPS key lookup. Replace `${providerName}` and `${providerEndpoint}`:

```yaml
sidecar:
  envoy:
    clusters:
      - name: cpln_${providerName}
        type: STRICT_DNS
        load_assignment:
          cluster_name: cpln_${providerName}
          endpoints:
            - lb_endpoints:
                - endpoint:
                    address:
                      socket_address:
                        address: ${providerEndpoint}
                        port_value: 443
        transport_socket:
          name: envoy.transport_sockets.tls
```

### Full JWT Example

This configuration validates JWTs from `https://foo.com/auth`, extracts `user.special` claim into `X_SPECIAL_USER` header, requires JWT for all paths except `/metric`:

```yaml
sidecar:
  envoy:
    clusters:
      - name: cpln_foo
        type: STRICT_DNS
        load_assignment:
          cluster_name: cpln_foo
          endpoints:
            - lb_endpoints:
                - endpoint:
                    address:
                      socket_address:
                        address: foo.com
                        port_value: 443
        transport_socket:
          name: envoy.transport_sockets.tls
    http:
      - name: envoy.filters.http.jwt_authn
        priority: 50
        typed_config:
          "@type": >-
            type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication
          providers:
            cpln_foo:
              audiences:
                - myaudience
              claim_to_headers:
                - claim_name: user.special
                  header_name: X_SPECIAL_USER
              issuer: https://foo.com/auth
              remote_jwks:
                cache_duration: 5s
                http_uri:
                  cluster: cpln_foo
                  timeout: 5s
                  uri: https://foo.com/auth
          rules:
            - match:
                headers: []
                prefix: /metric
            - match:
                headers: []
                prefix: /
              requires:
                provider_name: cpln_foo
```

For any OIDC-compliant provider (Auth0, Firebase, Cognito, Okta), set `issuer` to the provider's issuer URL, `remote_jwks.http_uri.uri` to its JWKS endpoint (typically `/.well-known/jwks.json`), and `audiences` to your client ID or API identifier. Use `rules` to exclude health/metrics paths, and `claim_to_headers` to pass identity context to the workload without re-parsing the token.

## Security Options

Runtime security settings for the workload, configured under `spec.securityOptions`:

| Field | Type | Range | Default | Description |
|---|---|---|---|---|
| `filesystemGroupId` | integer | 1-65534 | 0 (root) | Group ID assigned to any mounted volumes |
| `runAsUser` | integer | 1-65534 | Image default | User ID assigned to all container processes |

```yaml
spec:
  securityOptions:
    filesystemGroupId: 1000
    runAsUser: 1000
```

Set `runAsUser` to a non-root UID for defense in depth. Set `filesystemGroupId` when containers need shared access to mounted volumes (e.g., volume sets).

### Workload Permissions

Policies control workload access using these permissions:

| Permission | Description | Implies |
|---|---|---|
| `view` | Read-only access | |
| `edit` | Modify existing workloads | `view` |
| `create` | Create new workloads | |
| `delete` | Delete existing workloads | |
| `connect` | Open interactive shell to replica | |
| `configureLoadBalancer` | Configure the workload load balancer | |
| `exec` | Execute commands | `exec.runCronWorkload`, `exec.stopReplica` |
| `exec.runCronWorkload` | Force a cron workload to run | |
| `exec.stopReplica` | Force a replica to be stopped | |
| `manage` | Full access | All of the above |

## Direct Load Balancers

Expose workload ports directly through cloud load balancers in each deployment location. Unlike the shared load balancer, direct LBs support custom TCP/UDP ports and do not require domain registration. Use for non-HTTP protocols, custom ports, or when domain registration is not needed; workloads are responsible for their own TLS certificates. Set `spec.loadBalancer` (direct, geo headers, replicaDirect) with `mcp__cpln__configure_workload_load_balancer`.

Under `spec.loadBalancer.direct`:

| Field | Type | Description |
|---|---|---|
| `enabled` | boolean (required) | Enable/disable the direct LB. When `false`, LB is stopped and no charges accrue |
| `ports` | array | Ports exposed by the load balancer |
| `ipSet` | string (optional) | Link to an IP set for reserved static IPs |

Each entry in the `ports` array:

| Field | Type | Description |
|---|---|---|
| `externalPort` | number | Public port. Range: 22-32768 |
| `protocol` | string | `TCP` or `UDP` |
| `scheme` | string (optional) | URL scheme for UI links: `http`, `tcp`, `https`, `ws`, `wss`. Default: `https` |
| `containerPort` | number | Target container port (80-65535, excludes reserved ports) |

**Reserved container ports (cannot be used):** 8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000.

```yaml
spec:
  loadBalancer:
    direct:
      enabled: true
      ports:
        - externalPort: 5432
          protocol: TCP
          scheme: tcp
          containerPort: 5432
        - externalPort: 9000
          protocol: UDP
          containerPort: 9000
```

### Geo DNS Routing

Each location gets a public address configured as a target of the Geo DNS endpoint. Latency-based routing distributes traffic across locations. The workload DNS record can be used as a CNAME target for custom domains without registering domains in Control Plane.

### Replica Direct (Stateful Only)

For stateful workloads, `replicaDirect` enables individual replica endpoints:

```yaml
spec:
  loadBalancer:
    replicaDirect: true
```

Endpoint format:
- External: `<workloadName>-<gvcAlias>-<replicaIndex>.<locationName>.controlplane.us`
- Internal: `replica-<replicaIndex>.<workloadName>.<locationName>.<gvcName>.cpln.local:<port>`

## Geo Location Headers

Add geographic information to inbound HTTP requests using MaxMind GeoLite2 data. Configured under `spec.loadBalancer.geoLocation`:

| Field | Type | Description |
|---|---|---|
| `enabled` | boolean | Enable geo headers (default: `false`) |
| `headers.asn` | string | Header name for ASN (max 128 chars) |
| `headers.city` | string | Header name for city (max 128 chars) |
| `headers.country` | string | Header name for country (max 128 chars) |
| `headers.region` | string | Header name for region (max 128 chars) |

**Rules:**
- At least one header must be set when enabled
- All header names must be unique
- Existing headers with the same names are replaced
- Only works on workloads exposing an HTTP port
- Replicas receive the latest IP-to-geo database on startup

```yaml
spec:
  loadBalancer:
    geoLocation:
      enabled: true
      headers:
        asn: X-GeoIP-ASN
        city: X-GeoIP-City
        country: X-GeoIP-Country
        region: X-GeoIP-Region
```

Combine geo headers with header-based firewall filtering for geo-filtering (see the **cpln-firewall-networking** skill).

## Graceful Termination

Controls how workload replicas are removed during scaling, version updates, Capacity AI rollouts, and maintenance.

### Termination Grace Period

Configured under `spec.rolloutOptions.terminationGracePeriodSeconds`:

| Field | Type | Range | Default |
|---|---|---|---|
| `terminationGracePeriodSeconds` | number | 0-900 | 90 |

Total time available for graceful shutdown before all containers receive SIGKILL. Default 90s works for most workloads; increase (up to 900) for workloads with long-running requests.

### Rollout Options

Full `spec.rolloutOptions` configuration:

| Field | Type | Default | Description |
|---|---|---|---|
| `minReadySeconds` | integer | 0 | Minimum seconds a container must run without crashing to be considered available |
| `maxSurgeReplicas` | integer or percent | | Max replicas above desired count during rollout |
| `maxUnavailableReplicas` | integer or percent | | Max unavailable replicas during rollout (not for stateful workloads) |
| `scalingPolicy` | string | `OrderedReady` | `OrderedReady` or `Parallel` |
| `terminationGracePeriodSeconds` | number | 90 | Graceful shutdown timeout (0-900) |

### Termination Sequence

1. **Load balancer update** -- replica removed from pool (up to 10 seconds)
2. **Sidecar termination** (managed by Control Plane):
   - **Hold phase**: continues normally for `terminationGracePeriodSeconds - 10` seconds (default: 80s)
   - **Monitoring phase**: waits for active connections to complete
   - **Drain phase**: stops accepting new connections, verifies completion, shuts down
3. **Container termination**:
   - **Default preStop hook**: executes `sh -c "sleep N"` where N = half the grace period (default: 45s)
   - After preStop completes, the container receives **SIGTERM** (the Kubernetes default termination signal)
   - Remaining time for graceful shutdown before **SIGKILL**

### Critical Warnings

- If `sleep` is not available in **any** container, ALL containers receive SIGKILL immediately.
- If a custom preStop hook throws an error in **any** container, ALL containers receive SIGKILL immediately.

### Custom PreStop Hook

Only implement if the workload requires specific termination logic (graceful connection draining, containers without `sh`/`sleep`, or custom request handling during shutdown). A custom preStop hook must include a delay or check for ongoing requests to give load balancers time to update, and must be tested thoroughly — errors cause immediate SIGKILL for all containers.

```yaml
spec:
  rolloutOptions:
    terminationGracePeriodSeconds: 120
    minReadySeconds: 10
    maxSurgeReplicas: "25%"
    maxUnavailableReplicas: "25%"
    scalingPolicy: Parallel
```

## Combined Hardening

- Combine JWT auth with firewall CIDR rules for layered security.
- Use geo location headers with header-based firewall filtering for geo-blocking.
- Pair direct LBs with an IP set for reserved static IPs, and set an appropriate `terminationGracePeriodSeconds`.

## Quick Reference

### MCP Tools (use these first)

| Tool | Purpose |
|---|---|
| `mcp__cpln__create_workload` | Create a workload with security options, probes, and rollout settings |
| `mcp__cpln__update_workload` | Update security options, probes, or rollout config (PATCH — only sent fields change) |
| `mcp__cpln__configure_workload_load_balancer` | Set/clear the load balancer (direct, geo headers, replicaDirect) |
| `mcp__cpln__configure_workload_sidecar` | Set/clear the Envoy sidecar (JWT auth, filter chain) |
| `mcp__cpln__get_workload` | Inspect current workload configuration (read before any update for rollback) |
| `mcp__cpln__list_workloads` | Find workloads in a GVC before targeting one |
| `mcp__cpln__delete_workload` | Delete a workload (destructive — confirm blast radius first) |
| `mcp__cpln__get_workload_deployments` | PRIMARY post-deploy readiness monitor — poll until ready, surfaces probe failures per location |
| `mcp__cpln__get_workload_events` | Probe/liveness reason + message when a deploy fails |
| `mcp__cpln__get_workload_logs` | App-side logs to diagnose security/probe issues |
| `mcp__cpln__list_workload_replicas` | List running replicas before exec |
| `mcp__cpln__workload_exec` | Run a one-off command inside a replica (audited; targets live traffic) |
| `mcp__cpln__workload_start_cron` | Trigger an out-of-band run of a cron workload |

### CLI (fallback)

Use the CLI when the MCP server is unavailable or unauthenticated, in CI/CD pipelines (service-account `CPLN_TOKEN`), or for interactive debugging (`cpln workload exec`, `cpln workload connect`, `cpln logs`).

```bash
# Get workload YAML for editing (yaml-slim strips IDs, timestamps, metadata)
cpln workload get WORKLOAD_NAME --gvc GVC_NAME -o yaml-slim > workload.yaml

# Apply updated workload configuration (CI/CD: add --ready to block until deployed)
cpln apply --file workload.yaml --gvc GVC_NAME
```

### Related Skills

- **cpln-workload** — Start here: the primary workload skill (types, defaults, spec shape) that routes here for security & hardening.
- **cpln-firewall-networking** — CIDR rules, header filtering, geo-filtering, LB types
- **cpln-access-control** — Policies, service accounts, permissions
- **cpln-autoscaling-capacity** — Scaling and Capacity AI settings
- **cpln-stateful-storage** — Volume sets (use with `filesystemGroupId`)

## Documentation

For the latest reference, see:

- [Workload Security Reference](https://docs.controlplane.com/reference/workload/security.md)
- [JWT Auth Reference](https://docs.controlplane.com/reference/workload/jwt-auth.md)
- [Termination Reference](https://docs.controlplane.com/reference/workload/termination.md)
- [Load Balancing Reference](https://docs.controlplane.com/reference/workload/load-balancing.md)
- [Firewall Reference](https://docs.controlplane.com/reference/workload/firewall.md)
- [Workload General Reference](https://docs.controlplane.com/reference/workload/general.md)
