---
name: firewall-networking
description: "Firewall rules and service-to-service communication on Control Plane. Use when the user asks about inbound/outbound rules, CIDR whitelisting, IP blocking, hostname filtering, geo-blocking, header routing, internal endpoints, or network security."
---

# Firewall & Networking

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Deep detail for `spec.firewallConfig` and the enforcement model behind it; the `workload` skill owns the summary (deny-by-default, exposure decided at create time, LB picker). Set `firewallConfig` with `create_workload` / `update_workload` — or `public: true`, the shortcut that opens inbound AND outbound to `0.0.0.0/0` (mutually exclusive with an explicit `firewallConfig`). A firewall change creates a new deployment version — a rolling replace, live in about a minute (`vm` workloads are the exception: firewall updates apply in place without restarting the VM).

## How rules are enforced

**Inbound** is checked per request at the mesh sidecar. It counts as fully open only when `inboundAllowCIDR` contains the literal `0.0.0.0/0` AND `inboundBlockedCIDR` is empty; anything else is allow-list mode. Blocked beats allowed; a bare IP means /32. Header and geo filters apply to HTTP traffic only — `tcp`-protocol ports are CIDR-filtered at the connection level instead.

**Outbound** has two separate paths, which is why CIDR rules beat hostname rules:

- **CIDR path** — traffic to `outboundAllowCIDR` ranges bypasses the sidecar and exits directly, on ALL ports unless `outboundAllowPort` is set.
- **Hostname path** — everything else transits the sidecar, which only admits `outboundAllowHostname` entries, matched by Host header (HTTP) or TLS SNI, on ports 80, 443, and 445 (SMB) by default.
- `outboundBlockedCIDR` is subtracted at the network layer and beats both paths — an allowed hostname that resolves into a blocked range still fails.
- Outbound is fully open only with the literal `0.0.0.0/0` in `outboundAllowCIDR`.

## External inbound

```yaml
firewallConfig:
  external:
    inboundAllowCIDR:        # max 250 entries; deduped and sorted on save
      - 0.0.0.0/0            # or specific: 203.0.113.0/24, 198.51.100.10
    inboundBlockedCIDR:      # no max; wins over the allow list
      - 192.0.2.0/24
```

## External outbound

```yaml
firewallConfig:
  external:
    outboundAllowCIDR:
      - 198.51.100.0/24      # all ports open to this range while outboundAllowPort is unset
    outboundAllowHostname:   # lowercase; single wildcard on the prefix only; max 128 chars
      - api.stripe.com
      - "*.amazonaws.com"
    outboundBlockedCIDR:
      - 203.0.113.7
```

Source-verified traps:

- **`outboundAllowPort` REPLACES the hostname defaults 80/443/445** — re-list 80 and 443 if you still need them. It also restricts the CIDR path to the listed ports. `protocol` is required (`http`, `https`, or `tcp` — how the proxy treats the port); `number` must be 80 to 65000 and not platform-reserved (8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000).
- **Ports below 80 (22, 25, 53) cannot be listed.** To reach a low port, allow the CIDR and leave `outboundAllowPort` unset — the CIDR path then opens all ports.
- **Private ranges are silently stripped from `outboundAllowCIDR` on managed locations** (10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, 100.64/10, IPv6 ULA): allowing them does nothing, with no error. Reaching a VPC or datacenter takes a wormhole agent (`native-networking`). BYOK clusters keep private ranges.

## Header filters (inbound, HTTP only)

Each filter names a header `key` (max 128 chars) plus exactly ONE of `allowedValues` or `blockedValues` — RE2 regexes; anchor with `^...$` (a bare `bar` also matches `barbell`).

```yaml
firewallConfig:
  external:
    inboundAllowCIDR: [0.0.0.0/0]
    http:
      inboundHeaderFilter:
        - key: x-api-version
          allowedValues: ["^v2$"]
        - key: user-agent
          blockedValues: ["^BadBot.*", "^Scraper.*"]
```

Matching is OR across everything: a request is rejected if ANY `blockedValues` pattern matches (checked first), and — once at least one allow filter exists — admitted only if ANY `allowedValues` pattern matches. Two allow filters on different headers are alternatives, not both-required; a request missing the header fails its allow filter. **Mesh-internal traffic (10.0.0.0/8 sources) bypasses header filters entirely** — test from outside, not from another workload.

## Geo filtering (country / region / city / ASN)

Two steps: enable geo headers on the workload load balancer (you pick the header names), then filter on those names:

```yaml
spec:
  loadBalancer:
    geoLocation:
      enabled: true
      headers:               # at least one; names unique; values overwrite client-sent headers
        country: x-country
  firewallConfig:
    external:
      inboundAllowCIDR: [0.0.0.0/0]
      http:
        inboundHeaderFilter:
          - key: x-country
            allowedValues: ["^US$", "^CA$"]
```

The proxy resolves values from MaxMind GeoLite2 on each request: `country` is the two-letter ISO code (`US`, never `United States`), `region` the subdivision code, `city` the English city name, `asn` the AS number. Echo the headers from the app once before writing filters. HTTP ports only.

## Internal firewall (workload to workload)

`internal.inboundAllowType`: `none` (default), `same-gvc`, `same-org`, or `workload-list`. The admitted identity is the calling workload itself — all its replicas.

