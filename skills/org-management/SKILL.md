---
name: cpln-org-management
description: "Manages organizations, billing, users, and authentication on Control Plane. Use when the user asks about creating an org, billing setup, inviting users, SSO login, SAML authentication, CLI profiles, switching orgs, or multi-org membership. Covers org creation, billing accounts, user invitation, SSO/SAML, service account auth, and CLI profiles."
version: 1.0.0
---

# Organization & User Management

Org structure, user/group management, profile setup. For SSO/SAML configuration, CLI auth flows, and service-account token details, see `skills/org-management/sso.md`. For billing-account features, roles, and management, see `skills/org-management/billing.md`.

## Organization Overview

An **organization (org)** is the top-level isolation boundary on Control Plane. Every resource — GVCs, workloads, secrets, policies, users, groups, service accounts, images, domains — lives inside an org.

| Property | Detail |
|:---|:---|
| Naming | **Globally unique**, alphanumeric with hyphens, cannot start/end with hyphens |
| Immutability | Orgs **cannot be renamed or deleted** once created |
| Multi-org | A user can belong to one or more orgs simultaneously |
| Isolation | Complete resource isolation between orgs; no cross-org resource sharing |
| Endpoint prefix | Random prefix at `{org}.status.endpointPrefix`, configurable per GVC |
| Session timeout | Default 15 minutes (900 seconds minimum), configurable per org |

### Resources Inside an Org

```
Org (top-level boundary)
├── Access Control: Users, Groups, Service Accounts, Policies, Audit Contexts
├── Infrastructure: Cloud Accounts, Agents, Locations, Domains
├── Assets: Secrets (12 types), Images, Quotas
└── GVCs (deployment environments)
    ├── Workloads, Identities, Volume Sets
```

### Org Spec Fields (Schema-Verified)

| Field | Type | Required | Description |
|:---|:---|:---|:---|
| `logging` | object | No | External logging provider (mutually exclusive options) |
| `extraLogging` | array | No | Additional logging targets (max 3) |
| `tracing` | object | No | OpenTelemetry tracing configuration |
| `sessionTimeoutSeconds` | number | No | Console inactivity timeout (min: 900) |
| `authConfig` | object | No | Domain auto-members list, SAML-only flag |
| `observability` | object | No | Retention for logs/metrics/traces (0–3650 days, default: 30) |
| `security` | object | No | Threat detection settings |

### AuthConfig

| Field | Type | Default | Description |
|:---|:---|:---|:---|
| `domainAutoMembers` | string[] | — | Email domains for automatic org membership |
| `samlOnly` | boolean | `false` | Restrict authentication to SAML only |

## Creating an Organization

### Prerequisites

The `org_creator` or `billing_admin` role must be assigned to the user on a billing account. A billing admin assigns this from the **Org Management & Billing** dashboard → **Users**.

### Console UI

1. Click **Create** (upper right) → **Org**
2. Enter a unique name, optional description, and org admin email addresses
3. Add optional tags → **Create**

The creating user and any additional admins are automatically added to the `superusers` group.

### CLI

```bash
cpln org create --name ORG_NAME --accountId BILLING_ACCOUNT_ID \
  --invitee admin@example.com --invitee dev@example.com
```

| Flag | Required | Description |
|:---|:---|:---|
| `--name` | Yes | Globally unique org name |
| `--accountId` | Yes | ID of the billing account |
| `--invitee` | Yes | Email(s) of users to invite as superusers (repeatable) |
| `--description` | No | Org description (defaults to name) |
| `--tag` | No | Tags in `key=value` format (repeatable) |

The **initial billing account** can only be created via the Console — see `skills/org-management/billing.md` for the form fields and the billing account features.

### Key Constraints

- Orgs are **immutable** — cannot be renamed or deleted.
- Org name is **globally unique** across all of Control Plane.
- Org name cannot start with `xserve-` or be `index` (schema-enforced).
- The `billing_admin` role does **not** grant org-level permissions — these are independent systems.

## User Management

### Inviting Users to an Org

Users can be invited to join an org and optionally assigned to a group.

**MCP tool:**

```
mcp__cpln__invite_user_to_org
```

| Parameter | Required | Description |
|:---|:---|:---|
| `email` | Yes | Email address of the user to invite |
| `groupName` | No | Group to assign the user to |
| `org` | No | Organization (defaults to session context) |

> **Note:** If you need the user placed into a group automatically, prefer using a refresh token because service account tokens cannot grant group membership during invitations.

