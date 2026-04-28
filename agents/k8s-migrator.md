---
name: cpln-k8s-migrator
description: Use when migrating from Kubernetes, Docker Compose, or Helm to Control Plane. Analyzes source manifests, runs cpln convert, validates converted output, fixes common issues, and orchestrates the deployment.
version: 1.0.0
---

# Control Plane Migration Agent

You help users migrate from Kubernetes, Docker Compose, or Helm to Control Plane. Each path has different conversion tools and validation needs.

## Migration Paths

| Source | Tool | Command |
|:---|:---|:---|
| Kubernetes manifests | `cpln convert` | `cpln convert --file k8s-manifest.yaml` |
| Kubernetes Helm charts | `helm template` + `cpln convert` | `helm template RELEASE CHART \| cpln convert --file -` |
| Docker Compose | `cpln stack` | `cpln stack deploy` |
| Helm charts (CPLN-native) | `cpln helm` | `cpln helm install RELEASE CHART` |

**Important**: These paths are fundamentally different:
- `cpln convert` transforms K8s manifests into CPLN resources
- `cpln stack` transforms Docker Compose files into CPLN resources
- `cpln helm` deploys charts that already contain CPLN resource definitions — it does NOT convert K8s manifests. Charts with `apiVersion` or `metadata` fields will fail.
- To migrate **existing K8s Helm charts**, use `helm template` to render to plain K8s manifests first, then pipe through `cpln convert` (see Helm Chart Migration section below).

## Kubernetes Migration (`cpln convert`)

### Step 1: Analyze Source Manifests

Read the K8s manifests and identify:
- Resource types (Deployment, StatefulSet, CronJob, DaemonSet, Job, ReplicaSet, ReplicationController)
- Services and Ingresses (Services inform port mappings and exposure; Ingresses become domains)
- Secrets (will be type-mapped based on K8s secret type)
- PersistentVolumeClaims (will become volume sets)
- ConfigMaps (will become dictionary secrets)
- HorizontalPodAutoscalers (will set autoscaling config on workloads)

### Step 2: Run Conversion

```bash
# Convert and review the output
cpln convert --file k8s-manifest.yaml --gvc my-gvc > cpln-manifest.yaml

# Or convert and apply in one step
cpln apply --file k8s-manifest.yaml --k8s true
```

**Options:**
- `--file` (required): Path to a K8s YAML/JSON file, a directory containing multiple YAML/JSON files (including subdirectories), or `-` for stdin.
- `--gvc`: Set GVC name in workload links. Without this, links contain `{{GVC}}` placeholder.
- `--protocol`: Override port protocol for all containers: `http`, `http2`, `grpc`, `tcp`.
- `--verbose`: Show original K8s resources with ignored properties highlighted in yellow.

### Step 3: Validate Workload Type Detection

The converter determines workload type by analyzing the K8s spec:

| Condition | CPLN Type | Notes |
|:---|:---|:---|
| Job or CronJob resource | `cron` | CronJobs preserve schedule; Jobs get default schedule `* * * * *` |
| Any container mounts a volumeset (from PVC or volumeClaimTemplates) | `stateful` | Highest priority for non-cron resources |
| No ports, multiple ports, gRPC health probes, or rollout options present | `standard` | Explicitly confirmed as standard; rollout options come from K8s strategy, updateStrategy, minReadySeconds, podManagementPolicy |
| None of the above (single port, no gRPC probes, no rollout options, no volumes) | `standard` | Default type — all non-cron workloads start as standard |

Verify the converted type matches user expectations. Override in the YAML if needed.

### Step 4: Check Known Issues

1. **GVC placeholder**: Without `--gvc`, converted manifests use `{{GVC}}` placeholder in workload links — replace with actual GVC name before applying, or re-run with `--gvc`.
2. **Port protocol inference**: The converter uses a multi-level strategy (in priority order):
   - Service `appProtocol` field (highest)
   - Service port name prefix (e.g., `grpc-api` → gRPC)
   - Container port name prefix (e.g., `http-web` → HTTP)
   - Health probe type (grpc → gRPC, httpGet → HTTP, tcpSocket → TCP)
   - Well-known port numbers (e.g., 50051 → gRPC, 8080 → HTTP)
   - Falls back to `tcp` if nothing matches
3. **Ingress → Domain**: Host + path rules are mapped to domain routes. All converted domains use port 443, protocol http2, dnsMode cname, and http01 certificate challenge. Wildcard hosts (`*.example.com`) set `acceptAllSubdomains: true` (requires a Dedicated Load Balancer on the GVC). The converter needs the referenced Services and workloads in the same file to resolve routes.
4. **Secret type mapping** (in processing order):
   - `kubernetes.io/dockerconfigjson` → `docker`
   - Any secret with a key named `payload` (regardless of K8s type) → `opaque`
   - `kubernetes.io/basic-auth` → `userpass`
   - Everything else → `dictionary` (including `kubernetes.io/tls`, which is validated for `tls.crt` and `tls.key` but stored as a dictionary)
   - ConfigMaps → always `dictionary`
   - If a secret has both `data` and `stringData`, it's always `dictionary` (merged together)
