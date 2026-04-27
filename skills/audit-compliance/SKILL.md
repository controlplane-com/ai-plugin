---
name: cpln-audit-compliance
description: "Manages audit trail, compliance, and security monitoring on Control Plane. Use when the user asks about audit logs, SOC 2, HIPAA, PCI compliance, audit context, who changed what, change tracking, or regulatory requirements. Covers tamper-proof audit events, audit context configuration, compliance certifications, and security monitoring."
version: 1.0.0
---

# Audit Trail & Compliance

## Audit trail overview

Control Plane provides a tamper-proof audit trail service that captures every mutation performed via the Console UI, CLI, API, Terraform, Pulumi, or MCP Server. Events are securely stored and indexed for querying.

### What gets captured

Every action on any Control Plane resource (workloads, secrets, policies, identities, GVCs, etc.) produces an audit entry automatically. No configuration is required for platform events.

### Audit event structure

Each audit event contains:

| Field                 | Description                                                |
| --------------------- | ---------------------------------------------------------- |
| `id`                  | Unique event identifier                                    |
| `eventTime`           | When the action occurred                                   |
| `postedTime`          | When the event was posted to the audit service             |
| `receivedTime`        | When the audit service received the event                  |
| `requestId`           | Correlation ID for the request                             |
| `context.org`         | Organization where the action occurred                     |
| `context.name`        | Audit context name (e.g., `cpln` for platform events)      |
| `context.location`    | Location where the action occurred                         |
| `context.remoteIp`    | IP address of the caller                                   |
| `context.eventSource` | Source of the event                                        |
| `subject.email`       | Email of the user who performed the action                 |
| `subject.name`        | Name of the principal (user, service account)              |
| `resource.id`         | ID of the affected resource                                |
| `resource.type`       | Kind of the affected resource (e.g., `workload`, `secret`) |
| `resource.name`       | Name of the affected resource                              |
| `resource.data`       | Full resource snapshot at the time of the event            |
| `action.type`         | Type of action performed                                   |
| `result.status`       | Outcome status                                             |
| `result.message`      | Human-readable result description                          |

### Querying and retention

