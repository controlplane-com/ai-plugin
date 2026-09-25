---
name: access-control
description: "Primary skill for access control, policies, and RBAC on Control Plane. Use when the user asks about permissions, policies, service accounts, user access, group membership, bindings, who can do what, least-privilege, or IAM."
---

# Access Control & Policies — Primary Skill

> **Tool availability:** `create_group`, `edit_group`, `create_service_account`, `update_service_account`, `add_key_to_service_account`, and `invite_user_to_org` need `?toolsets=full`; reconnect with it or use the CLI.

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

**Valid target kinds:** the `targetKind` enum accepts all **33** resource kinds, but only the **20 kinds with permission schemas** (the ones `get_permissions` accepts) are meaningful targets: `workload, secret, gvc, identity, image, org, policy, group, serviceaccount, user, volumeset, domain, location, ipset, mk8s, cloudaccount, agent, auditctx, quota, task`.

**Create vs update:**
- `create_policy` builds **one** binding from `addPermissions` × (`addUsers`/`addGroups`/`addServiceAccounts`/`addIdentities`) — providing only one side is an **error** (a binding needs both). It also requires **exactly one** target scope (`targetAll` / `targetLinks` / `targetQuery`). For several distinct bindings, use `update_policy` `addBindings`.
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

An **identity never belongs to a group**, so authorize it only with a binding that names its exact link. At runtime the attached identity is the workload's API credential: calls from inside the workload with the injected `CPLN_TOKEN` against `CPLN_ENDPOINT` carry exactly the permissions policies grant that identity — nothing more.

### Groups
Members are **users and service accounts only** (≤ 200). Bind policies to groups, not individuals.
- **Create / edit:** `create_group` (`name`, `memberLinks`, `memberQuery`, `identityMatcher`); `edit_group` (`addMemberLinks` / `removeMemberLinks` — read first with `get_resource` (kind="group")).
- **Dynamic:** `memberQuery` matches users by tag query; `identityMatcher` matches identities by a `jmespath`/`javascript` expression.

### Service accounts (non-human / CI/CD)
- **Key:** `add_key_to_service_account` (`serviceAccountName`, optional `keyDescription` and `groupName`) creates the SA if missing and returns the Console keys page, where the user adds the key and sees it once; the key never passes through the chat (lost = revoke + remint). `create_service_account` makes one with no key.
- **Revoke:** `update_service_account` `removeKeys: [NAME]` (immediate). `delete_resource` (kind="serviceaccount") revokes all keys.
- **CI/CD auth:** store the key as the `CPLN_TOKEN` secret/env var — the CLI uses it ahead of any profile (and works without one); don't pass `--token` on the command line (it leaks into logs). Full setup: **gitops-cicd**.

### Users (IDP-backed)
- **Invite:** `invite_user_to_org` (`email`, optional `groupName`).
- **Read / remove:** `get_resource` (kind="user") / `delete_resource` (kind="user") take **`identifier`** (id or email); `list_resources` (kind="user") has an `email` filter.

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

1. Confirm the **org** (and **gvc** for identities); never guess.
2. `get_permissions` for the kind: confirm permission names.
3. Read current state: `list_resources` (kind="policy") / `get_resource` (kind="policy") (+ `get_resource` kind="group" / kind="serviceaccount").
4. Smallest change; if destructive, confirm blast radius.
5. `create_policy` / `update_policy` (+ group / SA / user tools).
6. **Verify:** read the policy back; confirm the bindings and target resolved.
