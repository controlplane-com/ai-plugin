---
name: migration-patterns
description: "Migrate workloads from Kubernetes, Docker Compose, or Helm to Control Plane. Use when the user asks to convert k8s manifests, a docker-compose.yml, or Helm charts, or to move an existing app onto the platform."
---

# Migrating to Control Plane

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Each source format has its own converter, and they are not interchangeable: Kubernetes through `cpln convert`, Docker Compose through `cpln stack`, a Helm chart of Control Plane resources through `cpln helm`. All three are **CLI-only — there is no MCP converter.** The dominant failure is hand-translating a Compose/k8s/Helm artifact into Control Plane YAML — even one "small enough to do by hand" — instead of running the tool and then reviewing what it left behind. The converter gets the mechanical translation right; your value is the gap analysis on top of it. If asked to translate by hand, push back: convert first, then work through the fix-ups.

## Pick the conversion path

| Source | Convert (CLI-only) | One-shot deploy |
|---|---|---|
| Kubernetes manifests | `cpln convert -f k8s.yaml --gvc GVC` | `cpln apply -f k8s.yaml --k8s true` |
| Kubernetes Helm chart | `helm template R ./chart \| cpln convert -f - --gvc GVC` | — |
| Docker Compose | `cpln stack manifest --gvc GVC` (preview) | `cpln stack deploy --gvc GVC` |
| Helm chart of CPLN resources | — | `cpln helm install R ./chart --gvc GVC` |

`cpln helm` does **not** convert Kubernetes manifests — its charts must render only Control Plane kinds. There is no `cpln stack convert`; `cpln stack manifest` previews the generated YAML.

## Kubernetes (`cpln convert`)

`cpln convert -f FILE [--gvc GVC]` reads a single file, a directory (recursive), or `-` for stdin, and writes Control Plane YAML. `cpln apply -f FILE --k8s true` runs the same converter and applies the result in one step. Resources that become their own Control Plane resource:

| K8s resource | Control Plane resource |
|---|---|
| Deployment, StatefulSet, ReplicaSet, ReplicationController, DaemonSet | Workload (type derived) |
| CronJob | Workload (cron, schedule from spec) |
| Job | Workload (cron, default schedule `* * * * *`) |
| Secret | Secret (type-mapped, below) |
| ConfigMap | Secret (dictionary) |
| Ingress | Domain (with routes) |
| PersistentVolumeClaim | VolumeSet |

Resources that shape the conversion without becoming their own resource: **Service** (port-protocol inference, public-exposure detection that sets the workload firewall, ingress route resolution), **HorizontalPodAutoscaler** (workload `minScale`/`maxScale`/`scaleToZeroDelay`/CPU target), **ServiceAccount** (image pull-secret extraction), **PersistentVolume + StorageClass** (volumeset capacity, performance class, filesystem), **EndpointSlice** (pod mapping for selectorless services).

**Workload type — `cron > stateful > standard`:** a Job/CronJob becomes `cron`; otherwise any container mounting a volumeset (from a PVC or `volumeClaimTemplates`) becomes `stateful`; everything else is `standard`. The converter never emits `serverless` or `vm` — switch a workload to those yourself after converting.

**Secret type mapping:**

| K8s secret | Control Plane type |
|---|---|
| `kubernetes.io/dockerconfigjson` | `docker` |
| any data key named `payload` | `opaque` |
| `kubernetes.io/basic-auth` | `userpass` |
| `kubernetes.io/tls` | `dictionary` (validated for `tls.crt`/`tls.key`, stored as a dictionary) |
| everything else / ConfigMap | `dictionary` |

**PVC performance class:** `io1`, `io2`, `pd-extreme`, `UltraSSD_LRS`, `thick`, `fast`, `persistent_1` map to `high-throughput-ssd` (matched on the StorageClass parameter value); everything else — `gp2`, `gp3`, the default — maps to `general-purpose-ssd`.

**Port protocol** (when `--protocol` is not forced): Service `appProtocol` wins outright; otherwise the converter gathers hints from the Service and container port-name prefixes, the probe type, and the port number, then picks the most specific (grpc > http2 > http > tcp); default `tcp`.

The converter auto-creates an identity `identity-<workload>` and policy `policy-<workload>` granting `reveal` for every workload that references secrets. When `--gvc` is omitted, workload links carry a `{{GVC}}` placeholder — replace it before applying.

## What `cpln convert` leaves for you

The converter translates structure faithfully but **warns on only two things** — a ConfigMap/Secret name collision (it renames the ConfigMap with a `-config` suffix) and an `acceptAll*` domain needing a dedicated load balancer. Everything below changes or disappears **silently**, so diff the source against the output.

