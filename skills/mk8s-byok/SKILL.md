---
name: mk8s-byok
description: "Provisions managed Kubernetes (mk8s) clusters and registers existing ones as BYOK locations on Control Plane. Use when the user asks about a Kubernetes cluster, mk8s, BYOK, node pools, add-ons, or multi-cloud K8s."
---

# Managed Kubernetes (mk8s) & BYOK

> **Tool availability:** the `create_mk8s_*` / `update_mk8s_*` tools and the GCP/Triton credential-secret tools (`create_secret_gcp`, `create_secret_keypair`) live in the `mk8s` toolset profile (`?toolsets=mk8s`; `full` includes it). `create_secret_opaque` (used by Azure and every token provider) is in `core`. If an mk8s tool is not advertised, tell the user to reconnect with `?toolsets=mk8s`, or create the resource via the `cpln` CLI. Reads and deletes work on every profile via `list_resources` / `get_resource` / `delete_resource` (kind `mk8s` or `location`).

Control Plane has three separate "Kubernetes" stories people routinely conflate — get the right one first:

- **mk8s** — Control Plane *provisions and manages* a real, conformant Kubernetes cluster on your cloud account (12 providers). You get a kubeconfig and run normal Kubernetes. It is a **standalone cluster** — to schedule Control Plane (GVC) workloads onto it, add the `byok` add-on (below). Resource kind `mk8s`.
- **BYOK location** — you already have a self-managed cluster; you *register it* as a Control Plane location so Control Plane workloads (GVC workloads) schedule onto it. Resource kind `location`, provider `byok`.
- **mk8s BYOK add-on** — `addOns.byok` makes an mk8s cluster register *itself* as a Control Plane location: it links a `location` you create and installs the agent automatically (no manual `cpln location install`). This is how Control Plane workloads run on an mk8s cluster.

(If the user instead wants to manage Control Plane resources *from* `kubectl`, that is the **k8s-operator** skill, not this one.) The dominant failures: reaching for a nonexistent `cpln mk8s create`; skipping the per-provider credential secret; and leaving the cluster's API-server firewall wide open.

## Providers & credential secrets

Exactly one provider per cluster (the schema enforces XOR). For every provider except AWS and Generic, **create the credential secret first**, then reference it in the create call.

| Provider | Create first (credential) | Node-sizing field | Location/region |
|:---|:---|:---|:---|
| `aws` | `deployRoleArn` — an assumed IAM role, **no secret** (also needs `vpcId`) | `instanceTypes[]` | `region` |
| `azure` | **opaque** secret (`sdkSecretLink`) — service-principal creds | `size` | `location` |
| `gcp` | **gcp** secret (`saKeyLink`) — SA JSON key | `machineType` | `region` |
| `digitalocean` | **opaque** secret (`tokenSecretLink`) | `dropletSize` | `region` |
| `hetzner` | **opaque** secret (`tokenSecretLink`) | `serverType` | `region` |
| `linode` | **opaque** secret (`tokenSecretLink`) | `serverType` | `region` |
| `oblivus` | **opaque** secret (`tokenSecretLink`) | `flavor` (GPU enum) | `datacenter` |
| `lambdalabs` | **opaque** secret (`tokenSecretLink`) | `instanceType` (GPU enum) | `region` |
| `paperspace` | **opaque** secret (`tokenSecretLink`) | `machineType` (GPU enum) | `region` |
| `triton` | **keypair** secret (`connection.privateKeySecretLink`) | `packageId` | `location` |
| `generic` | none — you join your own nodes | n/a (external nodes) | `location` |

**Azure uses an `opaque` secret, not an `azure-sdk` secret** — the create tool rejects the typed one. Triton/Generic/Ephemeral `location` is a *Control Plane* location (e.g. `aws-us-east-2`), not a cloud region. A 12th provider, `ephemeral`, exists in the schema but has **no create tool or CLI create** — ignore it for real clusters. Other required fields (network/VPC, image, SSH keys, region enum) vary per provider; `mcp__cpln__get_resource_schema` (kind `mk8s`) and the create tool's own validation give the exact required set. Generic nodes you supply each need Linux kernel ≥ 5.4, ≥ 1 CPU / 512 MB, mutual connectivity, and SSH access.

## The cluster spec essentials

- **`version`** — required, no default, a **closed enum** of specific patch versions (currently `1.26.0` through `1.35.3`). The set drifts as versions are added/retired; pull the live list from `get_resource_schema`, or just submit and let the typed tool's validation error name the valid values. Updating it is **upgrade-only** — mk8s rejects downgrades.
- **`nodePools`** (per provider) — give at least one to get worker capacity. Common fields are `name`/`labels`/`taints`; the rest are provider-specific. Each pool's **`minSize`/`maxSize` drive the cluster autoscaler** (set `maxSize > minSize` to allow scale-up).
- **`autoscaler`** (per provider) — defaults: `expander: [most-pods]`, `unneededTime: 10m`, `unreadyTime: 20m`, `utilizationThreshold: 0.7`. Usually leave it.
- **`networking`** (per provider) — `serviceNetwork` (default `10.43.0.0/16`) and `podNetwork` (default `10.42.0.0/16`) must differ and are **unmodifiable after creation**; pick non-overlapping CIDRs up front. AWS and GCP additionally accept `podNetwork: vpc`.
- **`firewall`** — the API-server allow-list. It **defaults to `0.0.0.0/0` (fully open)**, the opposite of the deny-by-default workload firewall; the create tool warns when you omit it. Restrict it to your admin CIDRs. Each rule is `sourceCIDR` (required) + `description`.

