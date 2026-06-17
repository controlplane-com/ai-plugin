---
name: cpln-domain-configurator
description: Use when setting up a custom domain for Control Plane workloads. Guides through DNS mode selection (CNAME vs NS), ownership verification, domain manifest creation, routing configuration, TLS certificates, and troubleshooting DNS/certificate issues.
---

# Control Plane Domain Configurator

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

You guide users through the complete domain setup for Control Plane workloads. A `domain` is org-scoped and routes traffic to workloads in **one GVC** via path-based or subdomain-based routing. The full manifest schema (spec, port, route, CORS, TLS fields) lives in the **Domain manifest reference** section below. Custom domains are configured only through this Domain resource — never by setting `spec.domain` on a GVC; that legacy field is deprecated even though schemas still list it (a domain still referenced that way reports `status.status: usedByGvc`).

**Created ≠ live.** After the resource exists, the user still adds records at their DNS provider. Read exactly which from `status.dnsConfig` and hand them over verbatim — never guess records. Report honestly: "domain created, routes configured, DNS records pending at your provider"; never claim the domain is serving before DNS exists.

## Prerequisites

Confirm with the user before starting:

- The domain name, and whether it is an apex (`example.com`) or a subdomain (`app.example.com`).
- Which workload(s) receive traffic, their GVC, and their type (spec-level `workloadLink` works only for stateful workloads).
- Path-based routing (multiple workloads on different paths) or subdomain-based routing (each workload gets a subdomain).
- That they can manage DNS records for the domain.

## Step 1: Choose DNS Mode

| Need | DNS mode | Routing |
| :--- | :--- | :--- |
| Multiple workloads on different paths (`/api`, `/app`) | `cname` | `ports[].routes` |
| Each workload gets a subdomain (`api.example.com`) | `ns` | `gvcLink` |
| Single workload on a domain | Either | One route with `prefix: /` |
| Apex domain (`example.com`) | `cname` only | `ports[].routes` (or `gvcLink` + custom cert) |

**Key distinctions:**

- **CNAME mode**: the user manages DNS and points CNAME records at the Control Plane endpoint. Supports `http01` (default) and `dns01` certificate challenges. Compatible with a CDN/WAF in front.
- **NS mode**: Control Plane manages DNS for the subdomain zone — the user delegates it with 4 NS records. `dns01` only (`http01` is rejected). With `gvcLink`, every workload in the GVC automatically gets `{workload}.{domain}`.

**Defaults and hard rules:**

- `dnsMode` defaults to `cname`; setting `gvcLink` defaults it to `ns`.
- Apex domains can ONLY use `cname` (`cname is the only valid dnsMode for apex domain …`).
- A `cname` domain cannot be created under an existing NS domain (`parent_ns_domain_exists`) — the NS zone owns everything beneath it.
- `.internal` domains: `cname` only, no `gvcLink`, `certChallengeType` forbidden; TLS requires a custom `serverCertificate` (no ACME).

## Step 2: Prove Domain Ownership

Control Plane verifies ownership through DNS TXT records before the domain can be created. Both `mcp__cpln__create_domain` and the CLI surface the exact records when ownership has not been proven — the create fails with `must_prove_ownership` and a list like:

```json
{
  "code": "must_prove_ownership",
  "details": {
    "ownershipConfig": [
      { "type": "TXT", "host": "_cpln.example.com", "ttl": 600, "value": "ORG_ID_GUID" },
      { "type": "TXT", "host": "_cpln.example.com", "ttl": 600, "value": "ORG_NAME" }
    ]
  },
  "message": "You need to prove ownership of the domain example.com by setting one of the following TXT records"
}
```

The user adds **one** of the listed records, waits for propagation (verify with `dig TXT _cpln.example.com`), and you retry the same create.

**Accepted record forms** (the response lists them; each accepts the org GUID or the org name as value):

