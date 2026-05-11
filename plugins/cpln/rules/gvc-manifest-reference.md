---
description: Validation constraints for Control Plane GVC manifests. Consult when generating or modifying GVC YAML to avoid creation/update failures.
alwaysApply: false
---

# GVC Manifest Validation Reference

Guardrails for generating correct GVC manifests. For full field details, inspect an existing GVC with `cpln gvc get GVC_NAME -o yaml`.

## Complete GVC YAML Structure

```yaml
kind: gvc
name: my-gvc                          # required, unique within org
description: Production GVC
tags:
  environment: production
spec:
  staticPlacement:
    locationLinks:                     # at least one location required
      - //location/aws-us-west-2
      - //location/gcp-us-central1
    locationOptions:                   # optional, per-location routing config
      - locationLink: //location/aws-us-west-2
        routingTier: 0                 # lower = higher priority (integer >= 0)
        latencyOffsetMs: 0            # push/pull traffic (integer)
        latencyToleranceMs: 100       # max acceptable latency (integer >= 0)
  endpointNamingFormat: org            # "default", "org", or "legacy"
  pullSecretLinks:                     # optional, Docker/ECR/GCP secrets only
    - //secret/docker-registry-secret
  env:                                 # optional, GVC-level env vars
    - name: ENVIRONMENT
      value: production
  tracing:                             # optional
    sampling: 10                       # 0-100, required when tracing is set
    provider:                          # exactly one of: controlplane, otel, lightstep
      controlplane: {}
    customTags:
      team: platform
  loadBalancer:                        # optional
    dedicated: true                    # enables custom ports, wildcard hostnames on domains
    trustedProxies: 0                  # 0, 1, or 2
    multiZone:
      enabled: true
    redirect:
      class:
        status5xx: https://error.example.com
        status401: https://auth.example.com/login?return_to=%REQ(:path)%
    ipSet: //ipset/my-ipset
  keda:                                # optional
    enabled: true
    identityLink: //identity/keda-identity
    secrets:
      - //secret/keda-trigger-auth
```

## Location Configuration

- Links use format `//location/PROVIDER-REGION` (e.g., `//location/aws-us-east-1`, `//location/gcp-us-central1`, `//location/azure-eastus`)
- At least one location is required for workloads to deploy
- Adding a location immediately provisions it for all workloads
- Removing a location gracefully terminates replicas and shifts traffic
- `locationOptions` allows priority-based failover with `routingTier`, `latencyOffsetMs`, and `latencyToleranceMs`

## Endpoint Naming Format

- `default`: `{workload}-{gvc}.cpln.app`
- `org`: `{workload}-{gvc}.{org}.cpln.app`
- `legacy`: legacy naming scheme (for backward compatibility)
- Defaults to `org` on creation

## Load Balancer Configuration

- `dedicated: true` enables custom ports and wildcard hostnames on domains (additional charges per location)
- `trustedProxies`: `0` (source IP), `1` (last XFF), `2` (second-to-last XFF)
- `redirect.class.status5xx` MUST be a valid URI
- `redirect.class.status401` supports Envoy format strings (e.g., `%REQ(:path)%`)
- `ipSet` links to an IpSet resource for static IP on dedicated LB

## Pull Secrets

- Only **Docker**, **ECR**, and **GCP** secret types are supported
- Configured at GVC level, inherited by all workloads
- Not needed for images from the same org's Control Plane registry

## Environment Variables

- GVC-level env vars are available to workloads that set `inheritEnv: true` on their containers
- Workload env vars override GVC env vars with the same name

## Tracing

- `sampling`: 0-100 (percentage), required when tracing is configured
- `provider`: exactly one of `controlplane`, `otel`, or `lightstep` (xor constraint)
- `controlplane` provider endpoints: GRPC `tracing.controlplane:80`, HTTP `tracing.controlplane:4318`
- `customTags`: key-value pairs added to each trace

## KEDA Configuration

- `enabled: true` deploys a KEDA operator in the GVC
- `identityLink`: optional, links to an identity for cloud/network resource access
- `secrets`: optional, list of secrets used as TriggerAuthentication objects

## Sticky Sessions (via Tags)

- Set tag `cpln/sessionCookie` with cookie name
- Set tag `cpln/sessionDuration` with Go duration (e.g., `300s`, `30m`)
- Enables soft session affinity for ALL workloads in the GVC

## Common Validation Errors

| Error | Fix |
|:---|:---|
| No locations configured | Add at least one `locationLinks` entry |
| Invalid location format | Use `//location/PROVIDER-REGION` (e.g., `//location/aws-us-east-1`) |
| Invalid pull secret type | Only Docker, ECR, and GCP secrets can be used as pull secrets |
| Invalid trustedProxies value | Must be 0, 1, or 2 |
| Redirect without dedicated LB | Set `loadBalancer.dedicated: true` to use redirect rules |
| Invalid endpointNamingFormat | Must be `default`, `org`, or `legacy` |
| Multiple tracing providers | Use exactly one of `controlplane`, `otel`, or `lightstep` |
| Sampling out of range | Must be 0-100 |
| KEDA secrets without KEDA enabled | Set `keda.enabled: true` before adding secrets |
| GVC-scoped resource confusion | Workloads, Identities, Volume Sets are GVC-scoped; Secrets, Domains are org-scoped |

## Example: Minimal GVC

```yaml
kind: gvc
name: staging
spec:
  staticPlacement:
    locationLinks:
      - //location/aws-us-east-1
```

## Example: Production GVC with All Features

```yaml
kind: gvc
name: production
description: Multi-region production GVC
tags:
  cpln/sessionCookie: session-id
  cpln/sessionDuration: 30m
spec:
  staticPlacement:
    locationLinks:
      - //location/aws-us-east-1
      - //location/aws-eu-west-1
      - //location/gcp-us-central1
  endpointNamingFormat: org
  pullSecretLinks:
    - //secret/ecr-pull-secret
  env:
    - name: LOG_LEVEL
      value: info
  tracing:
    sampling: 10
    provider:
      controlplane: {}
    customTags:
      environment: production
  loadBalancer:
    dedicated: true
    trustedProxies: 1
  keda:
    enabled: true
    identityLink: //identity/keda-identity
```

## MCP Tools

Use these MCP tools for programmatic GVC and location management:

| Tool | Action |
|:---|:---|
| `mcp__cpln__list_gvcs` | List all GVCs in an organization |
| `mcp__cpln__create_gvc` | Create a new GVC with optional locations, env, and pull secrets |
| `mcp__cpln__update_gvc` | Update GVC metadata, env variables, or pull secrets (merge semantics) |
| `mcp__cpln__add_gvc_locations` | Add locations to an existing GVC (duplicates skipped) |
| `mcp__cpln__remove_gvc_locations` | Remove locations from a GVC |
| `mcp__cpln__delete_gvc` | Delete a GVC (irreversible) |
| `mcp__cpln__list_locations` | List all available locations grouped by provider |
