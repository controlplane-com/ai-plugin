<p align="center">
  <a href="https://controlplane.com">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://cdn.jsdelivr.net/gh/controlplane-com/brand@main/logo/Control_Plane_logo_full_light.svg">
      <img src="https://cdn.jsdelivr.net/gh/controlplane-com/brand@main/logo/Control_Plane_logo_full_dark.svg" alt="Control Plane" width="240">
    </picture>
  </a>
</p>

# Control Plane AI Plugin

Run containerized workloads across AWS, GCP, Azure, OCI, and your own hardware under one API. It loads Control Plane's domain knowledge, production guardrails, and live MCP tools into Claude Code, Codex, and Antigravity CLI so your assistant can deploy, troubleshoot, secure, and migrate workloads with verified `cpln` commands.

## Installation

### Claude Code

```text
/plugin marketplace add https://github.com/controlplane-com/ai-plugin.git
/plugin install cpln@controlplane
/reload-plugins
```

Update with `/plugin marketplace update controlplane` then `/reload-plugins` (third-party marketplaces don't auto-update unless you enable it in `/plugin` → **Marketplaces**).

### Codex

```bash
codex plugin marketplace add https://github.com/controlplane-com/ai-plugin.git
```

Start Codex, open `/plugins`, and install `cpln`. Guardrail injection needs plugin hooks, which Codex gates off by default — enable them in `~/.codex/config.toml` and restart:

```toml
[features]
plugins = true
plugin_hooks = true
```

Update with `codex plugin marketplace upgrade controlplane`, then restart Codex.

### Antigravity CLI

Install the plugin with Antigravity CLI (`agy`):

```bash
agy plugin install https://github.com/controlplane-com/ai-plugin/plugins/cpln
```

### Generic MCP client

Point any other MCP client at the hosted server:

```json
{
  "mcpServers": {
    "cpln": {
      "type": "http",
      "url": "https://mcp.cpln.io/mcp?toolsets=full"
    }
  }
}
```

## Authentication

MCP uses OAuth 2.1 + PKCE. Sign in to let the assistant act on your Control Plane organizations — you choose which orgs it may operate on, and the token is scoped to those orgs and enforced server-side on every call. Sign in again to change the grant. Treat MCP access as production access to the orgs you grant. How to sign in:

- **Claude Code** — `/mcp`, select `cpln`, sign in (or `claude mcp login cpln`).
- **Codex** — `codex mcp login cpln`.
- **Antigravity CLI** — `/mcp`, select `cpln`, authenticate.

## Environment variables

Optional — only for the `cpln` CLI workflows some skills generate (CI/CD, Terraform, Pulumi). See `.env.example`.

| Variable       | Purpose                                                 |
| -------------- | ------------------------------------------------------- |
| `CPLN_TOKEN`   | Service-account token for `cpln` CLI calls (sensitive). |
| `CPLN_ORG`     | Default organization.                                   |
| `CPLN_GVC`     | Default GVC.                                            |
| `CPLN_PROFILE` | Local `cpln` CLI profile.                               |

## Usage

Ask in natural language — the assistant routes to the right skill or agent:

- "Troubleshoot why my `payments-api` workload in `production` keeps restarting."
- "Put `app.example.com` in front of my `web` workload with auto-TLS."
- "Give my `analytics` workload credential-free read access to S3 bucket `prod-event-logs` — no IAM keys."
- "Provision a production Postgres with HA failover and S3 backups."
- "Convert this `kustomization.yaml` to Control Plane and apply it to `staging` after I confirm."

Two workflows also have slash commands in Claude Code — `/cpln:troubleshoot WORKLOAD` and `/cpln:migrate-k8s FILE`; in other clients, ask for the same workflows by name.

## What's included

- Domain skills across CLI usage, access control, autoscaling, networking, observability, migration, templates, stateful storage, and security.
- Two guided agents: workload troubleshooting and Kubernetes / Compose / Helm migration.
- An always-on guardrail rule the assistant applies in every session.
- Pre-configured access to the hosted Control Plane MCP server.

## Security

- MCP access is production access — scoped to the orgs you grant and your own RBAC.
- Destructive actions (deleting resources, shrinking/deleting volumes, replacing workloads, applying to production) require explicit confirmation.
- Secret values are exposed only with `reveal` permission — use least privilege.
- The plugin stores no logs, secrets, prompts, or telemetry; your AI client and model provider process prompts per their own policies.

Report vulnerabilities per [SECURITY.md](SECURITY.md).

## More

- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)
- Docs: [docs.controlplane.com](https://docs.controlplane.com) · Support: `support@controlplane.com` or Slack
- License: MIT — see [LICENSE](LICENSE)
