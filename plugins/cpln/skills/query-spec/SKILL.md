---
name: query-spec
description: "Filters, selects, and sorts Control Plane resources with the query spec language. Use when the user asks about targetQuery, memberQuery, cpln query commands, tag-based selection, property filtering, or dynamic location selection."
---

# Query Spec — Filtering & Selecting Resources

Control Plane has one query language used in two ways: **ad-hoc filtering** of a resource list (CLI / API), and **dynamic targeting** embedded inside three resource fields.

| Where | Field / command | Purpose |
|:---|:---|:---|
| Policy | `targetQuery` | Target resources by tag/property instead of listing `targetLinks` (see **access-control**) |
| Group | `memberQuery` | Assign members dynamically — **users only** |
| GVC | `spec.staticPlacement.locationQuery` | Select locations dynamically instead of listing `locationLinks` |
| CLI | `cpln KIND query` | Ad-hoc filtering — every resource kind |
| API | `POST /org/ORG/KIND/-query` | Ad-hoc filtering — every resource kind |

**Not an MCP list parameter.** `list_resources` has no filter argument (list a kind, then filter the table yourself); `query_audit_events` filters by kind/name/subject/context/time; `query_metrics` takes PromQL. The query spec appears only inside the three resource fields above, set when you create or update that resource.

## Structure

```yaml
kind: workload          # resource kind being selected
fetch: items            # "items" (objects, default) or "links" (references)
spec:
  match: all            # "all" (default), "any", or "none"
  terms:
    - op: "="
      tag: environment
      value: production
    - op: exists
      tag: monitored
  sort:
    by: name
    order: asc
```

## Terms

Each term targets exactly **one** of three fields (mutually exclusive — the schema rejects a term that sets more than one):

| Field | Targets | Example |
|:---|:---|:---|
| `tag` | Resource tags (key/value labels) | `tag: environment`, `value: production` |
| `property` | Built-in properties (`name`, `description`, `status.phase`, …) | `property: name`, `value: my-app` |
| `rel` | Relationships to other resources | `rel: gvc`, `value: my-gvc` |

### Operators

| Operator | Needs `value` | Meaning |
|:---|:---:|:---|
| `=` | yes | Equal (default when `op` is omitted) |
| `!=` | yes | Not equal |
| `>` `>=` `<` `<=` | yes | Numeric / date comparison |
| `~` | yes | Pattern match (schema op name `match`) |
| `=~` | yes | Regex match (schema op name `regex`) |
| `contains` | yes | Substring match |
| `exists` | no | Tag/property is present (any value) |
| `!exists` | no | Tag/property is absent |

`value` accepts a string, number, boolean, or ISO date. **Boolean values are auto-converted to strings on `tag` terms only** — store `monitored=true` and you must query `value: "true"`, not `value: true`, or it silently matches nothing.

## Match modes

| Mode | Behavior |
|:---|:---|
| `all` | Every term must match (default) |
| `any` | At least one term matches |
| `none` | No term may match |

## Sorting

```yaml
sort:
  by: name            # required
  order: asc          # "asc" (default) or "desc"
```

Sort is **API- and manifest-only** — the `cpln KIND query` CLI has no sort flag, so a sort directive passed there is ignored.

Common fields (most kinds): `id`, `name`, `version`, `description`, `created`, `lastModified`. Kind-specific: `location` adds `origin`/`provider`/`region`; `cloudaccount` adds `provider`; `user` adds `idp`/`email`; `policy` and `group` add `origin`.

## CLI

**Ad-hoc filtering** — every kind supports `query`:

```bash
cpln workload query --tag environment=production
cpln workload query --match all --tag environment=production --tag region=europe
cpln workload query --rel gvc=my-gvc
cpln policy query --prop name=my-policy
cpln workload query --tag monitored                       # existence (no value)
cpln workload query --match any --rel gvc=one --rel gvc=two
```

| Flag | Alias | Notes |
|:---|:---|:---|
| `--match` | | `all` / `any` / `none` (default `all`); single value |
| `--tag` | | `KEY=VALUE`, or `KEY` for existence; repeatable |
| `--property` | `--prop` | `KEY=VALUE`; repeatable |
| `--rel` | | `KEY=VALUE`; repeatable |

Results cap at 50 by default — raise with `--max 0` for all records.

**Authoring dynamic targeting** — `gvc`, `policy`, and `group` create/update commands embed a query via `--query-match`, `--query-tag`, `--query-property`, `--query-rel` (group also `--query-kind user`):

```bash
cpln policy create --name img-policy --query-kind image --query-property repository=my-app ...
```

## API

```
POST https://api.cpln.io/org/ORG/workload/-query
```

```json
{ "spec": { "match": "all",
  "terms": [
    { "op": "=", "tag": "region", "value": "emea" },
    { "rel": "gvc", "op": "=", "value": "mygvc" }
  ],
  "sort": { "by": "name", "order": "asc" } } }
```

## Dynamic targeting examples

**Policy `targetQuery`** — applies to matching resources, including ones created later:

```yaml
kind: policy
targetKind: image
targetQuery:
  spec:
    terms:
      - { property: repository, value: my-app }
bindings:
  - permissions: [pull, view]
    principalLinks: [//group/developers]
```

**Group `memberQuery`** — dynamic membership by user tag (users only; service accounts must be added via `memberLinks`):

```yaml
kind: group
memberQuery:
  kind: user
  spec:
    terms:
      - { tag: "firebase/sign_in_provider", value: "microsoft.com" }
```

## Defaults & gotchas

- Omitted `op` defaults to `=`; omitted `match` defaults to `all`; omitted `fetch` defaults to `items`; omitted sort `order` defaults to `asc`.
- Boolean tag values become strings — query `"true"`, not `true`.
- `targetQuery` is retroactive: tag a new resource and matching policies cover it automatically — a scope to watch when granting permissions.
- `memberQuery` ignores service accounts.

## Related

**access-control** (policy `targetQuery` / group `memberQuery` in context) · **cpln** (CLI command surface).