- Apex level: `_cpln.{apex}` or `_verify.{apex}`.
- Any segment level of a subdomain: `_cpln-{label}.{rest}` or `_verify-{label}.{rest}` — `two.sample.domain.com` can be verified at `_cpln-two.sample.domain.com`, `_cpln-sample.domain.com`, or `_cpln.domain.com`.
- **No TXT needed** when the org already owns the verified apex — subdomains attach silently.
- For `ns` subdomains, the apex domain **resource** must also already exist in the org (`apex_must_exist`).
- **Multi-org:** the apex is verified in ONE org; other orgs can still create subdomains of it with their own TXT proof. Best practice: keep the apex in the production org. (`apex_owned_by_other_org` 409 applies only to `.internal` domains, which are strictly same-org.)

## Step 3: Create the Domain

### Option A: `mcp__cpln__create_domain` (preferred)

Call it with the domain name, `dnsMode`, and `ports` — both are **required inputs**; routing comes either from `ports[].routes` or from `gvcLink` (never both). The tool pre-validates apex/exclusivity rules and, on an ownership failure, returns the TXT records to hand the user. Afterwards read the domain back with `mcp__cpln__get_resource` (kind="domain") for `status.dnsConfig` and per-location certificate status.

### Option B: `cpln domain create` (CLI)

```bash
cpln domain create --name app.example.com --org ORG
```

Takes only `--name`, `--description`, `--tag` — it creates the domain with defaults (`dnsMode: cname`, one port: 443/http2/auto-TLS). Configure routing afterwards by editing the spec (`cpln domain edit`, or get/apply as below). There is no `cpln domain update`.

### Option C: `cpln apply` with a manifest (CI/CD path)

```bash
cpln apply --file domain.yaml --org ORG
```

The same `spec` shapes are the inputs to `mcp__cpln__create_domain`. Common patterns:

**Path-based routing (CNAME mode) — the default choice, any workload type:**

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
          workloadLink: //gvc/GVC/workload/API_SERVICE
        - prefix: /
          workloadLink: //gvc/GVC/workload/FRONTEND
```

**Subdomain-based routing (NS mode):** each workload in the GVC gets `{workload}.app.example.com`.

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: ns
  gvcLink: //gvc/GVC
```

**Apex (or any CNAME domain) with subdomain routing — custom cert required.** HTTP-01 cannot issue wildcard certificates, so `cname` + `gvcLink` + `http01` demands a `keypair` secret (PEM cert + key) on every TLS port:

```yaml
kind: domain
name: example.com
spec:
  dnsMode: cname
  gvcLink: //gvc/GVC
  ports:
    - number: 443
      protocol: http2
      tls:
        serverCertificate:
          secretLink: //secret/SERVER_CERT
```

**CDN/WAF in front (Cloudflare, CloudFront):** use `cname` mode and `certChallengeType: dns01`, because the proxy can block the HTTP-01 challenge path. `dns01` on a CNAME domain adds one more record to `status.dnsConfig` — a `_acme-challenge.{host}` CNAME; without it the certificate never issues.

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
          workloadLink: //gvc/GVC/workload/APP