## Add-ons

`spec.addOns` is a map of toggles and small config objects. The schema is **provider-agnostic — it does not block any add-on on any provider**; an add-on only *functions* where the provider supports it (column below is the documented applicability).

| Add-on key | What it does | Providers |
|:---|:---|:---|
| `dashboard` | Kubernetes Dashboard UI | all |
| `headlamp` | Headlamp web UI | all |
| `metrics` | Prometheus metrics to Control Plane | all |
| `logs` | pod logs + audit records to Control Plane | aws, hetzner, generic |
| `localPathStorage` | local-path PVC provisioner | all |
| `registryMirror` | P2P image-layer cache across nodes | all |
| `sysbox` | run Docker/Kubernetes inside pods (stronger isolation) | all |
| `nvidia` | NVIDIA GPU operator (`taintGPUNodes`) | GPU nodes |
| `kubevirt` | run VMs on the cluster (needs `nodeLocalDns` + `cpln.io/nodeType=vm` nodes) | nodes with HW virtualization |
| `nodeLocalDns` | per-node CoreDNS cache | all |
| `awsWorkloadIdentity` | pods assume AWS IAM roles | aws, hetzner, generic |
| `awsECR` | pull from private ECR | aws, hetzner, generic |
| `awsEFS` | EFS volumes (`roleArn` required) | aws, hetzner, generic |
| `awsELB` | AWS Load Balancer Controller (NLB/ALB) | aws |
| `azureWorkloadIdentity` | pods get Azure AD identities | all |
| `azureACR` | pull from private ACR (`clientId` required) | all |
| `byok` | register this cluster as a BYOK location (`addOns.byok.location` is a `//location/NAME` link) | all |

## Create & update (MCP)

Pick the provider's tool — `mcp__cpln__create_mk8s_<provider>` for any provider in the table above (e.g. `create_mk8s_aws`, `create_mk8s_generic`). Supply `version` and at least one node pool. Read with `mcp__cpln__get_resource` / `list_resources` (kind `mk8s`); delete with `mcp__cpln__delete_resource` (destructive — confirm the blast radius).

`mcp__cpln__update_mk8s_<provider>` is a **merge-patch**: send only what changes. Provided **arrays** (`nodePools`, `firewall`) **replace the previous values wholesale** — include the full set you want to keep. `addOns` merge-patches per key, so the update tool **cannot disable a toggle add-on by passing `false`** — remove one with `cpln apply` (set the key to `null`). `region`/`networking` and the provider/name are unmodifiable after creation.

Fallback (MCP unavailable, or CI/CD): author a YAML manifest from `get_resource_schema` (kind `mk8s`) and `cpln apply --file mk8s.yaml`.

## CLI (mk8s)

There is **no `cpln mk8s create`** — create via the MCP tools above or `cpln apply`. The CLI owns the operations with no MCP equivalent:

| Command | Purpose |
|:---|:---|
| `cpln mk8s get [ref...]` / `query` | read clusters |
| `cpln mk8s health <ref>` | readiness status of the cluster |
| `cpln mk8s kubeconfig <ref>` | generate a kubeconfig |
| `cpln mk8s dashboard <ref>` | open the Kubernetes dashboard |
| `cpln mk8s join <ref>` | join your own nodes (generic clusters and Hetzner dedicated-server pools) |
| `cpln mk8s eventlog <ref>` | cluster event log (alias `log`) |
| `cpln mk8s clone <ref>` | duplicate the spec (alias `copy`) |
| `cpln mk8s edit / patch / update / delete` | edit YAML / patch metadata / `--set` / remove |

`cpln mk8s update --set` accepts only `description`, `tags.<key>`, and `spec.version`. For provider, node-pool, or add-on changes use `update_mk8s_<provider>`, `cpln mk8s edit`, or `cpln apply`.

## BYOK location (register an existing cluster)

For a cluster you already run yourself. **All location create/install/uninstall steps are CLI-only — there is no MCP tool.**

1. `cpln location create --name CLUSTER` — create the BYOK location entry.
2. `cpln location install CLUSTER` — prints instructions for obtaining the install script (a signed `kubectl apply` command). The manifests carry sensitive tokens and are valid for **about 5 minutes** — run it promptly or regenerate.
3. Apply it against the target cluster's kubectl context.
4. Wait for the **`cpln-byok-agent`** deployment in the **`kube-system`** namespace to become ready: `kubectl get pod -l app=cpln-byok-agent -n kube-system`.
5. Add the location to a GVC, then deploy workloads onto it.

Remove with `cpln location uninstall CLUSTER` and run the printed command on the cluster.

