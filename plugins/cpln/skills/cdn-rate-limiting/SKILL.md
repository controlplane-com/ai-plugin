---
name: cdn-rate-limiting
description: "Sets up CDN caching and request rate limiting for Control Plane workloads. Use when the user asks about CDN, Cloudflare, CloudFront, rate limiting, request throttling, DDoS protection, cache headers, or traffic management. Covers CDN configuration and Envoy-based per-client rate limiting."
---

# CDN & Rate Limiting

A deep skill — assumes the `workload` primer (firewall deny-by-default, secrets 3-piece access, tags, create→verify).

## CDN Configuration

A CDN gives edge caching, DDoS protection, and accelerated delivery. Point your domain's CNAME at either a **GVC endpoint** (routes across all GVC locations, surviving a single-location outage) or a **Workload endpoint** (precise geo routing + per-workload failover).

### Cloudflare

**Prerequisites:** Cloudflare account, DNS hosted at Cloudflare, workload `Ready`, domain verified at Control Plane.

**Step 1 — DNS & Certificate at Cloudflare**

| Setting | Value |
|---|---|
| DNS record type | `CNAME` |
| Name | Target subdomain |
| Target | Workload's **Canonical Endpoint** (from Info page) |
| Proxy | **Proxied** (orange cloud on) |
| SSL/TLS mode | `Full (strict)` |

Generate an **Origin Certificate** under SSL/TLS > Origin Server: key type `RSA (2048)`, hostnames `*.DOMAIN` and `DOMAIN` (defaults), validity up to 15 years. Save the cert and private key for Step 2.

**Step 2 — TLS Secret at Control Plane**

