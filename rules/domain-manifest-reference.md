---
description: Validation constraints for Control Plane domain manifests. Consult when generating or modifying domain YAML to avoid creation/update failures.
alwaysApply: false
---

# Domain Manifest Validation Reference

Guardrails for generating correct domain manifests. For full field details, inspect an existing domain with `cpln domain get DOMAIN -o yaml`.

## Complete Domain YAML Structure

```yaml
kind: domain
name: sub.example.com                  # must be a valid domain name with TLD
spec:
  dnsMode: cname                       # "cname" or "ns"
  certChallengeType: http01            # "http01" or "dns01"
  gvcLink: //gvc/my-gvc               # subdomain routing — xor with ports.routes and workloadLink
  workloadLink: //gvc/my-gvc/workload/my-wl  # replica-direct — xor with gvcLink
  acceptAllHosts: false                # requires dedicated LB on GVC
  acceptAllSubdomains: false           # cannot combine with acceptAllHosts
  ports:                               # max 10 ports, default: one port 443/http2
    - number: 443                      # default 443
      protocol: http2                  # "http", "http2", or "tcp" (tcp requires dedicated LB)
      tls:
        minProtocolVersion: TLSV1_2    # TLSV1_0, TLSV1_1, TLSV1_2 (default), TLSV1_3
        cipherSuites:
          - ECDHE-ECDSA-AES256-GCM-SHA384
        clientCertificate:
          secretLink: //secret/client-ca  # keypair secret type
        serverCertificate:
          secretLink: //secret/server-cert  # keypair secret type, PEM encoded
      cors:                            # CORS is a port-level field, sibling of tls
        allowCredentials: true
        maxAge: 24h                    # regex: ^[\d\.]+[hms]+$
        allowOrigins:
          - exact: https://example.com
          - regex: "https://.*\\.example\\.com"
        allowMethods: [GET, POST]
        allowHeaders: [authorization]  # auto-lowercased
        exposeHeaders: [x-custom]      # auto-lowercased
      routes:                          # max 150 per port (200 with tag override)
        - prefix: /api/               # xor with regex, regex: ^\/[0-9a-zA-Z-\._~\/]*$
          replacePrefix: /v2/api/     # not supported with regex routes
          workloadLink: //gvc/my-gvc/workload/api-service  # required
          port: 8080                  # target port on workload
          hostPrefix: app             # requires acceptAllHosts or acceptAllSubdomains
          replica: 0                  # for stateful workloads only
          headers:
            request:
              set:
                X-Client-IP: "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%"
          mirror:
            - workloadLink: //gvc/my-gvc/workload/api-v2
              percent: 50             # 0-100, required
              port: 8080              # optional: target port on mirrored workload
```

## DNS Modes

### CNAME Mode (`dnsMode: cname`)

- Control Plane does NOT manage DNS — you create CNAME records pointing to cpln.app
- Supports `certChallengeType: http01` or `dns01`
- Required for apex domains (e.g., `example.com`)
- When using `gvcLink` (subdomain routing) with `http01`, a custom `serverCertificate` is required on all TLS ports

### NS Mode (`dnsMode: ns`)

- Control Plane manages subdomains and DNS records
- You add NS records pointing to `ns1.cpln.cloud`, `ns2.cpln.cloud`, `ns1.cpln.live`, `ns2.cpln.live`
- Only supports `certChallengeType: dns01` — `http01` is **NOT allowed**
- Cannot be used for apex domains

## Route Configuration

- Each route requires a `workloadLink` — format: `//gvc/GVC/workload/WORKLOAD`
- `prefix` and `regex` are mutually exclusive (xor)
- `hostPrefix` and `hostRegex` are mutually exclusive (nand)
- `hostPrefix`/`hostRegex` only active when `acceptAllHosts` or `acceptAllSubdomains` is true
- `replacePrefix` does NOT work with regex routes
- Routes are auto-sorted by prefix length (longest first) unless any regex route exists
- The `/` prefix matches all unmatched paths — placed last automatically
- All routes in a domain must reference workloads in the same GVC
- Header wildcards: `%REQUESTED_SERVER_NAME%`, `%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%`, `%START_TIME%`

## Port Configuration