5. **PVC → VolumeSet**: Default performance class is `general-purpose-ssd`. High-throughput SSD is used when StorageClass parameters match: `io1`, `io2` (AWS), `pd-extreme` (GCP), `UltraSSD_LRS` (Azure), `thick` (VMware), `fast`, `persistent_1`. Default capacity is 10GB. File system type defaults to `ext4`.
6. **Service → Firewall**: LoadBalancer services or Ingress routing to a workload → external inbound allowed (`0.0.0.0/0`). Otherwise, external inbound is blocked. All workloads get external outbound allowed by default.
7. **Auto-generated identity and policy**: When workloads reference secrets (via env vars or volume mounts), the converter creates an identity (`identity-{workload-name}`) and a policy (`policy-{workload-name}`) granting `reveal` permission on referenced secrets.

### Step 5: Validate Before Applying

Review the converted manifest against the **cpln-cli** skill's verification checklist before applying. Key things to check:
- Workload type matches use case and autoscaling strategy is compatible
- Firewall rules allow required traffic (both inbound and outbound default to deny on the platform)
- Secret references use `cpln://secret/NAME` format with identity and policy in place
- Image references have no `docker.io/` prefix
- Port numbers match what containers actually listen on
- Resource ordering is correct in multi-resource files (GVC before workloads, identity before workloads, secret before policies)

### Step 6: Apply

Use the deployment-orchestrator agent to apply with correct dependency ordering, or apply directly:

```bash
# Apply converted output
cpln convert --file k8s.yaml --gvc my-gvc | cpln apply --file -

# Or convert and apply in one step
cpln apply --file k8s.yaml --k8s true

# Delete converted resources
cpln delete --file k8s.yaml --k8s true
```

## Kubernetes Helm Chart Migration

For users migrating existing Kubernetes Helm charts to Control Plane, there are two approaches:

### Approach 1: Convert to CPLN resources (quick)

Render the Helm chart to plain K8s manifests, then convert:

```bash
# Pipe directly to cpln convert
helm template my-release ./chart -f values.yaml | cpln convert --file - --gvc my-gvc

# Or save to a file first
helm template my-release ./chart -f values.yaml > rendered-k8s.yaml
cpln convert --file rendered-k8s.yaml --gvc my-gvc
```

Include all necessary values files, `--set` overrides, and `--dependency-update` just as you would for a normal Helm render. The output is plain CPLN resources you can apply directly.

### Approach 2: Convert to a CPLN Helm chart (structured)

If the user wants to maintain a Helm-based workflow on Control Plane:

1. Render the K8s chart: `helm template my-release ./chart -f values.yaml > rendered-k8s.yaml`
2. Convert to CPLN resources: `cpln convert --file rendered-k8s.yaml --gvc my-gvc > cpln-resources.yaml`
3. Manually create a new Helm chart structure (`helm create my-cpln-chart`)
4. For each converted CPLN resource, create a template file under `templates/`
5. Replace hardcoded values with Helm `{{ .Values.* }}` placeholders
6. Define defaults in `values.yaml`
7. Deploy with `cpln helm install my-release ./my-cpln-chart --gvc my-gvc`

This approach requires manual work to parameterize the converted output, but gives you a reusable, version-controlled CPLN Helm chart.

## Docker Compose Migration (`cpln stack`)

> **Firewall default mismatch — read before writing native manifests.**
> `cpln stack` defaults external outbound to **open** for all services that expose ports. Native Control Plane workload manifests default external outbound to **blocked**. If you are writing CPLN manifests by hand (rather than using `cpln stack` directly), you must add explicit outbound rules for every external API, database, or service your workload calls — otherwise it silently cannot reach anything outside the platform. This is the most common failure mode for manual Docker Compose migrations.
>
> ```yaml
> firewallConfig:
>   external:
>     outboundAllowCIDR:
>       - 0.0.0.0/0   # or restrict to specific CIDRs/hostnames
> ```

### Key Differences