```

## Step 4: Set DNS Records

Read the records with `mcp__cpln__get_resource` (kind="domain") — CLI: `cpln domain get app.example.com --org ORG -o yaml` — and use `status.dnsConfig` exactly as returned.

- **CNAME mode**: a CNAME from the domain to the GVC endpoint alias. Via the MCP `get_resource`/domain tools the target comes back resolved (e.g. `0p2fpmbe7sr5c.t.cpln.app`); via `cpln domain get` the value is the literal `<gvcAlias>.t.cpln.app` placeholder — read the real alias from the GVC (`cpln gvc get GVC --org ORG -o json`, top-level field `alias`) and substitute it. Never hand the user a raw `<gvcAlias>` record. With `gvcLink`, each workload needs its own `{workload}.{domain}` CNAME to the same target; with `dns01`, add the `_acme-challenge` CNAME; with spec-level `workloadLink`, per-replica records (`{workload}-{i}-{location}`) appear too.
- **NS mode**: four NS records for the delegated label:

```
app  NS  600  ns1.cpln.cloud
app  NS  600  ns2.cpln.cloud
app  NS  600  ns1.cpln.live
app  NS  600  ns2.cpln.live
```

- **CNAME at the apex**: many providers refuse it — the user needs ALIAS/ANAME support or a CDN in front.

## Step 5: Wait for Certificate Provisioning

Certificates are provisioned automatically via Let's Encrypt once validation passes (~90-day certs, renewed automatically). Poll `mcp__cpln__get_resource` (kind="domain") and read `status.status`:

| Status | Meaning |
| :--- | :--- |
| `initializing` | Domain being set up |
| `pendingDnsConfig` | Waiting for DNS records to propagate |
| `pendingCertificate` | DNS verified, certificate issuing |
| `ready` | Fully operational |
| `usedByGvc` | Referenced by a legacy GVC `spec.domain` |
| `warning` / `errored` | Check `status.warning` for detail |

Pending states are expected, not errors. Challenge mechanics:

- `cname` defaults to `http01`: Let's Encrypt fetches `/.well-known/acme-challenge/` over plain HTTP — DNS must already resolve and the path must not be blocked by a WAF/CDN.
- `ns` always uses `dns01` (automatic via the delegated zone). Wildcard certificates exist only via `dns01`.
- Override with `certChallengeType: dns01` on `cname` domains (remember the extra `_acme-challenge` CNAME). `http01` is invalid for `ns` mode and for spec-level `workloadLink` domains.

## Troubleshooting

- **`must_prove_ownership`**: add ONE TXT record from the response, wait for propagation, retry the create.
- **`parent_ns_domain_exists`**: a CNAME domain cannot be created under an NS domain — route it inside the NS zone instead.
- **Stuck in `pendingDnsConfig`**: records not propagated — verify with `dig` against the exact `status.dnsConfig` entries.
- **Stuck in `pendingCertificate` (http01)**: run `curl -v http://DOMAIN/.well-known/acme-challenge/test` — a healthy domain 301s to `http://http01-solver.cpln.io/...`; a redirect to `https://DOMAIN/...` or a hang means a CDN/WAF is intercepting the challenge. Switch to `dns01` (and add the `_acme-challenge` CNAME).
- **`workloadLink must link to a stateful workload`**: spec-level `workloadLink` is stateful-only; route serverless/standard via `ports[].routes`.
- **Wrong workload responding**: prefix routes are auto-sorted longest-first, but regex routes are NOT sorted — check written order; duplicate prefix+host combinations are rejected outright.
- **`hostPrefix or hostRegex can only be used if …`**: set `acceptAllHosts` or `acceptAllSubdomains` — and the GVC needs dedicated load balancing for host-based routing.
- **`number of routes exceeds maximum of 150`**: consolidate, or add tag `cpln/routeLimitOverride` (raises to 200 per port).
- **Domain stuck in `warning`**: routes to a missing GVC/workload, no valid routes, a port other than 443/80 (or `tcp` protocol) without a dedicated load balancer, or an ignored `hostPrefix` — detail is in `status.warning`, and each occurrence increments the `domain_warnings` metric.
- **Host header surprises**: serverless workloads receive the canonical endpoint as `Host` (original domain in `X-Forwarded-Host`); standard/stateful receive the custom domain.

## MCP Tools Reference

Prefer these for every domain operation; fall back to `cpln domain` / `cpln apply` when MCP is unavailable or in CI/CD.

| Tool | Purpose |
| :--- | :--- |
| `mcp__cpln__list_resources` (kind="domain") | List domains in the org |
| `mcp__cpln__get_resource` (kind="domain") | Spec + `status.dnsConfig` + per-location cert status (FQDN names pass as-is) |
| `mcp__cpln__create_domain` | Create — `dnsMode` and `ports` required; surfaces ownership TXT records on failure |
| `mcp__cpln__update_domain` | Description/tags, `acceptAllHosts`/`acceptAllSubdomains`, bind or remove `gvcLink`/`workloadLink`. CANNOT touch ports, dnsMode, or certChallengeType |
| `mcp__cpln__delete_resource` (kind="domain") | Delete (destructive — confirm blast radius) |

Listener-level edits (use these instead of `update_domain` for ports/routes/TLS/CORS):

