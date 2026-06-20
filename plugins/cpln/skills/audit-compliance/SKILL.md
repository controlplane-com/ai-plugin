---
name: audit-compliance
description: "Audit trail and compliance on Control Plane. Use when the user asks about audit logs, who changed what, change tracking, audit contexts, writing custom audit events, security monitoring, SOC 2, HIPAA, or PCI compliance."
---

# Audit Trail & Compliance

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Every mutation on every Control Plane resource — via Console, CLI, API, Terraform, Pulumi, or MCP — is recorded automatically in an append-only, tamper-proof audit trail; nothing to configure. Most tasks are answering **"who changed what, when"** with `mcp__cpln__query_audit_events`. Custom audit contexts exist for one purpose only: letting your own workloads write their own audit events.

## The model

Events live in **audit contexts** (org-scoped namespaces):

| Context | Origin | Holds |
|---|---|---|
| `cpln` — built-in, one per org | `builtin` | every platform mutation, automatically |
| custom — user-created | `default` | only events your workloads POST to it |

- Platform events go **only** to `cpln`; custom contexts never receive them — querying one returns only what workloads wrote.
- The `origin` value `default` means "user-created", not "default for the org".
- **No audit context can be deleted** — there is no delete in the API, CLI, MCP, or Console, and `terraform destroy` only removes the context from Terraform state; events are append-only. The built-in `cpln` context can't be edited either. Creating a context is permanent.

## Event anatomy

Each event carries `id`, `eventTime` / `postedTime` / `receivedTime`, `requestId`, `context` (`org`, audit-context `name`, `location`, `gvcAlias`, `podId`, `remoteIp`, `eventSource`), `subject` (`name`, `email`), `resource` (`id`, `type`, `name`, `data` — the resource snapshot), `action.type` (`create` / `edit` / `delete` / `exec`), and `result` (`status`, `message`).

Secret snapshots are scrubbed: `resource.data` for a secret never includes the payload, so the audit trail itself stores no secret values.

## Querying events

### MCP — `query_audit_events`

```json
// all workload mutations in the last 24h
{ "kind": "workload", "org": "my-org", "since": "24h" }

// who changed a specific secret in the last 30 days
{ "kind": "secret", "name": "db-password", "since": "30d" }

// several policies in one call (merged, newest-first)
{ "kind": "policy", "names": ["admin", "readonly"], "since": "7d" }

// everything one subject touched across all secrets
{ "kind": "secret", "subject": "user@example.com", "since": "30d" }

// a custom context — kind matches the resource.type your workload wrote
{ "kind": "order", "context": "my-app-audit", "since": "7d" }

// a past window — relative from/to mean "that long ago from now"
{ "kind": "workload", "org": "my-org", "from": "3mo", "to": "1mo" }
```

Inputs: `kind` (required) · `name` **or** `names[]` (max 25, mutually exclusive; omit both for every resource of the kind) · `gvc` (**required** when `kind` is `workload` / `identity` / `dbcluster` / `volumeset` and a name is given) · `subject` (user email, full link, or bare service-account name) · `context` (default `cpln`) · `since` (default `7d`) **or** `from` / `to` (ISO 8601, or a relative duration meaning that long ago — units `m`, `h`, `d`, `w`, `mo`, `y`; months are `mo`, not `M`) · `limit` (default 50, max 1000). Results are merged, sorted newest-first, truncated to `limit`.

### CLI

Every resource type has an `audit` subcommand with the same flags:

```bash
cpln workload audit my-app --gvc my-gvc --org my-org --since 24h
cpln secret audit db-password --org my-org --subject user@example.com
cpln workload audit --org my-org --since 24h     # omit the ref: every workload in the org
cpln workload audit my-app --gvc my-gvc \
  --from 2025-10-23T07:00:00Z --to 2025-10-24T07:00:00Z
cpln workload audit my-app --gvc my-gvc --from now-3M --to now-1M   # window: 3 months ago to 1 month ago
```

Flags: `--since` (default `7d`; mutually exclusive with `--from`/`--to`), `--from`/`--to` (ISO 8601, a relative duration like `7d` or `3M`, or `now-` prefixed like `now-30d` — the CLI accepts `M` for months; MCP only accepts `mo`), `--subject`, `--context` (default `cpln`), `--max` (default 50).

