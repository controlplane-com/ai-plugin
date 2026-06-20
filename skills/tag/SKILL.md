---
name: tag
description: "Resource tags on Control Plane — labels that organize resources, trigger built-in cpln/ behaviors, and drive targeting. Use when the user asks about tags, labels, tagging, naming conventions, or resource protection."
---

# Tags — Labeling, Built-in Behaviors & Targeting

Tags are **key-value labels** on almost every Control Plane resource (workload, GVC, identity, secret, policy, group, domain, image, volumeset, agent, ipset, org, mk8s, user, service account). They live in a top-level `tags:` map. A tag is three things at once: **metadata** for humans, a **selector** that policies/groups/GVCs/queries target, and — under the reserved `cpln/` namespace — a **switch** that turns on platform behavior the spec doesn't yet expose as a field.

## Why tags pay off

| Capability | What a tag unlocks | Mechanism |
|:---|:---|:---|
| Dynamic RBAC | A policy `targetQuery` on `environment=production` grants on every match — **including resources created later** | **access-control** |
| Dynamic group membership | A group `memberQuery` auto-enrolls users by tag (e.g. SSO provider) | **access-control** |
| Dynamic placement | A GVC `locationQuery` picks locations by tag (e.g. `cpln/country`) instead of a fixed list | **query-spec** |
| Fleet inventory & bulk ops | `cpln KIND query --tag tier=frontend` finds every matching resource to act on | **cpln** |
| Built-in behaviors | Reserved `cpln/*` tags switch on features (protection, sticky sessions, mTLS, …) | see below |
| Console organization | List columns, custom logos, saved groups, and the Query filter all read tags | see below |

The payoff is **retroactive and self-maintaining**: tag a new workload `environment=production` and every prod policy, group, and dashboard that queries that tag covers it automatically — no rule edits.

## Setting tags

| Where | How |
|:---|:---|
| CLI, dedicated | `cpln KIND tag NAME --tag key=value` (repeatable); `--remove-tag key` drops one |
| CLI, on create | `cpln KIND create ... --tag key=value` |
| CLI, generic update | `cpln KIND update NAME --set tags.key=value` (kinds with no `tag` subcommand, e.g. `user`) |
| MCP | The `mcp__cpln__create_*` / `update_*` tool for the kind accepts a `tags` object |
| Manifest | A top-level `tags:` map, then `cpln apply -f FILE` |

```bash
cpln workload tag my-api --tag environment=production --tag team=payments
cpln workload tag my-api --remove-tag team
```

**`=` guesses the type, `:` forces a string.** `--tag replicas=3` stores the number `3`; `--tag replicas:3` stores the string `"3"`; an empty value (`--tag key=`) stores `null`. This matters because queries are type-sensitive (see Gotchas).

## A taxonomy that earns its keep

Tags become leverage only when keys and values are **uniform** — a query for `environment=production` silently misses anything tagged `env=prod` or `Environment=Production`. Agree on a small, lowercase vocabulary up front:

| Key | Example values | Drives |
|:---|:---|:---|
| `environment` | `production`, `staging`, `dev` | RBAC scope, dashboards, promotion |
| `team` / `owner` | `payments`, `platform` | ownership, on-call routing, group queries |
| `tier` | `frontend`, `backend`, `data` | fleet ops, firewall / policy scope |
| `app` | `checkout`, `billing-api` | grouping multi-workload apps |
| `managed-by` | `terraform`, `console` | drift detection, IaC ownership |

Tag for the keys you will actually query; a tag nobody selects on is just decoration. Stay out of the `cpln/`, `syncer.cpln.io/`, and `firebase/` prefixes — those are platform-defined (below).

## Built-in tags that change behavior

The `cpln/` namespace is reserved: don't invent your own keys under it, but **do** set the documented tags below to switch on behavior. They are the escape hatch for options not yet first-class fields.

**Any resource — deletion guard.** `cpln/protected=true` makes the platform refuse to delete the resource (any kind); remove the tag to delete. The MCP `delete_resource` and `cpln KIND delete` both fail until it's cleared. In the Console it's the lock switch next to **Actions**.

```bash
cpln workload tag WORKLOAD --tag cpln/protected=true     # block delete
cpln workload tag WORKLOAD --remove-tag cpln/protected   # allow delete
```

**Workload behavior:**

