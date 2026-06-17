---
name: ipset-load-balancing
description: "Static IPs and load balancers on Control Plane. Use when the user asks about IP sets, fixed IPs, direct or dedicated load balancers, exposing raw TCP/UDP ports, IP allowlisting, geo headers, or egress IPs."
---

# IP Sets & Load Balancing

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

An IP set reserves one static public IPv4 address per location and attaches it to a **direct** (per-workload) or **dedicated** (per-GVC) load balancer. The linking is bidirectional, and the recurring failure is configuring only one side: the IP set's `spec.link` must point at the workload/GVC AND that target's load balancer must reference the IP set back — otherwise addresses sit `unbound` and the IP set carries `status.warning: Cross-link misconfiguration`. The `workload` skill is primary for the LB-type picker and routing basics; this skill carries the full configuration.

## Load balancer types

| Type | Scope | What it adds | Cost |
|---|---|---|---|
| Default (shared) | every workload | HTTP/HTTPS on 80/443, nothing to configure | included |
| Direct | one workload | raw TCP/UDP on external ports 22-32768, static IPs, TLS passthrough | charged while enabled |
| Dedicated | whole GVC | domain custom ports and TCP routing, wildcard and accept-all hosts, redirects, trusted proxies, static IPs | per location (multiZone adds cross-zone charges) |

Toggling the `direct` block (workload) or `dedicated` flag (GVC) requires the **`configureLoadBalancer` permission** on that resource — `edit` does not imply it (403 "Not allowed to change loadBalancer configuration"); `manage` covers it.

## IP sets

```yaml
kind: ipset
name: partner-ips
spec:
  link: //gvc/GVC/workload/WORKLOAD   # or //gvc/GVC for a dedicated LB
  locations:
    - name: //location/aws-us-west-2
      retentionPolicy: keep           # keep | free
```

How allocation actually works:

