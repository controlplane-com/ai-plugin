---
name: cpln-ipset-load-balancing
description: "Reserves static IP addresses and configures load balancers on Control Plane. Use when the user asks about IP sets, static IPs, dedicated load balancers, direct load balancers, fixed IPs, IP whitelisting, or egress IPs. Covers IP set reservation, direct load balancers (per-workload), and GVC dedicated load balancers."
version: 1.0.0
---

# IP Sets & Load Balancing

## Load Balancer Types

| Type             | Scope         |  Custom Ports  | Static IPs | Wildcard Hosts | Protocols                      | Extra Cost |
| :--------------- | :------------ | :------------: | :--------: | :------------: | :----------------------------- | :--------: |
| Default (shared) | All workloads |       No       |     No     |       No       | HTTP/HTTPS only                |     No     |
| Direct           | Per-workload  | Yes (22-32768) | Via IP Set |       No       | TCP, UDP, HTTP, HTTPS, WS, WSS |    Yes     |
| Dedicated        | Per-GVC       |      Yes       | Via IP Set |      Yes       | All (via Domains)              |    Yes     |

- **Default (shared):** Standard load balancer used by all workloads. No configuration needed. HTTP/HTTPS on ports 80/443 only.
- **Direct:** Per-workload load balancer with custom port mappings, Geo DNS routing, and optional static IPs. Customer manages TLS certificates.
- **Dedicated:** Per-GVC load balancer enabling custom ports on domains, wildcard hostnames, accept-all-hosts, and redirect rules.

## IP Sets

An IP set reserves a **static public IP address in each location** of a GVC. Use IP sets when external partners need to allowlist your IPs, or compliance requires fixed egress addresses.

### How IP Sets Work

1. Create an IP set with target locations and a link to a workload or GVC
2. The target workload/GVC must link back to the IP set (bidirectional)
3. Control Plane allocates one public IP per location
4. IPs persist across deployments as long as `retentionPolicy: keep`

### IP Set Spec

| Field                              | Type   | Required | Description                                                                  |
| :--------------------------------- | :----- | :------: | :--------------------------------------------------------------------------- |
| `spec.link`                        | string |    No    | Resource link to workload (`//gvc/NAME/workload/NAME`) or GVC (`//gvc/NAME`) |
| `spec.locations[].name`            | string |   Yes    | Location reference (e.g., `//location/aws-us-west-2`)                        |
| `spec.locations[].retentionPolicy` | string |   Yes    | `keep` (retain IP) or `free` (release IP)                                    |

**Status fields:** `status.ipAddresses[]` contains `name` (location), `ip` (public IP), `id` (cloud allocation ID), `state` (`bound` or `unbound`), and `created` (ISO 8601).

### Create an IP Set

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

Apply with `cpln apply -f ipset.yaml --org MY_ORG`.

### Release an IP

Set `retentionPolicy: free` to release an allocated IP and stop charges:

```yaml
spec:
  locations:
    - name: //location/aws-us-west-2
      retentionPolicy: free
```

An IP address is not released until it is no longer in use (no linked workload, GVC location not active).

### CLI Commands

```bash
# Create
cpln ipset create --name my-ips --link //gvc/my-gvc \
  --location aws-us-west-2,keep --location aws-eu-west-1,keep --org MY_ORG

# View allocated IPs
cpln ipset get my-ips --org MY_ORG -o yaml

# Add a location
cpln ipset add-location my-ips --location aws-ap-southeast-1,keep --org MY_ORG

# Update retention policy
cpln ipset update-location my-ips --location aws-us-west-2,free --org MY_ORG

# Remove a location
cpln ipset remove-location my-ips --location aws-ap-southeast-1 --org MY_ORG

# Delete
cpln ipset delete my-ips --org MY_ORG
```

**Location format:** `location-name,retention-policy` (default retention: `keep`).

## Direct Load Balancer (Per-Workload)

Creates a load balancer in each location where the workload runs. Provides Geo DNS with latency-based routing across locations. No domain registration required.

### Configuration

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
        - externalPort: 80
          protocol: TCP
          scheme: http
          containerPort: 8080
        - externalPort: 9000
          protocol: UDP
          containerPort: 9000
```

### Port Configuration

| Field           | Type    | Required | Constraints                         | Description                                   |
| :-------------- | :------ | :------: | :---------------------------------- | :-------------------------------------------- |
| `externalPort`  | integer |   Yes    | 22-32768                            | Publicly exposed port                         |
| `protocol`      | string  |   Yes    | `TCP` or `UDP`                      | Transport protocol                            |
| `scheme`        | string  |    No    | `http`, `tcp`, `https`, `ws`, `wss` | Overrides default `https` for UI/status links |
| `containerPort` | integer |    No    | 80-65535                            | Container listening port                      |

**Reserved container ports** (cannot be used): 8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000.

### Attach Static IPs via IP Set

Both the workload and the IP set must reference each other:

**Workload:**

```yaml
spec:
  loadBalancer:
    direct:
      enabled: true
      ipSet: //ipset/my-static-ips
      ports:
        - externalPort: 443
          protocol: TCP
          containerPort: 8443
