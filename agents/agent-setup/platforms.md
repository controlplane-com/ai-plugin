# Agent Deployment — Per-Platform Reference

Companion to `agents/agent-setup.md`. Pick the platform and follow the section. Each section assumes you have already saved the bootstrap config JSON from Step 1 of the parent agent.

## Kubernetes

### Generate the manifest

```bash
cpln agent manifest \
  --bootstrap-file AGENT_NAME-bootstrap.json \
  --namespace NAMESPACE \
  --replicas 2 \
  --cluster CLUSTER_ID \
  > agent-manifest.yaml
```

**Flags:**
- `--bootstrap-file` — path to the bootstrap JSON (required).
- `--namespace` / `-n` — K8s namespace (required).
- `--replicas` — number of agent deployments (default: 1, use 2 for HA).
- `--cluster` — metadata tag identifying which cluster the agent runs in.
- `--create-namespace` — create the namespace if it doesn't exist (default: true).
- `--image` — advanced: override the agent Docker image.

**`--replicas 2` is recommended for production.** This creates two separate deployments in active-passive mode using leader election through the Control Plane API.

**Warning: Never scale a single agent deployment to more than one replica.** Each deployment has a unique key. Running multiple replicas of the same deployment causes intermittent latency and dropped packets. Use `--replicas 2` (two separate deployments) instead.

On startup, each agent generates a public/private key pair stored as a K8s secret. The agent's service account needs permission to create/modify secrets in its namespace. If this is a concern, run the agent in a dedicated namespace.

### Apply the manifest

```bash
kubectl apply -f agent-manifest.yaml
```

## Docker (Private Network / Developer Laptop)

`cpln agent up` handles preparation and deployment in one command — no separate manifest is needed.

```bash
cpln agent up --bootstrap-file AGENT_NAME-bootstrap.json
```

**Flags:**
- `--bootstrap-file` — path to the bootstrap JSON (required).
- `--background` / `-b` — run as a background process.
- `--net` — Docker network to use (default: `bridge`).
- `--image` — advanced: override the agent Docker image.

**Note:** On Windows, configure Docker to NOT use the WSL 2 based engine and run the command from a Windows command prompt (not WSL).

**Important:** When running locally, the agent runs inside a Docker container. When configuring identity network resources, use the IP of the network adapter that Docker installed on the local machine — not `localhost` or `127.0.0.1`.

## AWS (VM)

1. Subscribe to the **Control Plane Secure Communications Agent** in the [AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-dq5cug2iej46m).
   - ARM version: [ARM agent listing](https://aws.amazon.com/marketplace/pp/prodview-fvvtn73sdxxos).
2. Launch through EC2:
   - Select the same VPC as the target resources.
   - Enable **Auto-assign Public IP** (or configure NAT for outbound internet).
   - Security group: no inbound ports required; add the agent's security group to target resource inbound rules.
   - Advanced Details → **User data**: paste the bootstrap config JSON.
3. Set **Delete on termination** to `Yes` for the volume to prevent orphaned volumes.

**The agent requires outbound internet access to connect to Control Plane servers. No inbound ports are needed.**

Refer to the **cpln-native-networking** skill for agent sizing guidance and instance type selection.

## Azure (VM)

1. In Azure Marketplace, search for `Control Plane Secure Communications Agent`, select `gen-1`.
2. Configure the VM:
   - Size: at least 2 vCPUs, 4 GiB memory.
   - Public IP: `None` (the agent needs outbound internet, not a public IP).
   - Public inbound ports: `None`.
   - OS disk type: Premium SSD.
   - Advanced → **Custom data**: paste the bootstrap config JSON.
3. Create the VM.

## GCP (VM)

1. Deploy using the Google Cloud SDK:

   ```bash
   gcloud compute instances create INSTANCE_NAME \
     --image controlplane-agent-amd64-20260218-2334239718-16cf8727 \
     --image-project cpln-build \
     --metadata-from-file=user-data=AGENT_NAME-bootstrap.json
   ```

   Add `--machine-type=MACHINE_TYPE` to select a specific type (default: `n1-standard-1`). Deploy in the same VPC and region as target resources.

2. Configure firewall: the agent does not need SSH, RDP, or ICMP ports open. It needs outbound internet access and connectivity to your GCP resources.
