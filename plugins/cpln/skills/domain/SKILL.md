---
name: domain
description: "Custom domains for Control Plane workloads. Use when the user asks to put a domain or subdomain in front of a workload, pick cname vs ns, configure routing or TLS, or hits apex, ownership, or workloadLink errors."
---

# Custom Domains

A `domain` is an org-level resource that binds a DNS name to workloads in **one GVC**. **Created ≠ live:** after the resource exists, the user still adds records at their DNS provider — read exactly which from `status.dnsConfig` and hand them over verbatim, never guessed. Every shape decision below is platform-enforced and a wrong combination is a rejected mutation, so decide BEFORE calling `mcp__cpln__create_domain` (pass `workload` and `gvc` and it derives the 443 listener, its route, and `cname`; pass `dnsMode` and `ports` for anything else). Never set `spec.domain` on a GVC — that legacy field is deprecated; the Domain resource is the only path.

## Decide the shape first

**1. Apex or subdomain?** The apex is the registrable root (`example.com`, `example.co.uk`); anything deeper is a subdomain (`app.example.com`).

**2. `dnsMode` — who runs DNS:**

| Mode | Valid for | Wiring | Cert challenge |
|---|---|---|---|
| `cname` | **apex (required)** and subdomains | User adds CNAME records per `status.dnsConfig` | `http01` default, `dns01` opt-in |
| `ns` | **subdomains only** | Delegates the subdomain zone via 4 NS records (`ns1`/`ns2.cpln.cloud`, `ns1`/`ns2.cpln.live`) | `dns01` only — `http01` rejected |

`dnsMode` defaults to `cname` (to `ns` when `gvcLink` is set). The platform rejects `ns` on an apex, and rejects a `cname` domain nested under an existing NS domain (`parent_ns_domain_exists`).

**3. Routing — exactly ONE of three.** All routes in a domain must target workloads in the **same GVC**.

| Mode | What it does | Constraints |
|---|---|---|
| `ports[].routes` | Explicit path routes to workloads | The default choice; works for every workload type |
| `gvcLink` | Every workload in the GVC gets `{workload}.{domain}` | Excludes `workloadLink` and any `ports[].routes`. With `cname` + `http01` it demands `tls.serverCertificate` on every TLS port (http01 cannot issue wildcard certs) |
| `workloadLink` (spec-level) | Replica-direct: binds the whole domain to ONE stateful workload with per-replica DNS names | **Stateful only** (`workloadLink must link to a stateful workload`); every port exactly ONE route to that same workload; `http01` rejected |

For an app, site, or API on serverless/standard, the answer is `ports[].routes`. Route-level `workloadLink` inside `routes[]` is a different field with no stateful restriction.

## Ownership and create order

- **`ns` subdomain:** the apex domain resource must already exist in the org (`apex_must_exist`).
- **Everything else:** ownership is proven either by the org already owning the verified apex (subdomains then attach with no extra records), or by a TXT record — the create fails with `must_prove_ownership` listing the options: `_cpln.{apex}` / `_verify.{apex}`, or `_cpln-{label}.{rest}` / `_verify-{label}.{rest}` at any segment level, value = org GUID **or** org name (TTL 600). The user adds **one**, waits for propagation, and you retry the same create. `mcp__cpln__create_domain` surfaces these records in its error output.
- **Apex owned by another org?** The apex name itself is taken (globally unique), but **subdomains still work**: they go through the same TXT proof in this org — the standard multi-org pattern (keep the apex in the production org).
- **`.internal` domains** are strict same-org — apex and subdomains must live in one org (`apex_owned_by_other_org`, HTTP 409) — and: `cname` only, no `gvcLink`, `certChallengeType` forbidden; every TLS port needs `tls.serverCertificate.secretLink` (no ACME).

## Manifest shape

```yaml
kind: domain
name: app.example.com
spec:
  dnsMode: cname
  ports:                                # max 10 per domain
    - number: 443                       # default 443; 443 + http/http2 auto-gets a TLS block
      protocol: http2                   # http | http2 | tcp (tcp needs a dedicated load balancer)
      routes:                           # max 150 per port (200 with tag cpln/routeLimitOverride)
        - prefix: /api                  # prefix XOR regex (RE2); prefix defaults to "/"
          replacePrefix: /              # optional rewrite before forwarding
          workloadLink: //gvc/GVC/workload/API
          port: 8080                    # optional target container port
        - prefix: /
          workloadLink: //gvc/GVC/workload/FRONTEND
```

- **Longest prefix wins** — prefix routes are auto-sorted; regex routes are NOT sorted, written order matters. Duplicate prefix+host combinations are rejected (`There are more than one routes for the prefix …`).
- **Listener ports other than 443/80 — and the `tcp` protocol — require a dedicated load balancer.** Without one the domain deploys into `warning` (`Unable to configure port …`) instead of serving.
- **Subdomain matching on one domain** (`hostPrefix` / `hostRegex`, mutually exclusive) requires `acceptAllHosts` or `acceptAllSubdomains` (which exclude each other) AND a GVC with a dedicated load balancer. `hostPrefix` charset: alphanumeric, dot, underscore, hyphen.
- **Header rewrites** (`headers.request.set`): values may use only `%REQUESTED_SERVER_NAME%`, `%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%`, `%START_TIME%`.
- **Traffic mirroring** per route: `mirror: [{workloadLink, percent 0-100, port}]` — same GVC, response comes only from the primary.
- **CORS** per port: `allowOrigins` entries take `exact` XOR `regex`; header lists are lowercased; `maxAge` format is digits + `h`/`m`/`s` only.
- **TLS** per port: `minProtocolVersion` default `TLSV1_2`; custom cert = keypair secret (PEM) on `serverCertificate.secretLink`; `clientCertificate` enables mTLS verification — client cert details reach the workload in the XFCC header.

