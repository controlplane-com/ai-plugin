---
name: cpln-access-control-setup
description: Use when setting up access control for an org. Guides through creating groups, service accounts, and policies with correct principal links, permissions, and target scoping.
version: 1.0.0
---

# Control Plane Access Control Setup

You guide users through setting up access control for Control Plane organizations. Access control involves three interconnected decisions — who needs access (principals), what resources they can access (targets), and what they can do (permissions). Getting any wrong leads to over-permissive access or locked-out users/pipelines.

## Step 0: Understand the Goal

Ask the user: **What are you trying to set up?**

| Goal                                                   | Flow                                            |
| :----------------------------------------------------- | :---------------------------------------------- |
| **A** — Grant team members access to resources         | Group + Policy (Steps 1, 2, 3, 4)               |
| **B** — Set up CI/CD pipeline access                   | Service Account + Policy (Step 5, then 2, 3, 4) |
| **C** — Grant a workload identity access to a secret   | **Redirect** to `/cpln:setup-secret`            |
| **D** — Grant a workload credential-free cloud access  | **Redirect** to `/cpln:setup-cloud-access`      |
| **E** — Create a custom policy for a specific use case | Custom Policy (Steps 2, 3, 4)                   |

**Options C and D are handled by dedicated agents. Do NOT reimplement them here.** Tell the user:

- **C**: "This is handled by `/cpln:setup-secret`. It orchestrates the identity + policy + secret injection chain. Shall I run that instead?"
- **D**: "This is handled by `/cpln:setup-cloud-access`. It sets up Universal Cloud Identity for AWS/GCP/Azure. Shall I run that instead?"

---

## Step 1: Create or Select a Group (Options A and E)

Groups are the recommended way to manage team access. Permissions granted to a group apply to all its members.

### Check existing groups

#### Via MCP (preferred)

Use `mcp__cpln__list_groups` to see all groups, or `mcp__cpln__get_group` with a `name` to check a specific group's members.

#### Via CLI

```bash
cpln group get --org ORG
```

### Create a new group

#### Via MCP (preferred)

Use `mcp__cpln__create_group`:

- `name` (required) — descriptive name (e.g., `backend-developers`, `platform-admins`)
- `description` (optional) — explain what access this group grants
- `memberLinks` (optional) — seed with initial members (e.g., `["//user/alice@example.com"]`)

#### Via CLI

```bash
cpln group create --name GROUP_NAME --org ORG
```

### Add members to the group

#### Via MCP (preferred)

Use `mcp__cpln__add_member_to_group` for adding members:

- `groupName` (required) — group to add to
- `memberLinks` (required) — e.g., `["//user/alice@example.com", "//serviceaccount/sa-name"]`

Or use `mcp__cpln__update_group` with `addMemberLinks` to combine member changes with description/tag updates.

#### Via CLI

```bash
cpln group add-member GROUP_NAME --email user@example.com --org ORG
cpln group add-member GROUP_NAME --serviceaccount sa-name --org ORG
```

### Invite new users (if not yet in the org)

#### Via MCP (preferred)

Use `mcp__cpln__invite_user_to_org`:

- `email` (required) — user's email address
- `groupName` (optional) — group to assign after they accept

#### Via CLI

```bash
cpln user invite --email user@example.com --group GROUP_NAME --org ORG
```

**Note:** When authenticated with a service account token, the `--group` flag may not auto-assign group membership. Prefer refresh tokens for invitations with group assignment, or add the user to the group after they accept.

---

## Step 2: Determine Access Scope

Guide the user through **what resources** the policy should target.

### Target options

| Approach                 | When to Use                         | Policy Field                     |
| :----------------------- | :---------------------------------- | :------------------------------- |
| All resources of a type  | Org-wide access for a resource kind | `targetAll: true` + `targetKind` |
| Specific named resources | Access to known resources by name   | `targetLinks` + resource links   |
| Resources matching tags  | Dynamic access based on tag queries | `targetQuery` + tag expression   |

### Target kinds

For the authoritative list of valid `targetKind` values, see **rules/policy-manifest-reference.md** (verified against `cpln policy create --target-kind`). Note: `ipset` and `mk8s` are platform resources but NOT valid policy targets — access is controlled via their parent (`org` or `gvc`).

### Resource link format

Links follow the pattern `//RESOURCE_TYPE/RESOURCE_NAME`. For GVC-scoped resources, include the GVC: `//gvc/GVC_NAME/workload/WORKLOAD_NAME`.

