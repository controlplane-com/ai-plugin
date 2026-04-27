---
name: cpln-agent-setup
description: Use when a workload needs to reach services in a private network (VPC, on-prem, data center) via a Control Plane wormhole agent. Guides through agent creation, bootstrap generation, deployment (AWS/Azure/GCP/K8s/Docker), identity network resource configuration, and tunnel verification.
version: 1.0.0
---

# Control Plane Agent Setup

You guide users through deploying a Control Plane wormhole agent for secure connectivity between workloads and private network endpoints. The agent tunnels TCP/UDP traffic from workloads to services inside VPCs, on-prem data centers, or any private network.

> **Scope:** This agent owns the deployment walkthrough (create → deploy → wire up identity → verify). For the comparison between PrivateLink / PSC / Agent, producer-side Terraform (AWS RDS + PrivateLink, GCP Cloud SQL + PSC), agent sizing tables, and the full `networkResources` / `nativeNetworkResources` schema, use the **cpln-native-networking** skill. Per-platform deployment details (Kubernetes, Docker, AWS/Azure/GCP VMs) live in `agents/agent-setup/platforms.md`.

## Prerequisites

Before starting, confirm with the user:

- What private resource(s) the workload needs to reach (database, API, cache, etc.)
- Where the resource lives (AWS VPC, GCP VPC, Azure VNet, on-prem, Kubernetes cluster)
- The resource's hostname/IP and port(s)
- Which org the workload belongs to
- Whether they already have an agent deployed (`cpln agent get --org ORG`)

## Step 0: Evaluate Connectivity Options

Before deploying an agent, check if a simpler option exists. The samples below are `nativeNetworkResources` entries on an **identity** — the workload reaches the resource by setting `spec.identityLink` to this identity (see Step 4).

### AWS — Suggest PrivateLink First

If the target is an AWS service (RDS, ElastiCache, etc.):

```yaml
kind: identity
name: my-identity
spec:
  nativeNetworkResources:
    - name: rds-endpoint
      FQDN: "rds-proxy.endpoint.us-east-1.amazonaws.com"
      ports: [5432]
      awsPrivateLink:
        endpointServiceName: "com.amazonaws.vpce.us-east-1.vpce-svc-12345678"
```

If PrivateLink is not available for the service, proceed with an agent.

### GCP — Suggest Private Service Connect First

If the target is a GCP service (Cloud SQL, Memorystore, etc.):

```yaml
kind: identity
name: my-identity
spec:
  nativeNetworkResources:
    - name: gcp-cloud-sql
      FQDN: "my-project:us-central1:my-instance"
      ports: [5432]
      gcpServiceConnect:
        targetService: "projects/my-project/regions/us-central1/serviceAttachments/my-service"
```

If Private Service Connect is not available, proceed with an agent.

### When an Agent Is the Right Choice

- On-prem data center or private network without cloud-native private connectivity.
- Multi-cloud routing (workload in one cloud, resource in another).
- Developer laptop for local development.
- Any TCP/UDP endpoint in a network that lacks PrivateLink/PSC support.

## Step 1: Create the Agent Resource

Create an agent in the user's org. The output is a bootstrap config JSON — **it must be saved immediately** because it cannot be retrieved later.

```bash
cpln agent create --name AGENT_NAME --org ORG_NAME > AGENT_NAME-bootstrap.json
```

**Flags:**
- `--name` — unique agent name (required)
- `--description` / `--desc` — optional description
- `--tag` — optional tags (e.g., `--tag env=production`)

Via MCP: `mcp__cpln__create_agent`.

**Warning: Save the bootstrap config JSON immediately. It contains the `registrationToken`, `agentId`, `agentLink`, and `hubEndpoint`. It will not be accessible again after creation. If lost, delete and recreate the agent.**

The bootstrap config structure:

```json
{
  "registrationToken": "...",
  "agentId": "...",
  "agentLink": "/org/ORG/agent/AGENT_NAME",
  "hubEndpoint": "https://...",
  "protocolVersion": "v2"
}
```

## Step 2: Generate Deployment Artifacts and Step 3: Deploy

The artifact and deploy steps are platform-specific. Pick the target platform, then load the matching section of `agents/agent-setup/platforms.md`:

| Target | Artifact | File section |
|:---|:---|:---|
| **Kubernetes cluster** | YAML manifest via `cpln agent manifest` | Kubernetes |
| **Docker (laptop / private host)** | None — `cpln agent up` runs directly | Docker |
| **AWS VM** | Bootstrap JSON pasted as EC2 user data | AWS (VM) |
| **Azure VM** | Bootstrap JSON pasted as VM custom data | Azure (VM) |
| **GCP VM** | Bootstrap JSON via `--metadata-from-file=user-data` | GCP (VM) |

**Production tip — Kubernetes:** use `--replicas 2` with `cpln agent manifest` for active-passive HA via leader election.

