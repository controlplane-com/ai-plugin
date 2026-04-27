# Security Policy

## Supported Versions

Security fixes are handled for the latest public release and the current `main` branch after the repository is public.

## Reporting a Vulnerability

Email `support@controlplane.com` with the subject `Security: ai-plugin`.

Include:

- Affected file, workflow, or client integration.
- Steps to reproduce.
- Impact, including whether credentials, secrets, infrastructure state, or destructive operations are involved.
- Any suggested remediation.

Do not open a public issue for vulnerabilities that expose secrets, tokens, customer data, or a path to unauthorized infrastructure changes.

## Secrets and Credentials

- Never commit real `CPLN_TOKEN` values or service account keys.
- Use least-privilege service accounts for MCP access.
- Rotate any token that may have been exposed to an AI client, shell history, logs, screenshots, or repository history.

## Operational Safety

This plugin can guide AI clients toward live Control Plane operations through the hosted MCP Server. Treat MCP access as production infrastructure access.

Write-capable or destructive workflows must confirm the target org/GVC and explain blast radius before applying changes, deleting resources, shrinking volumes, deleting snapshots, or replacing immutable workload types.
