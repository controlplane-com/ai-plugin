---
name: cpln-access-control
description: "Sets up access control, policies, and RBAC on Control Plane. Use when the user asks about permissions, policies, service accounts, user access, group membership, bindings, who can do what, least-privilege setup, or IAM. Covers policy creation, permission bindings, group management, service account setup, user invitation, and common RBAC patterns."
version: 1.0.0
---

# Access Control & Policy Patterns

This is the **#1 area where mistakes happen** on Control Plane. Wrong `targetKind`, wrong binding syntax, wrong permission names — all silently fail. Use this skill any time you create policies, manage groups, invite users, or set up service accounts.

For the per-resource permissions table and built-in groups/policies, see `skills/access-control/permissions-matrix.md`. For day-to-day group, service-account, and user management workflows, see `skills/access-control/principals.md`.

## Access Control Model

Control Plane uses a **two-part** access control system:

| Layer | Scope | Purpose |
|:---|:---|:---|
| **Billing account roles** | Account-wide | Coarse-grained: who can manage billing, create orgs |
| **Org-level policies** | Per-resource | Fine-grained: who can do what on which resources |

### Billing Account Roles

| Role | Description |
|:---|:---|
| `billing_admin` | Full access to billing settings and invoices |
| `billing_viewer` | Read-only access to billing information |
| `org_creator` | Can create new organizations under the billing account |

**Billing roles are independent from org policies.** A `billing_admin` has zero implicit permissions on org resources.

### Org-Level Policies

Policies grant fine-grained permissions on specific resource types to specific principals (users, groups, service accounts, identities). This is where all day-to-day access control happens.

## Policy Structure

A policy has four parts: **target kind**, **target scope**, **bindings**, and **origin**.

```yaml
kind: policy
name: POLICY_NAME
description: Optional description
tags:
  team: backend
origin: default
targetKind: secret
targetLinks:                    # OR target: all OR targetQuery
  - //secret/my-secret
bindings:                       # max 50 bindings
  - permissions:                # sorted, unique
      - reveal
      - view
    principalLinks:             # 1-200 links
      - //group/developers
```

### Target Kind

The `targetKind` field specifies which resource type this policy applies to. Common kinds: `secret`, `workload`, `gvc`, `identity`, `domain`, `image`, `serviceaccount`, `group`, `org`.

For the full authoritative list (verified against `cpln policy create --target-kind`), see **rules/policy-manifest-reference.md**. Note: `ipset` and `mk8s` are platform resources but are NOT valid policy targets — access is controlled via their parent (`org` or `gvc`).

### Target Scope

Three mutually exclusive ways to select which resources a policy applies to:

| Method | Field | CLI Flag | When to Use |
|:---|:---|:---|:---|
| **All resources** | `target: all` | `--all` | Org-wide roles (admin, viewer) |
| **Named resources** | `targetLinks: [//secret/NAME]` | `--resource NAME` | Scoped access to specific resources |
| **Tag query** | `targetQuery: {...}` | `--query-tag TAG` | Dynamic scoping based on tags |

**Decision rule:** Use `target: all` for role-based patterns. Use `targetLinks` when you know the exact resources. Use `targetQuery` when resources share tags (e.g., `team=backend`).

#### Target Query

Use `targetQuery` to dynamically target resources by tags or properties. See the **cpln-query-spec** skill for the full query system (operators, match modes, term fields).

```yaml
targetQuery:
  kind: secret
  fetch: items
  spec:
    match: all
    terms:
      - op: "="
        tag: team
        value: backend
```

### Origin

| Origin | Meaning | Modifiable? |
|:---|:---|:---|
| `default` | User-created policies | Yes |
| `builtin` | System-provided defaults (e.g., `superusers-secret`) | **No — cannot be modified or deleted** |

Built-in policies cover common roles like `superusers-RESOURCE` and `viewers-RESOURCE` — see `skills/access-control/permissions-matrix.md` for the full list.

## Bindings

Bindings link principals (who) to permissions (what they can do).

```yaml
bindings:
  - permissions:
      - reveal
      - view
    principalLinks:
      - //group/backend-team
      - //serviceaccount/ci-deployer
```