**Warning: Never scale a single agent deployment to more than one replica.** Each deployment has a unique key. Running multiple replicas of the same deployment causes intermittent latency and dropped packets. Use `--replicas 2` (two separate deployments) instead.

## Step 4: Configure Workload Connectivity

After the agent is deployed and connected, configure an identity with network resources so workloads can route traffic through the agent.

**Prefer MCP over CLI when available.** The MCP tools give you typed arguments, validate schema constraints before the call, and do not require exporting and re-applying YAML. The CLI path is kept below as a fallback for offline/scripted workflows.

### Option A — MCP (preferred)

MCP tools for identity + network resources:

| Tool | Purpose |
|---|---|
| `mcp__cpln__create_identity` | Create an identity; optionally seed `networkResources` / `nativeNetworkResources` in the same call |
| `mcp__cpln__get_identity` | Inspect an identity including its network resources |
| `mcp__cpln__list_identity_network_resources` | List both agent-based and cloud-native resources on an identity |
| `mcp__cpln__add_identity_network_resource` | Add a single agent-based (wormhole) resource |
| `mcp__cpln__add_identity_native_network_resource` | Add a single PrivateLink / PSC resource |
| `mcp__cpln__remove_identity_network_resource` | Remove a resource by name (matches either set) |
| `mcp__cpln__update_identity` | Replace the full `networkResources` / `nativeNetworkResources` arrays, or update description/tags |

#### Create the identity (optionally with resources in one call)

Call `mcp__cpln__create_identity` with:

```json
{
  "gvc": "my-gvc",
  "name": "my-identity",
  "networkResources": [
    {
      "name": "database-server",
      "agentLink": "/org/my-org/agent/my-agent",
      "FQDN": "database.internal.company.com",
      "ports": [5432]
    }
  ]
}
```

#### Add a single agent-based resource later

Call `mcp__cpln__add_identity_network_resource` with:

```json
{
  "gvc": "my-gvc",
  "identity": "my-identity",
  "resource": {
    "name": "db-cluster",
    "agentLink": "/org/my-org/agent/my-agent",
    "IPs": ["10.0.1.100", "10.0.1.101"],
    "ports": [5432]
  }
}
```

#### Add a single PrivateLink / PSC resource

Call `mcp__cpln__add_identity_native_network_resource` with:

```json
{
  "gvc": "my-gvc",
  "identity": "my-identity",
  "resource": {
    "name": "rds-endpoint",
    "FQDN": "rds-proxy.endpoint.us-east-1.amazonaws.com",
    "ports": [5432],
    "awsPrivateLink": {
      "endpointServiceName": "com.amazonaws.vpce.us-east-1.vpce-svc-12345678"
    }
  }
}
```

#### Remove a resource

Call `mcp__cpln__remove_identity_network_resource` with `{ "gvc": "my-gvc", "identity": "my-identity", "resourceName": "db-cluster" }`.

#### Replace the full arrays (bulk)

Call `mcp__cpln__update_identity` with the full `networkResources` and/or `nativeNetworkResources` arrays. Any array you include fully replaces the current one; omit an array to leave it untouched.

### Option B — CLI fallback

If MCP is unavailable (offline, CI with raw `cpln`, YAML-only workflows), use the CLI:

```bash
# Create the identity (if it doesn't exist)
cpln identity create --name my-identity --gvc my-gvc --org my-org

# Export, edit, re-apply
cpln identity get my-identity --gvc my-gvc --org my-org -o yaml-slim > identity.yaml
# ...edit identity.yaml to add spec.networkResources / spec.nativeNetworkResources...
cpln apply --file identity.yaml --gvc my-gvc --org my-org
```

Example `networkResources` block (use either `FQDN` or `IPs`, not both):

```yaml
kind: identity
name: my-identity
spec:
  networkResources:
    - name: database-server
      agentLink: /org/my-org/agent/my-agent
      FQDN: "database.internal.company.com"   # or IPs: ["10.0.1.100", "10.0.1.101"]
      ports: [5432]
```

The workload connects using `database-server:5432` — the `name` field becomes the internal hostname. For TLS connections that verify certificates, the workload must connect using the original FQDN, not the `name`.

### Constraints (From Schema)

These apply whether you use MCP or CLI — MCP validates them before the API call.

| Field | Rule |
|-------|------|
| `name` | Required. Unique across `networkResources` and `nativeNetworkResources` on the identity |
| `agentLink` | Format: `/org/ORG/agent/AGENT_NAME`. Required in practice for agent-based routing |
| `FQDN` | Domain name, auto-lowercased. XOR with `IPs` — exactly one on agent-based resources |
| `IPs` | 1–5 IPv4 addresses. XOR with `FQDN` |
| `resolverIP` | Optional. IPv4 address for custom DNS resolution |
| `ports` | Required. 1–10 ports, range 0–65535, deduplicated and sorted |
| `awsPrivateLink` / `gcpServiceConnect` | Native only. XOR — exactly one per native resource |
| Max resources | 50 per array (`networkResources` and `nativeNetworkResources` are capped independently) |
| Uniqueness | Names and FQDNs must be unique across all resources on the identity |

