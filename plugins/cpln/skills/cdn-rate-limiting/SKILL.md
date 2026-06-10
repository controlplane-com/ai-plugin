---
name: cdn-rate-limiting
description: "CDN caching and request rate limiting for Control Plane workloads. Use when the user asks about CDN, Cloudflare, CloudFront, edge caching, rate limiting, request throttling, per-key or per-route limits, or DDoS protection."
---

# CDN & Rate Limiting

Two edge concerns, both built from existing primitives — there is no CDN or rate-limit resource kind. A **CDN** is bring-your-own (Cloudflare / CloudFront) pointed at the workload's canonical endpoint; **rate limiting** is an Envoy ratelimit service you deploy, enabled per workload by `cpln/rateLimit*` **tags**. Assumes the `workload` primer (firewall deny-by-default, canonical URL rules, create-then-verify).

## CDN

The pattern: the CDN proxies your domain and uses the workload's **canonical endpoint** as origin — read it from `status.canonicalEndpoint` or `mcp__cpln__list_deployments`, never construct it. A **workload endpoint** gives precise geo-routing and per-workload failover; a **GVC endpoint** serves one CDN route for many domains or wildcard subdomains, but keeps sending traffic to every location even when that location's workload is down.

### Cloudflare

1. **DNS at Cloudflare:** proxied CNAME (orange cloud on) from your subdomain to the canonical endpoint; SSL/TLS mode **Full (strict)**.
2. **Origin certificate** (SSL/TLS, then Origin Server; RSA 2048) becomes a Control Plane **TLS secret** — `mcp__cpln__create_secret_tls` with the cert and key, **TLS chain left empty** (the origin cert is self-signed).
3. **Domain at Control Plane:** `mcp__cpln__create_domain` (CNAME DNS mode), `mcp__cpln__set_domain_tls` with the secret as the custom **server certificate**, `mcp__cpln__add_domain_route` to the workload. **The apex domain must be verified before configuring a subdomain.**

### Amazon CloudFront

1. **ACM public certificate in `us-east-1`** (CloudFront requires that region), DNS validation, covering your subdomain or wildcard.
2. **Distribution:** origin = the workload's canonical endpoint (BYOK: the per-location endpoint from `mcp__cpln__list_deployments`); alternate domain name = your subdomain; attach the ACM cert.
3. **DNS:** CNAME your subdomain to the distribution's `*.cloudfront.net` name.

### Lock out direct access

With a CDN in front, restrict the workload firewall so only CDN traffic reaches it: set `inboundAllowCIDR` to the provider's published ranges ([CloudFront IP list](https://d7uri8nf7uskq.cloudfront.net/tools/list-cloudfront-ips)) via `mcp__cpln__update_workload`, and keep the list current. BYOK locations must also admit the ranges in the cluster's ingress security group — the CloudFront list is large, so raise the VPC quota for rules per security group to at least **530**. Details: **firewall-networking**.

## Rate limiting

