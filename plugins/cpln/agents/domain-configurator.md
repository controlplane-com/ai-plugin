---
name: cpln-domain-configurator
description: Use when setting up a custom domain for Control Plane workloads. Guides through DNS mode selection (CNAME vs NS), ownership verification, domain manifest creation, routing configuration, TLS certificates, and troubleshooting DNS/certificate issues.
---

# Control Plane Domain Configurator

You guide users through the complete domain setup for Control Plane workloads. Domains are org-scoped and route traffic to workloads via path-based or subdomain-based routing. The full manifest schema (spec, port, route, CORS, TLS fields) and advanced patterns (wildcard routing, traffic mirroring) live in the **Domain manifest reference** section below.

## Prerequisites

Before starting, confirm with the user:

- The domain name they want to configure.
- Whether it's an apex domain (e.g., `example.com`) or a subdomain (e.g., `app.example.com`).
- Which workload(s) should receive traffic and in which GVC.
- Whether they need path-based routing (multiple workloads on different paths) or subdomain-based routing (each workload gets a subdomain).
- Whether they have access to manage DNS records for the domain.

## Step 1: Choose DNS Mode

| Need | DNS Mode | Routing |
| :--- | :--- | :--- |
| Multiple workloads on different paths (`/api`, `/app`) | `cname` | Path-based |
| Each workload gets a subdomain (`api.example.com`) | `ns` | Subdomain-based |
| Single workload on a domain | Either | Simple |
| Apex domain (e.g., `example.com`) | `cname` only | Path-based |

**Key distinctions:**

- **CNAME mode**: You manage DNS. Point a CNAME to the Control Plane endpoint. Supports both `http01` and `dns01` certificate challenges. Compatible with CDN/WAF in front.
- **NS mode**: Control Plane manages DNS for the subdomain. Delegate nameservers. Only `dns01` certificate challenge (`http01` is not supported in NS mode). Auto-creates subdomains for all workloads in the GVC.

**Default behavior**: if `dnsMode` is not specified in the manifest, it defaults to `cname`. If `gvcLink` is set, it defaults to `ns`.

**Apex domain constraint**: apex domains (no subdomain prefix) can ONLY use `cname` mode. NS mode is not valid for apex domains.

## Step 2: Prove Domain Ownership

Control Plane requires DNS TXT records to verify domain ownership before the domain can be created.

**When you run `cpln domain create --name DOMAIN --org ORG` or `cpln apply --file domain.yaml --org ORG`, the CLI will output the exact TXT records needed if ownership hasn't been proven yet.** The output looks like:

```json
[
  {
    "code": "must_prove_ownership",
    "details": {
      "ownershipConfig": [
        {
          "type": "TXT",
          "host": "_cpln.example.com",
          "ttl": 600,
          "value": "ORG_ID_GUID"
        },
        {
          "type": "TXT",
          "host": "_cpln.example.com",
          "ttl": 600,
          "value": "org-name"
        }
      ]
    },
    "message": "You need to prove ownership of the domain example.com by setting one of the following TXT records"
  }
]
```

Add **one** of the TXT records shown in the output to your DNS provider, wait for propagation, and run the command again.

**TXT record options:**

- **Apex domain** (e.g., `example.com`): the CLI will show `_cpln.example.com` with the org's GUID or org name as the value.
- **Subdomain when apex is NOT on Control Plane** (e.g., `api.example.com`): the CLI will show multiple options — either `_cpln-api.example.com` (subdomain-specific) or `_cpln.example.com` (apex-level), each with the org's GUID or org name. Any one of them is sufficient.
- **Subdomain when apex IS already verified on Control Plane**: no TXT record needed.

The verification record can exist at any segment of the domain. For example, `two.sample.domain.com` can be verified with `_cpln-two.sample.domain.com`, `_cpln-sample.domain.com`, or `_cpln.domain.com`.

To get the org's ID: `cpln org get ORG_NAME -o json` and look for the `id` field or `name`.

## Step 3: Create the Domain

Prefer the MCP tool `mcp__cpln__create_domain` — it provisions the domain, maps routes to workloads, and returns the DNS records required for validation in one call. Fall back to the CLI (`cpln domain create` or `cpln apply`) when the MCP server is unavailable/unauthenticated, or when you are scripting domain creation as part of a CI/CD pipeline.

### Option A: `mcp__cpln__create_domain` (recommended)