```

**IP Set:**

```yaml
kind: ipset
name: my-static-ips
spec:
  link: //gvc/my-gvc/workload/my-workload
  locations:
    - name: //location/aws-us-west-2
      retentionPolicy: keep
```

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

- Requires at least one header when enabled
- All header names must be unique
- Only works on workloads exposing an HTTP port
- Header name max length: 128 characters

### Replica Direct (Stateful Workloads)

Address individual replicas via subdomain `replica-<index>`:

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

Only valid for `type: stateful` workloads.

## Dedicated Load Balancer (Per-GVC)

Creates a dedicated load balancer in each GVC location. Enables features unavailable with the shared load balancer: custom ports on domains, wildcard hostnames, accept-all-hosts, and redirect rules.

### Configuration

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

| Field                      | Type    | Default | Valid Values    | Description                                     |
| :------------------------- | :------ | :-----: | :-------------- | :---------------------------------------------- |
| `dedicated`                | boolean | `false` | `true`, `false` | Enable dedicated LB per location                |
| `trustedProxies`           | integer |   `0`   | `0`, `1`, `2`   | How to determine client IP (see below)          |
| `multiZone.enabled`        | boolean | `false` | `true`, `false` | Cross-zone load balancing (extra charges)       |
| `ipSet`                    | string  |    -    | IP set link     | Reference to IP set for static IPs              |
| `redirect.class.status5xx` | string  |    -    | Valid URI       | Redirect URL for 500-level errors               |
| `redirect.class.status401` | string  |    -    | String          | Redirect for 401; supports Envoy format strings |

### Trusted Proxies

| Value | Behavior                                               |
| :---: | :----------------------------------------------------- |
|  `0`  | Use source client IP address (default)                 |
|  `1`  | Use last address in `X-Forwarded-For` header           |
|  `2`  | Use second-to-last address in `X-Forwarded-For` header |

Controls the IP used for request logging and the `X-Envoy-External-Address` header.

### Attach Static IPs via IP Set

Both the GVC and IP set must reference each other:

**GVC:**

```yaml
kind: gvc
name: my-gvc
spec:
  loadBalancer:
    dedicated: true
    ipSet: //ipset/my-gvc-ips
```

**IP Set:**

```yaml
kind: ipset
name: my-gvc-ips
spec:
  link: //gvc/my-gvc
  locations:
    - name: //location/aws-us-west-2
      retentionPolicy: keep
```

## Common Patterns

### Static IPs for Partner Allowlisting

Partners require fixed IPs to allowlist your service:

1. Create an IP set linked to the workload or GVC
2. Configure the direct or dedicated load balancer
3. Share the allocated IPs from `status.ipAddresses`
4. Use `retentionPolicy: keep` to prevent IP changes

### Non-HTTP Service Exposure

Expose TCP/UDP services (databases, game servers, custom protocols):

```yaml
spec:
  loadBalancer:
    direct:
      enabled: true
      ports:
        - externalPort: 5432
          protocol: TCP
          containerPort: 5432
```

### Consistent IPs Across a GVC

Use a dedicated load balancer with an IP set at the GVC level — all workloads share the same static IPs per location.

## Quick Reference

### MCP Tools

| Tool                              | Purpose                                                                                             |
| :-------------------------------- | :-------------------------------------------------------------------------------------------------- |
| `mcp__cpln__create_ipset`         | Create an IP set with optional `link` (workload/GVC) and `locations[]` (`name`, `retentionPolicy`). |
| `mcp__cpln__add_ipset_location`   | Add new locations or overwrite the retentionPolicy of existing ones (use `free` to release an IP).  |
| `mcp__cpln__remove_ipset_location`| Drop one or more locations from the IP set entirely.                                                |

Location names accept friendly names (`"frankfurt"`, `"tel aviv"`), location IDs (`"aws-us-west-2"`), or full links (`"//location/aws-us-west-2"`). The MCP server resolves friendly names automatically.

For load balancer configuration (direct/dedicated), edit the workload or GVC spec — there are no dedicated load-balancer MCP tools. Use `mcp__cpln__update_workload` / `mcp__cpln__update_gvc`, `cpln apply`, or the CLI.

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

### Example: release an IP without dropping the location record

```json
{
  "ipsetName": "my-static-ips",
  "locations": [
    { "name": "aws-us-west-2", "retentionPolicy": "free" }
  ]
}
```

### Related Skills

- **cpln-firewall-networking** — Firewall rules, CIDR filtering, and load balancer type overview
- **cpln-workload-security** — Direct load balancer security, JWT auth, mTLS
- **cpln-native-networking** — PrivateLink, Private Service Connect, agent-based connectivity
- **cpln-stateful-storage** — Replica direct addressing for stateful workloads

## Documentation

For the latest reference, see:

- [IP Set Reference](https://docs.controlplane.com/reference/ipset.md)
- [Load Balancing Reference](https://docs.controlplane.com/reference/workload/load-balancing.md)
- [GVC Reference (Dedicated LB)](https://docs.controlplane.com/reference/gvc.md)
- [Domain Reference](https://docs.controlplane.com/reference/domain.md)
