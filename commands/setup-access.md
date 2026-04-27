---
name: setup-access
description: Set up access control for an org — groups, service accounts, and policies with correct permissions and targets
argument-hint: "[--team team-name | --cicd pipeline-name]"
version: 1.0.0
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
2. Creates or selects a group or service account
3. Determines target resources (all, specific, or tag-based)
4. Discovers valid permissions for the target resource kind
5. Creates the policy with correct bindings
6. Verifies the access configuration

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