| Tool | Purpose |
| :--- | :--- |
| `mcp__cpln__add_domain_port` | Add a listener (errors if the port number already exists) |
| `mcp__cpln__remove_domain_port` | Remove a listener (destructive — live traffic on that port stops) |
| `mcp__cpln__add_domain_route` | Append a route to a port (errors if the same prefix/regex already exists) |
| `mcp__cpln__update_domain_route` | Replace a route — identified by `routeIdentifier` (`prefix` or `regex`) |
| `mcp__cpln__remove_domain_route` | Delete a route (matched traffic 404s until re-routed) |
| `mcp__cpln__set_domain_tls` / `clear_domain_tls` | Overwrite or remove the whole TLS block on a listener (443 with http/http2 reverts to the default TLS block — TLS cannot be disabled there) |
| `mcp__cpln__set_domain_cors` / `clear_domain_cors` | Overwrite or remove the whole CORS block on a listener |

## Domain manifest reference

These `spec` shapes are the inputs to `mcp__cpln__create_domain`; each listener block is also managed by its focused patch tool above. CLI fallback: `cpln apply -f domain.yaml`.

### Spec fields

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: cname # "cname" or "ns". Default: "cname" (or "ns" if gvcLink is set)
  certChallengeType: http01 # "http01" or "dns01". Optional. NS mode only supports dns01
  gvcLink: //gvc/GVC # Subdomain-based routing. Mutually exclusive with ports.routes and workloadLink
  workloadLink: //gvc/GVC/workload/APP # Replica-direct shortcut — STATEFUL workloads only (rejected otherwise; use ports.routes). Mutually exclusive with gvcLink
  acceptAllHosts: false # Accept wildcard traffic (requires dedicated LB). Cannot be true with acceptAllSubdomains
  acceptAllSubdomains: false # Accept *.domain (requires dedicated LB). Cannot be true with acceptAllHosts
  ports: [...] # Max 10. Default: one port (443, http2, auto-TLS)
```

### External port fields

```yaml
ports:
  - number: 443 # Default: 443. Ports other than 443/80 require a dedicated load balancer (deploy-time warning otherwise)
    protocol: http2 # "http", "http2", or "tcp" (tcp requires a dedicated load balancer). Default: "http2"
    routes: [...] # Max 150 per port (200 with the cpln/routeLimitOverride tag)
    cors: { ... } # Optional CORS configuration
    tls: { ... } # Optional. Auto-configured for port 443 with http/http2
```

### Route fields

```yaml
routes:
  - prefix: /api # Path prefix. prefix XOR regex. Defaults to "/" when regex is not set
    # regex: /user/.*/profile       # RE2 path match. prefix XOR regex
    workloadLink: //gvc/GVC/workload/API_SERVICE # Required. All routes must target workloads in the same GVC
    port: 8080 # Optional: target container port; defaults to the workload's first port
    replacePrefix: /v2/api # Optional: rewrite the URI prefix before forwarding
    replica: 0 # Optional: pin one replica of a stateful workload (0-based); omitted = all replicas
    hostPrefix: api # Optional subdomain match. Requires acceptAllHosts/acceptAllSubdomains + dedicated LB. Excludes hostRegex
    # hostRegex: "^api-.*$"         # RE2 host match, same requirements. Excludes hostPrefix
    headers: # Optional request-header rewrites
      request:
        set:
          X-Custom-Header: "value"
          X-Client-IP: "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%"
          # Allowed value wildcards: %REQUESTED_SERVER_NAME%, %DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%, %START_TIME%
    mirror: # Optional traffic mirroring (canary) — response comes only from the primary
      - workloadLink: //gvc/GVC/workload/API_V2 # Must be in the same GVC
        percent: 10 # Required, 0-100
        port: 8080 # Optional; defaults to the first discovered port
```

### CORS fields

```yaml
cors:
  allowOrigins:
    - exact: "https://app.example.com" # exact XOR regex per entry
    # - regex: "^https://.*\\.example\\.com$"
  allowMethods: ["GET", "POST", "PUT", "DELETE"]
  allowHeaders: ["content-type", "authorization"] # lowercased
  exposeHeaders: ["x-request-id"] # lowercased
  maxAge: "24h" # digits + h/m/s only (e.g., "24h", "30m")
  allowCredentials: true
