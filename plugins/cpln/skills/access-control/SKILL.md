---
name: access-control
description: "Primary skill for access control, policies, and RBAC on Control Plane. Use when the user asks about permissions, policies, service accounts, user access, group membership, bindings, who can do what, least-privilege, or IAM."
---

# Access Control & Policies — Primary Skill

A **policy** targets one resource kind and binds **permissions** to **principals** (users, groups, service accounts, workload identities). The common failure is a policy that **exists but grants nothing** — a wrong `targetKind`, permission name, or principal link fails with no error — so read the policy back after writing.

## The model

| Layer | Scope | Controls |
|---|---|---|
| **Billing-account roles** | account-wide (set on the billing account, separate from org policies) | `billing_admin`, `billing_viewer`, `org_creator` — none grant org-resource access |
| **Org policies** | per resource kind | all day-to-day access |

A caller is allowed an action when some policy on the resource's kind has a binding that lists that action (or a permission implying it) **and** names the caller — or a group the caller is in.

## Policy anatomy

A policy = one **`targetKind`** + a **target scope** + **bindings**.

```yaml
kind: policy
name: app-secret-access
targetKind: secret           # exactly one resource kind
targetLinks:                 # OR `target: all` OR `targetQuery:` (pick one)
  - //secret/database-url
bindings:                    # ≤ 50
  - permissions: [reveal, use]
    principalLinks:          # 1–200
      - //gvc/production/identity/app-identity
```

**Limits:** `bindings` ≤ 50; `principalLinks` 1–200 per binding; `targetLinks` ≤ 200. `origin` is read-only — `default` (yours) or `builtin` (locked; see Built-ins).

**Target scope (pick one):** `target: all` (org-wide roles) · `targetLinks` (specific resources) · `targetQuery` (tag query — see **query-spec**).

**Valid target kinds:** `workload, secret, gvc, identity, image, org, policy, group, serviceaccount, user, volumeset, domain, location, ipset, mk8s, cloudaccount, agent, auditctx, quota, task` — `ipset` and `mk8s` included.