- **IPs are allocated in the locations of the linked GVC** (for a workload link, the workload's GVC). No `spec.link`, no allocation — `spec.locations` alone does nothing.
- `spec.locations` pins a per-location `retentionPolicy`; unlisted locations behave as `keep` while in the GVC. Workload links require the GVC segment — `//workload/WORKLOAD` without it is rejected.
- `keep` (default) allocates eagerly and holds the IP through unlinking, GVC location removal, and target deletion (state drops to `unbound`, billing continues until the IP set is deleted). `free` allocates only while bound and releases once the location leaves the GVC or the link/target goes away.
- **Flipping `keep` to `free` does not release an IP whose location is still active in the GVC.** To stop charges: detach the binding (`update_ipset` with `removeLink: true`) so `free` locations release, then delete the IP set to release the rest.
- `state: bound` means both sides point at each other; `unbound` means allocated but unused. Delete is **blocked with 400 while any address is bound** — remove the back-link first. Re-adding a location later does NOT return the same IP.
- Supported on AWS (Elastic IP), GCP (static external address, STANDARD network tier), and Azure (static public IPv4), including BYOK on those clouds. Other providers fail with `status.error` "provider not configured to use IpSets"; cloud IP-quota errors also land in `status.error`.

## Direct load balancer (per workload)

One cloud L4 load balancer per location running the workload, with `externalTrafficPolicy: Local` so the client IP reaches the workload. No TLS termination — the workload owns its certificates. No domain registration needed: each location's address is published on the workload's canonical endpoint DNS with latency-based geo routing, and `status.canonicalEndpoint` switches to the **first** port's `scheme://HOST:externalPort`. Custom hostnames can CNAME to that endpoint. Inbound firewall CIDRs still apply — they become cloud-level source ranges on the LB.

```yaml
spec:
  loadBalancer:
    direct:
      enabled: true
      ipSet: //ipset/partner-ips   # optional static IPs; that IP set must link back to this workload
      ports:
        - externalPort: 5432       # 22-32768
          protocol: TCP            # TCP or UDP
          containerPort: 5432      # plain number 80-65535; reserved: 8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000
        - externalPort: 443
          protocol: TCP
          scheme: https            # display-only (http|tcp|https|ws|wss): sets the URL scheme shown in UI/status
```

Set with `mcp__cpln__configure_workload_load_balancer` — it replaces the whole `spec.loadBalancer` block (`remove: true` clears it) and rolls a new deployment (about a minute).

### Geo location headers (`spec.loadBalancer.geoLocation`)

Injects MaxMind GeoLite2 client-location headers on inbound HTTP requests — works with any LB type, no effect on non-HTTP ports. Set `enabled: true` plus `headers` naming at least one of `asn`/`city`/`country`/`region` (names unique, max 128 chars each). Matching client-sent headers are replaced, so apps can trust the values; the country header carries the two-letter ISO code. Filtering on these headers (geo blocking) lives in the `firewall-networking` skill.

### Replica direct (`spec.loadBalancer.replicaDirect: true`)

Stateful workloads only (rejected for other types, including `vm`), capped by a separate quota of **6 replicas per workload**. Each replica becomes addressable as `replica-INDEX.` on the workload's endpoints; internal names appear in `status.replicaInternalNames`. Per-replica custom-domain routing is in the `domain` skill; replica identities and database patterns in `stateful-storage`.

## Dedicated load balancer (per GVC)

A GVC setting — set with `mcp__cpln__update_gvc` (the `loadBalancer` object is replaced wholesale):

```yaml
spec:
  loadBalancer:
    dedicated: true
    ipSet: //ipset/gvc-ips         # optional; that IP set must link back to //gvc/GVC
    trustedProxies: 0              # 0 (default) source client IP | 1 last X-Forwarded-For address | 2 second-to-last; sets the logged IP and X-Envoy-External-Address
    multiZone: { enabled: false }  # cross-zone load balancing, extra charges
    redirect:
      class:
        status5xx: https://errors.example.com   # any 500-level response (must be a valid URI)
        status401: https://auth.example.com/login?return_to=%REQ(:path)%   # supports Envoy format strings
```

Required before domains can use custom ports or the TCP protocol (without it those deploy as warnings and never route) and for wildcard / accept-all hosts — details in the `domain` skill. Enabling or disabling it can cause a brief connectivity blip while DNS propagates. Its access logs are queryable as `{gvc="GVC", workload="_loadbalancer"}`.

## Verify

- `mcp__cpln__get_resource` (kind="ipset") — every `status.ipAddresses[].state` is `bound`, and no `status.warning` (cross-link) or `status.error` (provider/quota). Share the `ip` values only once bound.
- `mcp__cpln__list_deployments` — all locations ready after an LB change; the workload's `status.canonicalEndpoint` reflects the direct-LB scheme and port.
- CLI fallback (CI/CD): `CPLN_TOKEN` + `cpln ipset get NAME --org ORG -o yaml`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| IPs stay `unbound`, warning `Cross-link misconfiguration: /org/...` | Only one side is linked — the object named in the warning points here without a matching `spec.link` (or vice versa); configure both sides |
| No IPs allocated at all | `spec.link` missing (locations alone allocate nothing), or the linked GVC has no locations |
| Delete fails 400 "one or more ip addresses are bound" | Remove the workload/GVC back-link or pass `removeLink: true` to `update_ipset`, wait for `unbound`, delete again |
| Still billed after setting `free` | The location is still active in the GVC — `free` releases only when it leaves the GVC or the IP set is unlinked |
| `status.error` "provider not configured to use IpSets" | That location's cloud has no IP-set support (AWS, GCP, Azure only — including BYOK on them) |
| `status.error` AddressLimitExceeded / QUOTA_EXCEEDED / PublicIPCountLimitReached | Cloud-account IP quota exhausted in that region — request an increase from the provider |
| 403 "not granted [configureLoadBalancer]" | Toggling direct/dedicated needs that permission — `edit` alone is not enough |
| API rejects `containerPort` | It is a plain number (80-65535 minus reserved ports); the docs' `containerPort: {port: N}` object form is wrong |
| Deploy warning "TCP access can only be restricted to specific ip addresses when using a custom domain and the GVC has dedicated loadBalancer enabled" | Inbound CIDR rules on a TCP port need the dedicated LB (custom domain) or a direct LB — the shared LB cannot enforce them |

## Quick reference

| Tool | Purpose |
|---|---|
| `mcp__cpln__create_ipset` | Create with optional `link` and `locations[]` (`retentionPolicy` defaults to `keep`); friendly location names resolve server-side |
| `mcp__cpln__update_ipset` | Description, tags, replace `link`, or `removeLink: true` to detach |
| `mcp__cpln__add_ipset_location` | Add locations or overwrite an existing location's `retentionPolicy` |
| `mcp__cpln__remove_ipset_location` | Drop location entries (releases only IPs whose location is no longer active in the GVC) |
| `mcp__cpln__list_resources` / `mcp__cpln__get_resource` / `mcp__cpln__delete_resource` (kind="ipset") | Read, and delete (releases every IP; blocked while bound) |
| `mcp__cpln__configure_workload_load_balancer` | Workload side: `direct`, `geoLocation`, `replicaDirect` (`remove: true` clears) |
| `mcp__cpln__update_gvc` | GVC side: `loadBalancer` (dedicated, ipSet, trustedProxies, multiZone, redirect) |

CLI fallback: `cpln ipset create --name NAME --link LINK --location LOC,POLICY`, plus `add-location` / `update-location` / `remove-location REF --location ...` and `get` / `delete`. `cpln gvc update --set` cannot reach `spec.loadBalancer` — use `cpln gvc edit` or `cpln apply`.

### Related skills

- **workload** — the primary skill: LB-type picker, container ports, endpoints, the `configure_workload_*` tools.
- **domain** — custom domains, custom ports and TCP routes on the dedicated LB, per-replica routing.
- **firewall-networking** — inbound/outbound CIDR rules, header filtering on geo headers.
- **workload-security** — TLS on the workload behind a direct LB, JWT auth, mTLS.
- **stateful-storage** — replica identities and replica-direct with databases.

## Documentation

- [IP Set Reference](https://docs.controlplane.com/reference/ipset.md)
- [Load Balancing Reference](https://docs.controlplane.com/reference/workload/load-balancing.md)
- [GVC Reference (Dedicated LB)](https://docs.controlplane.com/reference/gvc.md)
- [Domain Reference](https://docs.controlplane.com/reference/domain.md)
