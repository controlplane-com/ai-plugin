---
name: mk8s-byok
description: "Provisions managed Kubernetes (mk8s) clusters and registers existing clusters via BYOK on Control Plane. Use when the user asks about creating a Kubernetes cluster, mk8s, BYOK, node pools, cluster add-ons, or multi-cloud Kubernetes."
---

# Managed Kubernetes & BYOK Patterns

## Managed Kubernetes (mk8s)

Control Plane provisions and manages Kubernetes clusters across cloud providers.

### Providers

Exactly one provider must be specified per cluster (mutually exclusive).

| Provider | Infrastructure | Key Features |
|:---|:---|:---|
| AWS | EC2 instances | VPC CNI, EBS storage, ALB integration |
| Azure | Azure VMs | Azure networking and identity |
| GCP | Compute Engine | GKE-compatible networking |
| DigitalOcean | Droplets | Simple cloud provisioning |
| Hetzner | Hetzner Cloud | Cost-effective European hosting |
| Linode | Linode instances | Akamai cloud infrastructure |
| Oblivus | Oblivus Cloud | GPU cloud provider |
| Lambdalabs | Lambda GPU Cloud | GPU-optimized instances |
| Paperspace | Paperspace machines | ML/AI workloads |
| Triton | Joyent Triton | SmartOS-based infrastructure |
| Ephemeral | Temporary clusters | Short-lived test/dev clusters |
| Generic | Any infrastructure | Bring any server with SSH access |

### Requirements

- Linux OS with kernel > 5.4
- Internet access (for mk8s to download components)
- Cluster nodes must be able to reach each other (same VPC, same L2 network, etc.)

Documented sizing guidance is provider-specific. The Generic provider documents a minimum of 1 CPU core and 512 MB RAM per server; cloud providers size via their own instance types.

### Add-Ons

| Add-On | Purpose | Providers |
|:---|:---|:---|
| Dashboard | Kubernetes Dashboard web UI | All |
| Headlamp | Extensible Kubernetes web UI | All |
| AWS Workload Identity | IAM roles for service accounts | AWS, Hetzner, Generic |
| Azure Workload Identity | Azure AD service principals for pods | All |
| AWS ECR | Pull images from private ECR registries | AWS, Hetzner, Generic |
| AWS EFS | Mount EFS shared file storage | AWS, Hetzner, Generic |
| AWS ELB | AWS Load Balancer Controller (NLB/ALB) | AWS |
| Azure ACR | Pull images from private ACR registries | All |
| BYOK (CPLN Platform) | Register cluster as a BYOK location | All |
| Local Path Storage | Local path persistent volume provisioner | All |
| Metrics | Send Prometheus metrics to Control Plane | All |
| Logs | Send pod logs and audit records to Control Plane | AWS, Hetzner, Generic |
| Registry Mirror | P2P image layer caching across nodes | All |
| Sysbox | Enhanced container isolation (run Docker/K8s in containers) | All |

### Supported Kubernetes Versions

Valid `spec.version` values (must be an exact match): `1.26.0`, `1.26.4`, `1.27.3`, `1.28.2`, `1.28.4`, `1.29.7`, `1.30.3`, `1.31.5`, `1.31.13`, `1.32.1`, `1.32.9`, `1.33.5`, `1.34.2`.

### Firewall Rules

The `spec.firewall` array contains allow-list rules. Each rule has `sourceCIDR` (required, IPv4 or IPv6 with optional CIDR) and `description` (optional). Default: `0.0.0.0/0` (allow all).

### Create mk8s Cluster

Prefer the MCP server. Each provider has its own create tool — pick the one matching your infrastructure: `mcp__cpln__create_mk8s_aws`, `mcp__cpln__create_mk8s_azure`, `mcp__cpln__create_mk8s_gcp`, `mcp__cpln__create_mk8s_digitalocean`, `mcp__cpln__create_mk8s_hetzner`, `mcp__cpln__create_mk8s_linode`, `mcp__cpln__create_mk8s_oblivus`, `mcp__cpln__create_mk8s_lambdalabs`, `mcp__cpln__create_mk8s_paperspace`, `mcp__cpln__create_mk8s_triton`, or `mcp__cpln__create_mk8s_generic`. Supply at least one node pool to get worker capacity. Several providers need a credential secret first (use the typed `mcp__cpln__create_secret_<type>` tool): Azure (`sdkSecretLink` → `create_secret_azure_sdk`), GCP (`saKeyLink` → `create_secret_gcp`), DigitalOcean / Hetzner / Linode / Oblivus / Lambdalabs / Paperspace (`tokenSecretLink` → `create_secret_opaque`), Triton (`connection.privateKeySecretLink` → `create_secret_keypair`). AWS uses an assumed `deployRoleArn` instead of a secret.

Inspect with `mcp__cpln__get_resource` (kind="mk8s") and `mcp__cpln__list_resources` (kind="mk8s"). Update an existing cluster with the per-provider `mcp__cpln__update_mk8s_<provider>` tool (merge-patch — supply only the fields to change; provided `nodePools`/`firewall` replace the existing values). Delete with `mcp__cpln__delete_resource` (kind="mk8s") (destructive — confirm the blast radius first).

Fallback (MCP unavailable, or CI/CD): create via `cpln apply` with a YAML manifest. Author it from the live schema with `mcp__cpln__get_resource_schema` (kind `mk8s`).

```bash
# Fallback: create/update a cluster via cpln apply with a YAML manifest
cpln apply --file mk8s-cluster.yaml
```

### mk8s CLI Commands

