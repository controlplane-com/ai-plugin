---
name: native-networking
description: "Connects Control Plane workloads to private VPCs, on-prem networks, and cross-cloud resources. Use when the user asks about AWS PrivateLink, GCP Private Service Connect, wormhole agents, or reaching a private network."
---

# Native Networking & Agent Connectivity

> **Tool availability:** the `create_agent` / `update_agent`, `get_agent_info` / `get_agent_eventlog`, and `add_identity_network_resource` / `add_identity_native_network_resource` / `remove_identity_network_resource` / `list_identity_network_resources` tools live in the **`full`** toolset profile. If one is not advertised, tell the user to reconnect the MCP server with `?toolsets=full`, or use the `cpln` CLI. Reads and deletes work on every profile via `list_resources` / `get_resource` / `delete_resource` (kind `agent` or `identity`).

A Control Plane workload reaches a private or cross-cloud endpoint through an **identity** (gvc-scoped) carrying one of two resource arrays. Attach that identity to the workload (`spec.identityLink`) — without the attachment, nothing routes. Both paths are wired **independently of the workload's external egress firewall**: you do *not* open an `outboundAllow*` rule to reach them. The two options:

- **Native networking** (`nativeNetworkResources`) — cloud-native private connectivity over **AWS PrivateLink** or **GCP Private Service Connect**. No agent, lowest latency, no public-internet traversal. The catch: the consumer-side endpoint is created by **Control Plane support**, not self-service.
- **Agent / wormhole** (`networkResources`) — a lightweight VM or container you run inside the target network that tunnels TCP traffic. Self-service, works for **any** network (VPC, on-prem, cross-cloud, Azure, a laptop), but throughput depends on the agent instance size.

> **Scope:** this skill is the reference for the comparison, producer-side setup, the identity schema, agent sizing, and permissions. For the agent **deployment walkthrough** (create, generate K8s/Docker/VM artifacts, wire up the identity, verify the tunnel), delegate to the **setup-agent** skill.

## Choosing an option

| Target | Option | Agent? | Consumer side set up by |
|:---|:---|:---|:---|
| AWS service (RDS, etc.) | AWS PrivateLink (native) | No | Support, then **you accept** the endpoint in the AWS console |
| GCP service (Cloud SQL, etc.) | GCP Private Service Connect (native) | No | Support (Cloud SQL needs **no** manual acceptance) |
| On-prem / data center | Agent | Yes | Self-service |
| Cross-cloud / multi-VPC | Agent | Yes | Self-service |
| Azure VNet, or a developer laptop | Agent | Yes | Self-service |

## Calling a resource from a workload

Once the identity is attached (`spec.identityLink`), the workload reaches either kind of resource like an ordinary host — no SDK, env var, or code change:

- **Connect to the resource's `name`** (or its `FQDN`) on one of the configured **`ports`** — e.g. a Postgres client points at `aws-rds:5432` (native) or `on-prem-db:5432` (agent).
- Control Plane injects a hosts entry so that name resolves and routes to the real endpoint: for **native**, straight to the PrivateLink/PSC private IP; for an **agent**, through the tunnel to the upstream `IPs`/`FQDN` on the private side.
- **Use the `FQDN`, not the `name`, when the target serves TLS** — the certificate is issued for the FQDN, so the short `name` fails certificate validation.
- Only the ports you list are wired to the resource — a port you did not configure is not opened.

## Native networking (PrivateLink / PSC)

Traffic flows from the workload, through Control Plane infrastructure, to your cloud's private endpoint — never the public internet. Setup:

1. **Provision the producer side.** Use the reference Terraform, or wire up an existing resource:
   - AWS RDS + PrivateLink: `github.com/controlplane-com/cpln-rds-producer` (new-infra mode also builds the VPC/RDS/Secrets Manager; existing-infra mode adds only RDS Proxy + NLB + Lambda + the endpoint service). Output: the **endpoint service name**.
   - GCP Cloud SQL + PSC: `github.com/controlplane-com/gcp-psc-producer-automation`. Output: the **service attachment**. For an *existing* Cloud SQL instance, enable PSC via gcloud — it is **not available in the GCP console**:
     ```bash
     gcloud sql instances patch INSTANCE --enable-private-service-connect --allowed-psc-projects=cpln-prod01
     ```
     The allowed consumer project must be **`cpln-prod01`**. Cloud SQL must use a private IP only.