**Constraints:**
- Each binding's permissions must be **unique**. The API auto-sorts them alphabetically — you don't need to sort manually.
- A policy can have up to **50 bindings**, each with up to **200 principal links**.
- The same principal can appear in multiple bindings (different permission sets).

### Principal Link Formats

| Principal Type | Format | Example |
|:---|:---|:---|
| User | `//user/USER_EMAIL` | `//user/alice@example.com` |
| Group | `//group/GROUP_NAME` | `//group/backend-team` |
| Service Account | `//serviceaccount/SA_NAME` | `//serviceaccount/cicd-deployer` |
| Identity (workload-bound) | `//gvc/GVC_NAME/identity/IDENTITY_NAME` | `//gvc/production/identity/app-identity` |

Short format (org from context): `//user/USER_EMAIL`

## Common RBAC Patterns

### Org Admin — Full Access to Everything

```yaml
kind: policy
name: org-admin-policy
targetKind: org
target: all
bindings:
  - permissions:
      - manage
    principalLinks:
      - //group/org-admins
```

Repeat for each `targetKind` the admin needs, or create one policy per kind. There is no single "super-admin" policy that covers all kinds — you need one policy per `targetKind`.

### GVC Developer — Create/Edit Workloads and Secrets in a GVC

```yaml
kind: policy
name: gvc-dev-workloads
targetKind: workload
target: all
bindings:
  - permissions:
      - connect
      - create
      - delete
      - edit
      - exec
      - view
    principalLinks:
      - //group/gvc-developers
---
kind: policy
name: gvc-dev-secrets
targetKind: secret
target: all
bindings:
  - permissions:
      - create
      - delete
      - edit
      - reveal
      - use
      - view
    principalLinks:
      - //group/gvc-developers
```

### GVC Viewer — Read-Only Access

```yaml
kind: policy
name: gvc-viewer-workloads
targetKind: workload
target: all
bindings:
  - permissions:
      - view
    principalLinks:
      - //group/gvc-viewers
```

### CI/CD Service Account — Deploy Workloads, Push Images

```yaml
kind: policy
name: cicd-deploy-policy
targetKind: workload
target: all
bindings:
  - permissions:
      - create
      - delete
      - edit
      - view
    principalLinks:
      - //serviceaccount/cicd-deployer
---
kind: policy
name: cicd-image-policy
targetKind: image
target: all
bindings:
  - permissions:
      - create
      - pull
      - view
    principalLinks:
      - //serviceaccount/cicd-deployer
---
kind: policy
name: cicd-secret-policy
targetKind: secret
target: all
bindings:
  - permissions:
      - use
      - view
    principalLinks:
      - //serviceaccount/cicd-deployer
```

### Workload Identity Secret Access

```yaml
kind: policy
name: app-secret-access
targetKind: secret
targetLinks:
  - //secret/database-url
  - //secret/api-key
bindings:
  - permissions:
      - reveal
      - use
    principalLinks:
      - //gvc/production/identity/app-identity
```

### Security Auditor — View Audit Trail and Policies, No Mutations

```yaml
kind: policy
name: auditor-policy-view
targetKind: policy
target: all
bindings:
  - permissions:
      - view
    principalLinks:
      - //group/security-auditors
---
kind: policy
name: auditor-auditctx-view
targetKind: auditctx
target: all
bindings:
  - permissions:
      - view
    principalLinks:
      - //group/security-auditors
```

## Gotchas

- **Policies fail silently when wrong.** A typo in `targetKind`, a missing principal link, or an invalid permission name produces a policy that exists but grants nothing. Always verify with `cpln policy access-report POLICY_NAME` after creation.
- **Permission ordering doesn't matter — the API auto-sorts.** You do not need to sort permissions alphabetically in your manifests; the platform sorts them on write. Duplicate permissions in the same binding will cause a validation error.
- **Built-in policies cannot be modified or deleted.** Origins `builtin` are read-only; create your own with `default` origin.
- **`reveal` (not `read`) is the permission for accessing secret values.** This is the most common permission-name mistake.
- **Identity links are GVC-scoped.** Use `//gvc/GVC/identity/NAME`, not `//identity/NAME`.
- **`manage` implies all other permissions** for that resource kind. Use only for true admins.
- **Service account keys are shown once.** Save immediately or delete and regenerate.