For read/update/delete, prefer the MCP tools above (`get_resource`/`list_resources` (kind="mk8s"), `update_mk8s_<provider>`, `delete_resource` (kind="mk8s")). The CLI is the fallback when MCP is unavailable and the only interface for the operations below that have no MCP equivalent (`kubeconfig`, `dashboard`, `join`, `eventlog`, `clone`).

| Command | Description |
|:--------|:------------|
| `cpln mk8s get [ref...]` | Retrieve one or more mk8s clusters |
| `cpln mk8s delete <ref...>` | Delete one or more mk8s clusters |
| `cpln mk8s edit <ref>` | Edit cluster YAML in an editor |
| `cpln mk8s patch <ref>` | Update metadata using a patch file |
| `cpln mk8s update <ref>` | Update properties via `--set` / `--unset` |
| `cpln mk8s kubeconfig <ref>` | Create a kubeconfig for a cluster |
| `cpln mk8s dashboard <ref>` | Open the K8s dashboard for the cluster |
| `cpln mk8s join <ref>` | Join compute nodes to a cluster |
| `cpln mk8s eventlog <ref>` | Show cluster event log (alias: `log`) |
| `cpln mk8s clone <ref>` | Clone cluster spec (alias: `copy`) |

There is no `cpln mk8s create` command. Create clusters with the `mcp__cpln__create_mk8s_<provider>` tools, or fall back to `cpln apply --file mk8s.yaml`.

`cpln mk8s update --set` only accepts `description`, `tags.<key>`, and `spec.version`. To edit provider or add-on fields, use `cpln mk8s edit` or `cpln apply`.

### Key Constraints

- No pre-installed service mesh (Control Plane ships an Istio-based mesh out of the box)
- Exactly one provider (`spec.provider.*`) must be populated — the schema enforces XOR across providers
- EKS/GKE prerequisites live under **BYOK → Provider-Specific Notes**; they do not apply to mk8s (Control Plane provisions the cluster itself)

## Bring Your Own Kubernetes (BYOK)

Register an existing Kubernetes cluster as a Control Plane location.

### Setup Flow

1. **Create the BYOK location** in Control Plane (Console or CLI).
2. **Generate the install command** (valid for about 5.5 minutes — the manifests contain sensitive tokens).
3. **Run the install command** on the target cluster.
4. **Wait for the `cpln-byok-agent` deployment** in the `kube-system` namespace to become ready (allow a few minutes for all components to deploy).
5. **Add the location to a GVC** to deploy workloads onto it.

### Bootstrap Commands

```bash
# 1. Create a BYOK-provider location entry in Control Plane
cpln location create --name my-cluster

# 2. Print the kubectl install command (valid ~5.5 minutes)
cpln location install my-cluster

# 3. Run the printed command against the target cluster's kubectl context
#    (it is an inline `kubectl apply -f <signed-url>` command, not a saved file)
```

To remove a BYOK cluster, use `cpln location uninstall <ref>` and run the printed command on the cluster.

### Prerequisites

- A Kubernetes cluster within the three most recent supported minor releases (see [Kubernetes releases](https://kubernetes.io/releases/))
- `kubectl` configured for the target cluster
- Egress (internet) access from all nodes
- At least one nodegroup labeled `cpln.io/nodeType=core` (core components land there)
- Minimum 2 nodes per cluster (3+ recommended)
- Minimum 2 CPUs per node (4+ recommended) and 8 GB RAM (16+ recommended)
- Node architecture: `amd64` or `arm64`
- Full node-to-node connectivity (public or private network)
- No pre-installed service mesh (Control Plane provides an Istio-based mesh)
- A working LoadBalancer controller (at least one Service of type LoadBalancer must obtain an IP)

### Provider-Specific Notes

**GKE:** After Control Plane config is applied, scale `kube-dns` and `kube-dns-autoscaler` deployments in `kube-system` to 0 replicas. Provide the `kube-dns` Service IP to support during onboarding.

**EKS:** Ensure these cluster add-ons are enabled: Amazon VPC CNI, `kube-proxy`, CoreDNS, and Amazon EBS CSI Driver.

**On-Prem:** Enable egress for all nodes (contact support for airgapped alternatives).

### Post-Installation

After the agent connects:
1. Add the BYOK location to your GVC — `mcp__cpln__add_gvc_locations`
2. Deploy workloads that target the new location
3. Verify workload health across all locations — `mcp__cpln__list_deployments` (poll until ready), then `mcp__cpln__get_resource` (kind="workload")

The BYOK location create/install/uninstall steps above are CLI-only (no MCP equivalent). Once the location exists, prefer MCP for the GVC and workload work:

```bash
# Fallback for adding the location via CLI
cpln gvc add-location my-gvc --location my-cluster

# Or, equivalently, via the generic update + `+=` append operator
cpln gvc update my-gvc --set 'spec.staticPlacement.locationLinks+=//location/my-cluster'

cpln workload get my-app --gvc my-gvc
```

## Documentation

For the latest reference, see:

- [mk8s Overview](https://docs.controlplane.com/mk8s/overview.md)
- [mk8s on AWS](https://docs.controlplane.com/mk8s/aws.md)
- [mk8s on GCP](https://docs.controlplane.com/mk8s/gcp.md)
- [mk8s on Hetzner](https://docs.controlplane.com/mk8s/hetzner.md)
- [mk8s Generic Provider](https://docs.controlplane.com/mk8s/generic.md)
- [Location Reference](https://docs.controlplane.com/reference/location.md)
- [CLI mk8s Commands](https://docs.controlplane.com/cli-reference/commands/mk8s.md)