```yaml
firewallConfig:
  internal:
    inboundAllowType: workload-list
    inboundAllowWorkload:
      - //gvc/GVC/workload/frontend      # GVC segment REQUIRED; //workload/NAME is rejected
      - /org/ORG/gvc/OTHER-GVC/workload/backend
      - cpln://internal/keda             # required when a KEDA trigger source is a CP workload
      - //agent/DC-AGENT                 # inbound from behind a wormhole agent (native-networking)
```

- `inboundAllowWorkload` is honored under `same-gvc` too — add specific cross-GVC callers without going `same-org`.
- Links are validated for shape only, never existence — a typo silently denies the caller.
- Internal calls use `http://WORKLOAD.GVC.cpln.local:PORT` (the container port) — plain `http://`, the sidecar adds mTLS. Cross-GVC calls may span locations and then incur egress charges.

## Load balancers (summary)

| Type | Scope | Ports | Static IPs | Wildcard hosts |
|---|---|---|---|---|
| Shared (default) | all workloads | HTTP/HTTPS on 80/443 | no | no |
| Direct | per workload | TCP/UDP, externalPort 22 to 32768 | via IP set | no |
| Dedicated | per GVC (`update_gvc`) | custom domain ports/protocols | via IP set | yes |

```yaml
spec:
  loadBalancer:
    direct:
      enabled: true
      ports:
        - externalPort: 5432   # 22 to 32768
          protocol: TCP        # TCP or UDP
          containerPort: 5432
```

Direct LB does not terminate TLS (the workload owns its certificates), and its traffic still passes the inbound CIDR rules. `geoLocation` and `replicaDirect` (stateful only) also live under `spec.loadBalancer`. Dedicated LB is a GVC setting (`loadBalancer.dedicated: true`, charged per location) that also carries `trustedProxies` (0 to 2 — which X-Forwarded-For hop counts as the client IP for logging) and a GVC-level `ipSet`. Static IPs and full LB detail: `ipset-load-balancing`.

## Verify

1. `mcp__cpln__get_resource` (kind="workload") — read `spec.firewallConfig` before changing it, and send the COMPLETE desired `firewallConfig` on update (it replaces as a unit, not field-by-field).
2. `mcp__cpln__list_deployments` — wait for the new version to report ready in every location.
3. Probe: inbound with `curl` from an allowed and a blocked vantage; outbound from inside via `mcp__cpln__workload_exec` running `curl -sv https://HOST`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Outbound to a VPC/private IP fails though its CIDR is allowed | Private ranges are stripped on managed locations — use a wormhole agent (`native-networking`) |
| Hostname egress broke after adding `outboundAllowPort` | The list replaced 80/443/445 — add 80/443 back |
| Need outbound to port 22/25/53 | Below the allowed 80-65000 range — allow the CIDR and leave `outboundAllowPort` unset |
| Header/geo filter not enforced in tests | Testing from another workload (10.0.0.0/8 bypasses header filters), or the port is `tcp` protocol (filters are HTTP-only) |
| Geo allow-list blocks everyone | Values are ISO codes (`^US$`) — full country names never match; echo the header to confirm |
| `workload-list` caller still denied | Link is missing the GVC segment, or has a typo (existence is never validated) |
| KEDA scaler cannot reach its workload trigger source | Add `cpln://internal/keda` to that workload's `inboundAllowWorkload` |
| Firewall seems ignored for one container | `runAsUser: 1337` escapes the mesh and its firewall (see `workload`) |

## Quick reference

| Tool | Purpose |
|---|---|
| `mcp__cpln__update_workload` | Patch `firewallConfig` (send it complete) or `public` |
| `mcp__cpln__create_workload` | Decide exposure in the create call: `public: true` or an explicit `firewallConfig` |
| `mcp__cpln__configure_workload_load_balancer` | Set `spec.loadBalancer` (direct, geo headers, replicaDirect); `remove: true` clears it |
| `mcp__cpln__update_gvc` | Dedicated LB, `trustedProxies`, GVC-level `ipSet` |
| `mcp__cpln__get_resource` (kind="workload") / `mcp__cpln__list_deployments` | Read back config; confirm the rollout |
| `mcp__cpln__workload_exec` | In-pod curl to test outbound rules |

CLI fallback (no MCP, or CI/CD with `CPLN_TOKEN`): `cpln workload get WORKLOAD --gvc GVC -o yaml > w.yaml`, edit `spec.firewallConfig`, then `cpln apply --file w.yaml --gvc GVC`.

## Related skills

- **workload** — start here: types, spec shape, exposure defaults, internal DNS, LB picker
- **ipset-load-balancing** — static IPs, direct/dedicated LB detail, replicaDirect
- **native-networking** — wormhole agents, PrivateLink/PSC: the answer for private-network traffic
- **cdn-rate-limiting** — CDN in front of workloads, rate limiting
- **workload-security** — JWT authentication, mTLS hardening, direct-LB security

## Documentation

- [Firewall Reference](https://docs.controlplane.com/reference/workload/firewall.md)
- [Load Balancing Reference](https://docs.controlplane.com/reference/workload/load-balancing.md)
- [Service-to-Service Guide](https://docs.controlplane.com/guides/service-to-service.md)