- The built-in audit context `cpln` captures all Control Plane platform events
- Audit events are returned in paginated pages, with a `next` link in the response for fetching subsequent pages
- The audit API supports querying by resource, subject, request ID, audit context, and time window (see the [OpenAPI spec](https://audit.cpln.io/openapi.json) for full parameters)

## Viewing audit events

### MCP (preferred for agents)

Use `mcp__cpln__query_audit_events` to fetch audit events. One call handles a single resource, multiple resources of the same kind, or every resource of that kind in the org.

```json
// all workload mutations in the last 24h
{ "kind": "workload", "org": "my-org", "since": "24h" }

// who changed a specific secret in the last 30 days
{ "kind": "secret", "name": "db-password", "since": "30d" }

// audit several policies in one call (merged, newest-first)
{ "kind": "policy", "names": ["admin", "readonly", "secret-access"], "since": "7d" }

// filter by subject across all workloads
{ "kind": "workload", "subject": "user@example.com", "since": "30d" }

// query a custom audit context instead of the built-in cpln context
{ "kind": "workload", "name": "my-app", "context": "my-app-audit", "since": "7d" }
```

Inputs: `kind` (required), `org`, `name` **or** `names[]` (mutually exclusive, max 25 names), `subject`, `context` (default `cpln`), `since` (default `7d`) **or** `from`/`to` (ISO 8601), `limit` (default 200, max 1000). Results come back merged, sorted newest-first, and truncated to `limit`.

To **create** a custom audit context, use `mcp__cpln__create_audit_context`:

```json
// minimal
{ "name": "my-app-audit", "org": "my-org" }

// with description and tags
{
  "name": "my-app-audit",
  "org": "my-org",
  "description": "Audit trail for my-app",
  "tags": [{ "key": "env", "value": "production" }]
}
```

For other audit context operations (list, get, update, patch, delete), use the generic `mcp__cpln__cpln_resource_operation` tool with `kind: "auditctx"`.

### Per-resource audit trail (CLI)

Every resource type supports the `audit` subcommand to view its audit history:

```bash
# View audit events for a specific workload
cpln workload audit my-app --gvc my-gvc --org my-org

# View audit events for a secret
cpln secret audit db-password --org my-org

# View audit events for a policy
cpln policy audit secret-access --org my-org

# View audit events for an audit context itself
cpln auditctx audit my-context --org my-org
```

The `audit` subcommand supports time-range filtering:

```bash
# Relative lookback (default: 7d)
cpln workload audit my-app --gvc my-gvc --since 24h

# Absolute time range (ISO 8601)
cpln workload audit my-app --gvc my-gvc \
  --from 2025-10-23T07:00:00Z --to 2025-10-24T07:00:00Z

# Relative time range — --from/--to accept "now-<duration>" (e.g., the day before yesterday)
cpln workload audit my-app --gvc my-gvc --from now-2d --to now-1d

# Filter by subject
cpln workload audit my-app --gvc my-gvc --subject user@example.com

# Filter by custom audit context (default is cpln)
cpln workload audit my-app --gvc my-gvc --context my-app-audit

# Omit the positional ref to get ALL audit events for that resource kind in the org
cpln workload audit --org my-org --since 24h       # every workload mutation in the last 24h
cpln secret audit --org my-org --subject user@example.com
```

**Flags:** `--since` (relative, default `7d`), `--from`/`--to` (ISO 8601, relative duration like `7d`, or `now-<duration>` like `now-2d`), `--subject` (user email, service account name, or full link), `--context` (audit context name, default `cpln`; set to a custom context to query workload-written events). `--since` is mutually exclusive with `--from`/`--to`. When the positional resource ref is omitted, the command returns events for every resource of that kind in the org.

### Org-wide audit trail (Console UI)

The Console UI Audit Trail page (`Audit Trail` in the left menu) provides org-wide querying with filters:

- **Kind**: Filter by resource type (workload, secret, policy, etc.)
- **Audit Context**: Select which context to query (default: `cpln`)
- **Resource Name or ID**: Search by specific resource
- **Subject Name**: Filter by the user or service account that performed the action
- **Date Range**: Start and optional end date with time presets

The Console also supports **diff view** for comparing audit snapshots and **applying a previous version** of a resource directly from an audit entry.

### Audit API

The audit API is available at `https://audit.cpln.io`. View the [OpenAPI spec](https://audit.cpln.io/openapi.json) for the full schema and available methods.

API query pattern:

```
GET /audit/org/{org}?contextName=cpln&resourceType=workload&fromEvent={ISO}&toEvent={ISO}
GET /audit/org/{org}/resource/name/{name}?resourceType=secret
GET /audit/org/{org}/resource/id/{id}?subjectName=user@example.com
```

## Audit contexts

An **audit context** is an org-scoped resource that acts as a namespace for audit events. It enables custom workloads and third-party systems to write their own tamper-proof audit entries alongside platform events.

### Built-in `cpln` context vs. custom contexts

Every org has exactly one built-in audit context named `cpln` (origin: `builtin`). It is created automatically, captures every Control Plane platform mutation, and cannot be deleted. The `cpln` context is the default target of `cpln <resource> audit` — platform events go here regardless of the resource you are auditing.

Custom audit contexts (origin: `default`) are user-created and exist only for workloads or third-party systems that want to write their own tamper-proof audit entries. Platform events never flow into custom contexts — you must explicitly POST to them from your workload. Querying a custom context returns only the events that workload wrote.

Terminology note: the `origin` enum uses `builtin` for the `cpln` context and `default` for every user-created context — the label `default` here means "user-created", not "default for the org".

### Creating custom audit contexts

Create custom contexts to separate audit streams for different workloads or systems:

```bash
# Create a custom audit context
cpln auditctx create --name my-app-audit --org my-org

# With description and tags
cpln auditctx create --name my-app-audit \
  --desc "Audit trail for my-app" \
  --tag env=production --org my-org
```

### Audit context properties

| Property      | Type                   | Description                                                  |
| ------------- | ---------------------- | ------------------------------------------------------------ |
| `name`        | string                 | Unique name within the org (required)                        |
| `description` | string                 | Optional, defaults to name                                   |
| `origin`      | `default` or `builtin` | `builtin` for the `cpln` context, `default` for user-created |
| `tags`        | key-value pairs        | Optional metadata                                            |

### Writing audit events from workloads

To write custom audit events from a workload:

1. **Create an audit context** for your workload
2. **Create an identity** with `writeAudit` permission on the audit context
3. **Assign the identity** to the workload
4. **POST events** to the internal audit endpoint from within the workload:

```bash
curl -H "Content-Type: application/json" \
  -X POST http://127.0.0.1:43000/audit/org/${CPLN_ORG}/auditctx/my-app-audit?async=true \
  -d '{"resource": {"id": "anyid123", "type": "anytype"}}'
```

The internal endpoint (`127.0.0.1:43000`) is available to every workload via the sidecar. The workload's `CPLN_TOKEN` is used automatically for authentication.

### Audit context permissions

| Permission   | Description                            | Implies                                                       |
| ------------ | -------------------------------------- | ------------------------------------------------------------- |
| `create`     | Create new contexts                    |                                                               |
| `edit`       | Modify existing contexts               | `view`                                                        |
| `manage`     | Full access                            | `create`, `edit`, `manage`, `readAudit`, `view`, `writeAudit` |
| `readAudit`  | Read events from this context          | `view`                                                        |
| `view`       | Read-only view of the context resource |                                                               |
| `writeAudit` | Write events to this context           | `view`                                                        |

### Managing audit contexts (CLI)

```bash
# List all audit contexts
cpln auditctx get --org my-org

# Get a specific context
cpln auditctx get my-app-audit --org my-org

# Update description
cpln auditctx update my-app-audit --set description="Updated description" --org my-org

# Query contexts by property
cpln auditctx query --match any --prop name=my-app-audit --org my-org

# View access report
cpln auditctx access-report my-app-audit --org my-org

# View permissions
cpln auditctx permissions --org my-org
```

## Compliance certifications

### PCI DSS Level 1

Control Plane is Level 1 PCI DSS compliant. Stripe handles payment information and credit card processing. Annual on-site assessments and continuous risk management are performed.

- [Download PCI Responsibility Matrix](https://controlplane.com/downloads/Control_Plane_PCI_Responsibilities_Matrix.pdf)
- For a copy of the PCI Attestation of Compliance (AoC), contact [support@controlplane.com](mailto:support@controlplane.com)

### SOC 2 Type II

Control Plane has completed the AICPA SOC 2 Type II audit, confirming that information security practices, policies, procedures, and operations meet SOC 2 standards for security.

Key practices:

- **Secure personnel**: Background checks, NDAs, continuous security training
- **Secure development**: Secure development lifecycle, design reviews, OWASP Top 10 alignment
- **Secure testing**: Third-party penetration testing, vulnerability scanning, SAST/DAST
- **Cloud security**: Customer isolation via patented approach, encryption at rest and in transit, unique encryption keys per customer, role-based access controls

Audited by Prescient Assurance. For a copy of the audit report, contact [support@controlplane.com](mailto:support@controlplane.com).

### Compliance summary

| Certification   | Status    | Contact for Details      |
| --------------- | --------- | ------------------------ |
| PCI DSS Level 1 | Compliant | support@controlplane.com |
| SOC 2 Type II   | Compliant | support@controlplane.com |

## Security monitoring patterns

### Track secret access

Use the audit trail to monitor who reveals or modifies secrets:

```bash
# View all audit events for a secret
cpln secret audit db-password --org my-org --since 30d

# Filter by specific subject
cpln secret audit db-password --org my-org --subject suspicious-user@example.com
```

### Monitor policy changes

Track changes to access control policies:

```bash
cpln policy audit secret-access --org my-org --since 7d
```

### Monitor identity and service account changes

```bash
cpln identity audit my-identity --gvc my-gvc --since 7d
cpln serviceaccount audit deploy-sa --org my-org --since 7d
```

### Org-wide security review

Use the Console UI Audit Trail with filters to review all actions across the org for a specific time period, subject, or resource kind.

## Quick reference

### CLI commands

| Command                                      | Purpose                                       |
| -------------------------------------------- | --------------------------------------------- |
| `cpln <resource> audit [ref]`                | View audit events for any resource            |
| `cpln auditctx create --name NAME`           | Create a custom audit context                 |
| `cpln auditctx get [ref]`                    | List or get audit contexts                    |
| `cpln auditctx update <ref> --set KEY=VALUE` | Update audit context properties               |
| `cpln auditctx query --prop KEY=VALUE`       | Search audit contexts                         |
| `cpln auditctx access-report <ref>`          | View who has access to an audit context       |
| `cpln auditctx permissions`                  | List grantable permissions for audit contexts |
| `cpln auditctx clone <ref> --name NAME`      | Clone an audit context                        |
| `cpln auditctx patch <ref> --file FILE`      | Patch audit context from file                 |

### API endpoint

`https://audit.cpln.io` -- [OpenAPI spec](https://audit.cpln.io/openapi.json)

### MCP Server

- **`mcp__cpln__query_audit_events`** — query audit events (see the [MCP (preferred for agents)](#mcp-preferred-for-agents) section for input shape and examples)
- **`mcp__cpln__create_audit_context`** — create a custom audit context (inputs: `name`, optional `org`, `description`, `tags`)
- **`mcp__cpln__cpln_resource_operation`** with `kind: "auditctx"` — other operations on audit contexts (`list`, `get`, `update`, `patch`, `delete`)

### Related Skills

- **cpln-cli** — CLI setup, command lookup, deploy/secret/GitOps/debug workflows
- **cpln-access-control** — Policies, permissions, identity bindings
- **cpln-external-logging** — Ship logs to external destinations for long-term retention

## Documentation

For the latest reference, see:

- [Audit Trail](https://docs.controlplane.com/core/audittrail.md)
- [Audit Context Reference](https://docs.controlplane.com/reference/auditctx.md)
- [Compliance](https://docs.controlplane.com/compliance.md)