## Managing audit contexts

- **Create:** `mcp__cpln__create_audit_context` (`name`; `description` defaults to the name; `tags`). CLI: `cpln auditctx create --name my-app-audit --org my-org`.
- **Read:** `mcp__cpln__list_resources` (kind="auditctx") / `mcp__cpln__get_resource` (kind="auditctx").
- **Edit:** `mcp__cpln__edit_audit_context` — description and tags only; `origin` is immutable; the built-in `cpln` context rejects edits. CLI: `cpln auditctx update my-app-audit --set description="..."`.
- **Delete:** impossible by design (see The model) — don't promise it.

## Writing events from a workload

1. **Create a context** — `mcp__cpln__create_audit_context`.
2. **Create an identity** — `mcp__cpln__create_identity`.
3. **Grant `writeAudit`** — `mcp__cpln__create_policy` with `targetKind: auditctx`, the context in `targetLinks`, and a binding of `writeAudit` to the identity (binding shape: **access-control** skill).
4. **Attach the identity** to the workload via `spec.identityLink` — `mcp__cpln__update_workload`.
5. **POST from inside the container:**

```bash
curl -H "Content-Type: application/json" \
  -X POST "http://127.0.0.1:43000/audit/org/${CPLN_ORG}/auditctx/my-app-audit?async=true" \
  -d '{"resource": {"id": "order-1234", "type": "order"}, "action": {"type": "refund"}}'
```

- The sidecar serves `127.0.0.1:43000` in every workload pod and attaches the workload's identity automatically — no token or auth header needed. The write is rejected unless that identity has `writeAudit` on the context.
- Body: `resource.id` and `resource.type` are required; `eventTime` (ISO 8601, defaults to now), `subject`, `action.type`, and `result` are optional; unknown fields are rejected.
- `?async=true` is fire-and-forget; drop it to get the stored event's `id` back in the response.

## Permissions (kind `auditctx`)

`create`, `edit`, `view`, `manage`, and the two that matter: **`readAudit`** (query events) and **`writeAudit`** (post events) — both distinct from `view`, which only reads the context resource itself. `manage` implies all; `edit`, `readAudit`, and `writeAudit` each imply `view`. Confirm with `mcp__cpln__get_permissions` (`kind: auditctx`).

## Compliance

Control Plane is **PCI DSS Level 1** and **SOC 2 Type II** certified (audited by Prescient Assurance). For the SOC 2 report or PCI Attestation of Compliance, contact support on Slack or [support@controlplane.com](mailto:support@controlplane.com); the [PCI Responsibility Matrix](https://controlplane.com/downloads/Control_Plane_PCI_Responsibilities_Matrix.pdf) is public. Stripe handles all payment data.

## Quick reference — MCP tools

| Tool | Purpose | Key params |
|---|---|---|
| `mcp__cpln__query_audit_events` | Query events for a kind | `kind`, `name`/`names`, `gvc`, `subject`, `context`, `since`/`from`/`to`, `limit` |
| `mcp__cpln__create_audit_context` | Create a custom context (permanent) | `name`, `description`, `tags` |
| `mcp__cpln__list_resources` (kind="auditctx") / `get_resource` (kind="auditctx") | List / read contexts | `name` |
| `mcp__cpln__edit_audit_context` | Update description / tags | `name`, `description`, `tags`, `removeTagKeys` |

**CLI fallback** (read the `cpln` skill first; verify with `cpln auditctx --help`): `cpln RESOURCE audit [ref]`, `cpln auditctx create / get / update / query / access-report / permissions`. There is no delete.

## Related skills

| Need | Skill |
|---|---|
| Policy and binding shape for `writeAudit` / `readAudit` grants | `access-control` |
| Ship runtime logs to external destinations for retention | `external-logging` |
| CLI setup and command reference | `cpln` |

## Documentation

- [Audit Trail](https://docs.controlplane.com/core/audittrail.md)
- [Audit Context Reference](https://docs.controlplane.com/reference/auditctx.md)
- [Compliance](https://docs.controlplane.com/compliance.md)
