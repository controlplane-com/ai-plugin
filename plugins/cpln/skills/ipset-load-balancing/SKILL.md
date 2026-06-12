---
name: ipset-load-balancing
description: "Reserves static IP addresses and configures load balancers on Control Plane. Use when the user asks about IP sets, static or fixed IPs, dedicated or direct load balancers, IP whitelisting, or egress IPs."
---

# IP Sets & Load Balancing

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Deep detail for IP sets plus direct and dedicated load balancers. For the LB-type picker basics and routing, see the `workload` skill — this skill carries the full configuration.

## Load Balancer Types

| Type | Scope | Custom Ports | Static IPs | Wildcard Hosts | Protocols | Extra Cost |
|---|---|---|---|---|---|---|
| Default (shared) | All workloads | No | No | No | HTTP/HTTPS only | No |
| Direct | Per-workload | Yes (22-32768) | Via IP Set | No | TCP, UDP, HTTP, HTTPS, WS, WSS | Yes |
| Dedicated | Per-GVC | Yes | Via IP Set | Yes | All (via Domains) | Yes |

- **Default (shared):** all workloads, no config, HTTP/HTTPS on 80/443 only.
- **Direct:** per-workload, custom port mappings, Geo DNS routing, optional static IPs; you manage TLS certs. Set with `mcp__cpln__configure_workload_load_balancer`.
- **Dedicated:** per-GVC, enables custom ports on domains, wildcard hostnames, accept-all-hosts, and redirect rules. A GVC setting — enable `spec.loadBalancer.dedicated` with `mcp__cpln__update_gvc`.

## IP Sets

An IP set reserves a **static public IP address in each location** of a GVC. Use them when external partners need to allowlist your IPs, or compliance requires fixed egress addresses.

### How IP Sets Work

1. Create an IP set with target locations and a link to a workload or GVC.
2. The target workload/GVC must link back to the IP set (**bidirectional**).
3. Control Plane allocates one public IP per location.
4. IPs persist across deployments as long as `retentionPolicy: keep`.

### IP Set Spec

| Field | Type | Required | Description |
|---|---|---|---|
| `spec.link` | string | No | Link to workload (`//gvc/NAME/workload/NAME`) or GVC (`//gvc/NAME`) |
| `spec.locations[].name` | string | Yes | Location reference (e.g. `//location/aws-us-west-2`) |
| `spec.locations[].retentionPolicy` | string | Yes | `keep` (retain the IP — reserved IPs bill while kept) or `free` (release the IP and stop charges) |

**Status fields:** `status.ipAddresses[]` contains `name` (location), `ip` (public IP), `id` (cloud allocation ID), `state` (`bound` or `unbound`), and `created` (ISO 8601).

### Create an IP Set

Prefer `mcp__cpln__create_ipset` — pass `name`, optional `link` (workload/GVC), and `locations[]`. Read with `mcp__cpln__list_resources` (kind="ipset") / `mcp__cpln__get_resource` (kind="ipset"). Fall back to `cpln apply -f ipset.yaml --org MY_ORG` when MCP is unavailable, or in CI/CD.

```yaml
kind: ipset
name: my-static-ips
description: Static IPs for partner allowlisting
spec:
  link: //gvc/my-gvc
  locations:
    - name: //location/aws-us-west-2
      retentionPolicy: keep
    - name: //location/aws-eu-west-1
      retentionPolicy: keep
```

### Release an IP

