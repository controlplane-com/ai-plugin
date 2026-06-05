---
name: firewall-networking
description: "Configures firewall rules and service-to-service communication on Control Plane. Use when the user asks about inbound/outbound rules, CIDR whitelisting, IP blocking, hostname filtering, geo-blocking, header-based routing, internal endpoints, or network security. Covers external/internal firewall configuration, geo-filtering, header matching, and service mesh connectivity."
---

# Firewall & Networking Patterns

Deep firewall rules for `spec.firewallConfig`. The deny-by-default summary, the LB picker, internal DNS, and which tool sets `firewallConfig` vs `loadBalancer` live in the `workload` skill — this skill is the detail.

**Precedence (both inbound and outbound):** blocked CIDRs beat allowed CIDRs; when both CIDR and hostname allow-lists are set, CIDR rules beat hostname rules.

## External Firewall Rules

### Inbound (internet → workload)

Allow all (`0.0.0.0/0`), or list specific CIDRs, and block CIDRs that override the allow-list:
```yaml
firewallConfig:
  external:
    inboundAllowCIDR:
      - 0.0.0.0/0           # or specific: 203.0.113.0/24, 198.51.100.10/32
    inboundBlockedCIDR:
      - 192.0.2.0/24        # blocked wins over allowed
```

### Outbound (workload → internet)

CIDR allow/block (CIDR-based allows all ports):
```yaml
firewallConfig:
  external:
    outboundAllowCIDR:
      - 0.0.0.0/0
    outboundBlockedCIDR:
      - 10.0.0.0/8          # blocked wins over allowed
```

Hostname allow-list (wildcard prefix supported). **Hostname rules only allow ports 80, 443, and 445 by default** — widen with `outboundAllowPort`:
```yaml
firewallConfig:
  external:
    outboundAllowHostname:
      - api.stripe.com
      - "*.amazonaws.com"
```

### Outbound Port Control

`outboundAllowPort` restricts which ports are allowed (protocols: `http`, `https`, `tcp`):
```yaml
firewallConfig:
  external:
    outboundAllowCIDR:
      - 203.0.113.0/24
    outboundAllowPort:
      - protocol: tcp
        number: 5432
      - protocol: https
        number: 8443
```

### Header-Based Filtering (Inbound HTTP)

Each filter matches a header `key` with either `allowedValues` (allow-list) or `blockedValues` (block-list) — **never both on the same filter**. Combine multiple filters, each on a different key:
```yaml
firewallConfig:
  external:
    inboundAllowCIDR:
      - 0.0.0.0/0
    http:
      inboundHeaderFilter:
        - key: x-api-version       # allow-list: reject everything else for this header
          allowedValues:
            - "^v2$"
        - key: user-agent          # block-list: allow everything else
          blockedValues:
            - "^BadBot.*$"
            - "^Scraper.*$"
```

**Header filter values are RE2 regular expressions.** Use `^...$` to match whole strings; a bare substring matches partially (`^bar$` vs. `bar` which also matches `barbell`). When multiple values are listed, the filter matches if **any** value matches — not all.

### Geo-Filtering (Country / Region / City)

**Two-step setup:** enable geo headers on the load balancer with custom header names, then filter on those names in `inboundHeaderFilter`:
```yaml
spec:
  loadBalancer:
    geoLocation:
      enabled: true
      headers:
        country: x-country
        region: x-region
        city: x-city
        asn: x-asn
  firewallConfig:
    external:
      inboundAllowCIDR:
        - 0.0.0.0/0
      http:
        inboundHeaderFilter:
          - key: x-country
            allowedValues:
              - United States
              - Canada
```

- You choose the header names; the workload receives the resolved values on each request.
- At least one of `asn`, `city`, `country`, or `region` must be configured; header names must be **unique** per type.
- Geo filtering only affects workloads with an HTTP port; no effect on TCP-only workloads.

## Internal Firewall (Workload-to-Workload)

`inboundAllowType` is one of `none`, `same-gvc`, `same-org`, `workload-list`. For `workload-list`, name the allowed workloads (cross-GVC supported):
```yaml
firewallConfig:
  internal:
    inboundAllowType: workload-list   # or: none, same-gvc, same-org
    inboundAllowWorkload:
      - //gvc/my-gvc/workload/frontend
      - //gvc/other-gvc/workload/backend
```

