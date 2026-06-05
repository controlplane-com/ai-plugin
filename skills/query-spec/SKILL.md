---
name: query-spec
description: "Filters, selects, and sorts Control Plane resources using the query spec language. Use when the user asks about targetQuery, memberQuery, cpln query commands, tag-based selection, property filtering, or dynamic location selection. Covers query spec syntax (match/property/rel/sort/tag), policy targetQuery, group memberQuery, and GVC dynamic locations."
---

# Query Spec — Filtering & Sorting Resources

Control Plane has a universal query system for filtering and sorting resources. The same spec is used everywhere:

- **Policy** `targetQuery` — dynamically target resources by tags/properties (authored via `mcp__cpln__create_policy` / `mcp__cpln__update_policy`)
- **Group** `memberQuery` — dynamically assign users to groups (authored via `mcp__cpln__create_group` / `mcp__cpln__edit_group`)
- **GVC** `staticPlacement.locationQuery` — select locations by query instead of explicit `locationLinks` (authored via `mcp__cpln__create_gvc` / `mcp__cpln__update_gvc`)
- **MCP list/query tools** — the list tools accept the same `*_query` spec param to filter results: `mcp__cpln__list_workloads`, `mcp__cpln__list_secrets`, `mcp__cpln__list_identities`, `mcp__cpln__list_policies`, plus `mcp__cpln__query_audit_events` and `mcp__cpln__query_metrics`. **Prefer these for ad-hoc filtering.**
- **CLI** `cpln RESOURCE query` — fallback for the command line when the MCP server is unavailable
- **API** `POST /org/ORG/RESOURCE/-query` — filter via REST

## Query Structure

```yaml
kind: workload              # resource kind to query
fetch: items                # "items" (default) or "links"
spec:
  match: all                # "all", "any", or "none"
  terms:
    - op: "="
      tag: environment
      value: production
    - op: "exists"
      tag: monitored
  sort:
    by: name
    order: asc
```

### Match Modes

| Mode | Behavior |
|:---|:---|
| `all` | Every term must match (default) |
| `any` | At least one term matches |
| `none` | No terms may match |

## Terms

Each term filters on exactly **one** of three fields (mutually exclusive):

| Field | What It Targets | Example |
|:---|:---|:---|
| `tag` | Resource tags (key-value labels) | `tag: environment`, `value: production` |
| `property` | Resource properties (name, description, etc.) | `property: name`, `value: my-app` |
| `rel` | Resource relationships | `rel: gvc`, `value: my-gvc` |

### Operators

| Operator | Category | Requires `value` | Description |
|:---|:---|:---:|:---|
| `=` | Equality | Yes | Exact match (default if `op` omitted) |
| `!=` | Equality | Yes | Not equal |
| `>` | Comparison | Yes | Greater than |
| `>=` | Comparison | Yes | Greater than or equal |
| `<` | Comparison | Yes | Less than |
| `<=` | Comparison | Yes | Less than or equal |
| `~` | Pattern | Yes | Regex match |
| `=~` | Pattern | Yes | Regex match (case-sensitive) |
| `contains` | String | Yes | Substring match |
| `exists` | Existence | No | Tag/property exists (any value) |
| `!exists` | Existence | No | Tag/property does not exist |

## Sorting

Optional. Only available via API/manifest (not exposed as CLI flags).

```yaml
sort:
  by: name          # required — field to sort by
  order: asc        # "asc" (default) or "desc"
```

### Common Sort Fields

Available for most resources: `id`, `name`, `version`, `description`, `created`, `lastModified`.

Resource-specific fields:

| Resource | Extra Sort Fields |
|:---|:---|
| **location** | `origin`, `provider`, `region` |
| **cloudaccount** | `provider` |
| **user** | `idp`, `email` |
| **policy** | `origin` |
| **group** | `origin` |

## MCP-First Filtering

For ad-hoc filtering, pass the query spec to the list/query MCP tools rather than reaching for the CLI:

- `mcp__cpln__list_workloads`, `mcp__cpln__list_secrets`, `mcp__cpln__list_identities`, `mcp__cpln__list_policies` accept a `*_query` spec param that takes the same `match` / `terms` / `sort` shape shown above.
- `mcp__cpln__query_audit_events` filters the audit trail; `mcp__cpln__query_metrics` filters metric series.

The CLI shapes below are the fallback when the MCP server is unavailable or unauthenticated.

## CLI Usage (Fallback)

Every resource kind supports `cpln RESOURCE query`:

```bash
# Filter workloads by tag
cpln workload query --tag environment=production

# Filter with multiple tags (match all)
cpln workload query --match all --tag environment=production --tag region=europe

# Filter by relation (e.g., workloads in a specific GVC)
cpln workload query --rel gvc=my-gvc

# Filter by property
cpln policy query --prop name=my-policy

# Existence check (tag exists, no value)
cpln workload query --tag monitored

# Combine tag + rel
cpln workload query --match all --rel gvc=emea --tag payment-service=true

# Match any of multiple GVCs
cpln workload query --match any --rel gvc=gvc-one --rel gvc=gvc-two
```

### CLI Query Flags

| Flag | Alias | Description |
|:---|:---|:---|
| `--match` | | Match mode: `all`, `any`, `none` (default: `all`) |
| `--tag` | | Filter by tag: `key=value` or just `key` for existence |
| `--property` | `--prop` | Filter by property: `key=value` |
| `--rel` | | Filter by relation: `key=value` |

`--tag`, `--property`, and `--rel` can be repeated to add multiple terms. `--match` accepts a single value.

**Resources supporting query:** agent, auditctx, cloudaccount, domain, group, gvc, identity, image, ipset, location, mk8s, org, policy, quota, secret, serviceaccount, task, user, volumeset, workload.

## API Usage (Fallback)

When neither an MCP tool nor the CLI fits, every resource kind exposes a `/-query` POST endpoint:

```
POST https://api.cpln.io/org/ORG_NAME/workload/-query
```

```json
{
  "spec": {
    "match": "all",
    "terms": [
      { "op": "=", "tag": "region", "value": "emea" },
      { "rel": "gvc", "op": "=", "value": "mygvc" }
    ],
    "sort": { "by": "name", "order": "asc" }
  }
}
```

## Policy targetQuery

Policies can dynamically target resources instead of listing them explicitly in `targetLinks`:

```yaml
kind: policy
name: image-repo-policy
targetKind: image
targetQuery:
  kind: image
  fetch: items
  spec:
    match: all
    terms:
      - op: "="
        property: repository
        value: my-app
bindings:
  - permissions:
      - pull
      - view
    principalLinks:
      - //group/developers
```

This policy automatically applies to any image whose `repository` property equals `my-app` — including images created after the policy.

## Group memberQuery

Groups can dynamically assign users based on user tags:

```yaml
kind: group
name: microsoft-users
memberQuery:
  kind: user
  fetch: items
  spec:
    match: all
    terms:
      - op: "="
        tag: firebase/sign_in_provider
        value: microsoft.com
```

**Dynamic membership works for users only.** Service accounts must be added directly via `memberLinks`.

## Validation Constraints

From the platform schema:

- Each term uses exactly one of `tag`, `property`, or `rel` (mutually exclusive)
- `value` is required for all operators except `exists` and `!exists`
- `value` accepts: string, number, boolean, or date (ISO format)
- Boolean values in tag terms are auto-converted to strings (`true` → `"true"`)
- Default `op` is `=` if omitted
- Default `match` is `all` if omitted
- Default `fetch` is `items`
- Default sort `order` is `asc`

## Documentation

For the latest reference, see:

- [Query Reference](https://docs.controlplane.com/core/query.md)
- [Logs Reference](https://docs.controlplane.com/core/logs.md)