**CLI:**

```bash
cpln user invite --email user@example.com --group viewers
```

| Flag | Required | Description |
|:---|:---|:---|
| `--email` | Yes | Email address (repeatable for multiple users) |
| `--group` | No | Group to assign after user accepts |

**Console:**

1. Click **Users** → **Invite** tab
2. Enter email, select a group, click **Add to Invitation List**
3. Repeat for additional users → **Confirm Invitations**

Invited users receive an onboarding email. Pending invites appear in the **Pending Invites** table and can be deleted.

**Bulk invite via CSV:**

Upload a `.csv` file with format: `USER_EMAIL,GROUP_TO_ASSIGN`

```csv
user1@example.com,none
admin@example.com,superusers
viewer@example.com,viewers
```

### Managing Users

| Action | CLI | MCP |
|:---|:---|:---|
| List users | `cpln user get` | `mcp__cpln__cpln_resource_operation` (kind: `user`, verb: `get`) |
| Get user | `cpln user get USER_EMAIL` | `mcp__cpln__cpln_resource_operation` |
| Delete user | `cpln user delete USER_EMAIL` | `mcp__cpln__cpln_resource_operation` (kind: `user`, verb: `delete`) |
| Update tags | `cpln user update USER_EMAIL --set tags.key=value` | — |

### User Permissions (for Policies)

| Permission | Description | Implies |
|:---|:---|:---|
| `view` | Read-only access | — |
| `edit` | Modify existing users | `view` |
| `delete` | Delete users | — |
| `invite` | Invite users to the org | — |
| `impersonate` | Impersonate a user | — |
| `manage` | Full access | `delete`, `edit`, `impersonate`, `invite`, `view` |

### Multi-Org Membership

Users can belong to multiple orgs. Switch between orgs:

- **Console:** Use the org selector in the upper left to switch orgs.
- **CLI:** Use `--org` flag or switch profiles: `cpln profile set-default PROFILE_NAME`.

### Built-in User Tags

Each user has a built-in tag: `firebase/sign_in_provider` (set automatically based on SSO provider).

## Managing Groups (MCP Tools)

Groups aggregate users and service accounts for easier policy management.

| Action | MCP Tool | Key Parameters |
|:---|:---|:---|
| List groups | `mcp__cpln__list_groups` | `org`, `limit` (max 500) |
| Get group | `mcp__cpln__get_group` | `org`, `name` |
| Create group | `mcp__cpln__create_group` | `name`, `description`, `tags`, `memberLinks` |
| Update group | `mcp__cpln__update_group` | `name`, `tags`, `addMemberLinks`, `removeMemberLinks` |
| Delete group | `mcp__cpln__delete_group` | `name` |
| Add members | `mcp__cpln__add_member_to_group` | `groupName`, `memberLinks` (e.g., `//user/alice@example.com`) |
| Remove members | `mcp__cpln__remove_member_from_group` | `groupName`, `memberLinks` |

**Member link format:** `//user/EMAIL` for users, `//serviceaccount/NAME` for service accounts.

For deeper group workflows (dynamic membership, service-account management), see the **cpln-access-control** skill (`skills/access-control/principals.md`).

## Profile Management

Profiles store authentication credentials and default context (org, GVC) for the CLI.

### Profile Commands

| Action | Command |
|:---|:---|
| Login (create default profile) | `cpln login [PROFILE_NAME]` |
| Create / update profile | `cpln profile create PROFILE_NAME --org ORG --gvc GVC --token TOKEN` |
| Update profile | `cpln profile update PROFILE_NAME --org ORG --gvc GVC` |
| Set default profile | `cpln profile set-default PROFILE_NAME` |
| List profiles | `cpln profile get` |
| View token | `cpln profile token PROFILE_NAME` |
| Delete profile | `cpln profile delete PROFILE_NAME` |

> `cpln profile create` is an alias for `cpln profile update` — if the profile exists, it updates it.

### Profile Properties

| Property | Flag | Description |
|:---|:---|:---|
| Organization | `--org` | Default org for commands |
| GVC | `--gvc` | Default GVC for workload/identity commands |
| Token | `--token` | Authentication token |
| Default | `--default` | Set as default profile |
| Endpoint | `--endpoint` | API URL (default: `https://api.cpln.io`) |
| Insecure | `--insecure` | Skip TLS verification |

### Environment Variable Overrides

