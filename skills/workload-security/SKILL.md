---
name: cpln-workload-security
description: "Hardens workloads for production on Control Plane. Use when the user asks about JWT authentication, workload security options, TLS configuration, geo-location headers, graceful shutdown, readiness/liveness probes, or securing public-facing workloads. Covers JWT validation via Envoy sidecar, security options, geo headers, and graceful termination."
version: 1.0.0
---

# Workload Security & Production Hardening

## JWT Authentication

JWT Authentication validates JSON Web Tokens at the infrastructure level (Envoy sidecar) before requests reach the workload. Configured under `sidecar.envoy` in the workload or GVC spec.

When configured on the GVC layer, settings apply to all workloads in that GVC.

### Configuration Structure

JWT auth uses the Envoy `jwt_authn` HTTP filter:

| Field | Value |
|:------|:------|
| `name` | `envoy.filters.http.jwt_authn` |
| `typed_config."@type"` | `type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication` |
| `priority` | Integer for ordering multiple filters |
| `typed_config.providers` | Map of provider name to provider config |
| `typed_config.rules` | Array of rules controlling which requests require valid JWTs |

### Provider Configuration

Each provider is a key in `typed_config.providers`:

| Field | Type | Description |
|:------|:-----|:------------|
| `issuer` | string | URL of the domain that issued the JWT |
| `audiences` | string[] | Accepted audiences for the JWT |
| `claim_to_headers` | object[] | Maps JWT claims to request headers forwarded to the workload |
| `remote_jwks` | object | JWKS public key resolution and caching |

**Provider naming:** Names starting with `cpln_` are configured through the UI and have restricted settings (e.g., `cache_duration` must equal `http_uri.timeout`). Non-`cpln_` prefixed names allow full Envoy JWT configuration.

### Claim-to-Header Mapping

Extract JWT claims into headers forwarded to the workload:

| Field | Type | Description |
|:------|:-----|:------------|
| `header_name` | string | Header name added to the forwarded request |
| `claim_name` | string | Claim extracted from the JWT |

### Remote JWKS

Public key resolution for JWT verification:

| Field | Type | Description |
|:------|:-----|:------------|
| `http_uri.uri` | string | Endpoint for JWKS public key lookup |
| `http_uri.cluster` | string | Must match the cluster name for this provider |
| `http_uri.timeout` | string | Timeout in `Ns` format (e.g., `10s`) |
| `cache_duration` | string | JWKS cache duration in `Ns` format (e.g., `300s`) |

### Rules

Rules evaluated in order; the first matching rule applies:

| Field | Type | Description |
|:------|:-----|:------------|
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

### Common JWT Providers

For any OIDC-compliant provider (Auth0, Firebase, Cognito, Okta), set:
- `issuer`: the provider's issuer URL
- `remote_jwks.http_uri.uri`: the provider's JWKS endpoint (typically `/.well-known/jwks.json`)
- `audiences`: your application's client ID or API identifier

## Security Options

Runtime security settings for the workload, configured under `spec.securityOptions`:

| Field | Type | Range | Default | Description |
|:------|:-----|:------|:--------|:------------|
| `filesystemGroupId` | integer | 1-65534 | 0 (root) | Group ID assigned to any mounted volumes |
| `runAsUser` | integer | 1-65534 | Image default | User ID assigned to all container processes |

```yaml
spec:
  securityOptions:
    filesystemGroupId: 1000
    runAsUser: 1000
```

Use `filesystemGroupId` when containers need shared access to mounted volumes (e.g., volume sets). Use `runAsUser` to avoid running as root.

### Workload Permissions

Policies control workload access using these permissions:

| Permission | Description | Implies |
|:-----------|:------------|:--------|
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

Expose workload ports directly through cloud load balancers in each deployment location. Unlike the shared load balancer, direct LBs support custom TCP/UDP ports and do not require domain registration.

### Configuration

Under `spec.loadBalancer.direct`:

| Field | Type | Description |
|:------|:-----|:------------|
| `enabled` | boolean (required) | Enable/disable the direct LB. When `false`, LB is stopped and no charges accrue |
| `ports` | array | Ports exposed by the load balancer |
| `ipSet` | string (optional) | Link to an IP set for reserved static IPs |

### Port Configuration

Each entry in the `ports` array:

| Field | Type | Description |
|:------|:-----|:------------|
| `externalPort` | number | Public port. Range: 22-32768 |
| `protocol` | string | `TCP` or `UDP` |
| `scheme` | string (optional) | URL scheme for UI links: `http`, `tcp`, `https`, `ws`, `wss`. Default: `https` |
| `containerPort` | number | Target container port (80-65535, excludes reserved ports) |

**Reserved container ports (cannot be used):** 8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000.

### Direct Load Balancer Example

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
|:------|:-----|:------------|
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

Geo headers can be combined with header-based firewall filtering for geo-filtering (see the **cpln-firewall-networking** skill).

## Graceful Termination

Controls how workload replicas are removed during scaling, version updates, Capacity AI rollouts, and maintenance.

### Termination Grace Period

Configured under `spec.rolloutOptions.terminationGracePeriodSeconds`:

| Field | Type | Range | Default |
|:------|:-----|:------|:--------|
| `terminationGracePeriodSeconds` | number | 0-900 | 90 |

Total time available for graceful shutdown before all containers receive SIGKILL.

### Rollout Options

Full `spec.rolloutOptions` configuration:

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
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
   - After preStop completes, container receives **SIGINT**
   - Remaining time for graceful shutdown before **SIGKILL**

### Critical Warnings

- If `sleep` is not available in **any** container, ALL containers receive SIGKILL immediately — the entire grace period is skipped. This silently affects distroless images, scratch-based images, and some minimal Alpine builds. Verify with `cpln workload exec WORKLOAD --gvc GVC -- which sleep` before relying on the grace period. If `sleep` is absent, either add it to the image or configure an explicit preStop hook that does not depend on it.
- If a custom preStop hook throws an error in **any** container, ALL containers receive SIGKILL immediately

### Custom PreStop Hook

Only implement if the workload requires specific termination logic:
- Graceful connection draining
- Containers without `sh`/`sleep` binaries
- Custom request handling during shutdown

A custom preStop hook must include a delay or check for ongoing requests to allow load balancers time to update.

### Termination Example

```yaml
spec:
  rolloutOptions:
    terminationGracePeriodSeconds: 120
    minReadySeconds: 10
    maxSurgeReplicas: "25%"
    maxUnavailableReplicas: "25%"
    scalingPolicy: Parallel
```

## Best Practices

### JWT Authentication
- Use JWT for API authentication to offload validation from application code
- Set appropriate `cache_duration` for JWKS to balance security and performance
- Use rules to exclude health/metrics paths from JWT requirements
- Use `claim_to_headers` to pass identity context to the workload without re-parsing the token

### Security Options
- Set `runAsUser` to a non-root UID for defense in depth
- Set `filesystemGroupId` when using volume sets so containers can access mounted files

### Direct Load Balancers
- Use for non-HTTP protocols (TCP/UDP), custom ports, or when domain registration is not needed
- Pair with an IP set for reserved static IPs in each location
- Workloads are responsible for TLS certificates when using direct LBs
- Enable `replicaDirect` for stateful workloads needing per-replica addressing

### Graceful Termination
- Default 90-second grace period works for most workloads
- Increase for workloads with long-running requests (max 900 seconds)
- Ensure containers include `sleep` binary to avoid immediate SIGKILL
- Test preStop hooks thoroughly; errors cause immediate SIGKILL for all containers

### Combined Hardening
- Combine JWT auth with firewall CIDR rules for layered security
- Use geo location headers with header-based firewall filtering for geo-blocking
- Configure appropriate `terminationGracePeriodSeconds` when using direct load balancers

## Quick Reference

### MCP Tools

| Tool | Purpose |
|:-----|:--------|
| `mcp__cpln__create_workload` | Create a workload with security, LB, and rollout settings |
| `mcp__cpln__update_workload` | Update workload security, LB, or rollout configuration |
| `mcp__cpln__get_workload` | Inspect current workload configuration |
| `mcp__cpln__get_workload_logs` | View workload logs to diagnose security issues |

### CLI

```bash
# Get workload YAML for editing (yaml-slim strips IDs, timestamps, metadata)
cpln workload get WORKLOAD_NAME --gvc GVC_NAME -o yaml-slim > workload.yaml

# Apply updated workload configuration
cpln apply --file workload.yaml --gvc GVC_NAME
```

### Related Skills

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