```

### TLS fields

```yaml
tls:
  minProtocolVersion: TLSV1_2 # TLSV1_0 .. TLSV1_3. Default: TLSV1_2
  cipherSuites: # Optional override; defaults:
    - ECDHE-ECDSA-AES256-GCM-SHA384
    - ECDHE-ECDSA-CHACHA20-POLY1305
    - ECDHE-ECDSA-AES128-GCM-SHA256
    - ECDHE-RSA-AES256-GCM-SHA384
    - ECDHE-RSA-CHACHA20-POLY1305
    - ECDHE-RSA-AES128-GCM-SHA256
    - AES256-GCM-SHA384
    - AES128-GCM-SHA256
  serverCertificate: # Custom cert instead of Let's Encrypt auto-provisioning
    secretLink: //secret/SERVER_CERT # keypair secret, PEM encoded
  clientCertificate: # Enable client-certificate verification (mTLS)
    secretLink: //secret/CA_CERT # keypair secret, PEM encoded CA cert
    # Client cert details reach the workload in the x-forwarded-client-cert (XFCC) header.
    # Without a CA cert there is no verification — the workload can check the XFCC hash itself
```

### Wildcard routing (requires dedicated load balancer)

`acceptAllHosts` or `acceptAllSubdomains` on the domain, dedicated load balancing on the GVC, then host-based routes:

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
          workloadLink: //gvc/GVC/workload/API_SERVICE
        - prefix: /
          workloadLink: //gvc/GVC/workload/DEFAULT_SERVICE
```

### Key constraints from the schema

- Exactly one routing approach: `gvcLink`, spec-level `workloadLink`, or `ports[].routes` (`gvcLink`/`workloadLink` are `.nand`; `gvcLink` + non-empty routes is rejected).
- All routes must point to workloads in the **same GVC**.
- `prefix` XOR `regex` per route; `hostPrefix` and `hostRegex` exclude each other and require `acceptAllHosts`/`acceptAllSubdomains`; `acceptAllHosts` and `acceptAllSubdomains` cannot both be true.
- Routes must be unique — one route per prefix+host combination.
- Prefix routes are auto-sorted longest-first (trailing-slash first on ties); regex routes are NOT sorted, written order matters.
- Max 10 ports per domain; max 150 routes per port (200 with the `cpln/routeLimitOverride` tag).
- Port 443 with `http`/`http2` automatically gets a TLS block.
- `cname` + `gvcLink` + `http01` requires `tls.serverCertificate.secretLink` on every TLS port (HTTP-01 cannot issue wildcard certs); `ns` mode and spec-level `workloadLink` reject `http01` outright.
- Spec-level `workloadLink` must link to a **stateful** workload; every port must have exactly one route referencing that same workload. (Route-level `workloadLink` inside `routes[]` has no stateful restriction.)
- `.internal` domains: `cname` only, no `gvcLink`, no `certChallengeType`; TLS ports need `serverCertificate.secretLink`.
- `hostPrefix` charset: alphanumeric, dot, underscore, hyphen (`^[0-9a-zA-Z-\._]*$`).

### Special tags

- `cpln/routeLimitOverride`: raises the per-port route limit from 150 to 200.
- `cpln/skipDNSCheck: "true"`: certificate processing skips the DNS-propagation gate (delayed propagation, externally managed DNS).
- `cpln/wildcard: "true"`: wildcard certificate for custom-ingress (dedicated load balancer) domains; `acceptAllHosts: true` implies it.

## Common Mistakes

- **Setting `spec.domain` on the GVC** — deprecated; use the Domain resource.
- **Guessing DNS records instead of reading `status.dnsConfig`** — always hand over the exact records from the domain status.
- **Claiming the domain works right after create** — DNS at the provider and certificate issuance still stand between create and serving.
- **Spec-level `workloadLink` for a serverless/standard workload** — stateful-only; everything else routes via `ports[].routes`.
- **Forgetting the `_acme-challenge` CNAME with `dns01` on a CNAME domain** — the certificate never issues without it.
- **Not waiting for DNS propagation** — after adding TXT/CNAME/NS records, verify with `dig` before retrying.
- **Missing `--org`** — domains are org-scoped; every CLI call needs the org.