2. **Hand the service name (AWS) / service attachment (GCP) plus the region to `support@controlplane.com`.** They create the consumer-side endpoint and associate it with your org.
3. **AWS only:** accept the connection in the AWS console (VPC, Endpoint Services, Pending endpoint connections, Accept). Cloud SQL connections are accepted automatically.
4. **Add a `nativeNetworkResources` entry** to the identity (tools and schema below), then attach the identity to the workload.

> **The identity entry is inert until support has wired the consumer side** (and, for AWS, you have accepted the endpoint connection). Until then — or if the `endpointServiceName` is mistyped — the platform **silently skips** it (no error, no connection). So add the entry *last*, not first.

```yaml
nativeNetworkResources:
  - name: "aws-rds"                 # a label; must be unique and must NOT equal the FQDN
    FQDN: "rds-proxy.us-west-2.amazonaws.com"
    ports: [5432]
    awsPrivateLink:
      endpointServiceName: "com.amazonaws.vpce.us-west-2.vpce-svc-12345abcdef"
  - name: "gcp-sql"
    FQDN: "my-sql.us-central1.gcp.internal"
    ports: [5432]
    gcpServiceConnect:
      targetService: "projects/PROJECT/regions/us-central1/serviceAttachments/NAME"
```

## Agents (wormholes)

An agent runs inside the target network and opens a persistent **outbound** connection to Control Plane; workload requests are tunneled through it (workload, Control Plane, agent, private endpoint). Use it for on-prem, cross-cloud, Azure, or local development — anywhere PrivateLink/PSC does not reach.

The deployment flow (create the agent, deploy it, attach `networkResources`, verify) is owned by the **setup-agent** skill. The pieces that belong here regardless of how it is deployed:

```yaml
networkResources:
  - name: "on-prem-db"
    agentLink: "//agent/dc-agent"   # or /org/ORG/agent/dc-agent
    IPs: ["10.0.1.50"]              # OR FQDN — exactly one
    ports: [5432, 3306]
```

**High availability** (`reference/agent.mdx`): run agents in a fixed-size instance group (autoscaling group on AWS, VMSS on Azure) sized **min 2, max = number of availability zones**. The agent is **not CPU-intensive — do not autoscale on CPU.** Agents run **active-active**: every instance registers and serves traffic at once (load-balanced); if one misses heartbeats it is dropped and the rest keep serving while the group replaces it.

**Bi-directional:** the agent also exposes a proxy on port **3128** so systems inside the private network can call Control Plane workloads without opening external firewall access — enable with `cpln agent up --exposeProxy` and grant it on the workload's **Internal** firewall (Add Agent — see `firewall-networking`).

### Agent sizing

Benchmarked with qperf (30s) from a workload in the server VM's region. Plan against **baseline** bandwidth, not burst.

**AWS** — server `c5.2xlarge` in `aws-us-west-2`:

| Agent instance | Bandwidth (MB/s) | Latency (us) | Baseline (Gbps) |
|:---|:---|:---|:---|
| No agent | 307.6 | 585.6 | n/a |
| t2.micro | 21.23 | 1301 | 0.064 |
| t3.small | 143.9 | 1107 | 0.128 |
| c5.large | 341.1 | 629.6 | 0.75 |
| c4.xlarge | 70.25 | 680.8 | 5.0 |

Find any instance's baseline with `aws ec2 describe-instance-types --query "InstanceTypes[].[InstanceType,NetworkInfo.NetworkCards[0].BaselineBandwidthInGbps]"`.

**GCP** — server `e2-standard-8` in `gcp-us-east1`:

| Agent machine | Bandwidth (MB/s) | Latency (us) |
|:---|:---|:---|
| No agent | 313.4 | 251.2 |
| n2-standard-2 | 250.3 | 407.7 |
| n2-standard-8 | 223.3 | 350.7 |
| n2-standard-4 | 217.5 | 354.1 |
| n1-standard-1 | 199.9 | 409.3 |

## Identity network-resource schema

Both arrays live on the identity object. Constraints are enforced by the platform (Joi) — the typed tools mirror them.

**`networkResources`** (agent-based):

| Field | Required | Notes |
|:---|:---|:---|
| `name` | Yes | label or domain; the dialable hostname |
| `agentLink` | No | `//agent/NAME` or `/org/ORG/agent/NAME` |
| `IPs` | one of | 1-5 IPv4 — **xor with `FQDN`** |
| `FQDN` | one of | one domain — **xor with `IPs`** |
| `resolverIP` | No | IPv4 of the DNS resolver the agent uses to resolve the `FQDN` inside the private network |
| `ports` | Yes | 1-10 ports, each 0-65535 |

**`nativeNetworkResources`** (PrivateLink / PSC):

