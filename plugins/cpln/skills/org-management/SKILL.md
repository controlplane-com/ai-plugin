---
name: org-management
description: "Manages organizations, billing, users, and authentication on Control Plane. Use when the user asks about creating an org, billing, inviting users, SSO or SAML login, CLI profiles, switching orgs, or service accounts."
---

# Organization & User Management

An **org** is the top-level isolation boundary: every GVC, workload, secret, policy, image, domain, user, group, and service account lives inside one, with no cross-org sharing. An org **cannot be renamed or deleted** once created (every DELETE on `/org` returns 405) and its name is **globally unique** across all of Control Plane — so the first job is choosing a name you can live with permanently.

> **Tool availability:** the org-settings, group, service-account, and invite tools live in the `full` MCP toolset; only `list_quotas` and the generic `list_resources`/`get_resource`/`delete_resource` reads are in `core`. If a tool below is not advertised, reconnect with `?toolsets=full` or use the `cpln` CLI fallback.

## Organization

| Rule | Detail |
|:---|:---|
| Name charset | Lowercase letters, digits, hyphens; **must start with a letter**, cannot end with a hyphen; max 64 chars |
| Reserved names | Cannot be `index`; cannot start with `xserve-` |
| Uniqueness | Globally unique across the whole platform (DB-enforced), not per billing account |
| Immutability | Name is unmodifiable; the org cannot be deleted — plan the name carefully |

**Create an org** (requires the `org_creator` or `billing_admin` role on a billing account — enforced by the billing service, not org policy):

```bash
cpln org create --name ORG --accountId BILLING_ACCOUNT_ID \
  --invitee admin@example.com --invitee dev@example.com
```

`--name`, `--accountId`, and `--invitee` (repeatable) are all required; invitees join the `superusers` group. Optional: `--description`, `--tag key=value`. Console path: **Create**, then **Org**. The **first** billing account can only be created in the Console.

## Org-wide settings

Read with `mcp__cpln__get_resource` (kind `org`); change with `mcp__cpln__update_org` (a merge/PATCH — pass only the blocks you change). Settings apply to every member and workload.

| Spec block | Set via `update_org`? | Notes |
|:---|:---|:---|
| `sessionTimeoutSeconds` | Yes | Console inactivity timeout; minimum **900** (15 min); no platform default |
| `authConfig.domainAutoMembers` | Yes | Email domains whose users auto-join the org |
| `authConfig.samlOnly` | Yes | Boolean, **no default** (unset = off); require SAML for all members |
| `observability.*RetentionDays` | Yes | `logs`/`metrics`/`traces`, 0–3650, **default 30**; `0` turns that stream **off** |
| `observability.defaultAlertEmails` | Yes | Default Grafana alert recipients |
| `security.threatDetection` | Yes | Forward detected threats to a syslog target (`enabled` + optional `minimumSeverity` + syslog host/port) |
| `logging` / `extraLogging` | **No** | Use `mcp__cpln__configure_external_logging` — see **external-logging** |
| `tracing` | **No** | Escape hatch: `mcp__cpln__get_resource_schema` (kind `org`), author the block, `cpln apply -f org.yaml` |

## Billing

Billing accounts (invoices, payment methods, spend alerts, org creation) are managed **only in the Console** — there is no MCP tool or `cpln` command for them. Billing roles and org policies are **independent IAM systems**: a `billing_admin` has zero implicit permission on any org resource.

| Billing role | Grants |
|:---|:---|
| `billing_admin` | Full billing access: settings, invoices, billing users |
| `billing_viewer` | Read-only billing access |
| `org_creator` | Create orgs under the account |

## Users

**Invite** with `mcp__cpln__invite_user_to_org` (`email` required, `groupName` optional) or `cpln user invite --email EMAIL --group GROUP`. The user gets an onboarding email; **pending invites are viewable/cancellable only in the Console** (Users, then Pending Invites) — no MCP/CLI list exists. Up to 10 invites per API request; the Console also bulk-invites from a CSV.

> **A group chosen at invite time is applied only when the user accepts** — not immediately, and the invite still succeeds if the group can't be set. To place someone in a group right away, or fix one that didn't stick, use `mcp__cpln__edit_group`.

Read/delete users with the generic tools (no typed read tool): `mcp__cpln__get_resource` / `list_resources` / `delete_resource` (kind `user`), or `cpln user get` / `cpln user delete EMAIL`. Tags have no typed tool — use `cpln user update EMAIL --set tags.key=value`. Deleting a user is destructive: check their group memberships and policy bindings first.

**User permissions** (for policies):

| Permission | Implies |
|:---|:---|
| `view` | — |
| `edit` | `view` |
| `delete` | — |
| `invite` | — |
| `impersonate` | — |
| `manage` | all of the above |

## Groups & service accounts

Groups aggregate **users and service accounts only** (member links `//user/EMAIL`, `//serviceaccount/NAME`; max 200). `mcp__cpln__edit_group` is the **single** mutation tool — it edits description/tags and adds/removes members; there is no separate add-member tool. Dynamic membership (`memberQuery`, `identityMatcher`) and policy mechanics live in **access-control**.

Service-account **names are immutable** (rename = delete + recreate, which invalidates every key). `mcp__cpln__add_key_to_service_account` issues a key and **auto-creates the SA if absent** (`serviceAccountName`, `keyDescription` required ≤250 chars, optional `groupName`). There is no `create_service_account_key` tool. The key value is returned **once** — store it immediately. CLI fallback: `cpln serviceaccount create --name NAME` then `cpln serviceaccount add-key NAME --description "..."` (the CLI does **not** auto-create the SA; `--description` is required).

