---
name: cpln-native-networking
description: "Connects Control Plane workloads to private VPCs, on-prem networks, and cross-cloud resources. Use when the user asks about AWS PrivateLink, GCP Private Service Connect, VPN alternatives, wormhole agents, or accessing resources inside private networks from Control Plane."
version: 1.0.0
---

# Native Networking & Agent Connectivity

> **Scope:** This skill is the reference for connectivity options (PrivateLink / PSC / Agent), producer-side Terraform setup, agent sizing, permissions, and the `networkResources` / `nativeNetworkResources` schema. For the step-by-step agent deployment walkthrough (create → deploy → wire up identity → verify), delegate to the **cpln-agent-setup** agent.

## Connectivity Options Overview

| Option | Cloud | Use Case | Complexity | Performance |
|:-------|:------|:---------|:-----------|:------------|
| AWS PrivateLink | AWS | Private access to AWS services (RDS, etc.) | Medium | Native cloud speed, lowest latency |
| GCP Private Service Connect | GCP | Private access to GCP services (Cloud SQL, etc.) | Medium | Native cloud speed, lowest latency |
| Control Plane Agent (Wormhole) | Any / On-prem | VPC, data center, cross-cloud, developer laptop | Low-Medium | Tunneled, depends on agent instance size |

- **PrivateLink / PSC** = cloud-native private networking, no public internet traversal
- **Agent** = tunneled connectivity via a lightweight VM or container running inside the target network