Tags on the target workload inject an [Envoy rate-limit filter](https://github.com/envoyproxy/ratelimit) into its **inbound sidecar**: each request makes a gRPC check (1s timeout) against a ratelimit service you deploy (Envoy ratelimit + Redis); over-limit requests get **HTTP 429**.

### 1. Deploy the ratelimit stack

One multi-resource manifest (no bundled-apply MCP tool — use the CLI):

```bash
cpln gvc create --name ratelimit --location LOCATION --org ORG   # or mcp__cpln__create_gvc
cpln apply --file rate-limiting.yaml --org ORG --gvc ratelimit
```

The [example manifest](https://raw.githubusercontent.com/controlplane-com/examples/main/examples/rate-limiting/rate-limiting.yaml) creates the **ratelimit** workload (`envoyproxy/ratelimit`), a **redis** workload, the **ratelimit-config** opaque secret (the rules), and the identity + policy for secret access. It assumes the GVC is named `ratelimit` (edit it if yours differs) and pins an older `envoyproxy/ratelimit` image tag — substitute a newer tag if desired.

**As shipped, the manifest is a trial setup, not a production one:** both workloads run `minScale: 1` with `spot: true`. Because enforcement is fail-closed, the ratelimit stack is tier-1 infrastructure for every tagged workload — for production raise its `minScale` to 2+, set `spot: false`, and run the GVC in the same locations as the workloads it protects (every request pays the check's round trip). A Redis restart only resets counters; a ratelimit outage denies traffic.

### 2. Configure the rules

Edit the `ratelimit-config` opaque secret (`mcp__cpln__update_secret_opaque`), [Envoy ratelimit format](https://github.com/envoyproxy/ratelimit#configuration); `unit`: `second` / `minute` / `hour` / `day`:

```yaml
domain: cpln
descriptors:
  - key: authorization
    rate_limit:
      unit: minute
      requests_per_unit: 10
```

After editing, reload the config: `cpln workload force-redeployment ratelimit --gvc ratelimit`.

### 3. Tag the target workload

Set with `mcp__cpln__update_workload` (or at creation):

| Tag | Required | Default | Meaning |
|---|:-:|---|---|
| `cpln/rateLimitAddress` | **Yes** | — | Canonical endpoint **hostname** of the ratelimit workload (no scheme prefix) — nothing happens without it |
| `cpln/rateLimitDescriptors` | **Effectively yes** | `authority` | Comma-separated: `authorization`, `host`, `path` — the default matches none of them, so **no limiting is applied until you set this** |
| `cpln/rateLimitScheme` | No | `https` | `https` dials the service over TLS with SNI |
| `cpln/rateLimitPort` | No | `443` | Port of the ratelimit service |
| `cpln/rateLimitDomain` | No | `cpln` | Must match `domain` in the config secret |

| Descriptor | Buckets per | HTTP header |
|---|---|---|
| `authorization` | API key / token | `Authorization` |
| `host` | domain | `Host` |
| `path` | endpoint | `:path` |

**There is no per-IP descriptor** — these three are the only ones wired. For per-client-IP throttling use the CDN layer (e.g. Cloudflare rate-limiting rules); keep this stack for per-token and per-route limits. Don't invent a `remote_address` descriptor — it does nothing.

### Combining descriptors

`cpln/rateLimitDescriptors: authorization,path` produces **one compound key** (an ordered tuple), not two independent limits. The config must **nest in the same order** as the tag's comma order:

```yaml
domain: cpln
descriptors:
  - key: authorization      # first tag entry
    descriptors:
      - key: path           # second tag entry — nested, not a sibling
        rate_limit:
          unit: minute
          requests_per_unit: 60
```

This buckets per token-and-path **pair** (any values). Add `value:` under a key to pin one route or token (e.g. `key: path, value: /api/search`). Two genuinely independent limits are not expressible through the tags — the filter emits a single action tuple.

**Anonymous-bypass warning:** Envoy skips the rate-limit check entirely when a descriptor header is missing from the request (`skip_if_absent` defaults to false and the filter doesn't set it). With `authorization` in the list, requests **without** an `Authorization` header are never checked — including the sample 10/minute config above. Limit by `path` or `host` (always present) when anonymous traffic matters, or throttle it at the CDN.

### Traps (from the filter's actual wiring)

- **Fail-closed:** the filter is configured with `failure_mode_deny: true` and a 1s check timeout — if the ratelimit service is down, unreachable, or the address is wrong, **inbound requests are denied**, not passed through. Verify the ratelimit workload is Ready (`mcp__cpln__list_deployments`) **before** tagging the target, and treat a typo in `cpln/rateLimitAddress` as an outage.
- **Descriptors must be explicit:** the built-in default `authority` produces an empty action list — the filter runs but limits nothing.
- **Tags are not validated:** these are plain tags interpreted by the platform; a misspelled tag name silently does nothing.
- The address is resolved by DNS from inside the mesh — use the ratelimit workload's exact canonical endpoint hostname.

## Layering the full stack

Traffic passes, in order: the **CDN** (absorbs and caches), then the **firewall** (`inboundAllowCIDR` = CDN IPs only, so nobody bypasses the CDN), then **rate limiting** (catches abuse that passes the CDN), then the workload.

## Verify the setup

- **Limiting works:** send requests past the limit and expect `429` — with the sample 10/minute rule, the 11th call returns it: `for i in $(seq 1 11); do curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: test" https://CANONICAL_ENDPOINT/; done`. After any rules edit, `force-redeployment` the ratelimit workload first.
- **CDN serves:** `curl -I https://SUBDOMAIN` shows the CDN's header (`cf-cache-status` on Cloudflare, `x-cache` on CloudFront).
- **Bypass is closed:** `curl` the canonical endpoint directly — after the firewall lock-down it must no longer answer from outside the CDN ranges.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Every request denied | Ratelimit service down/unready, or `cpln/rateLimitAddress` wrong — enforcement is fail-closed |
| Requests never limited | `cpln/rateLimitDescriptors` unset (default matches nothing); `domain` mismatch between tag and config; rules edited without `force-redeployment`; misspelled tag (tags are unvalidated) |
| Cloudflare 526 / TLS errors | Domain TLS not using the origin-cert secret, or SSL mode not Full (strict) |
| Redirect loop behind Cloudflare | SSL mode is Flexible — switch to Full (strict) |
| Origin still reachable directly | `inboundAllowCIDR` not restricted to the CDN ranges |

## Quick reference

- `mcp__cpln__update_workload` — `cpln/rateLimit*` tags; `inboundAllowCIDR` lock-down
- `mcp__cpln__update_secret_opaque` — edit the ratelimit rules secret
- `mcp__cpln__create_secret_tls` / `create_domain` / `set_domain_tls` / `add_domain_route` — CDN domain wiring
- `mcp__cpln__list_deployments` — canonical endpoint + readiness checks
- CLI only: `cpln apply --file rate-limiting.yaml` (bundled manifest), `cpln workload force-redeployment` (config reload)

## Related skills

| Need | Skill |
|---|---|
| Workload types, defaults, canonical URL rules — start here | `workload` |
| Firewall rules, CIDR allow-lists | `firewall-networking` |
| TLS, probes, hardening | `workload-security` |

## Documentation

- [Configure CDN Guide](https://docs.controlplane.com/guides/configure-cdn.md)
- [Rate Limiting Guide](https://docs.controlplane.com/guides/rate-limiting.md)
- [Secret Reference (TLS)](https://docs.controlplane.com/reference/secret.md)