- Default: port 443, protocol http2, TLS auto-configured
- Max 10 ports per domain
- Protocols: `http`, `http2` (default), `tcp` (requires dedicated LB on GVC)
- Non-standard ports (not 443/80) require dedicated LB enabled on the GVC
- Excluded ports (dedicated LB): 8012, 8022, 9090, 9091, 15000, 15001, 15006, 15020, 15021, 15090, 41000

## TLS Settings

- Default min version: `TLSV1_2`
- Valid versions: `TLSV1_0`, `TLSV1_1`, `TLSV1_2`, `TLSV1_3`
- Port 443 auto-provisions TLS certificate if no `serverCertificate` is set (for http/http2 protocol)
- Custom certificates use `keypair` secret type with PEM content
- Auto-provisioned certs are Let's Encrypt, valid 90 days, renewed every 60 days

## Workload Link (Replica Direct)

- `workloadLink` and `gvcLink` are mutually exclusive (nand)
- When `workloadLink` is set: `certChallengeType` cannot be `http01`
- Every port must have exactly 1 route
- All routes must reference the same workload as the domain `workloadLink`

## Wildcard Support

- `acceptAllHosts` and `acceptAllSubdomains` cannot both be true
- At most one domain per GVC should use `acceptAllHosts`
- These settings require dedicated LB on the GVC

## Common Validation Errors

| Error | Fix |
|:---|:---|
| Apex domain with NS mode | Apex domains (e.g., `example.com`) can only use `dnsMode: cname` |
| NS mode with http01 challenge | NS mode only supports `dns01` challenge type |
| Both gvcLink and routes set | Use `gvcLink` for subdomain routing OR `ports.routes` for path routing, not both |
| Both gvcLink and workloadLink | These are mutually exclusive — use one or the other |
| CNAME + gvcLink + no serverCert | When using `cname` + `gvcLink` + `http01`, all TLS ports need `serverCertificate` |
| Routes exceed 150 limit | Max 150 routes per port (also max 150 routes per domain) |
| Both prefix and regex on route | Each route uses prefix OR regex, not both |
| Both hostPrefix and hostRegex | These are mutually exclusive on each route |
| hostPrefix without wildcard | Set `acceptAllHosts` or `acceptAllSubdomains` to true |
| Both acceptAllHosts and acceptAllSubdomains | Only one can be true |
| Routes span multiple GVCs | All routes must reference workloads in a single GVC |
| workloadLink with multiple routes per port | Each port must have exactly 1 route when `workloadLink` is set |

## Example: CNAME Domain with Path Routing

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: cname
  ports:
    - number: 443
      protocol: http2
      routes:
        - prefix: /api/
          workloadLink: //gvc/production/workload/api-service
          port: 8080
        - prefix: /
          workloadLink: //gvc/production/workload/web-app
          port: 3000
```

## Example: NS Domain with Subdomain Routing

```yaml
kind: domain
name: apps.example.com
spec:
  dnsMode: ns
  certChallengeType: dns01
  gvcLink: //gvc/production
```

## Example: Multi-Route Domain with CORS and Headers

```yaml
kind: domain
name: api.example.com
spec:
  dnsMode: cname
  certChallengeType: http01
  ports:
    - number: 443
      protocol: http2
      cors:
        allowOrigins:
          - exact: https://frontend.example.com
        allowMethods: [GET, POST, PUT, DELETE]
        allowHeaders: [authorization, content-type]
        maxAge: 24h
        allowCredentials: true
      routes:
        - prefix: /v2/
          workloadLink: //gvc/production/workload/api-v2
          port: 8080
          headers:
            request:
              set:
                X-Api-Version: "2"
        - prefix: /v1/
          replacePrefix: /
          workloadLink: //gvc/production/workload/api-v1
          port: 8080
        - prefix: /
          workloadLink: //gvc/production/workload/web-app
```

## MCP Tools

| Tool | Purpose |
|:---|:---|
| `mcp__cpln__list_domains` | List all domains in an organization |
| `mcp__cpln__get_domain` | Get detailed domain configuration (DNS mode, ports, routes, TLS) |
| `mcp__cpln__create_domain` | Create a domain with DNS mode, ports, routes, and TLS settings |
| `mcp__cpln__update_domain` | Update domain description, tags, or spec fields (partial patch) |
| `mcp__cpln__delete_domain` | Delete a domain by name |
