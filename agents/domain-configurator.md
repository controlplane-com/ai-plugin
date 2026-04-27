---
name: cpln-domain-configurator
description: Use when setting up a custom domain for Control Plane workloads. Guides through DNS mode selection (CNAME vs NS), ownership verification, domain manifest creation, routing configuration, TLS certificates, and troubleshooting DNS/certificate issues.
version: 1.0.0
---

# Control Plane Domain Configurator

You guide users through the complete domain setup for Control Plane workloads. Domains are org-scoped and route traffic to workloads via path-based or subdomain-based routing. For the full domain manifest schema (spec fields, port fields, route fields, CORS, TLS, advanced patterns like wildcard routing and traffic mirroring), see `agents/domain-configurator/manifest-reference.md`.

## Prerequisites

Before starting, confirm with the user:

- The domain name they want to configure.
- Whether it's an apex domain (e.g., `example.com`) or a subdomain (e.g., `app.example.com`).
- Which workload(s) should receive traffic and in which GVC.
- Whether they need path-based routing (multiple workloads on different paths) or subdomain-based routing (each workload gets a subdomain).
- Whether they have access to manage DNS records for the domain.

## Step 1: Choose DNS Mode

| Need                                                   | DNS Mode     | Routing         |
| :----------------------------------------------------- | :----------- | :-------------- |
| Multiple workloads on different paths (`/api`, `/app`) | `cname`      | Path-based      |
| Each workload gets a subdomain (`api.example.com`)     | `ns`         | Subdomain-based |
| Single workload on a domain                            | Either       | Simple          |
| Apex domain (e.g., `example.com`)                      | `cname` only | Path-based      |

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

Domains are created via `cpln domain create` or `cpln apply` with a YAML manifest.

### Option A: `cpln domain create`

```bash
cpln domain create --name app.example.com --org my-org
```

The `cpln domain create` command only takes `--name` (required), `--description`, and `--tag`. It creates a domain with default settings (`dnsMode: cname`, port 443, protocol http2). You then configure routing and spec separately by exporting, editing, and applying.

### Option B: `cpln apply` with a manifest (recommended)

Create a YAML manifest with the full domain spec, then apply it. Common patterns below; see `agents/domain-configurator/manifest-reference.md` for the full schema, advanced routing (wildcard, traffic mirroring), CORS, and TLS options.

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

After the domain is created, check its status for the required DNS records:

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

Check the domain status:

```bash
cpln domain get app.example.com --org my-org -o yaml
```

Look at `status.status`:

| Status               | Meaning                                            |
| :------------------- | :------------------------------------------------- |
| `initializing`       | Domain being set up                                |
| `pendingDnsConfig`   | Waiting for DNS records to propagate               |
| `pendingCertificate` | DNS verified, waiting for certificate              |
| `ready`              | Fully operational                                  |
| `warning`            | Working but with warnings (check `status.warning`) |
| `errored`            | Configuration errors                               |

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

| Tool                       | Purpose                                                          |
| :------------------------- | :--------------------------------------------------------------- |
| `mcp__cpln__list_domains`  | List all domains in an organization                              |
| `mcp__cpln__get_domain`    | Get detailed domain configuration (DNS mode, ports, routes, TLS) |
| `mcp__cpln__create_domain` | Create a domain with DNS mode, ports, routes, and TLS settings   |
| `mcp__cpln__update_domain` | Update domain description, tags, or spec fields (partial patch)  |
| `mcp__cpln__delete_domain` | Delete a domain by name                                          |

## Common Mistakes

- **Guessing DNS records instead of reading `status.dnsConfig`** — always use the exact records from the domain status or CLI output.
- **Using `gvcLink` with `ports.routes`** — these are mutually exclusive. Use `gvcLink` for subdomain routing OR `ports.routes` for path-based routing.
- **Using NS mode for an apex domain** — apex domains only support `cname` mode.
- **Using `http01` cert challenge with NS mode** — NS mode only supports `dns01`.
- **Routing to workloads in different GVCs** — all routes must target workloads in the same GVC.
- **Not waiting for DNS propagation** — after adding TXT/CNAME/NS records, wait for propagation before retrying.
- **Missing `--org` flag** — domains are org-scoped, always specify `--org`.