**Prerequisites:** a cluster within the three most recent Kubernetes minor releases; ≥ 2 nodes (3+ recommended); ≥ 2 CPU and 8 GB RAM per node (4 / 16 recommended); architecture `amd64` or `arm64`; at least one nodegroup labeled **`cpln.io/nodeType=core`**; full node-to-node connectivity and egress; a working LoadBalancer controller (a `Service` of type LoadBalancer must obtain an IP); and **no pre-installed service mesh** — Control Plane installs its own Istio-based mesh.

**Provider notes.** GKE: first give the `kube-dns` Service IP (`kubectl get svc -n kube-system kube-dns`) to support; then, *after* Control Plane config is applied, scale `kube-dns` and `kube-dns-autoscaler` (in `kube-system`) to 0 replicas. EKS: enable the Amazon VPC CNI, `kube-proxy`, CoreDNS, and Amazon EBS CSI Driver add-ons. On-prem/airgapped: contact support.

Once the location exists, prefer MCP for the GVC and workload work — `mcp__cpln__add_gvc_locations`, then deploy and poll `mcp__cpln__list_deployments`. CLI fallback: `cpln gvc add-location GVC --location CLUSTER`.

## Verify

- **mk8s:** poll `mcp__cpln__get_resource` (kind `mk8s`) until `status.serverUrl` is set, or `cpln mk8s health CLUSTER`; then `cpln mk8s kubeconfig CLUSTER` and `kubectl get nodes` to confirm worker capacity.
- **BYOK:** the agent pod is ready (`kubectl get pod -l app=cpln-byok-agent -n kube-system`), the location reports enabled, and a test workload targeting the location reaches ready in `list_deployments`.

## Troubleshooting

| Symptom | Cause and fix |
|:---|:---|
| Version create/update rejected | `version` must be in the closed enum, and updates are **upgrade-only** (no downgrade); read the valid set from `get_resource_schema` or the error. |
| Create rejected: secret type | Azure needs an **opaque** secret (not `azure-sdk`); GCP needs a **gcp** secret; Triton a **keypair** secret; token providers an **opaque** secret. Create it first. |
| Cluster reachable from anywhere | The API-server `firewall` defaulted to `0.0.0.0/0` — set it to your admin CIDRs. |
| Update wiped node pools / a rule | `nodePools` and `firewall` arrays replace wholesale on update — resend the full set. |
| Can't disable an add-on via update | The update tool ignores `false` toggles — remove the key with `cpln apply` (`null`). |
| Generic cluster has no workers | Generic nodes are external — run `cpln mk8s join` on each node. |
| BYOK agent never readies | Missing `cpln.io/nodeType=core` nodegroup, no working LoadBalancer, a pre-existing service mesh, or the install command expired (~5 min) — regenerate with `cpln location install`. |
| BYOK on GKE: DNS conflicts | Scale `kube-dns` and `kube-dns-autoscaler` to 0 and hand the `kube-dns` IP to support. |

## Quick reference

### MCP tools

- `mcp__cpln__create_mk8s_<provider>` / `update_mk8s_<provider>` — create/merge-patch a cluster (mk8s profile)
- `mcp__cpln__create_secret_opaque` (core) / `create_secret_gcp` / `create_secret_keypair` (mk8s profile) — provider credentials
- `mcp__cpln__get_resource` / `list_resources` / `delete_resource` (kind `mk8s` or `location`) — read/delete on any profile
- `mcp__cpln__get_resource_schema` (kind `mk8s`) — exact shape and the live `version` set before authoring YAML
- `mcp__cpln__add_gvc_locations` / `list_deployments` — attach a BYOK location to a GVC and verify workloads

BYOK *location* create/install/uninstall and `cpln mk8s kubeconfig|join|dashboard|health` are **CLI-only**. In CI/CD, `CPLN_TOKEN` + `cpln apply -f mk8s.yaml` provisions a cluster headlessly.

### Related skills

| Skill | Use for |
|:---|:---|
| workload | deploying workloads onto the cluster once its location is in a GVC |
| cpln | the CLI behind `mk8s` and `location` (kubeconfig, join, install) and `cpln apply` |
| stateful-storage | volumesets and the BYOK volumeset storage-class settings |
| access-control | policies and grantable permissions on cluster/location objects |
| image | pull secrets behind the ECR/ACR add-ons |
| k8s-operator | the opposite direction — managing Control Plane resources from `kubectl` |

## Documentation

- [mk8s Overview](https://docs.controlplane.com/mk8s/overview.md)
- [mk8s on AWS](https://docs.controlplane.com/mk8s/aws.md) · [GCP](https://docs.controlplane.com/mk8s/gcp.md) · [Hetzner](https://docs.controlplane.com/mk8s/hetzner.md) · [Triton](https://docs.controlplane.com/mk8s/triton.md) · [Generic](https://docs.controlplane.com/mk8s/generic.md)
- [BYOK Overview](https://docs.controlplane.com/byok/overview.md)
- [CLI mk8s Commands](https://docs.controlplane.com/cli-reference/commands/mk8s.md)