Both are configured through an [identity](https://docs.controlplane.com/reference/identity.md) attached to a workload.

## AWS PrivateLink

### How It Works

Traffic flows from workload -> Control Plane infrastructure -> AWS VPC endpoint -> your private AWS service. No public internet traversal. Uses the AWS PrivateLink endpoint service backed by a Network Load Balancer.

### Prerequisites

- AWS account with IAM permissions for VPC, RDS, Lambda, NLB, Secrets Manager, IAM, CloudWatch
- AWS CLI and Terraform CLI installed
- Deploy resources in the same AWS region as the Control Plane workload

### Setup Steps

**Step 1 - Provision infrastructure (Terraform):**

```bash
git clone https://github.com/controlplane-com/cpln-rds-producer
cd cpln-rds-producer
```

**Step 2 - Configure `terraform.tfvars`:**

For new infrastructure:
```hcl
aws_region  = "us-west-2"
db_username = "postgres"
db_password = "SecurePassword123!"
```

For existing RDS + Secrets Manager:
```hcl
db_instance_arn = "arn:aws:rds:us-west-2:123456789012:db:my-db"
secret_arn      = "arn:aws:secretsmanager:us-west-2:123456789012:secret:my-secret"
```

**Step 3 - Deploy:**

```bash
terraform init && terraform plan && terraform apply
```

Outputs the PrivateLink endpoint service name.

**What gets created (new infra mode):** VPC & subnets, RDS PostgreSQL (multi-AZ), Secrets Manager, RDS Proxy, NLB, Lambda (dynamic IP updates), PrivateLink Endpoint Service.

**What gets created (existing infra mode):** RDS Proxy, NLB, Lambda, PrivateLink Endpoint Service.

**Step 4 - Contact Control Plane support:**

Email `support@controlplane.com` with your **service name** and **region**. Control Plane creates the consumer-side endpoint.

**Step 5 - Accept the endpoint connection:**

In the AWS Console: VPC -> Endpoint Services -> select your service -> Pending endpoint connections -> Actions -> Accept.

**Step 6 - Configure identity:**

Add a `nativeNetworkResources` entry to your identity:

```yaml
nativeNetworkResources:
  - name: "aws-rds"
    FQDN: "rds-proxy.us-west-2.amazonaws.com"
    ports: [5432]
    awsPrivateLink:
      endpointServiceName: "com.amazonaws.vpce.us-west-2.vpce-svc-12345678abcdef"
```

### Verification

- Workload environment variable resolves the FQDN or name
- If TLS is configured on the internal resource, the `FQDN` field must be used (not `name`)
- Multiple connections supported on different ports; each new database requires a new PrivateLink endpoint

## GCP Private Service Connect

### How It Works

Traffic flows from workload -> Control Plane infrastructure -> GCP PSC endpoint -> your private GCP service. Uses GCP Private Service Connect with a service attachment. Cloud SQL must have PSC enabled with `cpln-prod01` as an allowed consumer project.

### Prerequisites

- GCP account with billing enabled
- Google Cloud CLI and Terraform CLI installed
- Deploy resources in the same GCP region as the Control Plane workload
- APIs enabled: SQL Admin, Compute Engine, Service Networking

### Setup Steps (Terraform)

**Step 1 - Clone and configure:**

```bash
git clone https://github.com/controlplane-com/gcp-psc-producer-automation
cd gcp-psc-producer-automation
```

**Step 2 - Create `terraform.tfvars`:**

```hcl
project_id  = "your-gcp-project-id"
region      = "us-central1"
db_username = "postgres"
db_password = "SecurePassword123!"
```

**Step 3 - Deploy:**

```bash
terraform init && terraform plan && terraform apply
```

Outputs the service attachment.

**What gets created:** Necessary APIs enabled, VPC with firewall rule, Private Service Access (PSA) with reserved IP, Cloud SQL PostgreSQL with PSC enabled.

### Setup Steps (Existing Cloud SQL)

For an existing Cloud SQL instance, enable PSC via the `gcloud` CLI:

```bash
gcloud config set project YOUR_PROJECT_ID

gcloud sql instances patch INSTANCE_NAME \
  --enable-private-service-connect \
  --allowed-psc-projects=cpln-prod01
```

The allowed consumer project must be `cpln-prod01`. The service attachment is found in the Cloud SQL console under Connections.

**To update allowed projects later**, rerun the command without the `--enable-private-service-connect` flag.

### Next Steps

1. Contact `support@controlplane.com` with your **service attachment** and **region**
2. Control Plane creates the consumer-side endpoint (no manual acceptance needed for Cloud SQL)
3. Configure identity:

```yaml
nativeNetworkResources:
  - name: "gcp-cloud-sql"
    FQDN: "my-cloudsql.us-central1.gcp.internal"
    ports: [5432]
    gcpServiceConnect:
      targetService: "projects/my-project/regions/us-central1/serviceAttachments/my-service"
```

### GCP PSC Constraints

- Cloud SQL must have private IP only (no public IP)
- PSA must be enabled with a reserved IP range before enabling PSC
- PSC enablement is **not** supported via the GCP console UI; use `gcloud` CLI
- The `targetService` must match pattern: `projects/PROJECT/regions/REGION/serviceAttachments/NAME`

## Control Plane Agents (Wormholes)

### What They Are

Agents provide tunneled TCP/UDP connectivity from Control Plane workloads to endpoints inside private networks. An agent VM or container runs inside the target network and establishes a persistent, secure outbound connection to Control Plane servers. Workload requests are tunneled through the agent transparently.

### Use Cases

- Access databases, APIs, or services inside a cloud VPC (AWS, Azure, GCP)
- Connect to on-premises data centers
- Bridge multiple private networks (cross-cloud)
- Development/testing against local services (developer laptop via Docker)

### How It Works

1. Create an agent resource in Control Plane (generates a bootstrap config)
2. Deploy the agent inside the target network (VM, container, or K8s)
3. Agent establishes outbound connection to Control Plane hub
4. Configure identity `networkResources` linking the agent to specific endpoints
5. Workload traffic is tunneled: workload -> Control Plane -> agent -> private endpoint

Agents run in **active-passive** mode. If an active agent misses heartbeats, it is replaced by a redundant agent.

### Agent Deployment

For the full walkthrough — creating the agent, generating deployment artifacts (K8s manifest, Docker, AWS/Azure/GCP VMs), configuring identity `networkResources`, and verifying the tunnel — delegate to the **cpln-agent-setup** agent.

This reference keeps the schema, sizing, and permissions that apply regardless of deployment method.

### Network Resource Fields

| Field | Type | Required | Description |
|:------|:-----|:---------|:------------|
| `name` | string | Yes | Resource name or domain |
| `agentLink` | string | No | Link to agent: `/org/ORG/agent/AGENT_NAME` |
| `IPs` | array | No* | IPv4 addresses (1-5) |
| `FQDN` | string | No* | Fully qualified domain name |
| `resolverIP` | string | No | Custom DNS resolver IPv4 |
| `ports` | array | Yes | Ports to expose (1-10 ports, range 0-65535) |

*Either `IPs` OR `FQDN` is required (not both). Max 50 entries per array (`networkResources` and `nativeNetworkResources` are capped independently).

### High Availability

For production, use an instance group / autoscaling group / VMSS:
- Fixed size: min 2, max = number of availability zones
- Agent is not CPU intensive; do not use CPU-based autoscaling
- Agents use leader election (active-passive)

### Agent Sizing Guidance

Tests performed using qperf (30-second runtime) with client as a Control Plane workload in the same region as the server VM.

**AWS** (server: c5.2xlarge in `aws-us-west-2`):

| Agent Instance | Avg Bandwidth (MB/s) | Avg Latency (us) | Baseline Bandwidth (Gbps) |
|:---------------|:---------------------|:------------------|:--------------------------|
| No Agent | 307.6 | 585.6 | n/a |
| t2.micro | 21.23 | 1301 | 0.064 |
| t3.small | 143.9 | 1107 | 0.128 |
| c5.large | 341.1 | 629.6 | 0.75 |
| c4.xlarge | 70.25 | 680.8 | 5.0 |

Use Baseline Bandwidth (not burst) for capacity planning. Discover baseline per instance type:
```bash
aws ec2 describe-instance-types \
  --filters "Name=instance-type,Values=t3.*" \
  --query "InstanceTypes[].[InstanceType, NetworkInfo.NetworkCards[0].BaselineBandwidthInGbps] | sort_by(@,&[1])" \
  --output table
```

**GCP** (server: e2-standard-8 in `gcp-us-east1`):

| Agent Machine Type | Avg Bandwidth (MB/s) | Avg Latency (us) |
|:-------------------|:---------------------|:------------------|
| No Agent | 313.4 | 251.2 |
| n2-standard-2 | 250.3 | 407.7 |
| n2-standard-8 | 223.3 | 350.7 |
| n2-standard-4 | 217.5 | 354.1 |
| n1-standard-1 | 199.9 | 409.3 |

## Agent CLI Commands

| Command | Description |
|:--------|:------------|
| `cpln agent create --name NAME --org ORG` | Create agent, outputs bootstrap config JSON |
| `cpln agent manifest --bootstrap-file FILE --namespace NS [--replicas N] [--cluster ID]` | Generate K8s manifest |
| `cpln agent up --bootstrap-file FILE [--background] [--net NET]` | Run agent locally via Docker |
| `cpln agent info REF` | Show agent info (lastActive, peerCount, serviceCount) |
| `cpln agent eventlog REF` | Show agent event log (alias: `cpln agent log`) |
| `cpln agent get [REF]` | Get agent resource(s) |
| `cpln agent delete REF` | Delete agent |
| `cpln agent update REF` | Update agent properties |
| `cpln agent edit REF` | Edit agent YAML in editor |

## Choosing the Right Option

```
Need private connectivity to a cloud service?
  |
  +-- AWS service (RDS, etc.)? --> AWS PrivateLink
  |     Cloud-native, lowest latency, no agent needed
  |
  +-- GCP service (Cloud SQL, etc.)? --> GCP Private Service Connect
  |     Cloud-native, lowest latency, no agent needed
  |
  +-- On-premises / data center? --> Control Plane Agent
  |
  +-- Cross-cloud or multi-VPC? --> Control Plane Agent
  |
  +-- Developer laptop / local? --> Control Plane Agent (Docker)
  |
  +-- Azure VPC resources? --> Control Plane Agent
```

**PrivateLink / PSC** require contacting `support@controlplane.com` to set up the consumer-side endpoint. **Agents** are self-service.

## Native Network Resource Schema

Both `nativeNetworkResources` and `networkResources` are arrays on the identity object. Names must be unique across both arrays combined.

```yaml
# Native networking (PrivateLink / PSC) - no agent needed
nativeNetworkResources:
  - name: "aws-rds"
    FQDN: "rds.example.com"
    ports: [5432]
    awsPrivateLink:
      endpointServiceName: "com.amazonaws.vpce.us-west-2.vpce-svc-abc123"

  - name: "gcp-sql"
    FQDN: "sql.example.com"
    ports: [5432]
    gcpServiceConnect:
      targetService: "projects/my-proj/regions/us-central1/serviceAttachments/my-sa"

# Agent-based networking (wormhole) - requires running agent
networkResources:
  - name: "on-prem-db"
    agentLink: "/org/my-org/agent/dc-agent"
    IPs: ["10.0.1.50"]
    ports: [5432, 3306]
```

Each `nativeNetworkResource` must have exactly one of `awsPrivateLink` or `gcpServiceConnect`.
Each `networkResource` must have exactly one of `IPs` or `FQDN`.

## Quick Reference

### MCP Tools

**Agent tools (dedicated):**

| Tool | Use |
|:-----|:----|
| `mcp__cpln__list_agents` | List all agents in an org |
| `mcp__cpln__get_agent` | Get agent details (registration token hidden) |
| `mcp__cpln__create_agent` | Create agent and return bootstrap config |
| `mcp__cpln__delete_agent` | Delete an agent |
| `mcp__cpln__get_agent_info` | Real-time agent status: active/inactive, lastActive, peerCount, serviceCount |
| `mcp__cpln__get_agent_eventlog` | Agent event log for troubleshooting connectivity |

**Identity tools (for network resource configuration):** see the **cpln-agent-setup** agent, Step 4 — it documents `create_identity`, `update_identity`, `add_identity_network_resource`, `add_identity_native_network_resource`, `remove_identity_network_resource`, and `list_identity_network_resources` with JSON input examples.

### Related Skills

- **cpln-agent-setup** (agent) — Agent deployment walkthrough + identity network resource configuration
- **cpln-firewall-networking** — Firewall rules, load balancers, service-to-service
- **cpln-access-control** — Policies, permissions, and identity-based access

### Agent Permissions

| Permission | Description | Implies |
|:-----------|:------------|:--------|
| `create` | Create new agents | |
| `delete` | Delete agents | |
| `edit` | Modify agents | view |
| `manage` | Full access | create, delete, edit, use, view |
| `use` | Use agent in an identity | view |
| `view` | Read-only access | |

## Documentation

For the latest reference, see:

- [Native Networking Setup Guide](https://docs.controlplane.com/guides/native-networking/native-networking-setup.md)
- [Identity Reference](https://docs.controlplane.com/reference/identity.md)
- [Agent Reference](https://docs.controlplane.com/reference/agent.md)
- [Agent Setup Guide](https://docs.controlplane.com/guides/agent.md)
