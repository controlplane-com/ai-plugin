# Domain Manifest Reference

Companion to `agents/domain-configurator.md`. Full schema for the `domain` resource, plus advanced patterns (wildcard routing, traffic mirroring) and key constraints. Read this when authoring or validating a domain manifest beyond the common patterns shown in the parent agent.

## Domain spec fields

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: cname # "cname" or "ns". Default: "cname" (or "ns" if gvcLink is set)
  certChallengeType: http01 # "http01" or "dns01". Optional. NS mode only supports dns01
  gvcLink: //gvc/my-gvc # For subdomain-based routing. Mutually exclusive with ports.routes and workloadLink
  workloadLink: //gvc/my-gvc/workload/my-app # Single-workload shortcut. Mutually exclusive with gvcLink
  acceptAllHosts: false # Accept wildcard traffic (requires dedicated LB). Cannot be true if acceptAllSubdomains is true
  acceptAllSubdomains: false # Accept *.domain (requires dedicated LB). Cannot be true if acceptAllHosts is true
  ports: [...] # Array of external ports. Max 10 per domain. Default: one port (443, http2, auto-TLS)
```

## External port fields

```yaml
ports:
  - number: 443 # Default: 443
    protocol: http2 # "http", "http2", or "tcp". Default: "http2"
    routes: [...] # Array of routes. Max 150 per domain
    cors: { ... } # Optional CORS configuration
    tls: { ... } # Optional TLS configuration. Auto-configured for port 443 with http/http2
```

## Route fields

```yaml
routes:
  - prefix: /api # Path prefix. Use prefix XOR regex (not both). Default: "/" if regex not set
    # regex: /user/.*/profile       # RE2 regex for path matching. Use regex XOR prefix (not both)
    workloadLink: //gvc/my-gvc/workload/api-service # Required. All routes must target workloads in the same GVC
    port: 8080 # Optional: target specific workload port
    replacePrefix: /v2/api # Optional: rewrite the URI prefix before forwarding to the workload
    replica: 0 # Optional: route to a specific replica of a stateful workload (integer, 0-based)
    hostPrefix: app # Optional: match subdomain prefix. Requires acceptAllHosts or acceptAllSubdomains. Mutually exclusive with hostRegex
    # hostRegex: "^app-.*$"         # Optional: regex to match host header. Requires acceptAllHosts or acceptAllSubdomains. Mutually exclusive with hostPrefix
    headers: # Optional: modify HTTP request headers
      request:
        set:
          X-Custom-Header: "value"
          X-Client-IP: "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%"
          X-Server-Name: "%REQUESTED_SERVER_NAME%"
          # Allowed header wildcards: %REQUESTED_SERVER_NAME%, %DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%, %START_TIME%
    mirror: # Optional: mirror traffic for canary testing
      - workloadLink: //gvc/my-gvc/workload/api-service-v2 # Must be in the same GVC
        percent: 10 # Percentage of traffic to mirror (0-100)
        port: 8080 # Optional: target port on the mirrored workload
```

## CORS fields

```yaml
cors:
  allowOrigins:
    - exact: "https://app.example.com" # Exact origin match. Use exact XOR regex per entry
    # - regex: "^https://.*\\.example\\.com$"  # RE2 regex origin match
  allowMethods: ["GET", "POST", "PUT", "DELETE"] # Optional
  allowHeaders: ["content-type", "authorization"] # Optional (lowercase)
  exposeHeaders: ["x-request-id"] # Optional (lowercase): headers the browser can access
  maxAge: "24h" # Optional: preflight cache duration. Format: digits + h/m/s (e.g., "24h", "30m")
  allowCredentials: true # Optional: allow cookies/auth headers in CORS requests