- **Scaling is pinned, not autoscaled.** A converted workload gets `minScale = maxScale =` the Deployment's `replicas` (or `1` if unset) with `capacityAI: false` — no headroom. An HPA, if present, supplies min/max and a CPU target. Raise `maxScale` above `minScale` for anything that should scale, keep customer-facing `minScale ≥ 2`, and consider Capacity AI (autoscaling-capacity skill).
- **Silently dropped from the pod spec** (the workload runs, but differently): `envFrom` (bulk ConfigMap/Secret env — re-add the keys as `env` or a mounted dictionary secret), `initContainers` (migrations/setup — run as a separate cron workload or an entrypoint step), `startupProbe` (only liveness/readiness carry over), container-level `securityContext` (only the pod-level `securityContext.fsGroup` carries over, as `filesystemGroupId`), and `hostPath` volumes. `emptyDir` becomes a `scratch://` volume.
- **Not converted at all** (no resource, no warning): NetworkPolicy, PodDisruptionBudget, RBAC, ResourceQuota/LimitRange, ServiceMonitor and other CRDs, and Namespaces — every namespace collapses into the one target GVC. Re-express network rules as the workload firewall (firewall-networking skill) and RBAC as policies (access-control skill).
- **Images stay literal, sizing is minimal.** `image: nginx:1.25` is kept verbatim, not rewritten to an internal `//image/` ref. `imagePullSecrets` (pod or ServiceAccount) carry over as `//secret/NAME`, but the secret must already exist for a private registry to pull. A container with no `resources` set defaults to a tiny `50m` CPU / `128Mi` memory — size it for production.

## Docker Compose (`cpln stack`)

`cpln stack deploy` (alias `up`) builds and deploys; `cpln stack manifest` previews the generated YAML without deploying; `cpln stack rm` (alias `down`) tears down. All take `--dir`/`--directory` and `--compose-file`. `--build` defaults `true` for `deploy` (local `docker build` for `linux/amd64`, then push as `<service>:1.0`) and `false` for `manifest`. Conversion rules:

- **Workload type:** `standard`, or `stateful` if the service attaches a named volume.
- **Volumes:** a named volume becomes a VolumeSet (stateful). A **file** bind mount becomes an opaque secret mounted at the target path. A **directory** bind mount is rejected with an error — split it into individual file bind mounts.
- **Ports:** `"PORT[:TARGET]/PROTO"` where `PROTO` is `http`, `http2`, `tcp`, or `grpc`; with no `/PROTO` suffix the port has no protocol set. Example: `"50051:50051/grpc"`.
- **Resources:** default `cpu: 42m`, `memory: 128Mi` (override via `deploy.resources.limits`). A GPU forces a minimum `cpu: 2000m`, `memory: 7168Mi`.
- **Firewall:** external inbound is opened (`0.0.0.0/0`) when the service has `ports` or `network_mode: host`; outbound is open unless `network_mode: none`.
- **Secrets/configs:** compose `secrets` and `configs` become opaque secrets with an auto-created identity and a `reveal` policy.

**`x-cpln` override block:** any top-level key under a service's `x-cpln` **replaces that entire `spec.<key>` section wholesale** (it does not deep-merge) — there is no allowlist, so any spec field works (`type`, `containers`, `defaultOptions`, `firewallConfig`, `identityLink`, …). Overriding `containers` means restating the full container spec.

```yaml
services:
  api:
    image: my-api:latest
    x-cpln:
      type: serverless              # replaces the derived workload type
      defaultOptions:               # replaces the whole defaultOptions block
        capacityAI: false
        autoscaling: { minScale: 2, maxScale: 10 }
```

`cpln stack` does **not** rewrite service URLs in your code or config. Update them to the internal form `<workload>.<gvc>.cpln.local[:<port>]` (e.g. `http://redis:6379` becomes `http://redis.GVC.cpln.local:6379`).

## Bind-mounts: content vs config

The decisive question for any bind-mounted file: **does it change between environments, or is it identical in dev/staging/prod?**

| Type | Examples | Where it goes |
|---|---|---|
| **Application content** — versioned with the code, same everywhere | `index.html`, JS/CSS bundle, fonts, ML model weights | Bake into the image (`COPY` in the Dockerfile), or serve from a CDN |
| **Configuration** — env-specific values | `nginx.conf` with `proxy_pass`, app config with env URLs, `.env` | Opaque secret mounted as a file volume — the ConfigMap equivalent |

Baking config into the image couples that image to one environment: a hostname or feature-flag change then forces a rebuild. Mounting application content as secret volumes is the opposite mistake — it decouples content from its image version and makes rollbacks strange. A single container's migration is usually **mixed**, decided file by file. Rule of thumb: if changing the file between environments would not count as a code change, it is config and belongs in a secret volume.

Workloads mount secrets as read-only files via `cpln://secret/<name>` volumes (the `workload`/`stateful-storage` skills own the mechanism; `get_resource_schema` for `workload` gives the exact shape):

- **Opaque** (single config file): the path needs at least one subpath; the last segment becomes the file name and holds the `payload`.
- **Dictionary** (multi-key ConfigMap): mount the secret at a directory path and each key becomes a file.
- **Docker / GCP / Azure SDK**: mounted as a single file `___cpln___.secret` in the path directory.