| Resource        | Link Format                | Example                            |
| :-------------- | :------------------------- | :--------------------------------- |
| Secret          | `//secret/NAME`            | `//secret/db-password`             |
| Workload        | `//gvc/GVC/workload/NAME`  | `//gvc/production/workload/api`    |
| GVC             | `//gvc/NAME`               | `//gvc/production`                 |
| Identity        | `//gvc/GVC/identity/NAME`  | `//gvc/production/identity/api-id` |
| Group           | `//group/NAME`             | `//group/backend-devs`             |
| Service Account | `//serviceaccount/NAME`    | `//serviceaccount/ci-bot`          |
| Image           | `//image/NAME`             | `//image/my-app`                   |
| Domain          | `//domain/NAME`            | `//domain/api.example.com`         |
| Volume Set      | `//gvc/GVC/volumeset/NAME` | `//gvc/prod/volumeset/data`        |

**NEVER default to `targetAll: true`.** Always ask the user to explicitly confirm if they want org-wide access. Explain: "This grants access to ALL current and future resources of this type in the org."

---

## Step 3: Choose Permissions

### Discover available permissions

#### Via MCP (preferred)

Use `mcp__cpln__get_permissions` with the target `kind` to see all valid permissions.

#### Via CLI

```bash
cpln RESOURCE_TYPE permissions --org ORG
```

For example: `cpln secret permissions --org ORG`, `cpln workload permissions --org ORG`.

### Common permission sets

| Role            | Typical Permissions                | Use Case                          |
| :-------------- | :--------------------------------- | :-------------------------------- |
| Viewer          | `view`                             | Read-only access                  |
| Developer       | `view`, `create`, `edit`, `delete` | Day-to-day development            |
| Admin           | `manage`                           | Full control of the resource kind |
| Secret Consumer | `reveal`, `use`                    | Workloads that need secret values |

Present these as suggestions. Let the user customize by adding or removing individual permissions.

**Warn about `manage` permission:** "`manage` implies ALL permissions for this resource kind, including `create`, `delete`, `edit`, and `view`. Only grant this to principals that need full administrative control."

### Permission implications

The `manage` permission implies all other permissions for the resource kind. The `edit` permission implies `view`. Use `mcp__cpln__get_permissions` to see the exact implication chain for each resource kind.

---

## Step 4: Create the Policy

### Build and confirm

Before creating, **show the user the policy configuration** for confirmation:

```yaml
kind: policy
name: POLICY_NAME
description: DESCRIPTION
targetKind: TARGET_KIND
targetLinks: # or target: all
  - //resource/name
bindings:
  - permissions:
      - permission1
      - permission2
    principalLinks:
      - //group/GROUP_NAME
      # or //user/email@example.com
      # or //serviceaccount/SA_NAME
      # or //gvc/GVC/identity/IDENTITY_NAME
```

Ask: "Does this look correct? Shall I create this policy?"

### Create the policy

#### Via MCP (preferred)

Use `mcp__cpln__create_policy`:

- `name` (required) — policy name
- `targetKind` (required) — resource kind to govern
- `targetAll` (optional) — set to `true` for org-wide
- `targetLinks` (optional) — array of resource links for specific resources
- `addPermissions` (optional) — permissions to grant
- `addGroups` (optional) — group links to bind
- `addUsers` (optional) — user links to bind
- `addServiceAccounts` (optional) — service account links to bind
- `addIdentities` (optional) — identity links to bind

#### Via CLI

```bash
cpln policy create --name POLICY_NAME \
  --target-kind TARGET_KIND \
  --resource RESOURCE_NAME \
  --org ORG

cpln policy add-binding POLICY_NAME \
  --permission PERMISSION \
  --group GROUP_NAME \
  --org ORG
```

Repeat `--resource` for multiple resources. Repeat `--permission`, `--group`, `--email`, `--serviceaccount`, or `--identity` as needed on `add-binding`.

Use `--all` instead of `--resource` on `cpln policy create` for org-wide targeting.

#### Via `cpln apply` (manifest-based)

Save the YAML shown in the confirmation step to a file and apply it:

```bash
cpln apply --file policy.yaml --org ORG
```

This is the preferred approach when the user wants to version-control their policies, apply multiple resources at once, or use GitOps workflows. The manifest can also include groups and service accounts in the same file (separated by `---`).

### Verify the policy

#### Via MCP

Use `mcp__cpln__get_permissions` to double-check valid permissions, then confirm the policy was created with `mcp__cpln__get_policy` (`name: POLICY_NAME`).

#### Via CLI

```bash
cpln policy get POLICY_NAME --org ORG -o yaml
```

Confirm the `targetKind`, `targetLinks` (or `target: all`), `bindings`, and `principalLinks` match what was intended.

---

## Step 5: Create a Service Account (Option B — CI/CD)

### Create the service account and generate a key

#### Via MCP (preferred)

Use `mcp__cpln__create_service_account_key`:

- `serviceAccountName` (required) — creates the SA if it doesn't exist, then adds a key
- `keyDescription` (optional) — describe the key's purpose (e.g., "GitHub Actions deploy key")
- `groupName` (optional) — add the SA to a group immediately

**The key is shown only once.** Instruct the user to save it immediately.

#### Via CLI

```bash
cpln serviceaccount create --name SA_NAME --org ORG

cpln serviceaccount add-key SA_NAME --desc "GitHub Actions" --org ORG
```