## Service-to-Service Communication

Internal DNS form: `http://WORKLOAD.GVC.cpln.local:PORT` (plain HTTP — the sidecar adds mTLS automatically, never `https://`):
```bash
curl http://api-service.my-gvc.cpln.local:8080/health      # same-GVC: free, low latency
curl http://shared-service.other-gvc.cpln.local:3000/data  # cross-GVC: needs same-org, egress charges
```

## Load Balancers (Summary)

| Type | Scope | Custom Ports | Static IPs | Wildcard Hosts |
|---|---|---|---|---|
| Default (shared) | All workloads | No (HTTP/HTTPS on 80/443) | No | No |
| Direct | Per-workload | Yes (TCP/UDP/HTTP/HTTPS/WS) | Via IP Set | No |
| Dedicated | Per-GVC | Yes | Via IP Set | Yes |

Minimal Direct LB (custom TCP port, per workload):
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

Full LB config, static IP reservation, and dedicated LB setup: see the **cpln-ipset-load-balancing** skill.

## Quick Reference

### Recommended: MCP

`firewallConfig` (and `loadBalancer`) live in the workload spec — patch them with the typed workload tools:

1. `mcp__cpln__get_workload` — read current `spec.firewallConfig` / `spec.loadBalancer` for a rollback baseline (`update_workload` is PATCH — only sent fields change).
2. `mcp__cpln__update_workload` — set `firewallConfig` (external inbound/outbound, internal, header filters). Load balancer is separate: `mcp__cpln__configure_workload_load_balancer`.
3. `mcp__cpln__get_workload_deployments` — poll until ready; rules apply within about a minute and trigger a new deployment.

Use `mcp__cpln__create_workload` to stand up a new workload with firewall rules from the start. Reserve static IPs for Direct/Dedicated LBs with `mcp__cpln__create_ipset` / `mcp__cpln__get_ipset` (see **cpln-ipset-load-balancing**).

### Fallback: CLI

When MCP is unavailable or unauthenticated, edit the manifest and apply it. Ground the spec shape with `mcp__cpln__get_resource_schema` (or `cpln workload --help`) first:
```bash
cpln workload get WORKLOAD_NAME --gvc GVC_NAME -o yaml > workload.yaml
# edit spec.firewallConfig in workload.yaml
cpln apply --file workload.yaml --gvc GVC_NAME
```

### MCP Tools

| Tool | Purpose |
|---|---|
| `mcp__cpln__get_workload` | Inspect current `spec.firewallConfig` and `spec.loadBalancer` before changing them. |
| `mcp__cpln__update_workload` | Patch `firewallConfig` on an existing workload (PATCH — only sent fields change). |
| `mcp__cpln__configure_workload_load_balancer` | Set/clear the workload load balancer (direct, geo headers, replicaDirect). |
| `mcp__cpln__create_workload` | Create a new workload with firewall rules from the start (load balancer is set separately). |
| `mcp__cpln__create_ipset` / `mcp__cpln__get_ipset` | Reserve and inspect static public IPs for Direct/Dedicated load balancers and IP allow-lists. |
| `mcp__cpln__get_workload_deployments` | Poll deployment readiness after a firewall change lands. |
| `mcp__cpln__get_workload_logs` | Query workload logs to diagnose connectivity issues. |

### Related Skills

- **cpln-workload** — Start here: the primary workload skill (types, defaults, spec shape) that routes here for firewall & exposure.
- **cpln-cdn-rate-limiting** — CDN setup, caching policies, and rate limiting configuration
- **cpln-ipset-load-balancing** — Static IP reservation, Direct and Dedicated load balancer configuration, and domain routing
- **cpln-native-networking** — PrivateLink, Private Service Connect, and agent-based private connectivity
- **cpln-workload-security** — JWT authentication, mTLS, and direct load balancer security configuration

## Documentation

- [Firewall Reference](https://docs.controlplane.com/reference/workload/firewall.md)
- [Load Balancing Reference](https://docs.controlplane.com/reference/workload/load-balancing.md)
- [Service-to-Service Guide](https://docs.controlplane.com/guides/service-to-service.md)
- [GVC Reference](https://docs.controlplane.com/reference/gvc.md)
