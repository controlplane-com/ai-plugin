---
name: access-control
description: "Sets up access control, policies, and RBAC on Control Plane. Use when the user asks about permissions, policies, service accounts, user access, group membership, bindings, who can do what, least-privilege setup, or IAM. Covers policy creation, permission bindings, group management, service account setup, user invitation, and common RBAC patterns."
---

# Access Control & Policy Patterns

This is the **#1 area where mistakes happen** on Control Plane. Wrong `targetKind`, wrong binding syntax, wrong permission names — all silently fail. Use this skill any time you create policies, manage groups, invite users, or set up service accounts.

## Access Control Model

Control Plane uses a **two-part** access control system:

| Layer | Scope | Purpose |
|---|---|---|
| **Billing account roles** | Account-wide | Coarse-grained: who can manage billing, create orgs |
| **Org-level policies** | Per-resource | Fine-grained: who can do what on which resources |

### Billing Account Roles

| Role | Description |
|---|---|
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

Other resource kinds — including `ipset` and `mk8s` — are also valid policy targets. For the full authoritative list, fetch the policy schema with `mcp__cpln__get_resource_schema` (`kind: policy`), or verify against `cpln policy create --target-kind`.

### Target Scope

Three mutually exclusive ways to select which resources a policy applies to:

| Method | Field | CLI Flag | When to Use |
|---|---|---|---|
| **All resources** | `target: all` | `--all` | Org-wide roles (admin, viewer) |
| **Named resources** | `targetLinks: [//secret/NAME]` | `--resource NAME` | Scoped access to specific resources |
| **Tag query** | `targetQuery: {...}` | `--query-tag TAG` | Dynamic scoping based on tags |

**Decision rule:** Use `target: all` for role-based patterns. Use `targetLinks` when you know the exact resources. Use `targetQuery` when resources share tags (e.g., `team=backend`). For the full `targetQuery` system (operators, match modes, term fields), see the **cpln-query-spec** skill.

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
|---|---|---|
| `default` | User-created policies | Yes |
| `builtin` | System-provided defaults (e.g., `superusers-secret`) | **No — cannot be modified or deleted** |

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
- Each binding's permissions must be **sorted alphabetically and unique** (validation rule).
- A policy can have up to **50 bindings**, each with up to **200 principal links**.
- The same principal can appear in multiple bindings (different permission sets).

### Principal Link Formats

| Principal Type | Format | Example |
|---|---|---|
| User | `//user/USER_EMAIL` | `//user/alice@example.com` |
| Group | `//group/GROUP_NAME` | `//group/backend-team` |
| Service Account | `//serviceaccount/SA_NAME` | `//serviceaccount/cicd-deployer` |
| Identity (workload-bound) | `//gvc/GVC_NAME/identity/IDENTITY_NAME` | `//gvc/production/identity/app-identity` |

Org is taken from context (short format), e.g. `//user/USER_EMAIL`.

## Permissions

Discover all permissions at runtime: `mcp__cpln__get_permissions` (MCP) or `cpln RESOURCE permissions` (CLI). Confirm names this way before creating any policy.

| Resource | Permissions | Key Implications |
|---|---|---|
| **workload** | `configureLoadBalancer`, `connect`, `create`, `delete`, `edit`, `exec`, `exec.runCronWorkload`, `exec.stopReplica`, `manage`, `view` | `exec` → `exec.runCronWorkload` + `exec.stopReplica`; `connect` = interactive shell |
| **secret** | `create`, `delete`, `edit`, `manage`, `reveal`, `use`, `view` | `edit` → `view` + `reveal`; `reveal` = read values; `use` = reference from workloads |
| **identity** | `create`, `delete`, `edit`, `manage`, `use`, `view` | `use` = link identity to workloads |
| **image** | `create`, `delete`, `edit`, `manage`, `pull`, `view` | `create` → `pull`; `pull` → `view` |
| **org** | `edit`, `exec`, `exec.echo`, `grafanaAdmin`, `manage`, `readLogs`, `readMetrics`, `readUsage`, `view`, `viewAccessReport` | `exec` → `exec.echo`; `readLogs` = logs from all workloads |
| **user** | `delete`, `edit`, `impersonate`, `invite`, `manage`, `view` | `impersonate` and `invite` are unique to user |

