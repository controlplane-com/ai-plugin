# Permissions Matrix & Built-In Resources

Companion to `skills/access-control/SKILL.md`. Read this when authoring a policy and you need to know which permissions exist for a given resource kind, or which built-in groups/policies you can rely on.

## Permissions by Resource Type

Discover all permissions at runtime: `mcp__cpln__get_permissions` (MCP) or `cpln RESOURCE permissions` (CLI).

| Resource | Permissions | Key Implications |
|:---|:---|:---|
| **workload** | `configureLoadBalancer`, `connect`, `create`, `delete`, `edit`, `exec`, `exec.runCronWorkload`, `exec.stopReplica`, `manage`, `view` | `exec` → `exec.runCronWorkload` + `exec.stopReplica`; `connect` = interactive shell |
| **secret** | `create`, `delete`, `edit`, `manage`, `reveal`, `use`, `view` | `edit` → `view` + `reveal`; `reveal` = read values; `use` = reference from workloads |
| **identity** | `create`, `delete`, `edit`, `manage`, `use`, `view` | `use` = link identity to workloads |
| **image** | `create`, `delete`, `edit`, `manage`, `pull`, `view` | `create` → `pull`; `pull` → `view` |
| **org** | `edit`, `exec`, `exec.echo`, `grafanaAdmin`, `manage`, `readLogs`, `readMetrics`, `readUsage`, `view`, `viewAccessReport` | `exec` → `exec.echo`; `readLogs` = logs from all workloads |
| **user** | `delete`, `edit`, `impersonate`, `invite`, `manage`, `view` | `impersonate` and `invite` are unique to user |

Most other resources (gvc, policy, group, domain, location, etc.) follow the standard pattern: `create`, `delete`, `edit`, `manage`, `view` — some add `use`. Run `cpln RESOURCE permissions` to see the exact list for any resource.

**`manage` always implies all other permissions for that resource type.** The `→` notation means "implies".

## Built-In Resources

Every org starts with:

| Resource | Name | Purpose |
|:---|:---|:---|
| Group | `superusers` | All administrators — has `manage` on everything |
| Group | `viewers` | Read-only access to all resources |
| Service account | `controlplane` | Used by the platform internally — cannot be modified |
| Policies | `superusers-RESOURCE` | One per resource kind granting `manage` to `superusers` group |
| Policies | `viewers-RESOURCE` | One per resource kind granting `view` to `viewers` group |

Built-in policies have origin `builtin` and **cannot be modified or deleted** — create your own with origin `default`.
