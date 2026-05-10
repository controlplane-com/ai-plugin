<p align="center">
  <a href="https://controlplane.com">
    <img src="assets/logo-white.svg" alt="Control Plane" width="240">
  </a>
</p>

# Control Plane AI Plugin

The AI plugin for [Control Plane](https://controlplane.com), the AI-native virtual cloud for vibe-coding enterprise infrastructure across AWS, GCP, Azure, OCI, and your own bare metal under one API built for agents and humans. It loads Control Plane domain knowledge, production guardrails, and live MCP access into Claude Code, Codex, Gemini CLI, and any MCP-capable client — so your assistant deploys workloads, grants credential-free cloud access via Universal Cloud Identity, and migrates off Kubernetes without hallucinating `cpln` commands or eyeballing manifests.

## Installation

### Claude Code

Add the marketplace, install the plugin, then reload plugins:

```text
/plugin marketplace add controlplane-com/ai-plugin
/plugin install cpln@controlplane
/reload-plugins
```

**Update to a newer release:** third-party Claude Code marketplaces have auto-update **disabled by default**, so you control when updates land. Either run the manual commands below when a new release is published, or enable auto-update once and forget it.

```text
/plugin marketplace update controlplane
/reload-plugins
```

To enable auto-update so future releases install at session start, run `/plugin`, open the **Marketplaces** tab, select **Control Plane**, and choose **Enable auto-update**. Claude Code will then refresh the marketplace and updated plugins on startup and prompt you to run `/reload-plugins`.

### Codex

Add the plugin marketplace to Codex:

```bash
codex plugin marketplace add controlplane-com/ai-plugin
```

Then start Codex and open `/plugins`. Use the left/right arrow keys to navigate between marketplaces until you reach Control Plane, then select and install the `cpln` plugin. The Codex plugin manifest points to `.codex-plugin/mcp.json`, which installs the hosted `cpln` MCP server with `CPLN_TOKEN` as its bearer-token environment variable.

If you prefer the standalone marketplace installer, install the plugin artifact directly from GitHub:

```bash
npx codex-marketplace add controlplane-com/ai-plugin --plugin
```

**Update to a newer release:** Codex does not auto-update plugin marketplaces. Run the upgrade command when a new release is published, then restart Codex so the new plugin manifest is picked up.

```bash
codex plugin marketplace upgrade controlplane
```

### Gemini CLI

Install the extension from GitHub:

```bash
gemini extensions install https://github.com/controlplane-com/ai-plugin.git
```

To enable per-extension auto-update at install time so future releases pull automatically, add the `--auto-update` flag:

```bash
gemini extensions install https://github.com/controlplane-com/ai-plugin.git --auto-update
```

**Update to a newer release:** if the extension was installed without `--auto-update`, pull the latest version manually. Use `--all` to update every installed Gemini extension in one shot.

```bash
gemini extensions update cpln
# or
gemini extensions update --all
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

If your client only needs MCP and does not consume one of this repo's plugin formats, add the `cpln` server manually using that client's MCP config format. For clients that support header interpolation:

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

| Variable       | Required                    | Sensitive | Used by                                 | Purpose                                              |
| -------------- | --------------------------- | --------- | --------------------------------------- | ---------------------------------------------------- |
| `CPLN_TOKEN`   | Required for MCP operations | Yes       | MCP server, Control Plane CLI workflows | Bearer token for live Control Plane API operations.  |
| `CPLN_ORG`     | Optional                    | No        | Control Plane CLI workflows             | Default Control Plane organization for CLI commands. |
| `CPLN_GVC`     | Optional                    | No        | Control Plane CLI workflows             | Default GVC for GVC-scoped CLI commands.             |
| `CPLN_PROFILE` | Optional                    | No        | Control Plane CLI workflows             | Selects a local `cpln` CLI profile.                  |

See `.env.example` for a local template. Do not commit real tokens.

## Usage

### Example Prompts

Real prompts that map to the agents and skills shipped in this plugin:

- "Troubleshoot why my `payments-api` workload in the `production` GVC keeps restarting — pull its events, deployments, and recent logs."
- "Wire up `app.example.com` to my `web` workload with auto-TLS and walk me through DNS verification."
- "My `worker` workload needs to read the `stripe-webhook-secret` opaque secret — set up the identity, the policy with `reveal`, and inject it as an env var."
- "Give my `analytics` workload credential-free read access to my AWS S3 bucket `prod-event-logs` — no IAM keys, no rotation."
- "Provision a production-grade Postgres with HA failover and S3 backups for the `production` GVC — use the template catalog, not a hand-rolled workload."
- "Convert this `kustomization.yaml` to Control Plane manifests, flag anything that won't translate cleanly, and apply it to the `staging` GVC after I confirm."
- "Create a least-privileged service account and policy for our GitHub Actions deploy pipeline — it should be able to apply workloads in `staging` but not touch `production`."
- "My workload needs to reach a Postgres instance inside our AWS VPC — set up a wormhole agent and configure the workload's identity to use it."

### Slash Commands

Claude Code uses the `/cpln:` prefix. Gemini CLI command names omit that prefix unless there is a name conflict.

| Claude Code command                        | Gemini CLI command                    | Capability                                         | Write-capable                                                 |
| ------------------------------------------ | ------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------- |
| `/cpln:troubleshoot WORKLOAD`              | `/troubleshoot WORKLOAD`              | Diagnose unhealthy workloads                       | May propose or apply fixes after confirmation.                |
| `/cpln:setup-secret WORKLOAD needs SECRET` | `/setup-secret WORKLOAD needs SECRET` | Configure identity, policy, and secret injection   | Yes.                                                          |
| `/cpln:setup-domain DOMAIN`                | `/setup-domain DOMAIN`                | Configure domain, DNS validation, TLS, and routes  | Yes.                                                          |
| `/cpln:setup-cloud-access PROVIDER`        | `/setup-cloud-access PROVIDER`        | Configure credential-free AWS/GCP/Azure/NGS access | Yes.                                                          |
| `/cpln:migrate-k8s FILE`                   | `/migrate-k8s FILE`                   | Convert Kubernetes, Compose, or Helm inputs        | Yes when applying converted resources.                        |
| `/cpln:setup-access`                       | `/setup-access`                       | Configure groups, service accounts, and policies   | Yes.                                                          |
| `/cpln:setup-stateful WORKLOAD`            | `/setup-stateful WORKLOAD`            | Create volumesets and stateful workloads           | Yes; can be destructive when converting an existing workload. |
| `/cpln:setup-agent`                        | `/setup-agent`                        | Deploy wormhole agents for private connectivity    | Yes.                                                          |

## Tools / Capabilities

This repository includes:

- 23 skills covering CLI usage, access control, autoscaling, networking, observability, migration, templates, stateful storage, and workload security.
- 8 guided agents for troubleshooting, secrets, domains, cloud identity, Kubernetes migration, access control, stateful workloads, and private-network agents.
- 8 slash commands that route common workflows to the matching agent.
- 8 guardrail/reference rule files for CLI conventions and manifest validation. The two `alwaysApply: true` rules are auto-injected into every Claude Code session by the plugin's `SessionStart` hook; the rest are loaded on demand by the agents and skills that cite them.
- Claude Code hooks that block common invalid `cpln` Bash patterns (generic `cpln secret create`, `cpln apply` without `--file`).
- MCP configuration for the hosted Control Plane MCP Server.

Client-specific MCP configuration files:

- Codex: `.codex-plugin/mcp.json` uses `url` and `bearer_token_env_var`.
- Claude Code: `.claude-mcp.json` uses `type: "http"` and `headers.Authorization`.
- Gemini CLI: `gemini-extension.json` uses `httpUrl` and `headers.Authorization`.

The hosted MCP server exposes live Control Plane tools for reading and mutating infrastructure. Treat MCP access as production access to the configured Control Plane organization.

## Security and Privacy

- `CPLN_TOKEN` is sent as a bearer token to `https://mcp.cpln.io/mcp` when MCP tools are used.
- MCP tools may read or modify Control Plane resources depending on the token's permissions.
- The plugin itself does not store logs, secrets, prompts, or telemetry.
- Your AI client and model provider may process prompts, command output, logs, manifests, and MCP responses according to their own retention policies.
- Workload logs, audit events, secret metadata, and infrastructure state are only fetched when a user or agent invokes the relevant workflow/tool.
- Secret values can be exposed if the token has `reveal` permission and a workflow requests secret access. Use least privilege.
- Destructive operations include deleting resources, shrinking or deleting volumes, deleting snapshots, replacing immutable workload types, and applying manifests that change production resources. Agents should present blast radius and request explicit confirmation before these operations.

Report vulnerabilities by following the process in [SECURITY.md](SECURITY.md).

## Troubleshooting

| Problem                                      | Check                                                                                                                                                                                                                                        |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| MCP requests fail with authentication errors | Confirm `CPLN_TOKEN` is set in the AI client environment and belongs to an active service account.                                                                                                                                           |
| MCP tools are unavailable in Codex           | Confirm the plugin was installed from `/plugins`, not only that the marketplace was added. Then restart Codex and use `/mcp` inside the session to inspect plugin-provided MCP servers.                                                      |
| MCP tools are unavailable in another client  | Confirm the client supports one of this repo's MCP configs (`.claude-mcp.json`, `.codex-plugin/mcp.json`, or the MCP block inside `gemini-extension.json`), or manually configured the `cpln` MCP server in that client's native MCP format. |
| Commands are not available                   | Confirm the client supports this repo's command format. Codex should use skills/MCP rather than Claude-style slash commands.                                                                                                                 |
| Gemini extension does not load               | Run `gemini extensions validate .` from the repository root.                                                                                                                                                                                 |
| AI proposes an uncertain `cpln` command      | Check `rules/cli-conventions.md` and verify flags with `cpln <command> --help` or the MCP suggest tool.                                                                                                                                      |
| A write operation targets the wrong org/GVC  | Stop and confirm `CPLN_ORG`, `CPLN_GVC`, `CPLN_PROFILE`, or explicit command flags before retrying.                                                                                                                                          |

## Contributing

Contributions are welcome. See `CONTRIBUTING.md` for development, safety, and release expectations.

## Support

- Product docs: [docs.controlplane.com](https://docs.controlplane.com)
- Control Plane support: `support@controlplane.com`
- Security issues: follow [SECURITY.md](SECURITY.md)

## License

MIT. See `LICENSE`.