## Profiles, tokens & auth

Profiles store CLI credentials and default context (org, GVC). A user can belong to many orgs; switch the active one with the Console org selector, the `--org` flag or `CPLN_ORG`, or a per-org profile.

| Action | Command |
|:---|:---|
| Interactive login (creates `default` profile) | `cpln login [PROFILE]` |
| Create / update profile (`create` is an alias of `update`) | `cpln profile update PROFILE --org ORG --gvc GVC --token TOKEN` |
| Set default | `cpln profile set-default PROFILE` |
| List / show token | `cpln profile get` / `cpln profile token PROFILE` |

**Token precedence:** `--token` flag, then `CPLN_TOKEN` env var, then the profile token. Env overrides: `CPLN_PROFILE`, `CPLN_TOKEN`, `CPLN_ORG`, `CPLN_GVC`. Prefer `CPLN_TOKEN` (or a profile) over `--token` in CI — flags leak into shell history and logs.

> **Switching org clears the default GVC.** `cpln profile update --org NEWORG` without `--gvc`, or saving a service-account `--token` (which carries its own org) without `--gvc`, **unsets the profile's GVC** (the new org rarely has a same-named GVC). Re-pass `--gvc`. A user `--token` leaves the GVC intact.

REST/API calls use `Authorization: Bearer TOKEN` against `https://api.cpln.io`; get a token from a service-account key or `cpln profile token`.

## SSO / SAML

The Console signs in via **Google, GitHub, Microsoft, and SAML** (Firebase-backed). Each user gets a built-in `firebase/sign_in_provider` tag set automatically from the provider used. After sign-in, access is governed entirely by group membership and policies — wire users in with `mcp__cpln__edit_group`, `mcp__cpln__create_policy`, and `mcp__cpln__invite_user_to_org`.

`authConfig.samlOnly` and `domainAutoMembers` are set with `update_org`, but **turning SAML on (IdP/provider setup) is support-gated** — email support@controlplane.com; there is no self-serve tool. The Service Provider metadata you give your IdP (Entity ID, ACS/callback URL) is shown on the Console SAML setup screen — read the exact values there rather than hard-coding them.

## Org permissions (for policies)

| Permission | Implies |
|:---|:---|
| `view` | — (every org member has this) |
| `edit` | `view` |
| `readLogs` | `view` |
| `readMetrics` | — |
| `readUsage` | — |
| `grafanaAdmin` | — |
| `exec` | `exec.echo` |
| `exec.echo` | — |
| `viewAccessReport` | — |
| `manage` | all of the above |

## Verify

- After `update_org`: re-read with `get_resource` (kind `org`) and confirm the block.
- After an invite: check the Console (**Users**, then **Pending Invites**) — there is no MCP/CLI list of pending invites.
- After a profile change: `cpln profile get` — the active profile is marked `*`; confirm org **and** GVC before mutating resources.

## Troubleshooting

| Symptom | Cause / fix |
|:---|:---|
| Org create rejected (name) | Lowercase, letter-first, ≤64 chars; not `index`, not `xserve-*`; globally unique; names can't be reused (orgs are never deleted) |
| Can't create an org | Needs `org_creator` or `billing_admin` on a billing account |
| `logging`/`tracing` won't set via `update_org` | Logging uses `configure_external_logging`; tracing uses schema + `cpln apply` |
| Invited user not in the group | Group is applied on acceptance, best-effort; add with `edit_group` after they accept |
| GVC missing after switching org | `--org` (or an SA `--token`) without `--gvc` clears it — re-pass `--gvc` |
| Service-account key lost | Shown once; issue a new one with `add_key_to_service_account` / `add-key` |
| `billing_admin` can't see workloads | Billing roles grant no org access — add an org policy |

## Quick reference

| MCP tool | Action |
|:---|:---|
| `mcp__cpln__get_resource` / `update_org` (kind `org`) | Read / change org-wide settings |
| `mcp__cpln__invite_user_to_org` | Invite a user (optional group) |
| `mcp__cpln__create_group` / `edit_group` | Create / edit a group and its members |
| `mcp__cpln__create_service_account` / `add_key_to_service_account` | Create an SA / issue a key (auto-creates the SA) |
| `mcp__cpln__list_quotas` / `get_quota` | Per-org resource limits (read-only; raising one is a support request); `nearLimit: true` shows ≥80%-used |
| `mcp__cpln__list_resources` / `get_resource` / `delete_resource` | Generic read/delete for users, groups, service accounts |

## Related skills

- **access-control** — Policies, bindings, RBAC patterns, dynamic group membership, service-account scoping.
- **external-logging** — Configure org `logging` / `extraLogging`.
- **cpln** — CLI setup and the full resource-command map.
- **audit-compliance** — Who changed what across the org.

## Documentation

- [Org Reference](https://docs.controlplane.com/reference/org.md) · [Org Concepts](https://docs.controlplane.com/concepts/org.md)
- [Create Org](https://docs.controlplane.com/guides/create-org.md) · [Invite Users](https://docs.controlplane.com/guides/invite-users.md)
- [Manage Profile](https://docs.controlplane.com/guides/manage-profile.md) · [Authentication](https://docs.controlplane.com/core/authentication.md)
