---
name: setup-agent
description: Deploy a wormhole agent for secure connectivity between workloads and private network resources
argument-hint: "[k8s|docker|aws|azure|gcp] --name [agent-name]"
---

# Setup Agent

Deploy and configure a Control Plane wormhole agent to connect workloads to services in private networks (VPCs, on-prem, data centers).

## Usage

```
/cpln:setup-agent k8s --name my-agent
/cpln:setup-agent docker --name my-agent
/cpln:setup-agent aws --name my-agent
```

## What It Does

1. Evaluates if PrivateLink or Private Service Connect can be used instead (cloud-native routing via `mcp__cpln__add_identity_native_network_resource`)
2. Creates an agent resource and captures the one-time bootstrap config (`mcp__cpln__create_agent`)
3. Guides deployment to the target environment (K8s, Docker, AWS, Azure, GCP)
4. Configures identity network resources for workload routing — agent-based wormhole via `mcp__cpln__add_identity_network_resource` (`mcp__cpln__create_identity` first if the workload has no identity)
5. Verifies the agent tunnel is active and reachable (`mcp__cpln__get_agent_info`, `mcp__cpln__get_agent_eventlog`)

Steps run through the MCP tools above. CLI is the fallback when MCP is unavailable or in CI/CD; agent runtime deployment (`cpln agent up`, `cpln agent manifest`) is always CLI.

## When to Use

- Workload needs to reach a database, API, or service inside a private network
- Connecting across clouds (workload in one cloud, resource in another)
- Accessing on-prem services from Control Plane workloads
- Local development against private resources via Docker agent


## Framework-Specific Syntax

- **Claude Code**: `/cpln:setup-agent ARGS`
- **Gemini CLI**: `/setup-agent ARGS` (omit the `cpln:` prefix; on name conflict, use `/cpln.setup-agent`)
- **Codex**: commands not supported — invoke the matching agent skill or MCP tool directly

Invokes the **cpln-agent-setup** agent.
