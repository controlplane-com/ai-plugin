# Control Plane AI Plugin

AI assistant knowledge, workflows, guardrails, and MCP configuration for deploying and managing workloads on [Control Plane](https://controlplane.com).

## Overview

This repository packages Control Plane domain knowledge for AI coding and operations assistants. It helps users write safer `cpln` CLI commands, understand Control Plane manifests, troubleshoot unhealthy workloads, configure secrets and access control, migrate from Kubernetes, and connect clients to the Control Plane MCP Server.

The plugin is intended for platform engineers, application developers, DevOps teams, and AI agents that operate Control Plane resources across AWS, GCP, Azure, and private clouds.

## Supported Clients

| Client / platform | Current repo support | Notes |
| --- | --- | --- |
| Claude Code | Plugin metadata, `CLAUDE.md`, skills, agents, commands, rules, hooks, MCP config | Public marketplace/listing status: not claimed. |
| Codex / OpenAI | Codex plugin metadata, skills directory, MCP config, app metadata | Codex CLI currently exposes plugin marketplaces through `codex plugin marketplace`. Slash commands and Claude-style agents are not assumed to be supported. |
| Gemini CLI | `gemini-extension.json`, `GEMINI.md`, commands, MCP config | Local validation uses `gemini extensions validate .`. |
| Generic MCP clients | `.mcp.json` remote MCP server config | Configure the `cpln` server manually if the client does not consume this repo format. |
| ChatGPT / OpenAI Apps SDK | App metadata only | No standalone Apps SDK server is included in this repository. |
| Other skill-only clients | Markdown skills in `skills/` | Support depends on the client’s skill import format. |

## Installation

### Claude Code

Add the marketplace, install the plugin, then reload plugins:

```text
/plugin marketplace add controlplane-com/ai-plugin
/plugin install cpln@controlplane
/reload-plugins
```

### Codex

Add the plugin marketplace to Codex:

```bash
codex plugin marketplace add controlplane-com/ai-plugin
```

If you prefer the standalone marketplace installer, install the plugin artifact directly from GitHub:

```bash
npx codex-marketplace add controlplane-com/ai-plugin --plugin
```

Codex plugin metadata is in `.codex-plugin/plugin.json`, and the Codex marketplace entry is in `.agents/plugins/marketplace.json`.

### Gemini CLI

Install the extension from GitHub:

```bash
gemini extensions install https://github.com/controlplane-com/ai-plugin.git
```

For local development, link the checkout:

```bash
git clone https://github.com/controlplane-com/ai-plugin.git
cd ai-plugin
gemini extensions link .
```

### Fresh Clone

Use a manual clone when you want to inspect or modify the plugin locally before installing it into a client:

```bash
git clone https://github.com/controlplane-com/ai-plugin.git
cd ai-plugin
```

### Generic MCP Client

If your client only needs MCP, add the `cpln` server manually:

```json
{
  "mcpServers": {
    "cpln": {
      "type": "http",
      "url": "https://mcp.cpln.io/mcp",
      "headers": {
        "Authorization": "Bearer ${CPLN_TOKEN}"
      }
    }
  }
}
```

## Configuration

Create a Control Plane service account token and expose it to the client environment as `CPLN_TOKEN`. Use least-privilege policies for the service account whenever possible.

```bash
export CPLN_TOKEN="<your-service-account-token>"
```

Gemini CLI prompts for `CPLN_TOKEN` because `gemini-extension.json` marks it as a sensitive setting.

## Environment Variables

| Variable | Required | Sensitive | Used by | Purpose |
| --- | --- | --- | --- | --- |
| `CPLN_TOKEN` | Required for MCP operations | Yes | MCP server, Control Plane CLI workflows | Bearer token for live Control Plane API operations. |
| `CPLN_ORG` | Optional | No | Control Plane CLI workflows | Default Control Plane organization for CLI commands. |
| `CPLN_GVC` | Optional | No | Control Plane CLI workflows | Default GVC for GVC-scoped CLI commands. |
| `CPLN_PROFILE` | Optional | No | Control Plane CLI workflows | Selects a local `cpln` CLI profile. |

See `.env.example` for a local template. Do not commit real tokens.

## Usage

### Example Prompts

- “Troubleshoot why my `api` workload is not starting in the `production` GVC.”
- “Set up secret access for `my-api` to read `db-password`.”
- “Review this workload manifest for Control Plane validation issues before I apply it.”
- “Migrate this Kubernetes deployment to Control Plane.”
- “Create least-privilege access for a GitHub Actions deployment service account.”

### Slash Commands

Claude Code uses the `/cpln:` prefix. Gemini CLI command names omit that prefix unless there is a name conflict.

| Claude Code command | Gemini CLI command | Capability | Write-capable |
| --- | --- | --- | --- |
| `/cpln:troubleshoot WORKLOAD` | `/troubleshoot WORKLOAD` | Diagnose unhealthy workloads | May propose or apply fixes after confirmation. |
| `/cpln:setup-secret WORKLOAD needs SECRET` | `/setup-secret WORKLOAD needs SECRET` | Configure identity, policy, and secret injection | Yes. |
| `/cpln:setup-domain DOMAIN` | `/setup-domain DOMAIN` | Configure domain, DNS validation, TLS, and routes | Yes. |
| `/cpln:setup-cloud-access PROVIDER` | `/setup-cloud-access PROVIDER` | Configure credential-free AWS/GCP/Azure/NGS access | Yes. |
| `/cpln:migrate-k8s FILE` | `/migrate-k8s FILE` | Convert Kubernetes, Compose, or Helm inputs | Yes when applying converted resources. |
| `/cpln:setup-access` | `/setup-access` | Configure groups, service accounts, and policies | Yes. |
| `/cpln:setup-stateful WORKLOAD` | `/setup-stateful WORKLOAD` | Create volumesets and stateful workloads | Yes; can be destructive when converting an existing workload. |
| `/cpln:setup-agent` | `/setup-agent` | Deploy wormhole agents for private connectivity | Yes. |

## Tools / Capabilities

This repository includes:

- 23 skills covering CLI usage, access control, autoscaling, networking, observability, migration, templates, stateful storage, and workload security.
- 8 guided agents for troubleshooting, secrets, domains, cloud identity, Kubernetes migration, access control, stateful workloads, and private-network agents.
- 8 slash commands that route common workflows to the matching agent.
- 8 guardrail/reference rule files for CLI conventions and manifest validation.
- Claude Code hooks that block common invalid `cpln` command patterns.
- MCP configuration for the hosted Control Plane MCP Server.

The hosted MCP server exposes live Control Plane tools for reading and mutating infrastructure. Treat MCP access as production access to the configured Control Plane organization.

## Security and Privacy

- `CPLN_TOKEN` is sent as a bearer token to `https://mcp.cpln.io/mcp` when MCP tools are used.
- MCP tools may read or modify Control Plane resources depending on the token’s permissions.
- The plugin itself does not store logs, secrets, prompts, or telemetry.
- Your AI client and model provider may process prompts, command output, logs, manifests, and MCP responses according to their own retention policies.
- Workload logs, audit events, secret metadata, and infrastructure state are only fetched when a user or agent invokes the relevant workflow/tool.
- Secret values can be exposed if the token has `reveal` permission and a workflow requests secret access. Use least privilege.
- Destructive operations include deleting resources, shrinking or deleting volumes, deleting snapshots, replacing immutable workload types, and applying manifests that change production resources. Agents should present blast radius and request explicit confirmation before these operations.

Report vulnerabilities using `SECURITY.md`.

## Troubleshooting

| Problem | Check |
| --- | --- |
| MCP requests fail with authentication errors | Confirm `CPLN_TOKEN` is set in the AI client environment and belongs to an active service account. |
| MCP tools are unavailable | Confirm the client loaded `.mcp.json` or manually configured the `cpln` MCP server. |
| Commands are not available | Confirm the client supports this repo’s command format. Codex should use skills/MCP rather than Claude-style slash commands. |
| Gemini extension does not load | Run `gemini extensions validate .` from the repository root. |
| AI proposes an uncertain `cpln` command | Check `rules/cli-conventions.md` and verify flags with `cpln <command> --help` or the MCP suggest tool. |
| A write operation targets the wrong org/GVC | Stop and confirm `CPLN_ORG`, `CPLN_GVC`, `CPLN_PROFILE`, or explicit command flags before retrying. |

## Contributing

Contributions are welcome after the public repository is available. See `CONTRIBUTING.md` for development, safety, and release expectations.

## Support

- Product docs: [docs.controlplane.com](https://docs.controlplane.com)
- Control Plane support: `support@controlplane.com`
- Security issues: follow `SECURITY.md`

## License

MIT. See `LICENSE`.
