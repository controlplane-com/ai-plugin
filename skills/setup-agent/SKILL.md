---
name: setup-agent
description: Deploys a Control Plane wormhole agent connecting workloads to private-network resources. Use when the user asks to reach a VPC, on-prem, data-center, or cross-cloud host, set up a tunnel, or run an agent.
---

# Agent Setup

> **Tool availability:** the agent lifecycle tools — `create_agent` / `update_agent`, `get_agent_info` / `get_agent_eventlog`, and `add_identity_network_resource` / `add_identity_native_network_resource` / `remove_identity_network_resource` / `list_identity_network_resources` — live in the **`full`** toolset profile. `create_identity` / `update_identity` / `update_workload` and all reads/deletes (`list_resources`, `get_resource`, `delete_resource`) are `core`. If a `full` tool is not advertised, reconnect the MCP server with `?toolsets=full`, or use the `cpln agent` CLI.

A wormhole agent is a lightweight VM or container you run **inside the target network**. It opens a persistent **outbound** connection to Control Plane and tunnels workload traffic to any TCP/UDP endpoint on the private side — VPC, on-prem, data center, Azure VNet, cross-cloud, or a laptop. A workload reaches the endpoint by attaching an **identity** (gvc-scoped) that carries a `networkResources` entry pointing at the agent. No external egress firewall rule is needed.

> **Scope:** this is the deploy walkthrough — create the agent, deploy it on your platform, wire up the identity, verify. For the PrivateLink/PSC-vs-agent comparison, agent **sizing tables**, the full identity schema, and agent permissions, read **native-networking**. For the cloud-credential side (AWS/GCP/Azure access without an agent), read **setup-cloud-access**.

## Before you start

Confirm with the user: what private resource the workload must reach (host/IP + ports), where it lives (cloud/VPC/on-prem/cluster), the org, and whether an agent already exists (`list_resources` kind="agent"). **Reach for an agent only when PrivateLink/PSC does not fit** — for an AWS or GCP managed service, native networking is lower-latency and needs no agent (see native-networking). An agent is right for on-prem, cross-cloud, Azure, or local development.

## Step 1 — Create the agent

If the user asked you to set one up, create it directly; only list first when they want to reuse an existing one. Call `create_agent` (`org`, `name`, optional `description` / `tags`). The response contains the **bootstrap config JSON** — copy it out immediately.

CLI fallback (pipes the bootstrap straight to a file):

```bash
cpln agent create --name AGENT --org ORG > AGENT-bootstrap.json
```

> **Save the bootstrap config now.** It holds the registration token and is shown **only once, at creation**. Reads (`get_resource` kind="agent") return it with the token hidden. It is immutable — if lost, delete and recreate the agent. `update_agent` changes description / tags only.

## Step 2 — Deploy the agent

Pick the target; each artifact path is CLI/console (no MCP equivalent). Deploy in the **same VPC/region** as the target, with **outbound internet** and **no inbound ports** required.

| Target | How |
|---|---|
| **Kubernetes** | `cpln agent manifest --bootstrap-file AGENT-bootstrap.json -n NAMESPACE --replicas 2 > agent.yaml` then `kubectl apply -f agent.yaml`. Each agent stores a generated keypair as a K8s secret, so its service account needs secret create/modify in that namespace — use a dedicated namespace if that is a concern. |
| **Docker** (laptop / private host) | `cpln agent up --bootstrap-file AGENT-bootstrap.json` (one command, no manifest). `-b` runs it in the background; `--net` picks the Docker network. On Windows, disable the WSL 2 engine and run from a Windows prompt. |
| **AWS VM** | Subscribe to the **Control Plane Secure Communications Agent** in AWS Marketplace, launch via EC2 in the target VPC, enable a public IP or NAT for egress, and paste the bootstrap JSON into **User data**. Add the agent's security group to the target resource's inbound rules. |
| **Azure VM** | Azure Marketplace **Control Plane Secure Communications Agent** (gen-1); Public IP **None**, inbound **None**; paste the bootstrap JSON into **Custom data**. |
| **GCP VM** | `gcloud compute instances create … --metadata-from-file=user-data=AGENT-bootstrap.json` with the Control Plane agent image; open egress only (no SSH/RDP/ICMP needed). |