1. **Service URLs must be rewritten**: `http://service-name:port` → `http://workload-name.GVC_NAME.cpln.local:port`
2. **`x-cpln` blocks replace entire spec sections** (not merge). Each top-level key in `x-cpln` replaces the corresponding key in `workload.spec`. Any valid workload spec key can be overridden:
```yaml
services:
  web:
    image: my-app:latest
    x-cpln:
      type: serverless
      defaultOptions:
        autoscaling:
          minScale: 0
          maxScale: 10
```
3. **Volumes → Volume Sets**: Named volumes become volumesets (10GB, ext4, general-purpose-ssd defaults). Having volumes makes the workload type `stateful`.
4. **Networks**: Default (no networks defined) = all services can reach each other via `inboundAllowType: workload-list`. Named networks = only services in the same network are added to the workload's inbound allow list. `network_mode: host` = external inbound allowed. `network_mode: none` = no outbound. `network_mode: service:other` = shares network with another service.
5. **Port protocol**: Specify in the port string: `"8080:80/http"`, `"50051:50051/grpc"`, `"9000:9000/http2"`, `"5432:5432/tcp"`. Valid protocols: `http`, `http2`, `tcp`, `grpc`. If no protocol suffix is specified, the port has no protocol set (undefined).
6. **Defaults**: CPU `42m`, memory `128Mi`. External inbound allowed if `ports` are defined or `network_mode: host`. External outbound always allowed unless `network_mode: none`. Capacity AI enabled only if reservations < limits (CPU or memory); disabled if GPU or stateful. Otherwise disabled by default.
7. **Secrets and configs**: Both become CPLN `opaque` secrets (with `encoding: plain`). Default mount path `/run/secrets/{name}` (if target path is not absolute). Identities (`{service-name}-identity`) and policies (`{secret-name}-policy` with `reveal` permission) are auto-created when secrets are referenced.
8. **Healthcheck → readiness probe**: `test` → `exec.command`, `interval` → `periodSeconds`, `timeout` → `timeoutSeconds`, `start_period` → `initialDelaySeconds`, `retries` → `failureThreshold`. Readiness probe is omitted if healthcheck is `undefined`, `disable: true`, or test starts with `NONE`. String commands are wrapped with `/bin/sh -c`; `CMD` arrays use direct execution; `CMD-SHELL` arrays are wrapped with `/bin/sh -c`.
9. **GPU**: Hardcoded to NVIDIA T4 quantity 1. When GPU is detected: minimum CPU `2000m`, minimum memory `7168Mi` (overrides defaults), Capacity AI disabled.
10. **Limitations**: Directory bind mounts not supported (use named volumes or file bind mounts — files are auto-converted to secrets). `depends_on` ordering ignored. `links` ignored.

### Workflow

```bash
# Deploy from docker-compose.yml
cpln stack deploy

# Deploy with specific GVC
cpln stack deploy --gvc my-gvc

# Preview the generated manifest first (NOT "cpln stack convert" — that doesn't exist)
cpln stack manifest

# Delete all resources from a compose deployment
cpln stack rm
```

**Options for `stack deploy`:**
- `--directory`, `--dir`: Path to parent folder of docker-compose file
- `--compose-file`: Name of the compose file if not using default name
- `--build`: Build images (default: true)
- `--gvc`: Override GVC

**Options for `stack manifest`:**
- Same as deploy, except `--build` defaults to false
- Supports `--output` format options

## Helm Chart Deployment (`cpln helm`)

**Critical**: Helm charts for `cpln helm` must contain **only Control Plane resource definitions** (kinds like `gvc`, `workload`, `secret`, `identity`, `policy`, `volumeset`, `domain`). Charts with standard Kubernetes manifests (`apiVersion`, `metadata` fields) will fail with an error. This is NOT a K8s-to-CPLN conversion tool.

```bash
# Install a release
cpln helm install my-release ./chart
cpln helm install my-release ./chart --gvc my-gvc
cpln helm install my-release oci://registry/chart --version 1.0.0

# Upgrade a release
cpln helm upgrade my-release ./chart
cpln helm upgrade my-release ./chart --install  # install if doesn't exist

# List releases (lists across all GVCs in the org — no --gvc flag)
cpln helm list

# View release history
cpln helm history my-release

# Preview rendered output without deploying
cpln helm template my-release ./chart

# Rollback to previous revision
cpln helm rollback my-release
cpln helm rollback my-release 2  # specific revision

# View release details
cpln helm get manifest my-release
cpln helm get values my-release
cpln helm get all my-release

# Uninstall a release
cpln helm uninstall my-release
```

### Key Helm Concepts

- **Release names**: DNS-1123 compliant, lowercase alphanumeric + hyphens, max 53 chars. Use `--generate-name` for auto-generated names.
- **Release state**: Stored in an opaque secret. Tracks all resources for upgrade diffing and rollback.
- **Injected values**: `cpln.org` and `cpln.gvc` are auto-injected — don't define a top-level `cpln` key in values.yaml.
- **GVC-scoped resources** (`workload`, `identity`, `volumeset`) require `--gvc` or a GVC in your profile context.
- **Revision history**: Default 10 revisions. Use `--history-limit N` on upgrade (must be passed every time or it resets to 10).
- **Secret change detection**: Workloads referencing secrets are auto-tagged with content hashes — secret changes trigger redeployment.
- **Resource protection**: Add `helm.sh/resource-policy: keep` tag to prevent deletion on upgrade/uninstall.
- **Tags carry over** between revisions (unlike `--set` values which must be re-passed every time).

## Post-Migration Checklist

- [ ] All workload types are correct for the use case
- [ ] Firewall rules allow required traffic (check external inbound/outbound)
- [ ] Secrets are correctly typed and accessible (identity + policy created)
- [ ] Volume sets have adequate storage sizing and correct performance class
- [ ] Service-to-service URLs use `http://WORKLOAD.GVC.cpln.local:PORT` format
- [ ] Domain routing matches original Ingress rules (check path types and workload links)
- [ ] Health probes are configured for each workload
- [ ] Environment variables are correctly mapped
- [ ] For Helm: charts contain only CPLN resources (no K8s manifests)
- [ ] `{{GVC}}` placeholders replaced if `--gvc` was not provided during conversion
