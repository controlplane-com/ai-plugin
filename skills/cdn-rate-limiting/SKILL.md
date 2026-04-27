---
name: cpln-cdn-rate-limiting
description: "Sets up CDN caching and request rate limiting for Control Plane workloads. Use when the user asks about CDN, Cloudflare, CloudFront, rate limiting, request throttling, DDoS protection, cache headers, or traffic management. Covers CDN configuration and Envoy-based per-client rate limiting."
version: 1.0.0
---

# CDN & Rate Limiting

## CDN Configuration

A CDN (Content Delivery Network) provides edge caching, DDoS protection, and accelerated delivery for workloads on Control Plane. Configure your domain's CNAME to target either a **GVC endpoint** (routes traffic across all locations in the GVC, even if a workload in one location is unavailable) or a **Workload endpoint** (routes to a specific workload with precise geo routing and per-workload failover).

### Cloudflare

**Prerequisites:** Cloudflare account, DNS hosted at Cloudflare, workload in `Ready` state, domain verified at Control Plane.

#### Step 1 -- DNS & Certificate at Cloudflare

| Setting | Value |
|:--------|:------|
| DNS record type | `CNAME` |
| Name | Target subdomain |
| Target | Workload's **Canonical Endpoint** (from Info page) |
| Proxy | **Proxied** (orange cloud on) |
| SSL/TLS mode | `Full (strict)` |

Generate an **Origin Certificate** under SSL/TLS > Origin Server:
- Key type: `RSA (2048)`
- Hostnames: `*.DOMAIN` and `DOMAIN` (defaults)
- Validity: up to 15 years
- Save the certificate and private key for the next step

#### Step 2 -- TLS Secret at Control Plane