So an nginx workload migrates *mixed*: `index.html` baked into a custom image, while `nginx.conf` mounts from a `cpln://secret/<name>` opaque secret at `/etc/nginx/conf.d/default.conf`.

## Helm (`cpln helm`)

`cpln helm install|upgrade|uninstall|list|template` manages releases of charts that render **only Control Plane kinds**. A rendered object carrying `apiVersion` or `metadata`, or an unknown kind, aborts with `ERROR: Some resources in the rendered template are not CPLN resources`. To migrate an existing Kubernetes Helm chart, render it first and pipe through the converter: `helm template R ./chart | cpln convert -f -`.

- `cpln.org` and `cpln.gvc` (plus `globals.cpln.*` / `global.cpln.*`) are injected as `--set` overrides — don't define a top-level `cpln` key in `values.yaml`, it gets clobbered.
- Release state is an opaque secret per revision; `cpln helm list` is org-scoped and takes no `--gvc`.
- GVC-scoped kinds (`workload`, `identity`, `volumeset`) need `--gvc` or a profile GVC; org-scoped kinds like `domain` do not.

Release-name rules, `--history-limit`, OCI charts, and `--wait` are general helm-release operations — the gitops-cicd and cpln skills own those.

## Exporting to Terraform / IaC

When the target is Infrastructure-as-Code rather than live resources, turn the converted Control Plane YAML into HCL with `mcp__cpln__convert_to_terraform` (dry-run validated against the API first, so the HCL always matches a schema-valid resource), or capture already-created resources with `mcp__cpln__export_terraform`. `mcp__cpln__list_terraform_kinds` and `mcp__cpln__export_terraform_batch` are in the `full` profile. The `iac-terraform-pulumi` skill owns the full Terraform/Pulumi story, including `terraform import`.

## Verify

- After `cpln convert`: confirm each workload's derived type, scaling (`maxScale` raised where needed), port protocols (gRPC/HTTP2), ingress-to-domain routes, and that any `{{GVC}}` placeholder is replaced.
- After create/apply: `cpln apply -f cpln.yaml --ready`, or poll `mcp__cpln__list_deployments` until each workload reports ready. Pair every mutation with a read.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `cpln helm`: "…not CPLN resources" | Chart renders Kubernetes objects (`apiVersion`/`metadata`). Render then convert: `helm template \| cpln convert`. |
| Env vars missing, or a setup step never ran | `envFrom` and `initContainers` are dropped silently — re-add env keys as `env`/a dictionary secret, and run init logic as a cron workload or entrypoint step. |
| Workload won't scale under load | `minScale = maxScale` from the source replicas — raise `maxScale` (and enable Capacity AI / a metric). |
| Compose: "Directory bind mount found" | Directory bind mounts are rejected — mount individual files (each becomes a secret). |
| App can't reach another service | The converters don't rewrite URLs — point them at `<workload>.<gvc>.cpln.local[:port]`. |
| Private image won't pull | The image string is kept literal; create the pull secret it references and link it (image skill). |
| Deployment stuck after converting | The workload references a secret without an identity/policy; the converter adds `identity-<wl>`/`policy-<wl>` — if you re-authored, wire `reveal` yourself (access-control skill). |

## Quick reference

### MCP tools

- `mcp__cpln__create_workload` / `create_gvc` / `create_secret_opaque` (and the other `create_secret_<type>`) / `create_identity` / `create_volumeset` — author converted resources with production-grade defaults
- `mcp__cpln__get_resource_schema` — exact shape before hand-editing or re-authoring a converted manifest
- `mcp__cpln__list_deployments` — poll converted workloads to ready
- `mcp__cpln__convert_to_terraform` / `mcp__cpln__export_terraform` — converted YAML or live resources to HCL (`iac-terraform-pulumi` skill)

The converters themselves (`cpln convert`, `cpln stack`, `cpln helm`, `cpln apply --k8s`) are CLI-only. In CI/CD, `CPLN_TOKEN` + `cpln apply -f` applies the converted manifest headlessly.

### Related skills

| Skill | Use for |
|---|---|
| workload | the spec the converter emits; deploy/diagnose flow, injected `CPLN_*` vars |
| cpln | the CLI that runs every converter; `apply` ordering, `exec`/`logs` |
| autoscaling-capacity | giving converted workloads scaling headroom and Capacity AI |
| stateful-storage | volumeset shape for converted PVCs and compose named volumes |
| iac-terraform-pulumi | turning converted YAML into Terraform or Pulumi |
| template-catalog | deploy a database from a template instead of converting one |

## Documentation

- [cpln convert](https://docs.controlplane.com/guides/cli/cpln-convert.md)
- [Compose Deploy](https://docs.controlplane.com/guides/compose-deploy.md)
- [cpln helm](https://docs.controlplane.com/guides/cpln-helm.md)
- [cpln apply](https://docs.controlplane.com/guides/cpln-apply.md)
- [Workload Volumes](https://docs.controlplane.com/reference/workload/volumes.md)
