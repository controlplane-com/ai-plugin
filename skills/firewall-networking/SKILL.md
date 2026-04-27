---
name: cpln-firewall-networking
description: "Configures firewall rules and service-to-service communication on Control Plane. Use when the user asks about inbound/outbound rules, CIDR whitelisting, IP blocking, hostname filtering, geo-blocking, header-based routing, internal endpoints, or network security. Covers external/internal firewall configuration, geo-filtering, header matching, and service mesh connectivity."
version: 1.0.0
---

# Firewall & Networking Patterns

## Firewall Defaults

Everything is blocked by default:
- **External inbound** (internet → workload): Disabled
- **External outbound** (workload → internet): Disabled
- **Internal** (workload → workload): `none` — no communication

## External Firewall Rules

### Inbound (internet to workload)

Allow all internet traffic:
```yaml
firewallConfig:
  external:
    inboundAllowCIDR:
      - 0.0.0.0/0
```

Allow specific IPs only:
```yaml
firewallConfig:
  external:
    inboundAllowCIDR:
      - 203.0.113.0/24
      - 198.51.100.10/32
```

Block specific IPs while allowing others:
```yaml
firewallConfig:
  external:
    inboundAllowCIDR:
      - 0.0.0.0/0
    inboundBlockedCIDR:
      - 192.0.2.0/24
```

**Blocked always takes precedence over allowed.**

### Outbound (workload to internet)

Allow all outbound:
```yaml
firewallConfig:
  external:
    outboundAllowCIDR:
      - 0.0.0.0/0
```

Allow specific hostnames:
```yaml
firewallConfig:
  external:
    outboundAllowHostname:
      - api.stripe.com
      - hooks.slack.com
      - "*.amazonaws.com"   # Wildcard prefix supported
```

**Hostname-based rules only allow ports 80, 443, and 445 by default.** Use `outboundAllowPort` to customize.

Block specific outbound destinations:
```yaml
firewallConfig:
  external:
    outboundAllowCIDR:
      - 0.0.0.0/0
    outboundBlockedCIDR:
      - 10.0.0.0/8
```

**Blocked always takes precedence over allowed** (same as inbound). When both CIDR and hostname allow-lists are set, **CIDR rules take precedence over hostname rules**.

### Outbound Port Control

By default, hostname-based outbound allows ports 80, 443, and 445. CIDR-based outbound allows all ports. Use `outboundAllowPort` to restrict:
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

Supported protocols: `http`, `https`, `tcp`.

### Header-Based Filtering (Inbound HTTP)

Filter inbound HTTP requests by headers. Each filter matches a header `key` with either `allowedValues` (allow-list) or `blockedValues` (block-list) — **never both on the same filter**.

Allow only specific header values (reject everything else for that header):
```yaml
firewallConfig:
  external:
    inboundAllowCIDR:
      - 0.0.0.0/0
    http:
      inboundHeaderFilter:
        - key: x-api-key
          allowedValues:
            - "^valid-key-.*$"
```

Block specific header values (allow everything else):
```yaml
firewallConfig:
  external:
    inboundAllowCIDR:
      - 0.0.0.0/0
    http:
      inboundHeaderFilter:
        - key: user-agent
          blockedValues:
            - "^BadBot.*$"
            - "^Scraper.*$"
```

Multiple filters can be combined (each on a different header key):
```yaml
firewallConfig:
  external:
    inboundAllowCIDR:
      - 0.0.0.0/0
    http:
      inboundHeaderFilter:
        - key: x-api-version
          allowedValues:
            - "^v2$"
        - key: user-agent
          blockedValues:
            - "^BadBot.*$"
```

**Header filter values are RE2 regular expressions.** Use `^...$` to match whole strings; bare substrings match partially (e.g., `^bar$` vs. `bar` which also matches `barbell`). When multiple allow or deny values are listed, the filter matches if **any** value matches — not all.

### Geo-Filtering (Country / Region / City)

Geo-filtering is a **two-step setup**: first enable geo headers on the load balancer with custom header names, then filter on those header names in `inboundHeaderFilter`.

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

- You choose the header names (`x-country`, `X-GeoIP-Country`, etc.); the workload receives the resolved values on each incoming request.
- At least one of `asn`, `city`, `country`, or `region` must be configured.
- Header names must be **unique** per type.
- Geo filtering only affects workloads with an HTTP port; it has no effect on TCP-only workloads.

## Internal Firewall (Workload-to-Workload)

```yaml
firewallConfig:
  internal:
    inboundAllowType: same-gvc    # Options: none, same-gvc, same-org, workload-list
```

For `workload-list`, specify which workloads can communicate:
```yaml
firewallConfig:
  internal:
    inboundAllowType: workload-list
    inboundAllowWorkload:
      - //gvc/my-gvc/workload/frontend
      - //gvc/other-gvc/workload/backend  # Cross-GVC supported
```

## Service-to-Service Communication

**Internal DNS format:** `WORKLOAD_NAME.GVC_NAME.cpln.local:PORT`

```bash
# From workload in same GVC
curl http://api-service.my-gvc.cpln.local:8080/health

# Cross-GVC (requires same-org firewall)
curl http://shared-service.other-gvc.cpln.local:3000/data
```

- Same-GVC traffic: free, low latency
- Cross-GVC traffic: incurs egress charges, higher latency
- All internal traffic is automatically mTLS-encrypted

## Load Balancers (Summary)

| Type | Scope | Custom Ports | Static IPs | Wildcard Hosts |
|:---|:---|:---:|:---:|:---:|
| Default (shared) | All workloads | No (HTTP/HTTPS on 80/443) | No | No |
| Direct | Per-workload | Yes (TCP/UDP/HTTP/HTTPS/WS) | Via IP Set | No |
| Dedicated | Per-GVC | Yes | Via IP Set | Yes |

Minimal Direct LB example (custom TCP port, per workload):
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

For full load balancer configuration, static IP reservation, and dedicated LB setup, see the **cpln-ipset-load-balancing** skill.

## Quick Reference

### Recommended: CLI

Edit the workload manifest and apply it:

```bash
cpln workload get WORKLOAD_NAME --gvc GVC_NAME -o yaml > workload.yaml
# edit spec.firewallConfig in workload.yaml
cpln apply --file workload.yaml --gvc GVC_NAME
```

Rules apply within about a minute and trigger a new deployment.

## Quick Reference

### MCP Tools

| Tool | Purpose |
|:-----|:--------|
| `mcp__cpln__get_workload` | Inspect current `spec.firewallConfig` and `spec.loadBalancer`. |
| `mcp__cpln__cpln_resource_operation` | Patch `firewallConfig` / `loadBalancer` on a workload (use `kind: workload`, `operation: patch`). |
| `mcp__cpln__get_workload_logs` | Query workload logs to diagnose connectivity issues. |

### Related Skills

- **cpln-cdn-rate-limiting** — CDN setup, caching policies, and rate limiting configuration
- **cpln-ipset-load-balancing** — Static IP reservation, Direct and Dedicated load balancer configuration, and domain routing
- **cpln-native-networking** — PrivateLink, Private Service Connect, and agent-based private connectivity
- **cpln-workload-security** — JWT authentication, mTLS, and direct load balancer security configuration

## Documentation

For the latest reference, see:

- [Firewall Reference](https://docs.controlplane.com/reference/workload/firewall.md)
- [Load Balancing Reference](https://docs.controlplane.com/reference/workload/load-balancing.md)
- [Service-to-Service Guide](https://docs.controlplane.com/guides/service-to-service.md)
- [GVC Reference](https://docs.controlplane.com/reference/gvc.md)