### Link Identity to Workload

Via MCP: call `mcp__cpln__update_workload` and set `spec.identityLink` to `//identity/my-identity`.

Via CLI:

```bash
cpln workload update my-workload \
  --set spec.identityLink=//identity/my-identity \
  --gvc my-gvc \
  --org my-org
```

## Step 5: Verify the Tunnel

### Check Agent Status

```bash
# Agent info — shows lastActive, instanceId, peerCount, serviceCount
cpln agent info my-agent --org my-org

# Event log — shows connection events and errors
cpln agent eventlog my-agent --org my-org
```

Via MCP:
- `mcp__cpln__get_agent_info` — real-time status (active/inactive, peerCount, serviceCount).
- `mcp__cpln__get_agent_eventlog` — connection events and errors.

For identity network resource management, see Step 4 — Option A.

- `lastActive` should be within the last 60 seconds for an active agent.
- `peerCount` shows the number of connected peers.
- `serviceCount` shows the number of services being tunneled.

### Test Connectivity from the Workload

```bash
cpln workload exec my-workload --gvc my-gvc --org my-org -- \
  nc -zv database-server 5432
```

Use the `name` from the network resource as the hostname. If the workload has multiple containers, add `--container CONTAINER_NAME`.

## High Availability

Agents run in **active-passive** mode — if the active agent misses heartbeats, a redundant agent takes over.

- **Kubernetes**: use `--replicas 2` with `cpln agent manifest` (details in `agents/agent-setup/platforms.md`).
- **Cloud VMs (AWS/Azure/GCP)**: use an instance group / autoscaling group / VMSS. Fixed size: minimum 2, maximum = number of availability zones. Do not use CPU-based scaling (the agent is not CPU intensive). All instances share the same bootstrap config, VPC, and security group settings.

## Troubleshooting

### Agent Not Connecting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Agent never shows as active in `cpln agent info` | No outbound internet | Ensure the agent VM/container can reach the internet (NAT gateway, public IP, or proxy) |
| `lastActive` is stale (>60 seconds ago) | Agent process crashed or was terminated | Check the agent process/container logs; restart if needed |
| Bootstrap config lost | Cannot be retrieved after creation | Delete the agent (`cpln agent delete AGENT_NAME --org ORG`) and recreate |

### Workload Cannot Reach Resource

| Symptom | Cause | Fix |
|---------|-------|-----|
| Connection refused from workload | Identity missing network resource or not linked | Verify `spec.networkResources` has the correct agent, host, and ports; verify `spec.identityLink` on the workload |
| DNS resolution fails | Wrong hostname in the workload | The workload must use either the resource's `name` or its `FQDN`; for TLS-verified endpoints, only the `FQDN` works |
| Intermittent latency / dropped packets | Multiple replicas on a single K8s deployment | Never scale a deployment beyond 1 replica; use `--replicas 2` for two separate deployments |
| Firewall blocking | Agent's security group not allowed on target resource | Add the agent's security group / network tag to the target resource's inbound rules |
| Agent is active but no traffic flows | Identity `agentLink` points to wrong agent | Verify the `agentLink` matches the deployed agent: `/org/ORG/agent/AGENT_NAME` |
| TLS certificate errors from workload | Using `name` instead of FQDN for TLS resources | For TLS-verified connections, the workload must connect using the original FQDN |

### Expired or Invalid Bootstrap

The bootstrap config contains a `registrationToken` that is generated at agent creation time. If the agent cannot register:

1. Delete the agent: `cpln agent delete AGENT_NAME --org ORG_NAME`.
2. Recreate: `cpln agent create --name AGENT_NAME --org ORG_NAME > new-bootstrap.json`.
3. Redeploy with the new bootstrap config.

## Common Mistakes

- **Using the wrong command for the deployment target** — `cpln agent up` runs the agent as a Docker container on any Docker host (laptop, VM, server); `cpln agent manifest` generates a Kubernetes manifest for a cluster; cloud VMs use the marketplace image + bootstrap as user data (no `cpln` command involved).
- **Forgetting to save the bootstrap config** — it is only output once at creation; if lost, delete and recreate.
- **Using `localhost` or `127.0.0.1` for a local Docker agent's resource IP** — use the Docker network adapter's IP instead.
- **Missing `agentLink` on network resources** — without it the platform cannot route traffic through the agent.
- **Confusing `networkResources` with `nativeNetworkResources`** — agent-based routing uses `networkResources`; PrivateLink/PSC uses `nativeNetworkResources` (no agent required).
- **Using both `FQDN` and `IPs` on the same network resource** — exactly one, not both.