Set `retentionPolicy: free` to release an allocated IP and stop charges. Use `mcp__cpln__add_ipset_location` with `retentionPolicy: free` (it overwrites an already-configured location's policy). An IP is not released until it is no longer in use (no linked workload, GVC location not active).

### Manage an IP Set

Typed MCP tools map one-to-one to these operations — see the **MCP Tools** table below (`create_ipset`, `get_resource`/`list_resources` (kind="ipset"), `add_ipset_location`, `remove_ipset_location`, `update_ipset`, `delete_resource` (kind="ipset")).

CLI fallback when MCP is unavailable or unauthenticated:

```bash
cpln ipset create --name my-ips --link //gvc/my-gvc \
  --location aws-us-west-2,keep --location aws-eu-west-1,keep --org MY_ORG
cpln ipset get my-ips --org MY_ORG -o yaml
cpln ipset add-location my-ips --location aws-ap-southeast-1,keep --org MY_ORG
cpln ipset update-location my-ips --location aws-us-west-2,free --org MY_ORG   # release an IP
cpln ipset remove-location my-ips --location aws-ap-southeast-1 --org MY_ORG
cpln ipset delete my-ips --org MY_ORG
```

**Location format:** `location-name,retention-policy` (default retention: `keep`).

## Direct Load Balancer (Per-Workload)

Creates a load balancer in each location where the workload runs, with Geo DNS latency-based routing across locations. No domain registration required.

```yaml
spec:
  loadBalancer:
    direct:
      enabled: true
      ports:
        - externalPort: 443
          protocol: TCP
          scheme: https
          containerPort: 8443
        - externalPort: 9000
          protocol: UDP
          containerPort: 9000
```

### Port Configuration

| Field | Type | Required | Constraints | Description |
|---|---|---|---|---|
| `externalPort` | integer | Yes | 22-32768 | Publicly exposed port |
| `protocol` | string | Yes | `TCP` or `UDP` | Transport protocol |
| `scheme` | string | No | `http`, `tcp`, `https`, `ws`, `wss` | Overrides default `https` for UI/status links |
| `containerPort` | integer | No | 80-65535 | Container listening port |

**Reserved container ports** (cannot be used): 8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000.

### Attach Static IPs via IP Set

Both the workload and the IP set must reference each other (bidirectional):

**Workload:** add `ipSet: //ipset/my-static-ips` under `spec.loadBalancer.direct` (alongside `enabled` and `ports`).

**IP Set:** set `spec.link: //gvc/my-gvc/workload/my-workload` with the matching `locations[]`.

### Geo Location Headers

Inject client geo data into HTTP request headers using MaxMind GeoLite2:

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

- Requires at least one header when enabled; all header names must be unique.
- Only works on workloads exposing an HTTP port. Header name max length: 128 characters.

### Replica Direct (Stateful Workloads)

Address individual replicas via subdomain `replica-<index>`. Only valid for `type: stateful` workloads.

```yaml
spec:
  type: stateful
  loadBalancer:
    replicaDirect: true
    direct:
      enabled: true
      ports:
        - externalPort: 5432
          protocol: TCP
          containerPort: 5432
```

## Dedicated Load Balancer (Per-GVC)

Creates a dedicated load balancer in each GVC location, enabling features unavailable with the shared LB: custom ports on domains, wildcard hostnames, accept-all-hosts, and redirect rules.

```yaml
spec:
  loadBalancer:
    dedicated: true
    trustedProxies: 1
    multiZone:
      enabled: true
    redirect:
      class:
        status5xx: https://error.example.com
        status401: https://auth.example.com/login?return_to=%REQ(:path)%
    ipSet: //ipset/my-gvc-ips
```

### Fields

| Field | Type | Default | Valid Values | Description |
|---|---|---|---|---|
| `dedicated` | boolean | `false` | `true`, `false` | Enable dedicated LB per location |
| `trustedProxies` | integer | `0` | `0`, `1`, `2` | How to determine client IP (see below) |
| `multiZone.enabled` | boolean | `false` | `true`, `false` | Cross-zone load balancing (extra charges) |
| `ipSet` | string | - | IP set link | Reference to IP set for static IPs |
| `redirect.class.status5xx` | string | - | Valid URI | Redirect URL for 500-level errors |
| `redirect.class.status401` | string | - | String | Redirect for 401; supports Envoy format strings |

### Trusted Proxies

Controls the IP used for request logging and the `X-Envoy-External-Address` header.

| Value | Behavior |
|---|---|
| `0` | Use source client IP address (default) |
| `1` | Use last address in `X-Forwarded-For` header |
| `2` | Use second-to-last address in `X-Forwarded-For` header |

### Attach Static IPs via IP Set

Both the GVC and IP set must reference each other (bidirectional):

**GVC:** set `spec.loadBalancer.dedicated: true` and `spec.loadBalancer.ipSet: //ipset/my-gvc-ips`.

**IP Set:** set `spec.link: //gvc/my-gvc` with the matching `locations[]`.

## Common Patterns

- **Static IPs for partner allowlisting:** create an IP set linked to the workload or GVC → configure the direct or dedicated LB → poll `get_resource` (kind="ipset") until each `status.ipAddresses[].state` is `bound` → share those IPs → keep `retentionPolicy: keep` so IPs don't change.
- **Non-HTTP service exposure** (databases, game servers, custom protocols): a direct LB with `protocol: TCP`/`UDP` ports (see the direct LB example above).
- **Consistent IPs across a GVC:** a dedicated LB with an IP set at the GVC level — all workloads share the same static IPs per location.

## Quick Reference

### MCP Tools

| Tool | Purpose |
|---|---|
| `mcp__cpln__create_ipset` | Create an IP set with optional `link` (workload/GVC) and `locations[]` (`name`, `retentionPolicy`). |
| `mcp__cpln__list_resources` (kind="ipset") | List all IP sets with locations, retention policies, and allocated IPs (read-only). |
| `mcp__cpln__get_resource` (kind="ipset") | Inspect one IP set: bound link, locations, retention, allocated IPs (`bound`/`unbound`), status. |
| `mcp__cpln__add_ipset_location` | Add new locations or overwrite the retentionPolicy of existing ones (use `free` to release an IP). |
| `mcp__cpln__remove_ipset_location` | Drop one or more locations from the IP set entirely (DESTRUCTIVE). |
| `mcp__cpln__update_ipset` | Edit description, tags, or bound workload/GVC link; pass `removeLink: true` to detach. |
| `mcp__cpln__delete_resource` (kind="ipset") | Delete an IP set, releasing every reserved IP (DESTRUCTIVE — confirm blast radius first). |

Location names accept friendly names (`"frankfurt"`, `"tel aviv"`), location IDs (`"aws-us-west-2"`), or full links (`"//location/aws-us-west-2"`) — the MCP server resolves them automatically.

Configure a **workload's** load balancer (direct, geo headers, replicaDirect) with `mcp__cpln__configure_workload_load_balancer`. A **GVC-level dedicated** LB is a GVC setting — enable `spec.loadBalancer.dedicated` with `mcp__cpln__update_gvc` (or `cpln apply`).

### Example: create an IP set bound to a workload

```json
{
  "name": "my-static-ips",
  "link": "//gvc/my-gvc/workload/my-workload",
  "locations": [
    { "name": "aws-us-west-2", "retentionPolicy": "keep" },
    { "name": "frankfurt", "retentionPolicy": "keep" }
  ]
}
```

### Related Skills

- **cpln-workload** — Start here: the primary workload skill (types, defaults, spec shape) that routes here for load balancers & static IPs.
- **cpln-firewall-networking** — Firewall rules, CIDR filtering, and load balancer type overview
- **cpln-workload-security** — Direct load balancer security, JWT auth, mTLS
- **cpln-native-networking** — PrivateLink, Private Service Connect, agent-based connectivity
- **cpln-stateful-storage** — Replica direct addressing for stateful workloads

## Documentation

- [IP Set Reference](https://docs.controlplane.com/reference/ipset.md)
- [Load Balancing Reference](https://docs.controlplane.com/reference/workload/load-balancing.md)
- [GVC Reference (Dedicated LB)](https://docs.controlplane.com/reference/gvc.md)
- [Domain Reference](https://docs.controlplane.com/reference/domain.md)