> **Never run two replicas of one deployment.** Each deployment has a unique key; duplicating it causes intermittent latency and dropped packets. For HA, run **separate** deployments (K8s `--replicas 2`; cloud VMs in a fixed-size instance group / ASG / VMSS). Agents run **active-active** — every instance serves traffic, and a missed-heartbeat instance is dropped while the group replaces it. The agent is **not CPU-intensive — do not autoscale on CPU**; size the group min 2, max = number of availability zones.

The agent also exposes a proxy on port **3128** (`cpln agent up --exposeProxy`) so systems inside the private network can call Control Plane workloads without external firewall changes — grant it on the workload's **Internal** firewall (see firewall-networking).

## Step 3 — Wire the identity to the agent

A workload routes through the agent only when an identity carrying a `networkResources` entry is attached to it. Create the identity first if it does not exist (`create_identity`, see access-control).

Add the agent-based resource with `add_identity_network_resource` (`org`, `gvc`, `identity`, one `resource`):

```json
{
  "org": "ORG", "gvc": "GVC", "identity": "IDENTITY",
  "resource": {
    "name": "on-prem-db",
    "agentLink": "//agent/AGENT",
    "IPs": ["10.0.1.50"],
    "ports": [5432]
  }
}
```

Key constraints (Joi-enforced; mirrored by the tool): `name` unique across **both** `networkResources` and `nativeNetworkResources` and never equal to a FQDN; `IPs` (1-5 IPv4) **xor** `FQDN` (exactly one); `ports` 1-10, each 0-65535; optional `resolverIP` for private DNS; max 50 per array. `update_identity` replaces the whole array; `remove_identity_network_resource` deletes by name from either array (destructive — confirm first).

> For a local Docker agent, set the resource `IPs` to the host's **Docker network-adapter IP**, never `localhost` / `127.0.0.1`.

**Attach the identity to the workload:** `update_workload` setting `spec.identityLink` to `//identity/IDENTITY`. Without the attachment, nothing routes.

## Step 4 — Verify

- `get_agent_info` — `lastActive` within 60s means active; check `peerCount` and `serviceCount`. `get_agent_eventlog` shows connection events and errors. (CLI: `cpln agent info|eventlog AGENT --org ORG`.)
- `list_identity_network_resources` confirms the entry is on the identity.
- From the workload, dial the resource **`name`** (e.g. `nc -zv on-prem-db 5432` via `workload_exec`). For a **TLS** target, connect on the **FQDN**, not the `name` — the certificate is issued for the FQDN.

## Common mistakes

- **Wrong deploy command** — `cpln agent up` is Docker hosts; `cpln agent manifest` is K8s; cloud VMs use the marketplace image + bootstrap as user-data (no `cpln` command).
- **Losing the bootstrap config** — output once at creation; if lost, delete and recreate.
- **Scaling one deployment past 1 replica** — drops packets; use separate deployments.
- **Missing `agentLink`, or `localhost` for a local agent's IP** — traffic cannot route.
- **Forgetting `spec.identityLink`** — the identity is wired but never reaches the workload.
- **Using `name` instead of `FQDN` for a TLS endpoint** — certificate validation fails.

## Related skills

| Need | Skill |
|---|---|
| PrivateLink/PSC vs agent, sizing, full identity schema, permissions | `native-networking` |
| Credential-free AWS / GCP / Azure access (no agent) | `setup-cloud-access` |
| The Internal firewall for the 3128 proxy, service-to-service rules | `firewall-networking` |
| Creating the identity, policies on the agent | `access-control` |

## Documentation

- [Agent Reference](https://docs.controlplane.com/reference/agent.md) · [Agent Setup Guide](https://docs.controlplane.com/guides/agent.md)
- [Identity Reference](https://docs.controlplane.com/reference/identity.md)