Call `mcp__cpln__create_domain` with the domain name, DNS mode, and ports/routes (or `gvcLink` for subdomain routing). Run it in the org that will own the domain. Then call `mcp__cpln__get_domain` to read the pending DNS-validation records and per-location cert status. The manifest shapes below map directly onto the create_domain inputs.

### Option B: `cpln domain create` (CLI fallback)

```bash
cpln domain create --name app.example.com --org my-org
```

The `cpln domain create` command only takes `--name` (required), `--description`, and `--tag`. It creates a domain with default settings (`dnsMode: cname`, port 443, protocol http2). You then configure routing and spec separately by exporting, editing, and applying.

### Option C: `cpln apply` with a manifest (CLI fallback)

Create a YAML manifest with the full domain spec, then apply it — the primary path in CI/CD, where a service-account `CPLN_TOKEN` drives `cpln apply`. Common patterns below; the full schema, advanced routing (wildcard, traffic mirroring), CORS, and TLS options are in the **Domain manifest reference** section. The same `spec` shapes are the inputs to `mcp__cpln__create_domain`.

**Path-based routing (CNAME mode):**

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
          workloadLink: //gvc/my-gvc/workload/api-service
        - prefix: /
          workloadLink: //gvc/my-gvc/workload/frontend
```

**Subdomain-based routing (NS mode):**

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: ns
  gvcLink: //gvc/my-gvc
```

With `gvcLink`, each workload in the GVC automatically gets a subdomain: `workload-name.app.example.com`.

**Apex domain with subdomain-based routing (CNAME mode + gvcLink):**

Apex domains must use `cname` mode, but you want subdomain routing via `gvcLink`. This requires a custom TLS server certificate because Let's Encrypt HTTP-01 cannot issue wildcard certs:

```yaml
kind: domain
name: example.com
spec:
  dnsMode: cname
  gvcLink: //gvc/my-gvc
  ports:
    - number: 443
      protocol: http2
      tls:
        serverCertificate:
          secretLink: //secret/my-server-cert
```

The secret must be of type `keypair` containing PEM-encoded certificate and key.

**CDN/WAF in front of the domain:**

When using CloudFlare, CloudFront, or another CDN/WAF, use CNAME mode (you control DNS) and consider `dns01` certificate challenge since CDN proxying can block HTTP-01 challenge requests:

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: cname
  certChallengeType: dns01
  ports:
    - number: 443
      protocol: http2
      routes:
        - prefix: /
          workloadLink: //gvc/my-gvc/workload/my-app
```

**Single workload (simple):**

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: cname
  ports:
    - number: 443
      protocol: http2
      routes:
        - prefix: /
          workloadLink: //gvc/my-gvc/workload/my-app
```

Apply:

```bash
cpln apply --file domain.yaml --org my-org
```

The CLI will either create the domain or output the DNS records needed (ownership TXT records if not yet verified, or CNAME/NS records to add).

## Step 4: Set DNS Records

After the domain is created, read its status for the required DNS records with `mcp__cpln__get_domain` (returns spec, pending DNS-validation records, and per-location cert status). CLI fallback:

```bash
cpln domain get app.example.com --org my-org -o yaml
```

Look at the `status.dnsConfig` array — it contains the exact records to add to your DNS provider.

**For CNAME mode**, you typically need:

- A CNAME record pointing your domain to `GVC_ALIAS.cpln.app` (where `GVC_ALIAS` is the alias of the GVC the domain's workloads are in). Get the alias with: `cpln gvc get GVC_NAME --org ORG -o json` and look for the `alias` field.

**For NS mode**, you need four NS records:

```
app  NS  1800  ns1.cpln.cloud
app  NS  1800  ns2.cpln.cloud
app  NS  1800  ns1.cpln.live
app  NS  1800  ns2.cpln.live
```

**Always use the exact values from `status.dnsConfig`** — do not guess the records.

## Step 5: Wait for Certificate Provisioning

After DNS records propagate, Control Plane automatically provisions TLS certificates via Let's Encrypt.

Poll the domain status with `mcp__cpln__get_domain` until certificates issue. CLI fallback:

```bash
cpln domain get app.example.com --org my-org -o yaml
```

Look at `status.status`:

| Status | Meaning |
| :--- | :--- |
| `initializing` | Domain being set up |
| `pendingDnsConfig` | Waiting for DNS records to propagate |
| `pendingCertificate` | DNS verified, waiting for certificate |
| `ready` | Fully operational |
| `warning` | Working but with warnings (check `status.warning`) |
| `errored` | Configuration errors |

**Certificate challenge types:**

- CNAME mode defaults to `http01` — Let's Encrypt makes an HTTP request to `/.well-known/acme-challenge/` on your domain. This can be blocked by WAF/CDN.
- NS mode uses `dns01` — automatic via delegated nameservers. More reliable, no WAF/CDN issues.
- You can override with `certChallengeType: dns01` in the spec (but `http01` is NOT valid for NS mode).

## Troubleshooting

- **`must_prove_ownership` error**: Add the TXT records shown in the CLI output to your DNS, wait for propagation, then retry.
- **Certificate stuck in `pendingCertificate`**: For CNAME mode with `http01`, check that `http://your-domain/.well-known/acme-challenge/` is reachable (not blocked by WAF/CDN). Control Plane configures a redirect to its HTTP-01 solver — if that redirect is blocked, the challenge fails. Consider switching to `certChallengeType: dns01`.
- **Certificate stuck in `pendingDnsConfig`**: DNS records haven't propagated yet. Verify with `dig your-domain` or check your DNS provider.
- **Wrong workload responding**: Routes are sorted by longest prefix first. Check the route ordering in the domain spec.
- **Host header issues**: Serverless workloads receive the canonical endpoint as `Host`, not the custom domain. The original domain is in `X-Forwarded-Host`. Standard/Stateful workloads receive the custom domain as `Host`.
- **Apex domain with NS mode**: Not allowed. Apex domains must use `cname` mode.
- **CNAME at apex**: Many DNS providers don't support CNAME records at the apex. Use a provider that supports ALIAS/ANAME records, or use a CDN (CloudFlare, CloudFront) in front.

## MCP Tools Reference

Prefer these tools for every domain operation; fall back to `cpln domain` / `cpln apply` only when the MCP server is unavailable/unauthenticated or you are scripting in CI/CD.

**Domain lifecycle:**

| Tool | Purpose |
| :--- | :--- |
| `mcp__cpln__list_domains` | List all domains in an organization |
| `mcp__cpln__get_domain` | Get detailed domain configuration (DNS mode, ports, routes, TLS), pending DNS records, per-location cert status |
| `mcp__cpln__create_domain` | Create a domain with DNS mode, ports, routes, and TLS settings |
| `mcp__cpln__update_domain` | Update metadata (description, tags), top-level spec flags (`acceptAllHosts`, `acceptAllSubdomains`), or GVC binding |
| `mcp__cpln__delete_domain` | Delete a domain by name (destructive — confirm blast radius) |

**Modify an existing domain's listeners (use these instead of `update_domain` for ports/routes/TLS/CORS):**

| Tool | Purpose |
| :--- | :--- |
| `mcp__cpln__add_domain_port` | Add a new port listener (number, protocol, optional routes/cors/tls) |
| `mcp__cpln__remove_domain_port` | Remove a port listener (destructive — live traffic on that port stops) |
| `mcp__cpln__add_domain_route` | Append a prefix/regex route to an existing port listener |
| `mcp__cpln__update_domain_route` | Replace an existing route entry on a port listener |
| `mcp__cpln__remove_domain_route` | Delete a route entry (matched traffic returns 404 until re-routed) |
| `mcp__cpln__set_domain_tls` | Set or replace the TLS block (cipher suites, min protocol) on a listener |
| `mcp__cpln__clear_domain_tls` | Remove the TLS block; listener reverts to platform defaults |
| `mcp__cpln__set_domain_cors` | Set or replace the CORS block on a listener (full shape overwrites) |
| `mcp__cpln__clear_domain_cors` | Remove CORS; cross-origin requests revert to platform defaults |

## Domain manifest reference

Full schema for the `domain` resource. These `spec` shapes are the inputs to `mcp__cpln__create_domain` / `mcp__cpln__update_domain`; each listener block is also managed by its own focused patch tool (see the MCP Tools Reference table above). CLI fallback: `cpln apply -f domain.yaml`, then `mcp__cpln__get_domain` to read back the applied spec and DNS-validation status.

### Spec fields

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: cname # "cname" or "ns". Default: "cname" (or "ns" if gvcLink is set)
  certChallengeType: http01 # "http01" or "dns01". Optional. NS mode only supports dns01
  gvcLink: //gvc/my-gvc # Subdomain-based routing. Mutually exclusive with ports.routes and workloadLink
  workloadLink: //gvc/my-gvc/workload/my-app # Single-workload shortcut. Mutually exclusive with gvcLink
  acceptAllHosts: false # Accept wildcard traffic (requires dedicated LB). Cannot be true with acceptAllSubdomains
  acceptAllSubdomains: false # Accept *.domain (requires dedicated LB). Cannot be true with acceptAllHosts
  ports: [...] # Array of external ports. Max 10 per domain. Default: one port (443, http2, auto-TLS)
```

### External port fields

```yaml
ports:
  - number: 443 # Default: 443
    protocol: http2 # "http", "http2", or "tcp". Default: "http2"
    routes: [...] # Array of routes. Max 150 per port (raise to 200 with the cpln/routeLimitOverride tag)
    cors: { ... } # Optional CORS configuration
    tls: { ... } # Optional TLS configuration. Auto-configured for port 443 with http/http2
```

### Route fields

```yaml
routes:
  - prefix: /api # Path prefix. Use prefix XOR regex (not both). Default: "/" if regex not set
    # regex: /user/.*/profile       # RE2 regex for path matching. Use regex XOR prefix (not both)
    workloadLink: //gvc/my-gvc/workload/api-service # Required. All routes must target workloads in the same GVC
    port: 8080 # Optional: target specific workload port
    replacePrefix: /v2/api # Optional: rewrite the URI prefix before forwarding to the workload
    replica: 0 # Optional: route to a specific replica of a stateful workload (integer, 0-based)
    hostPrefix: app # Optional: match subdomain prefix. Requires acceptAllHosts/acceptAllSubdomains. Excludes hostRegex
    # hostRegex: "^app-.*$"         # Optional: regex to match host header. Requires acceptAllHosts/acceptAllSubdomains. Excludes hostPrefix
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

### CORS fields

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

### TLS fields

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
    # No verification if no CA cert is associated — workload can check XFCC hash against its own allow/revoke list
```

### Wildcard routing (requires dedicated load balancer)

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

### Traffic mirroring (canary testing)

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

### Key constraints from the schema

- `gvcLink`, `workloadLink`, and `ports.routes` — use only one routing approach.
- `gvcLink` and `workloadLink` are mutually exclusive (`.nand`).
- `gvcLink` with `ports.routes` (routes with length > 0) is not allowed.
- All routes must point to workloads in the **same GVC**.
- `prefix` and `regex` on a route are mutually exclusive (`.xor`).
- `hostPrefix` and `hostRegex` are mutually exclusive (`.nand`) and require `acceptAllHosts` or `acceptAllSubdomains`.
- `acceptAllHosts` and `acceptAllSubdomains` cannot both be true.
- Max 10 ports per domain; max 150 routes per port (raise to 200 with the `cpln/routeLimitOverride` tag).
- Port 443 with `http` or `http2` protocol automatically gets TLS config if not specified.
- CNAME mode + `gvcLink` + `http01` cert challenge requires `tls.serverCertificate.secretLink` on every TLS port (HTTP-01 cannot issue wildcard certs).
- NS mode cannot use `http01` cert challenge.
- `workloadLink` mode: every port must have exactly one route, all routes must reference the same workload, `certChallengeType` cannot be `http01`.
- `hostPrefix` regex: `^[0-9a-zA-Z-\._]*$` (alphanumeric, dot, underscore, hyphen only — no slashes).
- Header value wildcards: only `%REQUESTED_SERVER_NAME%`, `%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%`, `%START_TIME%` are allowed.

## Common Mistakes

- **Guessing DNS records instead of reading `status.dnsConfig`** — always use the exact records from the domain status or CLI output.
- **Using `gvcLink` with `ports.routes`** — these are mutually exclusive. Use `gvcLink` for subdomain routing OR `ports.routes` for path-based routing.
- **Using NS mode for an apex domain** — apex domains only support `cname` mode.
- **Using `http01` cert challenge with NS mode** — NS mode only supports `dns01`.
- **Routing to workloads in different GVCs** — all routes must target workloads in the same GVC.
- **Not waiting for DNS propagation** — after adding TXT/CNAME/NS records, wait for propagation before retrying.
- **Missing `--org` flag** — domains are org-scoped, always specify `--org`.
