---
name: org-management
description: "Manages organizations, billing, users, and authentication on Control Plane. Use when the user asks about creating an org, billing setup, inviting users, SSO login, SAML authentication, CLI profiles, switching orgs, or multi-org membership. Covers org creation, billing accounts, user invitation, SSO/SAML, service account auth, and CLI profiles."
---

# Organization & User Management

Org structure, user/group management, profile setup, billing accounts, and SSO/SAML authentication.

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

> **Editing org-level spec blocks** — `authConfig`, `observability`, `security`, and `sessionTimeoutSeconds` are set with `mcp__cpln__update_org` (read current state with `mcp__cpln__get_org`). `logging`/`extraLogging` are the exception — use `mcp__cpln__configure_external_logging` (see the **cpln-external-logging** skill). For a block not covered by `update_org` (e.g. `tracing`), call `mcp__cpln__get_resource_schema` (kind `org`) and apply with `cpln apply -f org.yaml`.

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

The **initial billing account** can only be created via the Console — see the **Billing** section below for the form fields and billing-account features.

### Key Constraints

- Orgs are **immutable** — cannot be renamed or deleted.
- Org name is **globally unique** across all of Control Plane.
- Org name cannot start with `xserve-` or be `index` (schema-enforced).
- The `billing_admin` role does **not** grant org-level permissions — these are independent systems.

## Billing

A billing account manages user access, invoices, payment methods, and spending alerts. You can create multiple billing accounts.

> **Billing-account access is Console-only** — there is no MCP tool or `cpln` command for billing roles or billing-user management. Do not confuse it with org-level access: org users, groups, and service accounts are managed via the MCP tools below.

### Billing Account Features

| Feature | Description |
|---|---|
| Account Details | Company information, billing contact |
| Orgs | View orgs linked to the billing account |
| Invoices | View and download invoices |
| Payment Methods | Add, update, or remove payment methods |
| Users | Manage billing user access and roles |
| Cost & Usage | Review costs across all orgs in the account |
| Spend Alerts | Email alerts when monthly spending hits a threshold |

### Billing Account Roles

| Role | Description |
|---|---|
| `billing_admin` | Full access to billing settings, invoices, and user management |
| `billing_viewer` | Read-only access to billing information |
| `org_creator` | Can create new organizations under the billing account |

Billing roles control account-level access (invoices, payment, org creation); org-level policies control resource-level access (workloads, secrets, etc.). They are **completely independent** — a `billing_admin` has zero implicit permissions on any org resource.

### Initial Billing Account Creation (Console Only)

The initial billing account can only be created via the Console. The creation form collects:

- **Contact info**: full name, company, job title, phone (required), LinkedIn (optional).
- **Address**: country, city, postal code, address line 1 (required); state, line 2 (optional).
- **Org/GVC**: org name (required), GVC name (defaults to `default-gvc`), locations.
- **Payment**: Stripe integration for payment method.

### Managing Billing Users (Console Only)

1. Navigate to **Org Management & Billing** (profile icon → upper right).
2. Click **Users** in the left menu.
3. Add a user: enter email, select role(s), click **Add User**.
4. Edit a user: click **Edit**, modify roles, click **Confirm**.

A user must have at least one role (`billing_admin`, `billing_viewer`, or `org_creator`); access is immediate once added. These are **billing-account** users, not org members — to add or remove a user inside an org use the org-level MCP tools (`mcp__cpln__invite_user_to_org`, `mcp__cpln__delete_user`).

### Spend Threshold Alerts

Enable from Account Details. Set a monthly spending limit — you receive an email when the threshold is reached.

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

Lead with the MCP tools; fall back to the CLI when the MCP server is unavailable or for fields no typed tool covers (e.g. user tags).

| Action | MCP | CLI fallback |
|:---|:---|:---|
| List users | `mcp__cpln__list_users` | `cpln user get` |
| Get user | `mcp__cpln__get_user` (by id or email) | `cpln user get USER_EMAIL` |
| Delete user | `mcp__cpln__delete_user` | `cpln user delete USER_EMAIL` |
| Update tags | — (no typed tool) | `cpln user update USER_EMAIL --set tags.key=value` |

> `delete_user` is destructive — confirm the blast radius (group memberships, policy bindings the user participates in) before calling.

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

## Managing Groups (MCP Tools)

Groups aggregate users and service accounts for easier policy management.

| Action | MCP Tool | Key Parameters |
|:---|:---|:---|
| List groups | `mcp__cpln__list_groups` | `org`, `limit` (max 500) |
| Get group | `mcp__cpln__get_group` | `org`, `name` |
| Create group | `mcp__cpln__create_group` | `name`, `description`, `tags`, `memberLinks` |
| Edit group (description, tags, members) | `mcp__cpln__edit_group` | `name`, `description`, `tags`, `addMemberLinks`, `removeMemberLinks` |
| Delete group | `mcp__cpln__delete_group` | `name` |

> `edit_group` is the single tool for updating a group's description/tags **and** adding or removing member links — there is no separate add-/remove-member tool. Call `get_group` first to confirm current membership.

**Member link format:** `//user/EMAIL` for users, `//serviceaccount/NAME` for service accounts.

For deeper group workflows (dynamic membership, service-account management), see the **cpln-access-control** skill.

## Service Accounts (MCP Tools)

