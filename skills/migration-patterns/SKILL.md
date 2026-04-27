---
name: cpln-migration-patterns
description: "Migrates workloads from Kubernetes, Docker Compose, or Helm charts to Control Plane. Use when the user asks about converting k8s manifests, docker-compose.yml, or Helm charts to Control Plane YAML. Covers resource mapping (Deployment to workload, Ingress to domain), secret conversion, workload type detection, and post-migration validation."
version: 1.0.0
---

# Migration Patterns

## Migration Paths

Pick the path by source, not by destination tool — the tools are not interchangeable.

| Source | Tool | Command |
|:---|:---|:---|
| Kubernetes manifests | `cpln convert` | `cpln convert --file k8s.yaml --gvc my-gvc` |
| Kubernetes manifests (convert + apply) | `cpln apply --k8s` | `cpln apply --file k8s.yaml --k8s true` |
| Kubernetes Helm chart | `helm template` piped to `cpln convert` | `helm template R ./chart -f values.yaml \| cpln convert --file - --gvc my-gvc` |
| Docker Compose | `cpln stack` | `cpln stack deploy --gvc my-gvc` |
| Helm chart of CPLN resources | `cpln helm` | `cpln helm install R ./chart --gvc my-gvc` |

`cpln helm` does NOT convert Kubernetes manifests — charts must contain only Control Plane kinds. `cpln stack convert` does NOT exist; use `cpln stack manifest` to preview.

## Migration Workflow Discipline — Use the Conversion Tool First

**Hand-translating Compose / Kubernetes / Helm into Control Plane YAML is forbidden as the entry point of a migration**, even when you expect the converter output to need fix-ups. Always run the conversion tool first.

| Source format | First-step command (mandatory) | Notes |
|---|---|---|
| Docker Compose | `cpln stack manifest --compose-file docker-compose.yml --gvc <gvc>` | Converts to CPLN YAML *without deploying* — for review + edits. Or `cpln stack deploy --compose-file docker-compose.yml --gvc <gvc>` for one-shot deploy. |
| Kubernetes | `cpln convert --file k8s-manifest.yaml --gvc <gvc>` | Converts to CPLN YAML for review. Or `cpln apply --file k8s.yaml --k8s true --gvc <gvc>` for one-shot. |
| Helm chart | `cpln helm install <release> <chart> --gvc <gvc>` | Direct deploy. Chart contents must produce CPLN-compatible kinds — see "Helm Chart Deployment" below. |

**Why this is mandatory, not a suggestion:**

- The converter handles base translation correctly: resource shape, secret-type mapping, port protocol inference, identity/policy auto-creation, PVC → volumeset, ingress → domain. Re-doing that by hand duplicates work and introduces transcription errors the converter would not have made.
- The converter's output is your starting point for the migration's *gap analysis*: bind-mount triage, internal DNS rewrites, build-step replacements, anti-pattern checks. You cannot gap-analyze something you didn't convert.
- Hand-rolled and converter-rolled outputs diverge in subtle places (auto-created identity/policy names, port protocols, default firewall stance, location handling). Divergence makes future re-runs of the migration painful.

**Anti-patterns to push back against:**

- Writing CPLN workload manifests from scratch when the source is a Compose / k8s / Helm artifact, even when "the source is small enough to translate by hand"
- Running the converter, throwing the output away, and rewriting from scratch "for clarity"
- Using the converter only on parts of the source — translating the rest by hand
- Reasoning "I'll make the conversion explicit by writing it myself" — the AI's value here is the gap analysis on top of the converter's output, not duplicating the converter's work

**If the AI proposes hand-translation as the first step of a migration, push back:** *"Run `cpln stack manifest` (or `cpln convert`) first, then we'll work through the fix-ups."*

## Kubernetes Conversion (`cpln convert`)

### Supported Resources

Resources directly converted to Control Plane equivalents:

| K8s Resource | CPLN Equivalent |
|:---|:---|
| Deployment | Workload (type derived) |
| StatefulSet | Workload (type derived) |
| ReplicaSet, ReplicationController | Workload (type derived) |
| DaemonSet | Workload (type derived) |
| CronJob | Workload (cron, schedule from spec) |
| Job | Workload (cron, default schedule `* * * * *`) |
| Secret | Secret (type-mapped) |
| ConfigMap | Secret (dictionary). For post-convert decisions on file-mount vs. env-var, and the content-vs-config triage when migrating bind-mounted files, see **"Bind-Mounts: Content vs. Config"** below. |
| Ingress | Domain (with routes) |
| PersistentVolumeClaim | VolumeSet |

Resources that are NOT converted to separate CPLN resources but inform the conversion:

| K8s Resource | Role |
|:---|:---|
| Service | Port protocol inference, public-exposure detection (sets workload `firewallConfig`), Ingress route resolution |
| ServiceAccount | Image pull secret extraction |
| HorizontalPodAutoscaler | Sets workload `minScale`, `maxScale`, `scaleToZeroDelay`, CPU target |
| PersistentVolume, StorageClass | Volumeset capacity, performance class, file system type |
| EndpointSlice | Service-to-Pod mapping for selectorless services |

The converter also auto-creates an **identity** (`identity-<workload>`) and **policy** (`policy-<workload>`) per workload that references secrets, granting `reveal` on those secrets.

### Workload Type Detection Priority

**cron > stateful > standard**

1. Job or CronJob resource → **cron**
2. Any container mounts a volumeset (from PVC or volumeClaimTemplates) → **stateful**
3. Everything else → **standard** (this is the default for all non-cron workloads)

### Secret Type Mapping

| K8s Secret Type | CPLN Secret Type |
|:---|:---|
| `kubernetes.io/dockerconfigjson` | `docker` |
| Any secret with a key named `payload` | `opaque` |
| `kubernetes.io/basic-auth` | `userpass` |
| `kubernetes.io/tls` | `dictionary` (validated for tls.crt/tls.key but stored as dictionary) |
| Everything else / ConfigMap | `dictionary` |

### PVC to VolumeSet

| K8s Storage Class | CPLN Performance Class |
|:---|:---|
| Default, `gp2`, `gp3`, and others | `general-purpose-ssd` |
| `io1`, `io2` (AWS), `pd-extreme` (GCP), `UltraSSD_LRS` (Azure), `thick` (VMware), `fast`, `persistent_1` | `high-throughput-ssd` |

### Usage

```bash
# --gvc is optional; when omitted, workload links contain a {{GVC}} placeholder
cpln convert --file k8s-manifest.yaml --gvc my-gvc > cpln-manifest.yaml

# One-step convert + apply (equivalent to convert | apply --file -)
cpln apply --file k8s-manifest.yaml --k8s true
```

`--file` accepts a single file, a directory (recursive), or `-` for stdin.

### Port Protocol Inference

When `--protocol` is not set, each container port is resolved in this priority order (first match wins, default `tcp`): Service `appProtocol` → Service port name prefix → container port name prefix → liveness/readiness probe type → well-known port number.

### Post-Conversion Fixups

1. If `--gvc` was NOT passed, replace the `{{GVC}}` placeholder in workload links with the actual GVC name
2. Verify workload type matches your expectations
3. Check port protocol detection (gRPC, HTTP/2)
4. Validate Ingress → Domain route mapping
5. Update service-to-service URLs in your app code to `<workload>.<gvc>.cpln.local[:port]`

## Docker Compose Migration (`cpln stack`)

### Service-to-Service URLs (Manual Update)

`cpln stack` does NOT automatically rewrite service URLs inside your application code or config. Before deploying, update service-to-service URLs in your Compose file / app code to the Control Plane internal DNS format:

| Compose (before) | Control Plane (after) |
|:---|:---|
| `http://redis:6379` | `http://redis.my-gvc.cpln.local:6379` |
| `http://api:3000` | `http://api.my-gvc.cpln.local:3000` |

Format: `<workload-name>.<gvc>.cpln.local[:<port>]`.

### x-cpln Override Block

Add platform-specific overrides in the compose file. Each top-level key under `x-cpln` replaces the entire corresponding section in the generated workload `spec`:

```yaml
services:
  api:
    image: my-api:latest
    x-cpln:
      type: serverless           # Overrides derived workload type
      defaultOptions:            # Replaces entire defaultOptions block
        capacityAI: false
        autoscaling:
          minScale: 0
          maxScale: 10
```