**Create vs update:**
- `create_policy` builds **one** binding from `addPermissions` × (`addUsers`/`addGroups`/`addServiceAccounts`/`addIdentities`), and only if **both** sides are non-empty. For several distinct bindings, use `update_policy` `addBindings`.
- `update_policy` **merges** bindings (matched by exact permission set — you can't extend a set) but **replaces** targets (`targetLinks` wholesale, `removeTargetLinks` incremental, `targetAll` — mutually exclusive).

## Permissions

**`get_permissions` (`kind`) is the source of truth** — it returns the kind's exact permission list and its implication map. Confirm names with it before writing a policy; never hand-write them, and don't assume a kind only has `create` / `delete` / `edit` / `view` / `manage`.

Two traps that don't need a lookup:
- **`manage` implies every permission** for a kind — grant it only to true admins.
- **Secret values need `reveal`, not `read`** — the most common mistake.

Many kinds add non-obvious permissions beyond CRUD — e.g. secret `reveal`/`use`, image `pull`, workload `connect`/`exec.*`, serviceaccount `addKey`, user `invite`/`impersonate`, mk8s `clusterAdmin` — so pull the real set with `get_permissions`.

## Principals

| Type | Link |
|---|---|
| User | `//user/EMAIL` |
| Group (preferred) | `//group/NAME` |
| Service account | `//serviceaccount/NAME` |
| Workload identity | `//gvc/GVC/identity/NAME` (**GVC-scoped** — never `//identity/NAME`) |

An **identity never belongs to a group**, so authorize it only with a binding that names its exact link.

### Groups
Members are **users and service accounts only** (≤ 200). Bind policies to groups, not individuals.
- **Create / edit:** `create_group` (`name`, `memberLinks`, `memberQuery`, `identityMatcher`); `edit_group` (`addMemberLinks` / `removeMemberLinks` — read first with `get_group`).
- **Dynamic:** `memberQuery` matches users by tag query; `identityMatcher` matches identities by a `jmespath`/`javascript` expression.

### Service accounts (non-human / CI/CD)
- **Key:** `add_key_to_service_account` (`serviceAccountName`, **`keyDescription` required**, optional `groupName`) — **auto-creates the SA if missing** and returns the key **once** (save it; lost = revoke + remint). `create_service_account` makes one with no key.
- **Revoke:** `update_service_account` `removeKeys: [NAME]` (immediate). `delete_service_account` revokes all keys.
- **CI/CD auth:** store the key as the `CPLN_TOKEN` secret/env var — the CLI uses it ahead of any profile (and works without one); don't pass `--token` on the command line (it leaks into logs). Full setup: **gitops-cicd**.

### Users (IDP-backed)
- **Invite:** `invite_user_to_org` (`email`, optional `groupName`).
- **Read / remove:** `get_user` / `delete_user` take **`identifier`** (id or email); `list_users` has an `email` filter. No `create_user`/`update_user`.

## Built-ins (seeded per org)

| Resource | Name | Grants |
|---|---|---|
| Group | `superusers` | `manage` on every kind (creator auto-added) |
| Group | `viewers` | `view` on every kind |
| Service account | `controlplane` | platform-internal — off-limits |
| Policies | `superusers-KIND` / `viewers-KIND` | `origin: builtin`, `target: all` |

- **Grant org-admin by adding the principal to `superusers`** (or `viewers` for read-only) — don't recreate admin policies.
- Built-in **policies** can't be created/edited/deleted; built-in **groups** can't be deleted, but their membership is editable (you can't remove yourself from `superusers`).
- Any resource tagged **`cpln/protected=true` can't be deleted** until untagged.

## Common RBAC patterns

`create_policy` builds these; the `cpln apply -f` manifest is the policy-as-code equivalent for CI/CD.

- **Org admin** — add to `superusers`. Scoped admin — one policy per `targetKind` with `[manage]`.
- **GVC developer** — `workload` `[connect, create, delete, edit, exec, view]` + `secret` `[create, delete, edit, reveal, use, view]` on a `developers` group.
- **Read-only** — add to `viewers`.
- **CI/CD SA** — `workload` `[create, delete, edit, view]` + `image` `[create, pull, view]` + `secret` `[use, view]` on `//serviceaccount/cicd-deployer`.
- **Workload identity secret access** — the anatomy example above; full flow in **setup-secret** (create identity, bind, attach via `spec.identityLink`).
- **Auditor** — `policy` `[view]` + `auditctx` `[view]` on an `auditors` group.

## Standard flow

1. `get_cpln_rules` (once per mutating session) and read this skill.
2. Confirm the **org** (and **gvc** for identities) — never guess.
3. `get_permissions` for the kind — confirm permission names.
4. Read current state: `list_policies` / `get_policy` (+ `get_group` / `get_service_account`).
5. Smallest change; if destructive, confirm blast radius.
6. `create_policy` / `update_policy` (+ group / SA / user tools).
7. **Verify:** read the policy back; confirm the bindings and target resolved.

## Quick reference — MCP tools

| Tool | Purpose | Key params |
|---|---|---|
| `mcp__cpln__get_permissions` | Permissions + implications for a kind | `kind` |
| `mcp__cpln__list_policies` / `get_policy` | List / read policies | `name` |
| `mcp__cpln__create_policy` | Create a policy | `name`, `targetKind`, `targetAll`/`targetLinks`/`targetQuery`, `addPermissions`, `addUsers`/`addGroups`/`addServiceAccounts`/`addIdentities` |
| `mcp__cpln__update_policy` | Update metadata, targets, bindings | `name`, `addBindings`/`removeBindings`, `targetLinks`/`removeTargetLinks`/`targetAll`, `targetQuery` |
| `mcp__cpln__delete_policy` | Delete a policy (destructive) | `name` |
| `mcp__cpln__list_groups` / `get_group` | List / read groups | `name` |
| `mcp__cpln__create_group` | Create a group | `name`, `memberLinks`, `memberQuery`, `identityMatcher` |
| `mcp__cpln__edit_group` | Add/remove members, update meta | `name`, `addMemberLinks`, `removeMemberLinks` |
| `mcp__cpln__delete_group` | Delete a group (destructive) | `name` |
| `mcp__cpln__list_service_accounts` / `get_service_account` | List / read SAs (key metadata only) | `name` |
| `mcp__cpln__create_service_account` | Create an SA (no key) | `name`, `description` |
| `mcp__cpln__add_key_to_service_account` | Mint a key (auto-creates SA) | `serviceAccountName`, `keyDescription`, `groupName` |
| `mcp__cpln__update_service_account` | Update meta / revoke keys | `name`, `removeKeys` |
| `mcp__cpln__delete_service_account` | Delete an SA (revokes all keys) | `name` |
| `mcp__cpln__list_users` / `get_user` | List / read users | `email` / `identifier` |
| `mcp__cpln__invite_user_to_org` | Invite a user by email | `email`, `groupName` |
| `mcp__cpln__delete_user` | Remove a user (destructive) | `identifier` |

**CLI fallback** (read the `cpln` skill first; verify with `cpln <resource> --help`): policy-as-code in CI/CD (`CPLN_TOKEN` + `cpln apply -f`), `cpln RESOURCE permissions` to list a kind's permissions, `cpln policy access-report NAME` to audit a policy.

## Related skills

| Need | Skill |
|---|---|
| Query language for `targetQuery` / `memberQuery` | `query-spec` |
| Org creation, billing, profiles, SSO | `org-management` |
| Audit trail of policy / access changes | `audit-compliance` |
| Full workload secret-access flow | `setup-secret` |
| Workload identities, cloud identity | `native-networking` |

## Documentation

- [Access Control Concepts](https://docs.controlplane.com/concepts/access-control.md)
- [Policy Reference](https://docs.controlplane.com/reference/policy.md)