Service accounts are non-human principals (CI/CD, automation) that authenticate with keys.

| Action | MCP Tool | Notes |
|:---|:---|:---|
| Create service account | `mcp__cpln__create_service_account` | No keys yet; names are immutable (rename = delete + recreate, which invalidates all keys) |
| Add a key (and optionally the SA) | `mcp__cpln__add_key_to_service_account` | Creates the SA if it does not exist, adds a key, optional group placement |

> There is no `create_service_account_key` tool — use `mcp__cpln__add_key_to_service_account` to issue keys. The CLI fallback is `cpln serviceaccount create --name NAME` then `cpln serviceaccount add-key NAME`.

## Quotas (MCP Tools)

Quotas are per-org resource limits (CPU, memory, workload count, …). Read-only.

| Action | MCP Tool | Notes |
|:---|:---|:---|
| List quotas | `mcp__cpln__list_quotas` | Returns every quota in full (usage, max, unit, dimensions). Pass `nearLimit: true` for a quick "what is about to break?" check (≥80% used) |
| Get a quota | `mcp__cpln__get_quota` | Addressed by GUID `id` from `list_quotas` — call `list_quotas` first |

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

## SSO / SAML & Authentication

### Console SSO Providers

The Console uses single sign-on with these providers:

| Provider | Notes |
|---|---|
| Google | OAuth-based SSO |
| GitHub | OAuth-based SSO |
| Microsoft | OAuth-based SSO |
| SAML | Enterprise SSO — contact support@controlplane.com to enable |

After SSO, user access is determined by their group membership and policies. Each user gets a built-in tag `firebase/sign_in_provider`, set automatically from the SSO provider.

### SAML Configuration Values

Control Plane is the SAML Service Provider. Configure your IdP with its SP values — confirm the exact values in the Console when enabling SAML (these are console-level, not part of the org API):

| Setting | Value |
|---|---|
| Service Provider Entity ID | `cpln.io` |
| ACS / Callback URL | `https://console.cpln.io/__/auth/handler` |

Your SAML provider must supply: Entity ID, SSO URL, and Certificate.

> `authConfig.samlOnly` and `domainAutoMembers` are set with `mcp__cpln__update_org`, but **enabling SAML/SSO itself (provider setup) goes through Control Plane support** — there is no self-serve tool for it. To wire SSO users into the right access, manage their groups and policies via `mcp__cpln__edit_group`, `mcp__cpln__create_policy`, and `mcp__cpln__invite_user_to_org`.

### Token Precedence

The CLI resolves tokens in this order:

1. `--token` flag (highest priority).
2. `CPLN_TOKEN` environment variable.
3. Profile token (default).

### Service Account Keys (CLI Detail)

Prefer the MCP tools in **Service Accounts** above. CLI fallback for issuing a key:

```bash
cpln serviceaccount add-key SA_NAME --description "What this key is for" --org ORG
```

`add-key` **requires `--description`** and prints a JSON object:

```json
{
  "description": "What this key is for",
  "created": "2026-04-24T12:00:00.000Z",
  "key": "SERVICE_ACCOUNT_KEY_VALUE"
}
```

The token is the `key` value. It is shown **only once** — save it immediately to a secret store. Prefer the `CPLN_TOKEN` env var or a profile over passing `--token` on the command line (flags leak into shell history and CI logs). For full CI/CD setup, see the **cpln-gitops-cicd** skill.

### REST API Authentication

```bash
curl --request GET \
  --url https://api.cpln.io/org/ORG_NAME/gvc \
  --header 'Authorization: Bearer YOUR_TOKEN'
```

Tokens can come from a service account key or `cpln profile token PROFILE_NAME`.

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
| `mcp__cpln__list_users` | List users in an org |
| `mcp__cpln__get_user` | Get a user by id or email |
| `mcp__cpln__delete_user` | Remove a user from the org (destructive) |
| `mcp__cpln__list_groups` | List all groups in an org |
| `mcp__cpln__get_group` | Get group details |
| `mcp__cpln__create_group` | Create a group with optional members |
| `mcp__cpln__edit_group` | Update group description, tags, and member links |
| `mcp__cpln__delete_group` | Delete a group |
| `mcp__cpln__create_service_account` | Create a service account (no keys) |
| `mcp__cpln__add_key_to_service_account` | Add a key (creates the SA if needed) |
| `mcp__cpln__list_quotas` | List per-org resource quotas |
| `mcp__cpln__get_quota` | Get a single quota by GUID id |
| `mcp__cpln__get_org` / `mcp__cpln__update_org` | Read / update org spec — `authConfig`, `observability`, `security`, `sessionTimeoutSeconds` |
| `mcp__cpln__get_resource_schema` | Author an org manifest for `cpln apply` (for blocks not on `update_org`, e.g. `tracing`) |

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
- **cpln** — Workload deployment, CLI setup, resource hierarchy.

## Documentation

For the latest reference, see:

- [Org Reference](https://docs.controlplane.com/reference/org.md)
- [Org Concepts](https://docs.controlplane.com/concepts/org.md)
- [Create Org Guide](https://docs.controlplane.com/guides/create-org.md)
- [Invite Users Guide](https://docs.controlplane.com/guides/invite-users.md)
- [Manage Profile Guide](https://docs.controlplane.com/guides/manage-profile.md)
- [Authentication](https://docs.controlplane.com/core/authentication.md)