## Quick Reference

### MCP Tools

| Tool | Purpose | Key Params |
|:---|:---|:---|
| `mcp__cpln__list_policies` | List all policies in an org | `limit` (optional) |
| `mcp__cpln__get_policy` | Get policy details and bindings | `name` |
| `mcp__cpln__create_policy` | Create policy with bindings | `name`, `targetKind`, `targetAll`/`targetLinks`, `addPermissions`, `addUsers`/`addGroups`/`addServiceAccounts`/`addIdentities` |
| `mcp__cpln__update_policy` | Update policy description, tags, targetLinks, or merge bindings | `name`, `description`, `tags`, `targetLinks`, `bindings` |
| `mcp__cpln__delete_policy` | Delete a policy | `name` |
| `mcp__cpln__get_permissions` | List grantable permissions for a kind | `kind` |
| `mcp__cpln__list_groups` | List all groups in an org | `limit` (optional) |
| `mcp__cpln__get_group` | Get group details and members | `name` |
| `mcp__cpln__create_group` | Create a group | `name`, `memberLinks` |
| `mcp__cpln__add_member_to_group` | Add users/SAs to a group | `groupName`, `memberLinks` |
| `mcp__cpln__remove_member_from_group` | Remove users/SAs from a group | `groupName`, `memberLinks` |
| `mcp__cpln__update_group` | Update group description/tags/members | `name`, `addMemberLinks`, `removeMemberLinks`, `tags` |
| `mcp__cpln__delete_group` | Delete a group | `name` |
| `mcp__cpln__list_service_accounts` | List all service accounts in an org | `limit` (optional) |
| `mcp__cpln__get_service_account` | Get service account details, keys, and group memberships | `name` |
| `mcp__cpln__create_service_account_key` | Create SA + add key | `serviceAccountName`, `keyDescription`, `groupName` |
| `mcp__cpln__invite_user_to_org` | Invite user by email | `email`, `groupName` |
| `mcp__cpln__cpln_resource_operation` | Fallback CRUD for any resource | `kind`, `operation`, `name`, `body` |

### CLI Commands

| Task | Command |
|:---|:---|
| Create policy | `cpln policy create --name NAME --target-kind KIND [--all \| --resource RES]` |
| Add binding | `cpln policy add-binding NAME --permission PERM [--email \| --group \| --serviceaccount \| --identity]` |
| Remove binding | `cpln policy remove-binding NAME --permission PERM [--email \| --group \| --serviceaccount \| --identity]` |
| Clone policy | `cpln policy clone NAME --name NEW_NAME` |
| View access report | `cpln policy access-report NAME` |
| Create group | `cpln group create --name NAME` |
| Add group member | `cpln group add-member NAME [--email EMAIL \| --serviceaccount SA]` |
| Remove group member | `cpln group remove-member NAME [--email EMAIL \| --serviceaccount SA]` |
| Create service account | `cpln serviceaccount create --name NAME` |
| Add SA key | `cpln serviceaccount add-key NAME --description DESC` |
| Remove SA key | `cpln serviceaccount remove-key NAME --key KEY_NAME` |
| Invite user | `cpln user invite --email EMAIL [--group GROUP]` |
| Delete user | `cpln user delete EMAIL` |
| List permissions | `cpln RESOURCE permissions` (e.g., `cpln workload permissions`, `cpln secret permissions`) |

### Related Skills

- **cpln-org-management** — Org creation, billing, profiles, SSO
- **cpln-query-spec** — Query language for `targetQuery` and `memberQuery`
- **cpln-audit-compliance** — Audit access changes and policy modifications

### Linked Reference Docs

- `skills/access-control/permissions-matrix.md` — Per-resource permission table, implication chains, built-in groups/policies.
- `skills/access-control/principals.md` — Group / service account / user management workflows (CLI + MCP).

## Documentation

For the latest reference, see:

- [Access Control Concepts](https://docs.controlplane.com/concepts/access-control.md)
- [Policy Reference](https://docs.controlplane.com/reference/policy.md)
- [Group Reference](https://docs.controlplane.com/reference/group.md)
- [Service Account Reference](https://docs.controlplane.com/reference/serviceaccount.md)
- [User Reference](https://docs.controlplane.com/reference/user.md)