Most other resources (policy, group, domain, location, etc.) follow the standard pattern: `create`, `delete`, `edit`, `manage`, `view` — some add `use`; `gvc` also has `configureLoadBalancer`. Run `cpln RESOURCE permissions` for the exact list.

**`manage` always implies all other permissions for that resource type** (the `→` notation means "implies"). Use `manage` only for true admins.

### Built-In Groups & Policies

Every org starts with:

| Resource | Name | Purpose |
|---|---|---|
| Group | `superusers` | All administrators — has `manage` on everything |
| Group | `viewers` | Read-only access to all resources |
| Service account | `controlplane` | Used by the platform internally — cannot be modified |
| Policies | `superusers-RESOURCE` | One per resource kind granting `manage` to `superusers` group |
| Policies | `viewers-RESOURCE` | One per resource kind granting `view` to `viewers` group |

Built-in policies have origin `builtin` and **cannot be modified or deleted** — create your own with origin `default`. Inspect built-ins with the read MCP tools (CLI fallback `cpln RESOURCE get NAME` when the MCP server is unavailable): `mcp__cpln__get_group` for `superusers` / `viewers`, `mcp__cpln__get_policy` for the `superusers-RESOURCE` / `viewers-RESOURCE` policies, `mcp__cpln__get_service_account` for `controlplane`.

## Common RBAC Patterns

Create these with the MCP tools first — `mcp__cpln__create_policy` (target kind, scope, and bindings), `mcp__cpln__create_group` / `mcp__cpln__edit_group` for principals, and `mcp__cpln__add_key_to_service_account` for CI/CD principals. The YAML below is the equivalent `cpln apply -f manifest` shape — reach for it when the MCP server is unavailable or when applying policy-as-code from CI/CD (service-account `CPLN_TOKEN`).

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

There is no single "super-admin" policy covering all kinds — create one policy per `targetKind` the admin needs.

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

The identity must exist in the GVC before you can bind it — create it with `mcp__cpln__create_identity`, then attach it to the workload via `spec.identityLink`. Identity links are GVC-scoped: use `//gvc/GVC/identity/NAME`, not `//identity/NAME`. For the full secret-access flow (identity + policy + injection), see the **cpln:setup-secret** skill.

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

## Principals

Day-to-day workflows for creating and managing the principals that policies bind to.

### Groups

Groups simplify access control by letting you assign policies to teams instead of individuals. **Best practice: always assign policies to groups, not individual users.**

- **Create:** `mcp__cpln__create_group` — params: `name` (required), `description`, `tags`, `memberLinks` (optional seed members).
- **Add/remove members:** `mcp__cpln__edit_group` — one call updates description/tags AND manages membership via `addMemberLinks` / `removeMemberLinks` (e.g. `["//user/alice@example.com"]`, `["//serviceaccount/cicd-deployer"]`). Read current membership first with `mcp__cpln__get_group`.
- **Delete:** `mcp__cpln__delete_group` — params: `name`. Destructive: every policy targeting this group loses its member set, so confirm the blast radius first.

Groups support tag-based **dynamic membership for users only** (service accounts must be added directly), via `memberQuery` using the standard query spec — see the **cpln-query-spec** skill:

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

### Service Accounts

Service accounts provide non-human API access for CI/CD pipelines, automation, and infrastructure-as-code tools.

- **Create + key:** `mcp__cpln__add_key_to_service_account` — params: `name` (required), `keyDescription`, `groupName`. Creates the service account if it doesn't exist, adds a key, and optionally adds the SA to a group in one call. To create the SA without a key yet, use `mcp__cpln__create_service_account` (params: `name`, `description`) first.
- **Inspect:** `mcp__cpln__list_service_accounts` (key counts + origin) and `mcp__cpln__get_service_account` (key metadata — never key material).
- **Revoke key / delete:** revoke a key via `mcp__cpln__update_service_account`; delete the SA entirely via `mcp__cpln__delete_service_account` (params: `name`). Deleting revokes all keys at once and every consumer authenticating with this SA fails immediately — list its group memberships and policy bindings and confirm the blast radius first.

**CRITICAL: the generated key is displayed ONE TIME only.** If lost, revoke the key and generate a new one.

Create a CLI profile with a generated key (`cpln profile create` is an alias for `cpln profile update` — creates or updates the named profile; `--default` makes it active for all future commands):

