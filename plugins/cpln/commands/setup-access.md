---
name: setup-access
description: Set up access control for an org — groups, service accounts, and policies with correct permissions and targets
argument-hint: "[--team team-name | --cicd pipeline-name]"
---

# Setup Access Control

Guide through creating groups, service accounts, and policies to control who can access what in your org.

## Usage

```
/cpln:setup-access
/cpln:setup-access --team backend-developers
/cpln:setup-access --cicd github-actions
```

## What It Does

1. Identifies the access goal (team access, CI/CD, custom policy)
2. Creates or selects a group (`mcp__cpln__create_group` / `mcp__cpln__list_resources` (kind="group"), member links via `mcp__cpln__edit_group`) or service account (`mcp__cpln__create_service_account`, then `mcp__cpln__add_key_to_service_account`)
3. Determines target resources (all, specific, or tag-based)
4. Discovers valid permissions for the target resource kind (`mcp__cpln__get_permissions`)
5. Creates the policy with correct bindings (`mcp__cpln__create_policy`)
6. Verifies the access configuration (`mcp__cpln__get_resource` (kind="policy") / `mcp__cpln__get_resource` (kind="group"))

These operations run through the MCP tools above. The `cpln` CLI is the fallback when the MCP server is unavailable or for CI/CD pipelines authenticating with a service-account `CPLN_TOKEN`.

## When to Use

- Granting team members access to specific resources
- Setting up a service account for CI/CD pipelines
- Creating custom policies for fine-grained authorization
- Onboarding new team members with appropriate permissions


## Framework-Specific Syntax

- **Claude Code**: `/cpln:setup-access ARGS`
- **Gemini CLI**: `/setup-access ARGS` (omit the `cpln:` prefix; on name conflict, use `/cpln.setup-access`)
- **Codex**: commands not supported — invoke the matching agent skill or MCP tool directly

Invokes the **cpln-access-control-setup** agent.