| Field | Required | Notes |
|:---|:---|:---|
| `name` | Yes | label; must not equal the FQDN |
| `FQDN` | No | use it for TLS targets |
| `ports` | Yes | 1-10 ports, each 0-65535 |
| `awsPrivateLink.endpointServiceName` | one of | **xor with `gcpServiceConnect`** |
| `gcpServiceConnect.targetService` | one of | `projects/…/regions/…/serviceAttachments/…` — **xor with `awsPrivateLink`** |

Global rules (Joi-enforced): each array holds **max 50** entries, and **`name` and `FQDN` must be unique across both arrays combined**. Operationally (not a schema rule), two native resources that share a port need separate PrivateLink/PSC endpoints.

## Configuring & verifying

- Attach resources with `mcp__cpln__add_identity_native_network_resource` (PrivateLink/PSC) or `mcp__cpln__add_identity_network_resource` (agent-based) — each takes `org`, `gvc`, `identity`, and one `resource`. Create the identity first (`create_identity`, see `access-control`) if it does not exist.
- `mcp__cpln__remove_identity_network_resource` removes from **either** array by name (destructive — present the impact and get the user's explicit approval before calling). There is no separate native-remove tool.
- **Verify:** `mcp__cpln__list_identity_network_resources` lists both arrays; `mcp__cpln__get_agent_info` shows whether an agent is active plus its `peerCount` / `serviceCount`; then confirm the workload actually connects to the endpoint.

## Agent permissions

| Permission | Grants | Implies |
|:---|:---|:---|
| `view` | read-only | |
| `use` | reference the agent in an identity | view |
| `edit` | modify the agent | view |
| `create` | create agents | |
| `delete` | delete agents | |
| `manage` | full access | create, delete, edit, use, view |

## Troubleshooting

| Symptom | Cause and fix |
|:---|:---|
| Native resource never connects (no error) | Support hasn't created the endpoint / allow-listed the service, (AWS) the connection wasn't accepted, or `endpointServiceName` is mistyped — the platform silently skips an unmatched native resource. |
| TLS / certificate error to a native resource | Connect via the `FQDN`, not the `name` — the cert is issued for the FQDN. |
| "Provide exactly one of…" on the entry | `IPs` xor `FQDN` (agent), or `awsPrivateLink` xor `gcpServiceConnect` (native) — supply exactly one. |
| Duplicate name/FQDN rejected | Names and FQDNs must be unique across **both** arrays; the `name` must not equal any FQDN. |
| Agent shows inactive (`get_agent_info`) | No recent heartbeat — the deployed agent is down or cannot reach Control Plane; check `get_agent_eventlog`. |
| Workload cannot reach the agent's network | The identity is not attached to the workload (`spec.identityLink`), or the resource ports are wrong. |
| Agent will not delete | It is still referenced by an identity — remove the `networkResource` (or detach the identity) first. |
| Bootstrap config lost | It is shown only at `create_agent` time and is immutable — delete and recreate the agent. |

## Quick reference

### MCP tools

- `mcp__cpln__create_agent` / `update_agent` — create (returns the one-time bootstrap config) / patch description & tags (full profile)
- `mcp__cpln__get_agent_info` / `get_agent_eventlog` — live status and event log (full profile)
- `mcp__cpln__add_identity_native_network_resource` / `add_identity_network_resource` — attach a PrivateLink/PSC or agent resource (full profile)
- `mcp__cpln__remove_identity_network_resource` / `list_identity_network_resources` — remove from either array / list both (full profile)
- `mcp__cpln__get_resource` / `list_resources` / `delete_resource` (kind `agent` or `identity`) — read and delete on any profile

CLI fallback (MCP unavailable, or CI/CD with `CPLN_TOKEN`): `cpln agent create|manifest|up|info|eventlog`. Network resources on an identity are **not** settable via `cpln identity create`/`update` (description and tags only) — edit the identity YAML with `cpln identity edit REF` or `cpln apply -f identity.yaml`.

### Related skills

| Skill | Use for |
|:---|:---|
| workload | attaching the identity to the workload (`spec.identityLink`) that needs the connectivity |
| access-control | creating the identity, and policies/permissions on agents |
| firewall-networking | the Internal firewall for the bi-directional proxy, and service-to-service rules |
| cpln | the `cpln agent` CLI and `cpln apply` |

### Documentation

- [Native Networking Setup](https://docs.controlplane.com/guides/native-networking/native-networking-setup.md)
- [Agent Reference](https://docs.controlplane.com/reference/agent.md) · [Agent Setup Guide](https://docs.controlplane.com/guides/agent.md)
- [Identity Reference](https://docs.controlplane.com/reference/identity.md)