```bash
cpln profile create cicd-profile --org ORG_NAME --token GENERATED_KEY --default
```

### Users

- **Invite:** `mcp__cpln__invite_user_to_org` — params: `email` (required), `groupName`. Placing the invited user into a group during the invite requires a refresh token; service-account tokens cannot grant group membership at invite time. The user receives an onboarding email and appears in "Pending Invites" until they accept; pending invites can be deleted if sent by mistake.
- **Remove:** `mcp__cpln__delete_user` — params: `id` or `email`. Destructive: the user loses every group membership and policy binding immediately. Capture state first with `mcp__cpln__get_user` and confirm the blast radius.

**Multi-org membership:** users can belong to multiple orgs. Each org has independent policies — membership in one org grants no access to another.

## Gotchas

- **Policies fail silently when wrong.** A typo in `targetKind`, a missing principal link, or an invalid permission name produces a policy that exists but grants nothing. Always verify after creation — read the policy back with `mcp__cpln__get_policy` (or `cpln policy access-report POLICY_NAME` from the CLI) and confirm the bindings and target resolved as intended.
- **`reveal` (not `read`) is the permission for accessing secret values.** This is the most common permission-name mistake.
- **Identity links are GVC-scoped.** Use `//gvc/GVC/identity/NAME`, not `//identity/NAME`.
- **Built-in policies cannot be modified or deleted** (origin `builtin`); create your own with origin `default`.
- **Service account keys are shown once.** Save immediately or revoke and regenerate.

## Quick Reference

### MCP Tools

| Tool | Purpose | Key Params |
|---|---|---|
| `mcp__cpln__list_policies` | List all policies in an org | `limit` (optional) |
| `mcp__cpln__get_policy` | Get policy details and bindings | `name` |
| `mcp__cpln__create_policy` | Create policy with bindings | `name`, `targetKind`, `targetAll`/`targetLinks`, `addPermissions`, `addUsers`/`addGroups`/`addServiceAccounts`/`addIdentities` |
| `mcp__cpln__update_policy` | Update policy description, tags, targetLinks, or merge bindings | `name`, `description`, `tags`, `targetLinks`, `bindings` |
| `mcp__cpln__delete_policy` | Delete a policy | `name` |
| `mcp__cpln__get_permissions` | List grantable permissions for a kind | `kind` |
| `mcp__cpln__list_groups` | List all groups in an org | `limit` (optional) |
| `mcp__cpln__get_group` | Get group details and members | `name` |
| `mcp__cpln__create_group` | Create a group, optionally seed member links | `name`, `memberLinks` |
| `mcp__cpln__edit_group` | Update group description/tags AND add/remove member links in one call | `name`, `addMemberLinks`, `removeMemberLinks`, `description`, `tags` |
| `mcp__cpln__delete_group` | Delete a group | `name` |
| `mcp__cpln__list_service_accounts` | List all service accounts in an org | `limit` (optional) |
| `mcp__cpln__get_service_account` | Get service account details, keys, and group memberships | `name` |
| `mcp__cpln__create_service_account` | Create a service account (no keys yet) | `name`, `description` |
| `mcp__cpln__add_key_to_service_account` | Create the SA if needed, add a key, optionally add to a group | `name`, `keyDescription`, `groupName` |
| `mcp__cpln__update_service_account` | Update SA metadata or revoke keys by name | `name`, `description`, `tags` |
| `mcp__cpln__delete_service_account` | Delete a service account (revokes all keys) | `name` |
| `mcp__cpln__list_users` | List users in an org | `email` (optional) |
| `mcp__cpln__get_user` | Get a user by id or email | `id`/`email` |
| `mcp__cpln__invite_user_to_org` | Invite user by email | `email`, `groupName` |
| `mcp__cpln__delete_user` | Remove a user from the org | `id`/`email` |

### CLI Commands

| Task | Command |
|---|---|
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

## Documentation

For the latest reference, see:

- [Access Control Concepts](https://docs.controlplane.com/concepts/access-control.md)
- [Policy Reference](https://docs.controlplane.com/reference/policy.md)
- [Group Reference](https://docs.controlplane.com/reference/group.md)
- [Service Account Reference](https://docs.controlplane.com/reference/serviceaccount.md)
- [User Reference](https://docs.controlplane.com/reference/user.md)
