# Principal Management — Groups, Service Accounts, Users

Companion to `skills/access-control/SKILL.md`. Day-to-day workflows for creating and managing the principals that policies bind to.

## Group Management

Groups simplify access control by letting you assign policies to teams instead of individuals. **Best practice: always assign policies to groups, not individual users.**

### Create a Group

```bash
cpln group create --name backend-team --org ORG_NAME
```

MCP: `mcp__cpln__create_group` — params: `name` (required), `description`, `tags`, `memberLinks`.

### Add/Remove Members

```bash
cpln group add-member backend-team --email alice@example.com --org ORG_NAME
cpln group add-member backend-team --serviceaccount cicd-deployer --org ORG_NAME
cpln group remove-member backend-team --email alice@example.com --org ORG_NAME
```

MCP (dedicated tools):
- `mcp__cpln__add_member_to_group` — params: `groupName` (required), `memberLinks` (required, e.g. `["//user/alice@example.com"]`).
- `mcp__cpln__remove_member_from_group` — params: `groupName` (required), `memberLinks` (required).

MCP (general update): `mcp__cpln__update_group` — params: `name` (required), `addMemberLinks`, `removeMemberLinks`, `description`, `tags`.

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

```bash
cpln group delete backend-team --org ORG_NAME
```

MCP: `mcp__cpln__delete_group` — params: `name` (required).

## Service Account Management

Service accounts provide non-human API access for CI/CD pipelines, automation, and infrastructure-as-code tools.

### Create and Generate Key

```bash
cpln serviceaccount create --name cicd-deployer --org ORG_NAME
cpln serviceaccount add-key cicd-deployer --description "GitHub Actions" --org ORG_NAME
```

MCP: `mcp__cpln__create_service_account_key` — params: `serviceAccountName` (required), `keyDescription`, `groupName`. **Creates the service account if it doesn't exist.**

**CRITICAL: The generated key is displayed ONE TIME only.** If lost, remove the key and generate a new one:

```bash
cpln serviceaccount remove-key cicd-deployer --key KEY_NAME --org ORG_NAME
```

### Create a CLI Profile with the Key

```bash
cpln profile create cicd-profile --org ORG_NAME --token GENERATED_KEY --default
```

`cpln profile create` is an alias for `cpln profile update` — it creates or updates the named profile. The `--default` flag makes it the active profile for all future commands.

## User Management

### Invite a User

```bash
cpln user invite --email alice@example.com --group backend-team --org ORG_NAME
```

MCP: `mcp__cpln__invite_user_to_org` — params: `email` (required), `groupName`.

The user receives an onboarding email. They appear in "Pending Invites" until they accept. Pending invites can be deleted if sent by mistake.

### Remove a User

```bash
cpln user delete alice@example.com --org ORG_NAME
```

### Multi-Org Membership

Users can belong to multiple orgs. Each org has independent policies — membership in one org grants no access to another.