Create a [TLS secret](https://docs.controlplane.com/reference/secret.md) from the Cloudflare origin cert + key; leave the TLS Chain empty (self-signed). Use `mcp__cpln__create_secret_tls`; fall back to `cpln secret create-tls`.

```yaml
kind: secret
name: cloudflare-origin-cert
type: tls
data:
  cert: |
    -----BEGIN CERTIFICATE-----
    ...
  key: |
    -----BEGIN PRIVATE KEY-----
    ...
```

**Step 3 — Domain at Control Plane**

| Setting | Value |
|---|---|
| DNS Mode | `CNAME` |
| Routing Mode | As desired |
| Configure TLS | Enabled |
| Custom Server Certificate | The TLS secret from Step 2 |

Provision with `mcp__cpln__create_domain` (or `mcp__cpln__update_domain`), read back DNS-validation records with `mcp__cpln__get_domain`, set the listener TLS via `mcp__cpln__set_domain_tls`, and route to the GVC/workload endpoint with `mcp__cpln__add_domain_route`. Fall back to `cpln domain get DOMAIN -o yaml` for platform-emitted DNS records.

**The APEX domain must be verified before configuring a subdomain.**

### Amazon CloudFront

**Prerequisites:** AWS account, DNS access for your domain, workload `Ready`.

**Step 1 — Request a Public Certificate (ACM)** in the **us-east-1 (N. Virginia)** region:

| Setting | Value |
|---|---|
| Domain | `subdomain.mydomain.com` or `*.mydomain.com` |
| Validation | DNS Validation |
| Key Algorithm | RSA 2048 |

Validate by creating the CNAME records ACM provides in your DNS service.

**Step 2 — Create CloudFront Distribution**

| Setting | Value |
|---|---|
| Origin Domain | Workload's **Canonical Endpoint** (managed) or public endpoint from Deployments page (BYOK) |
| Alternate domain name | `subdomain.mydomain.com` |
| Custom SSL certificate | ACM certificate from Step 1 |
| Cache policy | Configure as needed |

- Managed location origin format: `workload-name-id.cpln.app`
- BYOK location origin format: `workload-name-id.cluster-name.controlplane.us`

**Step 3 — Configure DNS:** CNAME your subdomain to the CloudFront distribution domain (`*.cloudfront.net`).

**Step 4 — Restrict Direct Access (Recommended):** firewall the workload to allow inbound **only from CloudFront IPs**. Download the [CloudFront IP ranges](https://d7uri8nf7uskq.cloudfront.net/tools/list-cloudfront-ips) and add them to `inboundAllowCIDR`. See the [example YAML](https://cpln-public-bucket.s3.amazonaws.com/nginx3-workload-cloudfront-example.yaml).

**BYOK only:** update the Security Group or `INGRESS_FIREWALL_CIDR_LIST` actuator setting with CloudFront CIDRs. VPC quota for inbound rules per security group must be at least **530**.

## Rate Limiting

Rate limiting uses the [Envoy Rate Limit](https://github.com/envoyproxy/ratelimit) project with a Redis backend, deployed as a separate workload. At the limit, the workload returns **HTTP 429 (Too Many Requests)**.

### Architecture

```
Client request
  --> Target workload (Envoy sidecar)
    --> gRPC call to Rate Limit workload
      --> Redis backend (counter storage)
    <-- Allow / Deny (429)
```

### Step 1 — Deploy the Rate Limit Stack

Create the dedicated GVC with `mcp__cpln__create_gvc` (name it `ratelimit`). The stack ships as one multi-resource manifest (workloads + secret + identity + policy); there is no typed MCP tool for a bundled apply, so apply the [rate limiting manifest](https://raw.githubusercontent.com/controlplane-com/examples/main/examples/rate-limiting/rate-limiting.yaml) via the CLI fallback:

```bash
cpln apply --file rate-limiting.yaml --org ORG_NAME --gvc ratelimit
```

The manifest creates:
- **ratelimit** workload (Envoy Rate Limit service, image `envoyproxy/ratelimit`)
- **redis** workload (counter storage)
- **ratelimit-config** opaque secret (rate limiting rules)
- Workload identity and policy for secret access

### Step 2 — Configure Rate Limit Rules

Edit the `ratelimit-config` opaque secret with `mcp__cpln__update_secret_opaque` ([Envoy ratelimit config format](https://github.com/envoyproxy/ratelimit#configuration)); fall back to `cpln secret update`. Valid `unit` values: `second`, `minute`, `hour`, `day`.

**Example — 10 requests/minute per authorization header:**

```yaml
domain: cpln
descriptors:
  - key: authorization
    rate_limit:
      unit: minute
      requests_per_unit: 10
```

After editing the secret, **Force Redeploy** the `ratelimit` workload to reload the config.

### Step 3 — Enable Rate Limiting on a Workload

Add these **tags** to the target workload with `mcp__cpln__update_workload` (or `mcp__cpln__create_workload` at creation); fall back to the `cpln` get-edit-apply workflow below.

| Tag | Required | Default | Description |
|---|:-:|---|---|
| `cpln/rateLimitAddress` | **Yes** | -- | Global Endpoint hostname of the ratelimit workload (no `https://` prefix) |
| `cpln/rateLimitScheme` | No | `https` | Protocol to reach the ratelimit service |
| `cpln/rateLimitPort` | No | `443` | Port of the ratelimit service |
| `cpln/rateLimitDomain` | No | `cpln` | Must match the `domain` field in the config secret |
| `cpln/rateLimitDescriptors` | No | `authority` (matches no descriptor) | Comma-separated. Allowed: `authorization`, `host`, `path`. **You MUST set this explicitly** — the built-in default `authority` matches none of the allowed values, so no rate limiting is applied |

The `cpln/rateLimitAddress` value is the ratelimit workload's exact Global Endpoint (Canonical Endpoint format `<workload>-<gvcAlias>.cpln.app`, e.g. `ratelimit-GVC_ALIAS.cpln.app`) — copy it from that workload's Info page.

### Descriptor Behavior

Each descriptor maps to an HTTP header used for per-client bucketing. Combine with commas: `cpln/rateLimitDescriptors: authorization,path`.

| Descriptor | HTTP Header | Use Case |
|---|---|---|
| `authorization` | `Authorization` | Per-API-key / per-token limiting |
| `host` | `Host` | Per-domain limiting |
| `path` | `:path` | Per-endpoint limiting |

## Combined Stack: CDN + Firewall + Rate Limiting

Traffic flows through layers — set them up in this order:

```
Internet --> CDN (Cloudflare/CloudFront)
  --> Firewall (inboundAllowCIDR: CDN IPs only)
    --> Rate Limiting (Envoy, per-client)
      --> Workload
```

1. **CDN** — set up Cloudflare or CloudFront (above).
2. **Firewall** — restrict `inboundAllowCIDR` to CDN provider IPs so direct access is blocked (edit the firewall block via `mcp__cpln__update_workload`). See the **cpln-firewall-networking** skill.
3. **Rate limiting** — deploy the ratelimit stack and tag the workload.

CDN caching cuts the volume hitting rate limiting; the firewall ensures only CDN traffic reaches the workload; rate limiting catches abuse that passes the CDN. For CloudFront, keep the firewall CIDR list updated as AWS publishes new ranges.

## Quick Reference

Prefer the typed MCP tools below (secret edits, workload tags). Use `cpln` as the fallback when MCP is unavailable, and for the bundled-manifest apply and force-redeployment (no typed MCP tool).

```bash
# Deploy rate limiting stack
cpln apply --file rate-limiting.yaml --org ORG --gvc ratelimit

# Add rate limiting tags (get-edit-apply): get -o yaml, add cpln/rateLimit* tags, re-apply
cpln workload get my-api --gvc my-gvc -o yaml > workload.yaml
cpln apply --file workload.yaml --gvc my-gvc

# Create TLS secret for CDN origin certificate
cpln secret create-tls --name cloudflare-cert --cert ./cert.pem --key ./key.pem

# Force redeploy after config changes
cpln workload force-redeployment my-api --gvc my-gvc
```

**MCP tools:**
- `mcp__cpln__update_workload` — set `cpln/rateLimit*` tags (or the `inboundAllowCIDR` firewall block)
- `mcp__cpln__create_workload` — include rate limiting tags at creation
- `mcp__cpln__update_secret_opaque` — edit the `ratelimit-config` rules secret
- `mcp__cpln__create_gvc` / `mcp__cpln__create_domain` / `mcp__cpln__set_domain_tls` / `mcp__cpln__add_domain_route` — stand up the ratelimit GVC and wire CDN domain routing/TLS

### Related Skills

- **cpln-workload** — Start here: the primary workload skill (types, defaults, spec shape) that routes here for CDN & rate limiting.
- **cpln-firewall-networking** — Firewall rules, CIDR filtering, load balancers
- **cpln-workload-security** — TLS, identity, and access control

## Documentation

- [Configure CDN Guide](https://docs.controlplane.com/guides/configure-cdn.md)
- [Rate Limiting Guide](https://docs.controlplane.com/guides/rate-limiting.md)
- [Secret Reference (TLS)](https://docs.controlplane.com/reference/secret.md)