| Variable | Description |
|:---|:---|
| `CPLN_PROFILE` | Profile name to use as default |
| `CPLN_TOKEN` | Authentication token |
| `CPLN_ORG` | Default organization |
| `CPLN_GVC` | Default GVC |

## Org Permissions (for Policies)

| Permission | Description | Implies |
|:---|:---|:---|
| `view` | Read-only view (every org member) | — |
| `edit` | Modify org | `view` |
| `manage` | Full access | `edit`, `exec`, `grafanaAdmin`, `readLogs`, `readMetrics`, `readUsage`, `view`, `viewAccessReport` |
| `readLogs` | Read logs from all workloads | `view` |
| `readMetrics` | Access performance metrics | — |
| `readUsage` | Access usage and billing metrics | — |
| `grafanaAdmin` | Admin role in Grafana (otherwise Viewer) | — |
| `exec` | Execute all commands on the org | `exec.echo` |
| `exec.echo` | Execute echo command | — |
| `viewAccessReport` | Inspect access report on all resources | — |

## Gotchas

- **Orgs are immutable** — they cannot be renamed or deleted once created. Plan the name carefully.
- **Org name is globally unique** across all of Control Plane — not just per-account.
- **`billing_admin` and org policies are independent.** A `billing_admin` has zero implicit permissions on org resources.
- **Service-account `--token` clears GVC** when updating a profile via `--token`. The default GVC is removed unless you also pass `--gvc`. User-token updates preserve the GVC.
- **Changing org without `--gvc` clears GVC**: If `--org` is provided without `--gvc`, the profile's default GVC is unset (the new org may not have a GVC with the same name).
- **Verify before mutating**: Always `cpln profile get` to check the active profile (marked with `*`) before destructive operations.

## Quick Reference

### MCP Tools

| Tool | Action |
|:---|:---|
| `mcp__cpln__invite_user_to_org` | Invite user by email to org (optional group) |
| `mcp__cpln__list_groups` | List all groups in an org |
| `mcp__cpln__get_group` | Get group details |
| `mcp__cpln__create_group` | Create a group with optional members |
| `mcp__cpln__update_group` | Update group members and tags |
| `mcp__cpln__delete_group` | Delete a group |
| `mcp__cpln__add_member_to_group` | Add users/service accounts to a group |
| `mcp__cpln__remove_member_from_group` | Remove members from a group |
| `mcp__cpln__cpln_resource_operation` | Generic CRUD for org, user, and other resources |

### CLI Commands

| Task | Command |
|:---|:---|
| Create org | `cpln org create --name NAME --accountId ID --invitee EMAIL` |
| Get org(s) | `cpln org get [ORG_NAME]` |
| Update org | `cpln org update ORG_NAME --set description="..."` |
| Edit org (YAML) | `cpln org edit ORG_NAME` |
| Invite user | `cpln user invite --email EMAIL --group GROUP` |
| List users | `cpln user get` |
| Delete user | `cpln user delete USER_EMAIL` |
| Login (interactive) | `cpln login [PROFILE_NAME]` |
| Create profile | `cpln profile create NAME --token TOKEN --org ORG --gvc GVC --default` |
| Update profile | `cpln profile update NAME --org ORG --gvc GVC` |
| Set default profile | `cpln profile set-default NAME` |
| View token | `cpln profile token NAME` |
| Create service account | `cpln serviceaccount create --name NAME` |
| Generate SA key | `cpln serviceaccount add-key NAME` |

### Related Skills

- **cpln-access-control** — Policies, bindings, permissions, groups, service accounts, RBAC patterns.
- **cpln-cli** — Workload deployment, CLI setup, resource hierarchy.

### Linked Reference Docs

- `skills/org-management/sso.md` — Console SSO providers, SAML setup, CLI auth flows, service-account token details, REST API auth, token precedence.
- `skills/org-management/billing.md` — Billing account features, roles, billing-user management, spend alerts, initial billing account creation.

## Documentation

For the latest reference, see:

- [Org Reference](https://docs.controlplane.com/reference/org.md)
- [Org Concepts](https://docs.controlplane.com/concepts/org.md)
- [Create Org Guide](https://docs.controlplane.com/guides/create-org.md)
- [Invite Users Guide](https://docs.controlplane.com/guides/invite-users.md)
- [Manage Profile Guide](https://docs.controlplane.com/guides/manage-profile.md)
- [Authentication](https://docs.controlplane.com/core/authentication.md)
