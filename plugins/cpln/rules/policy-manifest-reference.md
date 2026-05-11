---
description: Validation constraints for Control Plane policy YAML manifests — valid targetKind values, principal link formats, permission strings, and targeting rules
alwaysApply: false
---

# Policy Manifest Validation Reference

Guardrails for generating correct policy manifests. For full field details, inspect an existing policy with `cpln policy get POLICY -o yaml`.

## Policy YAML Structure

```yaml
kind: policy                      # Required, must be "policy"
name: my-policy                   # Required, string
description: Policy description   # Optional, max 250 chars
tags:                             # Optional, key-value pairs
  environment: production
targetKind: secret                # Required — singular, lowercase (see valid values below)
target: all                       # Target ALL resources of the kind
# OR
targetLinks:                      # Target SPECIFIC resources by link
  - //secret/my-secret
# OR
targetQuery:                      # Target resources DYNAMICALLY by tags
  spec:
    match: all                    # "all", "any", or "none"
    terms:
      - op: "="
        tag: environment
        value: production
bindings:                         # At least one binding required
  - permissions:                  # Permissions specific to targetKind
      - reveal
      - view
    principalLinks:               # At least one principal required
      - //group/my-group
      - //user/alice@example.com
```

## Valid targetKind Values

All values are **singular, lowercase**. From `cpln policy create --target-kind`:

`account` · `agent` · `auditctx` · `cloudaccount` · `domain` · `group` · `gvc` · `identity` · `image` · `location` · `org` · `policy` · `quota` · `secret` · `serviceaccount` · `spicedbcluster` · `task` · `user` · `volumeset` · `workload`

**Not valid policy targets** even though they are platform resources: `ipset`, `mk8s`, `workloadreplica`. Access to these is controlled via the policies of their parent resources (e.g., `gvc` for workload-scoped constructs, `org` for ipset).

## Target Scope Rules

`target`, `targetLinks`, and `targetQuery` are **mutually exclusive** — use exactly one.

| Method | Field | When to Use |
|:---|:---|:---|
| All resources | `target: all` | Grant access to every resource of the kind |
| Specific resources | `targetLinks: [...]` | Grant access to named resources only |
| Dynamic query | `targetQuery: { spec: ... }` | Grant access to resources matching tags |

### targetLink Format by Resource Kind

| Scope | targetLink Format | Examples |
|:---|:---|:---|
| Org-scoped | `//KIND/NAME` | `//secret/db-creds`, `//domain/app.example.com` |
| GVC | `//gvc/GVC_NAME` | `//gvc/production` |
| GVC-scoped | `//gvc/GVC_NAME/KIND/NAME` | `//gvc/prod/workload/api`, `//gvc/prod/identity/main` |
| User | `//user/EMAIL` | `//user/alice@example.com` |

Org-scoped kinds: agent, auditctx, cloudaccount, domain, group, image, policy, quota, secret, serviceaccount, user.
GVC-scoped kinds: workload, identity, volumeset.

## Binding Structure

Each binding requires `permissions` (array) and `principalLinks` (array). Multiple bindings allowed — each MUST have a unique set of permissions.

### Principal Link Formats

| Principal Type | Format | Example |
|:---|:---|:---|
| User | `//user/EMAIL` | `//user/alice@example.com` |
| Service Account | `//serviceaccount/NAME` | `//serviceaccount/deploy-sa` |
| Group | `//group/NAME` | `//group/developers` |
| Identity | `//gvc/GVC_NAME/identity/NAME` | `//gvc/prod/identity/api-identity` |

## Permissions by Resource Kind

| targetKind | Permissions |
|:---|:---|
| agent | create, delete, edit, manage, use, view |
| auditctx | create, edit, manage, readAudit, view, writeAudit |
| cloudaccount | browse, create, delete, edit, manage, view |
| domain | create, delete, edit, manage, use, view |
| group | create, delete, edit, manage, view |
| gvc | configureLoadBalancer, create, delete, edit, manage, view |
| identity | create, delete, edit, manage, use, view |
| image | create, delete, edit, manage, pull, view |
| org | edit, exec, grafanaAdmin, manage, readLogs, readMetrics, readUsage, view, viewAccessReport |
| policy | create, delete, edit, manage, view |
| quota | create, edit, manage, view |
| secret | create, delete, edit, manage, reveal, use, view |
| serviceaccount | addKey, create, delete, edit, manage, view |
| user | delete, edit, impersonate, invite, manage, view |
| volumeset | create, delete, edit, exec, manage, view |
| workload | configureLoadBalancer, connect, create, delete, edit, exec, manage, view |

Use `cpln policy permissions` or the MCP `mcp__cpln__get_permissions` tool for the authoritative list per kind.

## MCP Tools

| Tool | Purpose |
|:---|:---|
| `mcp__cpln__list_policies` | List all policies in an org |
| `mcp__cpln__get_policy` | Get a specific policy's details and bindings |
| `mcp__cpln__create_policy` | Create a policy with target, permissions, and bindings |
| `mcp__cpln__update_policy` | Update description, tags, targetLinks, or merge new bindings |
| `mcp__cpln__delete_policy` | Delete a policy (irreversible) |
| `mcp__cpln__get_permissions` | Discover valid permissions for a resource kind |

## Common Mistakes

| Mistake | What Happens | Fix |
|:---|:---|:---|
| Plural targetKind (`workloads`) | API rejects manifest | Use singular: `workload` |
| Wrong identity link (`//identity/NAME`) | Binding silently ignored | Identities are GVC-scoped: `//gvc/GVC/identity/NAME` |
| Made-up permission (`read`, `access`) | API rejects | Use exact strings from permissions table above |
| `target: all` WITH `targetLinks` | Conflict, unpredictable behavior | Use one or the other, never both |
| Missing `kind: policy` in manifest | `cpln apply` ignores or fails | Always include `kind: policy` |
| Full self-link in targetLinks | May fail | Use relative format: `//secret/NAME` not `/org/ORG/secret/NAME` |
| Setting `origin` field | Field is read-only | Never set `origin` — system assigns `default` or `builtin` |
| Wrong targetLink scope | Resource not matched | GVC-scoped resources need `//gvc/GVC/KIND/NAME` format |

## Complete Examples

### Grant view on all workloads to a group

```yaml
kind: policy
name: dev-workload-viewers
description: Developers can view all workloads
targetKind: workload
target: all
bindings:
  - permissions:
      - view
    principalLinks:
      - //group/developers
```

### Grant edit on specific GVCs to a service account

```yaml
kind: policy
name: deployer-gvc-access
description: CI/CD deployer can manage staging and prod GVCs
targetKind: gvc
targetLinks:
  - //gvc/staging
  - //gvc/production
bindings:
  - permissions:
      - edit
      - view
    principalLinks:
      - //serviceaccount/deployer
```

### Query-based: access to secrets matching tags

```yaml
kind: policy
name: team-secret-access
description: Grant reveal on secrets tagged for backend team
targetKind: secret
targetQuery:
  spec:
    match: all
    terms:
      - op: "="
        tag: team
        value: backend
bindings:
  - permissions:
      - reveal
      - view
    principalLinks:
      - //group/backend-engineers
```

### Multi-binding: different permissions for different principals

```yaml
kind: policy
name: workload-multi-access
description: Different access levels for different teams
targetKind: workload
target: all
bindings:
  - permissions:
      - view
    principalLinks:
      - //group/viewers
  - permissions:
      - edit
      - exec
    principalLinks:
      - //group/developers
      - //serviceaccount/deploy-bot
```