| Tag | Value | Effect |
|:---|:---|:---|
| `cpln/timeoutSecondsOverride` | seconds (≤3600) | Raise the request timeout past the 600s ceiling |
| `cpln/largeDisk` | `true` | Allocate a large ephemeral disk |
| `cpln/tracingDisabled` | `true` | Turn off distributed tracing for this workload |
| `cpln/publishNotReadyAddresses` | `true` | Route internal traffic to replicas before they pass readiness |
| `cpln/discoverCrossGvcReplicas` | `true` | Discover replicas in other GVCs over mTLS |
| `cpln/bypassProxyOutbound` | `true` | Skip the service-mesh proxy on outbound traffic |
| `cpln/disableServiceMeshInboundPort` / `...OutboundPort` | port | Exclude one port from the service mesh |
| `cpln/externalAuth*` | family | Route every request through an external authorization service (`...Address` required; see **workload-security**) |
| `cpln/rateLimit*` | family | Enforce limits via an external rate-limit service (`...Address` required; see **cdn-rate-limiting**) |

BYOK / Direct-LB workloads add `cpln/disableServiceMesh`, `cpln/disableServiceMeshOutboundCIDR`, and `cpln/k8sClusterRole`.

**GVC — sticky sessions** (apply to every workload in the GVC): `cpln/sessionCookie` (cookie name) plus `cpln/sessionDuration` (a Go duration, e.g. `30m`).

**Domain:** `cpln/clientCertificateValidation=enabled` requires a valid client cert, i.e. mTLS (**domain**); `cpln/skipDNSCheck=true` skips DNS validation; `cpln/wildcard=true` enables a wildcard certificate.

## Auto-populated tags you can target

Some tags are set *by the platform* and are read-only — their value is that you can **query** them:

| Tag | On | Use |
|:---|:---|:---|
| `cpln/city` / `cpln/country` / `cpln/continent` | location | Select locations by geography in a GVC `locationQuery` |
| `firebase/sign_in_provider` | user | Auto-enroll users by SSO provider in a group `memberQuery` |
| `syncer.cpln.io/source` / `syncer.cpln.io/lastError` | secret | Trace External-Secret-Syncer ownership and its last sync error |
| `cpln/release` | helm-managed resources | Identify what `cpln helm` created |

## In the Console

| Tag | UI behavior |
|:---|:---|
| `cpln/protected` | Toggled by the lock switch; blocks the Delete action |
| Any tag whose value is a URL (`https://`, `http://`, `ws://`, `wss://`) | Rendered as a clickable link in the resource's Tag Links |
| `cpln/console.tagColumns` (org) | Surfaces chosen tags as list columns, e.g. `workload=env,team;gvc=region` |
| `cpln/custom-logo` / `cpln/custom-logo-dark` (org) | Custom org logo in the sidebar |
| `resourceGroup::KEY[::VALUE]` (org) | Saved, pinnable resource groups in the sidebar nav |

The **Query** button on any list maps directly to the query spec (match All / Any / None) — see **query-spec**.

## Worked examples

**Production RBAC by tag (retroactive).** Tag the workloads, then grant once:

```bash
cpln workload tag checkout payments-api --tag environment=production
cpln policy create --name prod-operators --target-kind workload \
  --query-tag environment=production          # then add a binding — see access-control
```

New workloads tagged `environment=production` fall under the policy automatically.

**Fleet query.** Find every frontend workload to audit or roll: `cpln workload query --tag tier=frontend`.

## Gotchas

| Trap | Detail |
|:---|:---|
| Booleans match as strings | A tag stored `true` is the string `"true"` — query `value: "true"`, not `true`, or it matches nothing |
| Set-time type matters | `--tag n=5` stores a number, `--tag n:5` a string; query the same type you stored |
| No inheritance | A GVC's tags do **not** flow to its workloads — tag each resource you want matched |
| Mutable on immutable resources | Name and type are fixed, but tags are always editable — even on the org |
| Protected blocks delete | `cpln/protected=true` makes deletes fail until you remove the tag |
| Removal | `--remove-tag key` (or set the value `null`); an empty value is kept as a marker, not deleted |
| Case-sensitive | Keys and values are exact-match; `Prod` is not `prod` |

## Verify

- `cpln KIND get NAME -o yaml` — confirm the `tags:` block.
- `cpln KIND query --tag key=value` — confirm the resource is selected by the tag a policy or group will use.

## Related skills

- **query-spec** — the query language: operators, match modes, and the three fields tags feed (`targetQuery`, `memberQuery`, `locationQuery`).
- **access-control** — policy `targetQuery` and group `memberQuery` in context.
- **workload-security** / **cdn-rate-limiting** — the `cpln/externalAuth*` and `cpln/rateLimit*` tag families.
- **domain** — `cpln/clientCertificateValidation`, `cpln/skipDNSCheck`, `cpln/wildcard`.
- **cpln** — the full CLI resource-command map.

## Documentation

- [Tags](https://docs.controlplane.com/core/misc.md) · [Query](https://docs.controlplane.com/core/query.md) · [Resource Protection](https://docs.controlplane.com/guides/resource-protection.md) · [Workload special tags](https://docs.controlplane.com/reference/workload/general.md)