```

## TLS fields

```yaml
tls:
  minProtocolVersion: TLSV1_2 # "TLSV1_0", "TLSV1_1", "TLSV1_2", "TLSV1_3". Default: "TLSV1_2"
  cipherSuites: # Optional: override default cipher suites
    - ECDHE-ECDSA-AES256-GCM-SHA384
    - ECDHE-ECDSA-CHACHA20-POLY1305
    - ECDHE-ECDSA-AES128-GCM-SHA256
    - ECDHE-RSA-AES256-GCM-SHA384
    - ECDHE-RSA-CHACHA20-POLY1305
    - ECDHE-RSA-AES128-GCM-SHA256
    - AES256-GCM-SHA384
    - AES128-GCM-SHA256
  serverCertificate: # Optional: custom server cert instead of Let's Encrypt auto-provisioning
    secretLink: //secret/my-server-cert # Secret type must be keypair, PEM encoded
  clientCertificate: # Optional: enable client certificate verification (mTLS)
    secretLink: //secret/my-ca-cert # Secret type must be keypair, PEM encoded CA cert
    # When set, client cert details appear in the x-forwarded-client-cert (XFCC) header
    # No verification is performed if no CA cert is associated — workload can check XFCC hash against its own allow/revoke list
```

## workloadLink mode (single-workload shortcut)

When `workloadLink` is set at the spec level, every port must have exactly one route and all routes must reference that same workload. `certChallengeType` cannot be `http01` in this mode.

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: cname
  certChallengeType: dns01
  workloadLink: //gvc/my-gvc/workload/my-app
  ports:
    - number: 443
      protocol: http2
      routes:
        - prefix: /
          workloadLink: //gvc/my-gvc/workload/my-app
```

## Wildcard routing (requires dedicated load balancer)

Route traffic by subdomain using `hostPrefix` or `hostRegex`. Requires the GVC to have dedicated load balancing enabled and either `acceptAllHosts` or `acceptAllSubdomains` set to true on the domain.

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: cname
  acceptAllHosts: true
  ports:
    - number: 443
      protocol: http2
      routes:
        - prefix: /
          hostPrefix: api
          workloadLink: //gvc/my-gvc/workload/api-service
        - prefix: /
          hostPrefix: web
          workloadLink: //gvc/my-gvc/workload/web-frontend
        - prefix: /
          workloadLink: //gvc/my-gvc/workload/default-service
```

## Traffic mirroring (canary testing)

Mirror a percentage of traffic to another workload without affecting the primary response:

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: cname
  ports:
    - number: 443
      protocol: http2
      routes:
        - prefix: /api
          workloadLink: //gvc/my-gvc/workload/api-v1
          mirror:
            - workloadLink: //gvc/my-gvc/workload/api-v2
              percent: 10
              port: 8080
```

## Key constraints from the schema

- `gvcLink`, `workloadLink`, and `ports.routes` — use only one routing approach.
- `gvcLink` and `workloadLink` are mutually exclusive (`.nand`).
- `gvcLink` with `ports.routes` (routes with length > 0) is not allowed.
- All routes must point to workloads in the **same GVC**.
- `prefix` and `regex` on a route are mutually exclusive (`.xor`).
- `hostPrefix` and `hostRegex` are mutually exclusive (`.nand`) and require `acceptAllHosts` or `acceptAllSubdomains`.
- `acceptAllHosts` and `acceptAllSubdomains` cannot both be true.
- Max 10 ports per domain, max 150 routes per port (and max 150 routes per domain).
- Port 443 with `http` or `http2` protocol automatically gets TLS config if not specified.
- CNAME mode + `gvcLink` + `http01` cert challenge requires `tls.serverCertificate.secretLink` on every TLS port (HTTP-01 cannot issue wildcard certs).
- NS mode cannot use `http01` cert challenge.
- `workloadLink` mode: every port must have exactly one route, all routes must reference the same workload, `certChallengeType` cannot be `http01`.
- `hostPrefix` regex: `^[0-9a-zA-Z-\._]*$` (alphanumeric, dot, underscore, hyphen only — no slashes).
- Header value wildcards: only `%REQUESTED_SERVER_NAME%`, `%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%`, `%START_TIME%` are allowed.