Recognized keys: `type`, `containers`, `defaultOptions`, `firewallConfig`, `identityLink`, `supportDynamicTags`, `loadBalancer`, `rolloutOptions`, `securityOptions`, `localOptions`.

**Warning:** `x-cpln` REPLACES entire top-level spec sections, it does NOT merge. If you override `containers`, you must include the full container spec.

### Commands

```bash
cpln stack deploy --gvc my-gvc                          # Deploy compose project (aliases: up)
cpln stack manifest --gvc my-gvc > cpln-manifest.yaml   # Preview generated manifest
cpln workload get --gvc my-gvc                          # List deployed workloads
cpln stack rm --gvc my-gvc                              # Tear down (aliases: down)
```

Options accepted by `deploy`, `manifest`, and `rm`: `--directory`/`--dir`, `--compose-file`. `deploy` and `manifest` also accept `--build` (default `true` for deploy, `false` for manifest). There is no `cpln stack convert` subcommand.

### Compose Conversion Gotchas

- **Port protocol suffix**: `"PORT[:TARGET]/PROTO"` where `PROTO` ∈ `http | http2 | tcp | grpc`. Without a suffix the port has no protocol set. Example: `"50051:50051/grpc"`.
- **Resource defaults**: `cpu: 42m`, `memory: 128Mi` (override via `deploy.resources.limits`). With GPU: min CPU `2000m`, min memory `7168Mi`.
- **Firewall derivation**: external inbound is allowed (`0.0.0.0/0`) when the service has `ports` OR `network_mode: host`. Outbound is blocked only for `network_mode: none`.
- **Stateful detection**: any named volume attached to a service makes that workload `stateful`.
- **Secrets/configs** become CPLN `opaque` secrets with auto-created identity + policy (reveal permission). Bind-mounts can be application content (HTML/JS/CSS, model weights, fonts) or environment-specific config (nginx.conf with `proxy_pass`, app config with env-specific URLs); these go to different places — see the next section.

## Bind-Mounts: Content vs. Config — Two Different Migrations

The single most important question when migrating bind-mounted files: **does this file change between environments, or is it the same in dev / staging / prod?**

| Type | Examples | Where it goes on Control Plane |
|---|---|---|
| **Application content** — versioned with the code, same in every environment | `index.html`, compiled JS/CSS bundle, font files, ML model weights | **Bake into the image.** `COPY` it in the Dockerfile. Or serve from a CDN / object store for SPAs. |
| **Configuration** — has env-specific values (hostnames, ports, routing, feature flags, paths, credentials) | `nginx.conf` with `proxy_pass http://api.<gvc>.cpln.local:3000/`, app config with env-specific URLs, `.env` files | **Opaque secret mounted as a file volume** at the target path — the ConfigMap equivalent. |

**Why the distinction matters:** baking config into the image couples that image to one environment. Want to deploy to staging next? Rebuild the image. Want to switch the upstream API hostname? Rebuild. That's the regression Kubernetes solved with ConfigMaps. Conversely, mounting *application content* via secret volumes is overkill — the content moves in lockstep with the code; image versioning is the right control surface.

**Rule of thumb:** if changing this file between environments wouldn't be considered a code change, it's config and belongs in a secret volume. If the file changes only when the application itself is updated, it belongs in the image.

### Mounting config via secret volumes — the canonical pattern

Control Plane workloads can mount opaque secrets as **read-only files at specific paths** via the volume mechanism. URI scheme `cpln://secret/<name>`. Reference: `docs/reference/workload/volumes.mdx`.

Worked example — nginx that serves baked-in HTML and uses a mounted nginx.conf:

```yaml
# 1. Opaque secret holding the env-specific nginx.conf
kind: secret
type: opaque
name: web-nginx-conf
data: { payload: |
  server {
    listen 80;
    location /api/ { proxy_pass http://api.<gvc>.cpln.local:3000/api/; }
    location / { try_files $uri $uri/ /index.html; }
  }
}
---
# 2. Identity + policy granting reveal on the config secret
kind: identity
name: web-identity
---
kind: policy
name: web-secrets-access
target: secret
targetLinks: [ //secret/web-nginx-conf ]
bindings:
  - permissions: [reveal]
    principalLinks: [ //gvc/<gvc>/identity/web-identity ]
---
# 3. CUSTOM nginx image with index.html baked in (application content),
#    but nginx.conf mounted from the secret (environment-specific config)
kind: workload
name: web
spec:
  identityLink: //gvc/<gvc>/identity/web-identity
  containers:
    - name: web
      image: //image/feedback-collector-web:1   # built from a Dockerfile that COPYs index.html into nginx:alpine
      ports: [{ protocol: http, number: 80 }]
      volumes:
        - uri: cpln://secret/web-nginx-conf
          path: /etc/nginx/conf.d/default.conf
```

Dockerfile for `feedback-collector-web`:

```dockerfile
FROM nginx:alpine
COPY web/index.html /usr/share/nginx/html/index.html
# nginx.conf is NOT copied — it's mounted from the secret at runtime
EXPOSE 80
```

### Mount semantics by secret type

From `docs/reference/workload/volumes.mdx`:

- **Opaque** (the typical config-file case): mount path must contain at least one subpath; the last path segment becomes the file name and contains the payload. Use this for nginx configs, init scripts, app config files — anything that's a single file.
- **Dictionary**: if the root secret is mounted, the path becomes a directory and each key becomes a file with the value as contents. Useful for migrating multi-key K8s ConfigMaps directly.
- **Docker / GCP / Azure SDK**: mounted as a single file `___cpln___.secret` in the path directory.

### Anti-patterns to avoid

- **Baking environment-specific config into a custom image** ("the simplest fix for the bind-mount problem") — couples the image to one environment, requires a rebuild for any config change. Use a secret volume instead.
- **Mounting application content (HTML/JS/CSS, model weights) as secret volumes** — overkill, decouples content from its image version, makes rollbacks weird. Bake it into the image.

If the AI proposes baking config into a custom image as the migration shortcut, push back. If the AI proposes mounting application content as secret volumes, also push back — the right answer is mixed: content in the image, config in secret volumes, decided file-by-file based on whether the content changes between environments.

## Helm Chart Deployment (`cpln helm`)

```bash
cpln helm install my-release ./chart --gvc my-gvc
cpln helm install my-release oci://registry/chart:tag --gvc my-gvc
cpln helm upgrade my-release ./chart --gvc my-gvc
cpln helm uninstall my-release --gvc my-gvc
cpln helm list --org my-org        # Release list is org-scoped; --gvc is NOT accepted
```

**Important:** `cpln helm` deploys charts that contain **only Control Plane resource definitions**. Charts with standard Kubernetes manifests (objects with `apiVersion` or `metadata` fields) will fail with `ERROR: Some resources in the rendered template are not CPLN resources.` To migrate existing K8s Helm charts, run `helm template` to render them to plain K8s manifests first, then pipe through `cpln convert`.

### Helm Gotchas

- **Release name**: DNS-1123 label (lowercase alphanumeric + `-`, start/end alphanumeric), max **53 chars**. Use `--generate-name` / `-g` for auto-generated names.
- **Injected values**: `cpln.org`, `cpln.gvc` (and `globals.cpln.*`, `global.cpln.*` aliases) are auto-injected as `--set` overrides. Do not define a top-level `cpln` key in `values.yaml` — it will be clobbered.
- **Release state**: stored in an opaque secret per release; release list is org-scoped (no `--gvc` on `helm list`).
- **`--history-limit`**: read per invocation (default `10`). If not re-passed on each `upgrade`, it falls back to the default — it is not persisted on the release.
- **GVC-scoped kinds** (`workload`, `identity`, `volumeset`, `domain`) require `--gvc` or a GVC in your profile context.

## Documentation

For the latest reference, see:

- [cpln convert Guide](https://docs.controlplane.com/guides/cli/cpln-convert.md)
- [cpln helm Guide](https://docs.controlplane.com/guides/cpln-helm.md)
- [Compose Deploy Guide](https://docs.controlplane.com/guides/compose-deploy.md)
- [cpln apply Guide](https://docs.controlplane.com/guides/cpln-apply.md)
- [Kubernetes Operator](https://docs.controlplane.com/core/kubernetes-operator.md)