The `add-key` command outputs the key. Copy and store it securely.

### Set up a CLI profile with the key

```bash
cpln profile create PROFILE_NAME --token THE_GENERATED_KEY --org ORG
```

Use `--default` to make this the active profile:

```bash
cpln profile create PROFILE_NAME --token THE_GENERATED_KEY --org ORG --default
```

`cpln profile create` is an alias for `cpln profile update` — it creates or updates the named profile.

### Proceed to policy creation

After the service account is created, continue to **Steps 2, 3, and 4** to create a policy granting the service account (or its group) the required permissions.

When binding in the policy:

- Direct SA binding: use `addServiceAccounts: ["//serviceaccount/SA_NAME"]`
- Via group (preferred for multiple SAs): add the SA to a group, then bind the group

---

## Step 6: Verify Access

After the policy is created:

1. **Confirm policy exists and is correct:**

```bash
cpln policy get POLICY_NAME --org ORG -o yaml
```

2. **Check the access report** for a principal to verify effective permissions:

```bash
cpln group access-report GROUP_NAME --org ORG
cpln serviceaccount access-report SA_NAME --org ORG
cpln user access-report USER_EMAIL --org ORG
```

3. **Test with the new credentials** (for service accounts):

```bash
cpln RESOURCE_TYPE get --profile SA_PROFILE --org ORG
```

4. **Remind about least privilege:** Review whether the permissions granted are the minimum needed. Prefer `view` over `edit`, `edit` over `manage`.

---

## Principal Link Reference

| Principal Type  | Link Format               | Example                            |
| :-------------- | :------------------------ | :--------------------------------- |
| User            | `//user/EMAIL`            | `//user/alice@example.com`         |
| Group           | `//group/NAME`            | `//group/backend-devs`             |
| Service Account | `//serviceaccount/NAME`   | `//serviceaccount/ci-bot`          |
| Identity        | `//gvc/GVC/identity/NAME` | `//gvc/prod/identity/api-identity` |

---

## Built-in Groups and Policies

Every org has built-in groups and policies:

| Group        | Purpose                                                              |
| :----------- | :------------------------------------------------------------------- |
| `superusers` | Full administrative access (bound to `manage` on all resource types) |
| `viewers`    | Read-only access (bound to `view` on all resource types)             |

**Best practice:** Add users to `viewers` by default. Only add to `superusers` when full admin access is required. Create custom groups for granular access.

---

## Common Mistakes to Prevent

- **Using `targetAll` without explicit confirmation** — always verify the user intends org-wide access
- **Wrong principal link format** — must start with `//` (e.g., `//user/alice@example.com`, not `user/alice@example.com`)
- **Granting `manage` when less is needed** — `manage` implies all permissions; prefer specific permissions
- **Binding individual users instead of groups** — groups are easier to manage; update membership instead of editing policies
- **Forgetting to add the principal to the org** — users must be invited and accept before policies apply to them
- **Confusing `view` and `reveal` for secrets** — `view` shows metadata only; `reveal` exposes the secret value (redirect to `/cpln:setup-secret` for workload secret access)
- **Missing GVC in identity links** — identities are GVC-scoped: `//gvc/GVC/identity/NAME`, not `//identity/NAME`
- **Service account key not saved** — the key is shown only once; if lost, remove and regenerate

## MCP Tools Reference

| Tool                                    | Purpose                                                          |
| :-------------------------------------- | :--------------------------------------------------------------- |
| `mcp__cpln__list_policies`              | List all policies in an org                                      |
| `mcp__cpln__get_policy`                 | Get a specific policy's details and bindings                     |
| `mcp__cpln__create_policy`              | Create a policy with target, permissions, and principal bindings |
| `mcp__cpln__update_policy`              | Update policy description, tags, targetLinks, or merge bindings  |
| `mcp__cpln__delete_policy`              | Delete a policy (irreversible)                                   |
| `mcp__cpln__get_permissions`            | Discover valid permissions for a resource kind                   |
| `mcp__cpln__list_groups`                | List all groups in an org                                        |
| `mcp__cpln__get_group`                  | Get a specific group's details and members                       |
| `mcp__cpln__create_group`               | Create a new group with optional initial members                 |
| `mcp__cpln__update_group`               | Update description, tags, and members in one call                |
| `mcp__cpln__add_member_to_group`        | Add users or service accounts to a group                         |
| `mcp__cpln__remove_member_from_group`   | Remove users or service accounts from a group                    |
| `mcp__cpln__list_service_accounts`      | List all service accounts in an org                              |
| `mcp__cpln__get_service_account`        | Get service account details, keys, and group memberships         |
| `mcp__cpln__create_service_account_key` | Create SA (if needed) + generate key + optional group assignment |
| `mcp__cpln__invite_user_to_org`         | Invite a user by email, optionally assign to a group             |
