---
name: setup-domain
description: Configure a custom domain for Control Plane workloads with DNS validation, TLS certificates, and routing
argument-hint: "[domain] [--gvc gvc-name] [--mode cname|ns]"
version: 1.0.0
---

# Setup Domain

Configure a custom domain with DNS mode selection, verification, routing, and TLS certificate provisioning.

## Usage

```
/cpln:setup-domain example.com
/cpln:setup-domain example.com --gvc my-gvc
/cpln:setup-domain api.example.com --mode cname
```

## What It Does

1. Determines CNAME vs NS mode based on your routing needs (apex domains must use CNAME)
2. Guides domain ownership verification via TXT record
3. Creates the domain in Control Plane with the correct manifest
4. Generates the required DNS records (CNAME or NS) for your provider
5. Validates TLS certificate provisioning
6. Troubleshoots DNS, certificate, and routing issues if they arise

## When to Use

- Setting up a custom domain for the first time
- Troubleshooting certificate or DNS issues
- Choosing between path-based (CNAME) and subdomain-based (NS) routing


## Framework-Specific Syntax

- **Claude Code**: `/cpln:setup-domain ARGS`
- **Gemini CLI**: `/setup-domain ARGS` (omit the `cpln:` prefix; on name conflict, use `/cpln.setup-domain`)
- **Codex**: commands not supported — invoke the matching agent skill or MCP tool directly

Invokes the **cpln-domain-configurator** agent.