## Certificates

- Let's Encrypt, auto-provisioned for port 443 once validation passes; ~90-day certs renewed automatically.
- `cname` defaults to `http01`: DNS must already resolve and `/.well-known/acme-challenge/` must redirect to the platform solver (`http01-solver.cpln.io`) — a CDN/WAF forcing HTTPS or blocking the path breaks it; switch to `dns01`. `ns` always uses `dns01`. The tag `cpln/skipDNSCheck: "true"` skips the DNS-propagation gate in certificate processing.
- **`dns01` on a `cname` domain adds an extra record**: a `_acme-challenge.{host}` CNAME appears in `status.dnsConfig` — without it the certificate never issues.
- Wildcard certs come only from `dns01` — that is why `cname` + `gvcLink` + `http01` demands a custom certificate.

## After create — DNS records and status

- Read the domain back and give the user the records from `status.dnsConfig`. CNAME mode points at the GVC endpoint alias. Via the MCP tools the alias is resolved for you, so the CNAME target comes back ready to paste (e.g. `0p2fpmbe7sr5c.t.cpln.app`); via the `cpln` CLI the value is the literal `<gvcAlias>.t.cpln.app` placeholder — substitute the GVC's top-level `alias` field. **Never hand the user a `<gvcAlias>` placeholder as a DNS record.** `cname` + `gvcLink` needs one CNAME per workload; `workloadLink` adds per-replica records (`{workload}-{i}-{location}`).
- Many DNS providers refuse CNAME at the apex — the user needs ALIAS/ANAME support or a CDN in front.
- `status.status`: `initializing`, `pendingDnsConfig` (records not seen yet), `pendingCertificate` (validated, cert issuing), `ready`; `warning`/`errored` carry detail in `status.warning`; `usedByGvc` marks a domain referenced by the legacy GVC `spec.domain`. Pending states are expected, not errors. Misconfigurations that pass schema validation — routes to a missing GVC/workload, no valid routes, a disallowed port/protocol, an ignored `hostPrefix` — land as `warning` and increment the `domain_warnings` metric.
- **Host header:** serverless workloads receive the canonical endpoint as `Host` (the custom domain arrives in `X-Forwarded-Host`); standard/stateful receive the custom domain.
- Report honestly: "domain created, routes configured, DNS records pending at your provider" + the record list. Never claim the domain is serving before DNS exists.

## Platform rejections and exact fixes

| Error | Fix |
|---|---|
| `cname is the only valid dnsMode for apex domain X` | Use `dnsMode: cname` on the apex; `ns` only delegates a subdomain zone |
| `The apex domain X must be created before Y` | Create the apex domain resource first, then the subdomain |
| `apex_owned_by_other_org` (409) | `.internal` only — internal apex + subdomains stay in one org. A public subdomain under another org's apex just needs the TXT proof |
| `must_prove_ownership` | Hand the user ONE TXT record from the response, wait for propagation, retry |
| `parent_ns_domain_exists` | A CNAME domain cannot live under an NS domain — create it as part of the NS zone or restructure |
| `workloadLink must link to a stateful workload` | Drop spec-level `workloadLink`; route serverless/standard via `ports[].routes` |
| `Only one of gvcLink or ports.routes may be configured` | Pick one routing mode |
| `when workloadLink is configured, every port must have exactly ONE route` / `no route can reference another workload` | One route per port, all to the linked workload — or drop `workloadLink` |
| `certChallengeType can not be http01` / `http01 … not supported for dnsMode ns` | Use `dns01` or omit `certChallengeType` |
| `Domains may only route to Workloads in a single GVC` | Split into one domain per GVC, or move the workloads |
| `hostPrefix or hostRegex can only be used if …` | Set `acceptAllHosts` or `acceptAllSubdomains` (and use a dedicated load balancer) |
| `number of routes exceeds maximum of 150` | Consolidate routes, or add tag `cpln/routeLimitOverride` (raises to 200) |

## Which tool changes what

`create_domain` with `workload` and `gvc` derives the 443 listener, its route, and `cname` mode and returns the DNS records; pass `dnsMode` and `ports` for anything else. After creation, routes, ports, TLS, and CORS (full profile) each have their own tool; `update_domain` never changes ports, `dnsMode`, or `certChallengeType`. Domain names are FQDNs, passed as is.

## Verify

1. `mcp__cpln__get_resource` (kind `domain`) — `status.status` progressing, `status.dnsConfig` matches what the user added.
2. After the user adds records: `dig TXT _cpln.DOMAIN` / `dig CNAME DOMAIN` to confirm propagation before retrying or polling.
3. Once `ready`: `curl -I https://DOMAIN/PATH` and confirm each prefix lands on the intended workload.

## CLI fallback

Commands come from the `cpln` skill; CI/CD uses `CPLN_TOKEN` and `cpln apply`. `cpln domain create` takes only `--name`, `--description`, and `--tag`: spec changes go through `cpln domain edit`, or `cpln domain get -o yaml-slim` then `cpln apply`. There is no `cpln domain update`.
