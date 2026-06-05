# Principal Management — Groups, Service Accounts, Users

Companion to `skills/access-control/SKILL.md`. Day-to-day workflows for creating and managing the principals that policies bind to.

## Group Management

Groups simplify access control by letting you assign policies to teams instead of individuals. **Best practice: always assign policies to groups, not individual users.**

### Create a Group

Use `mcp__cpln__create_group` — params: `name` (required), `description`, `tags`, `memberLinks` (optional seed members). CLI fallback when the MCP server is unavailable:

```bash
cpln group create --name backend-team --org ORG_NAME
```

### Add/Remove Members

Use `mcp__cpln__edit_group` — one call updates the description/tags AND manages membership via `addMemberLinks` / `removeMemberLinks` (e.g. `["//user/alice@example.com"]`, `["//serviceaccount/cicd-deployer"]`). Params: `name` (required), `addMemberLinks`, `removeMemberLinks`, `description`, `tags`. Read current membership first with `mcp__cpln__get_group`.

CLI fallback:

```bash
cpln group add-member backend-team --email alice@example.com --org ORG_NAME
cpln group add-member backend-team --serviceaccount cicd-deployer --org ORG_NAME
cpln group remove-member backend-team --email alice@example.com --org ORG_NAME
```

### Dynamic Membership

Groups support tag-based dynamic membership for **users only** (service accounts must be added directly). Uses the standard query spec — see the **cpln-query-spec** skill for full syntax.

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

### Delete a Group

Use `mcp__cpln__delete_group` — params: `name` (required). Destructive: every policy targeting this group loses its member set, so confirm the blast radius first (list members with `mcp__cpln__get_group`). CLI fallback:

```bash
cpln group delete backend-team --org ORG_NAME
```

## Service Account Management

Service accounts provide non-human API access for CI/CD pipelines, automation, and infrastructure-as-code tools.

### Create and Generate Key

Use `mcp__cpln__add_key_to_service_account` — params: `name` (required), `keyDescription`, `groupName`. **It creates the service account if it doesn't exist, adds a key, and optionally adds the SA to a group in one call.** To create the SA without issuing a key yet, use `mcp__cpln__create_service_account` (params: `name`, `description`) first. CLI fallback:

```bash
cpln serviceaccount create --name cicd-deployer --org ORG_NAME
cpln serviceaccount add-key cicd-deployer --description "GitHub Actions" --org ORG_NAME
```

**CRITICAL: The generated key is displayed ONE TIME only.** If lost, revoke the key and generate a new one — revoke via `mcp__cpln__update_service_account` (params: `name`, plus the key name to revoke), or the CLI fallback:

```bash
cpln serviceaccount remove-key cicd-deployer --key KEY_NAME --org ORG_NAME
```

### Inspect and Delete a Service Account

Discover and inspect with `mcp__cpln__list_service_accounts` (key counts + origin) and `mcp__cpln__get_service_account` (key metadata — never key material). To remove one entirely, use `mcp__cpln__delete_service_account` (params: `name`). Destructive: all keys are revoked at once and every consumer authenticating with this SA fails immediately, so list the SA's group memberships and policy bindings (`mcp__cpln__list_groups` / `mcp__cpln__list_policies`) and confirm the blast radius first. CLI fallback:

```bash
cpln serviceaccount get cicd-deployer --org ORG_NAME
cpln serviceaccount delete cicd-deployer --org ORG_NAME
```

### Create a CLI Profile with the Key

```bash
cpln profile create cicd-profile --org ORG_NAME --token GENERATED_KEY --default
```

`cpln profile create` is an alias for `cpln profile update` — it creates or updates the named profile. The `--default` flag makes it the active profile for all future commands.

## User Management

### Invite a User

Use `mcp__cpln__invite_user_to_org` — params: `email` (required), `groupName`. Note: placing the invited user into a group during the invite requires a refresh token; service-account tokens cannot grant group membership at invite time. CLI fallback:

```bash
cpln user invite --email alice@example.com --group backend-team --org ORG_NAME
```

The user receives an onboarding email. They appear in "Pending Invites" until they accept. Pending invites can be deleted if sent by mistake.

### Remove a User

Use `mcp__cpln__delete_user` — params: `id` or `email`. Destructive: the user loses every group membership and policy binding immediately. Discover the target with `mcp__cpln__list_users` (or look up by email), capture state first with `mcp__cpln__get_user`, and confirm the blast radius. CLI fallback:

```bash
cpln user delete alice@example.com --org ORG_NAME
```

### Multi-Org Membership

Users can belong to multiple orgs. Each org has independent policies — membership in one org grants no access to another.