Create a [TLS secret](https://docs.controlplane.com/reference/secret.md) using the Cloudflare origin certificate and private key. Leave the TLS Chain empty (self-signed).

```yaml
kind: secret
name: cloudflare-origin-cert
type: tls
data:
  cert: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  key: |
    -----BEGIN PRIVATE KEY-----
    ...
    -----END PRIVATE KEY-----
```

#### Step 3 -- Domain at Control Plane

| Setting | Value |
|:--------|:------|
| DNS Mode | `CNAME` |
| Routing Mode | As desired |
| Configure TLS | Enabled |
| Custom Server Certificate | Select the TLS secret from Step 2 |

**The APEX domain must be verified before configuring a subdomain.**

### Amazon CloudFront

**Prerequisites:** AWS account, DNS access for your domain, workload in `Ready` state.

#### Step 1 -- Request a Public Certificate (ACM)

Request via AWS Certificate Manager in the **us-east-1 (N. Virginia)** region:

| Setting | Value |
|:--------|:------|
| Domain | `subdomain.mydomain.com` or `*.mydomain.com` |
| Validation | DNS Validation |
| Key Algorithm | RSA 2048 |

Validate by creating the CNAME records ACM provides in your DNS service.

#### Step 2 -- Create CloudFront Distribution

| Setting | Value |
|:--------|:------|
| Origin Domain | Workload's **Canonical Endpoint** (managed locations) or public endpoint from Deployments page (BYOK) |
| Alternate domain name | `subdomain.mydomain.com` |
| Custom SSL certificate | ACM certificate from Step 1 |
| Cache policy | Configure as needed |

**Managed location origin format:** `workload-name-id.cpln.app`
**BYOK location origin format:** `workload-name-id.cluster-name.controlplane.us`

#### Step 3 -- Configure DNS

Create a CNAME record pointing your subdomain to the CloudFront distribution domain (`*.cloudfront.net`).

#### Step 4 -- Restrict Direct Access (Recommended)

Configure the workload's firewall to allow inbound traffic **only from CloudFront IPs**. Download the [CloudFront IP ranges](https://d7uri8nf7uskq.cloudfront.net/tools/list-cloudfront-ips) and add them to `inboundAllowCIDR`. See the [example YAML](https://cpln-public-bucket.s3.amazonaws.com/nginx3-workload-cloudfront-example.yaml).

**BYOK only:** Update the Security Group or `INGRESS_FIREWALL_CIDR_LIST` actuator setting with CloudFront CIDRs. Ensure the VPC quota for inbound rules per security group is at least **530**.

## Rate Limiting

Rate limiting on Control Plane uses the [Envoy Rate Limit](https://github.com/envoyproxy/ratelimit) project with a Redis backend, deployed as a separate workload. When a request hits the configured limit, the workload returns **HTTP 429 (Too Many Requests)**.

### Architecture

```
Client request
  --> Target workload (Envoy sidecar)
    --> gRPC call to Rate Limit workload
      --> Redis backend (counter storage)
    <-- Allow / Deny (429)
```

### Step 1 -- Deploy the Rate Limit Stack

Apply the [rate limiting manifest](https://raw.githubusercontent.com/controlplane-com/examples/main/examples/rate-limiting/rate-limiting.yaml) to a GVC named `ratelimit`:

```bash
cpln gvc create --name ratelimit --org ORG_NAME
cpln apply --file rate-limiting.yaml --org ORG_NAME --gvc ratelimit
```

The manifest creates:
- **ratelimit** workload (Envoy Rate Limit service, image `envoyproxy/ratelimit`)
- **redis** workload (counter storage)
- **ratelimit-config** opaque secret (rate limiting rules)
- Workload identity and policy for secret access

### Step 2 -- Configure Rate Limit Rules

Edit the `ratelimit-config` opaque secret. The config follows the [Envoy ratelimit configuration format](https://github.com/envoyproxy/ratelimit#configuration).

Valid `unit` values: `second`, `minute`, `hour`, `day`.

**Example -- 10 requests per minute per authorization header:**

```yaml
domain: cpln
descriptors:
  - key: authorization
    rate_limit:
      unit: minute
      requests_per_unit: 10
```

**Example -- per-host limits:**

```yaml
domain: cpln
descriptors:
  - key: host
    rate_limit:
      unit: second
      requests_per_unit: 100
```

After editing the secret, **Force Redeploy** the `ratelimit` workload to reload the config.

### Step 3 -- Enable Rate Limiting on a Workload

Add the following **tags** to the target workload:

| Tag | Required | Default | Description |
|:----|:--------:|:--------|:------------|
| `cpln/rateLimitAddress` | **Yes** | -- | Global Endpoint hostname of the ratelimit workload (no `https://` prefix) |
| `cpln/rateLimitScheme` | No | `https` | Protocol to reach the ratelimit service |
| `cpln/rateLimitPort` | No | `443` | Port of the ratelimit service |
| `cpln/rateLimitDomain` | No | `cpln` | Must match the `domain` field in the config secret |
| `cpln/rateLimitDescriptors` | No | `authorization` | Comma-separated. Allowed: `authorization`, `host`, `path`. **Always set explicitly** — omitting this tag may produce unexpected behavior |

**Complete workload YAML example with rate limiting tags:**

```yaml
kind: workload
name: my-api
spec:
  containers:
    - name: main
      image: 'myorg/my-api:latest'
      port: 8080
tags:
  # Canonical Endpoint format: <workload>-<gvcAlias>.cpln.app
  # Copy the exact Global Endpoint hostname from the ratelimit workload's Info page.
  cpln/rateLimitAddress: ratelimit-GVC_ALIAS.cpln.app
  cpln/rateLimitDomain: cpln
  cpln/rateLimitDescriptors: authorization
```

### Descriptor Behavior

Each descriptor maps to an HTTP header used for per-client bucketing:

| Descriptor | HTTP Header | Use Case |
|:-----------|:------------|:---------|
| `authorization` | `Authorization` | Per-API-key / per-token limiting |
| `host` | `Host` | Per-domain limiting |
| `path` | `:path` | Per-endpoint limiting |

Multiple descriptors can be combined: `cpln/rateLimitDescriptors: authorization,path`

## Combined Stack: CDN + Firewall + Rate Limiting

When using all three together, traffic flows through layers:

```
Internet --> CDN (Cloudflare/CloudFront)
  --> Firewall (inboundAllowCIDR: CDN IPs only)
    --> Rate Limiting (Envoy, per-client)
      --> Workload
```

**Configuration order:**

1. **CDN** -- Set up Cloudflare or CloudFront as described above
2. **Firewall** -- Restrict `inboundAllowCIDR` to CDN provider IPs so direct access is blocked. See the **cpln-firewall-networking** skill for firewall patterns
3. **Rate limiting** -- Deploy the ratelimit stack and tag the workload

**Key considerations:**
- CDN caching reduces the request volume hitting rate limiting
- Firewall ensures only CDN traffic reaches the workload
- Rate limiting protects against abuse that passes through the CDN
- For CloudFront, keep the firewall CIDR list updated as AWS publishes new IP ranges

## Quick Reference

### CLI Commands

```bash
# Deploy rate limiting stack
cpln apply --file rate-limiting.yaml --org ORG --gvc ratelimit

# Add rate limiting tags to a workload (get-edit-apply workflow)
cpln workload get my-api --gvc my-gvc -o yaml > workload.yaml
# Edit workload.yaml to add cpln/rateLimit* tags
cpln apply --file workload.yaml --gvc my-gvc

# Create TLS secret for CDN origin certificate
cpln secret create-tls --name cloudflare-cert --cert ./cert.pem --key ./key.pem

# Force redeploy after config changes
cpln workload force-redeployment my-api --gvc my-gvc
```

### MCP Tools

Rate limiting is configured via workload **tags**. Use the existing MCP workload tools:
- **`mcp__cpln__update_workload`** -- Set `cpln/rateLimit*` tags on a workload
- **`mcp__cpln__create_workload`** -- Include rate limiting tags at creation time

### Related Skills

- **cpln-firewall-networking** — Firewall rules, CIDR filtering, load balancers
- **cpln-workload-security** — TLS, identity, and access control

## Documentation

For the latest reference, see:

- [Configure CDN Guide](https://docs.controlplane.com/guides/configure-cdn.md)
- [Rate Limiting Guide](https://docs.controlplane.com/guides/rate-limiting.md)
- [Secret Reference (TLS)](https://docs.controlplane.com/reference/secret.md)
