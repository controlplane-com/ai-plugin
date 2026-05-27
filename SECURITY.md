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

- The hosted MCP server authenticates the user via OAuth 2.1 + PKCE. Tokens are issued per-client, scoped to the orgs the user explicitly granted at consent time, and stored by the AI client.
- If you suspect an AI client's stored OAuth token is compromised, sign in and re-run consent — the new grant supersedes the old one. (For a hard revoke, the org owner can remove the user.)
- The `cpln` CLI workflows in this plugin (CI/CD, Terraform, Pulumi) use a service account token in `CPLN_TOKEN`. Never commit real values or service account keys, and use least-privilege service accounts.

## Operational Safety

This plugin can guide AI clients toward live Control Plane operations through the hosted MCP Server. Treat MCP access as production infrastructure access.

Write-capable or destructive workflows must confirm the target org/GVC and explain blast radius before applying changes, deleting resources, shrinking volumes, deleting snapshots, or replacing immutable workload types.
