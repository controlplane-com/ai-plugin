---
name: cpln
description: "Writes cpln CLI commands and workflows for deploying and managing workloads on Control Plane. Use when the user asks about cpln login, cpln apply, cpln workload, deploying via CLI, container debugging with cpln exec/logs, or any cpln resource command. Covers CLI setup, authentication, the resource command map, deployment workflows, interactive debugging, and hallucination traps."
---

# cpln CLI

**MCP first; the CLI is the fallback** — use it when the MCP server is unavailable or unauthenticated, for the few CLI-only operations, and for interactive debugging or scripted GitOps. **In CI/CD the CLI is the primary interface** — pipelines authenticate non-interactively with a service-account token (`CPLN_TOKEN`) and use it to build/push images (`cpln image build --push`) and apply resources (`cpln apply --ready`). Platform rules (resource model, secrets, destructive ops, production defaults, scale-to-zero, firewall) live in `rules/cpln-guardrails.md`; this skill is the CLI mechanics.

**Never write a `cpln` command from memory.** Verify every verb and flag with `cpln <command> --help` before quoting it. If you cannot cite a verified flag, say so instead of guessing — if something isn't in the resource command map below, assume it isn't real.

## CLI-only operations

Five operations have **no MCP equivalent** — the CLI's primary job:

| Command | Purpose |
|---|---|
| `cpln image build` | Build a container image (Dockerfile or buildpacks) and push to the org registry |
| `cpln image copy` | Copy an image between orgs / registries |
| `cpln port-forward` | Forward a local port to a running workload |
| `cpln convert` | Translate Kubernetes / Compose manifests into Control Plane specs |
| `cpln cp` | Copy files in or out of a running container |

Also CLI-only: interactive debugging (`exec`, `connect`, `logs`) and scripted GitOps (`cpln apply`). Everything else — discovery and CRUD — prefer the MCP tools (`list_*`/`get_*` for discovery, `create_*`/`update_*`/`delete_*` for mutations; e.g. `mcp__cpln__list_workloads`, `mcp__cpln__create_workload`). The `image` commands have no MCP create/update path — read images with `mcp__cpln__get_image` / `mcp__cpln__list_images`, but build/copy stay CLI.

## Setup

```bash
cpln login                                            # interactive (opens browser)
cpln profile update default --org my-org --gvc my-gvc # set defaults
```

For CI/CD, set via your platform's secrets management: `CPLN_TOKEN` (service-account key, from `cpln serviceaccount add-key`), `CPLN_ORG`, `CPLN_GVC`, `CPLN_PROFILE`. Override per-command with `--org`/`--gvc`/`--profile`.

**Never pass `--token`** — it leaks into logs and shell history. Profiles are the primary way to supply tokens and defaults. Inspect context with `cpln profile get <profile>` — **there is no `cpln whoami`.** Explain any profile state changes so operators can revert them.

## Command structure & shared flags

```
cpln <resource> <action> [REF] [--flags]
```

Standalone (break the pattern): `cpln apply`, `cpln delete`, `cpln logs`, `cpln port-forward`, `cpln cp`, `cpln convert`, `cpln login`.

Flags on nearly every command — never list per-command:
- **Context**: `--profile`, `--org`, `--gvc`
- **Output**: `--output`/`-o` (`text|json|yaml|json-slim|yaml-slim|tf|crd|names`), `--color`, `--ts` (`iso|local|age`), `--max` (default 50)
- **Request**: `--token`, `--endpoint`, `--insecure`/`-k`
- **Debug**: `--verbose`/`-v`, `--debug`/`-d`

- **Always use `yaml-slim`/`json-slim` for round-tripping.** Plain `yaml`/`json` include server-side fields (`status`, `id`, `created`, `lastModified`, `links`) that break `cpln apply`.
- **Include `--org` (and `--gvc`) explicitly on every mutation**, even with profile defaults. `--gvc` is on all subcommands of GVC-scoped resources (workload, identity, volumeset) plus helm, stack, apply, convert, cp, delete, port-forward — but **not** on `cpln logs` (GVC goes inside the LogQL query).
- **Cap lists with `--max`** (`--max 0` = all). Omit only when targeting a specific named resource.

## Standard CRUD

| Action | Syntax | Notes |
|---|---|---|
| **List** | `cpln <resource> get` | No args = list all. **There is NO `list` subcommand.** |
| **Get** | `cpln <resource> get REF` | |
| **Create** | `cpln <resource> create --name NAME` | Also `--description`, `--tag K=V` |
| **Delete** | `cpln <resource> delete REF...` | Multiple refs |
| **Edit** | `cpln <resource> edit REF` | Opens YAML in editor. `--replace` |
| **Patch** | `cpln <resource> patch REF --file FILE` | |
| **Tag** | `cpln <resource> tag REF... --tag K=V` | Remove: `--remove-tag K` |
| **Update** | `cpln <resource> update REF --set PROP=VAL` | Also `--unset PROP` |
| **Clone** | `cpln <resource> clone REF --name NEW` | Spec only. Preferred for renames. |
| **Audit** | `cpln <resource> audit [REF]` | `--since`, `--from`, `--to` (ISO 8601 / duration / `now-<duration>`) |
| **Query** | `cpln <resource> query` | See below |

Also: `access-report REF`, `eventlog REF`, `permissions` (no args). **Pair every mutation with a verification read** (`get`, or `get-deployments` for workloads).

### Query

```bash
cpln workload query --match all --tag environment=production --tag region=europe
cpln workload query --match any --rel gvc=gvc-a --rel gvc=gvc-b
cpln workload query --property name=my-workload
```

`--match` (`all` default / `any` / `none`, single value); `--tag KEY=VALUE`, `--property`/`--prop NAME=VALUE` (e.g. `status.phase=running`), `--rel KIND=VALUE` (e.g. `gvc=my-gvc`) — all repeatable. Some `create` commands (gvc, policy, group) accept `--query-match`/`--query-tag`/`--query-property`/`--query-rel` for dynamic targeting. Full language: `query-spec` skill.

## Resource command map

Core anti-hallucination reference. **Scope**: org = needs `--org`; gvc = needs `--org` + `--gvc`; local = no API call.

| Resource | Scope | CRUD | Non-standard subcommands |
|---|---|---|---|
| **workload** | gvc | Full | `connect`, `exec`, `run`, `cron` (get/run/start/stop), `replica` (get/stop), `force-redeployment`, `get-deployments`, `open`, `start`, `stop` |
| **gvc** | org | Full | `add-location`, `remove-location`, `delete-all-workloads` |
| **secret** | org | **No generic create** | 12 type-specific create commands (below), `reveal` |
| **policy** | org | Full | `add-binding`, `remove-binding` |
| **identity** | gvc | Full | — |
| **volumeset** | gvc | Full | `expand`, `shrink`, `snapshot` (create/delete/get/restore), `volume` (delete/get) |
| **domain** | org | Full (no clone) | — |
| **cloudaccount** | org | **No generic create** | `create-aws`, `create-azure`, `create-gcp`, `create-ngs` |
| **image** | org | No create | `build`, `copy`, `docker-login` |
| **agent** | org | Full (no clone) | `info`, `manifest`, `up` |
| **group** | org | Full | `add-member`, `remove-member` |
| **ipset** | org | Full | `add-location`, `remove-location`, `update-location` |
| **serviceaccount** | org | Full (no update) | `add-key`, `remove-key` |
| **mk8s** | org | **No create** | `dashboard`, `join`, `kubeconfig` |
| **user** | org | No create | `invite` |
| **org** | — | **No delete** (immutable) | — |
| **profile** | local | get, delete, update | `login`, `set-default`, `token`. `update` creates if missing (alias: `create`) |
| **helm** | gvc | get | `install`, `upgrade`, `template`, `rollback`, `uninstall`, `list`, `history` |
| **stack** | gvc | — | `deploy`, `manifest`, `rm` |
| **location** | org | Partial | `install`, `uninstall` |
| **auditctx** | org | Full (no delete) | — |
| **quota** | org | get, edit, patch | — |
| **task** | org | get, delete | `complete`, `get-mine` |
| **account** | org | get only | — |
| **rest** | org | get, create, delete, edit, patch | `post`, `put` |
| **operator** | — | — | `install`, `uninstall` |

## Non-standard commands

### cpln apply / cpln delete

```bash
cpln apply --file ./manifests/ --gvc <gvc> --ready  # apply a DIRECTORY — cpln resolves resource order
cpln apply --file all.yaml --ready                  # apply a MULTI-DOC file (resources split by ---)
cpln apply --file workload-update.yaml --ready      # apply ONE resource — incremental updates only
cpln delete --file manifest.yaml                    # delete resources in a file
```

**For multi-resource deploys, apply once via a directory or multi-doc file** — `cpln apply` walks the inter-resource dependency graph automatically. Splitting into multiple calls reintroduces the ordering problem (workloads referencing not-yet-applied secrets, bindings before the identity exists).

- **Single-GVC bundle** (common): pass `--gvc <gvc>`; it fills in the GVC for every GVC-scoped resource that doesn't declare one.
- **Per-resource GVC** (resources span multiple GVCs): declare `gvc:` inline as a top-level field (same level as `kind`/`name`), and apply **without** `--gvc`:

```yaml
kind: workload
name: my-app
gvc: prod          # ← target GVC declared inline
spec: { ... }
---
kind: workload
name: my-app
gvc: staging       # ← same name, different GVC — routed correctly
spec: { ... }
```

Org-scoped resources (secret, policy, domain, image, agent, group, cloudaccount, serviceaccount, ipset, mk8s) ignore the gvc field/flag. `--file`/`-f` required; `--ready` blocks until healthy; `--k8s` auto-converts K8s manifests inline; `--file -` reads stdin.

### cpln logs

```bash
cpln logs '{gvc="GVC", workload="WORKLOAD"}' --org ORG --tail
```

- Query is a **positional argument** (first arg, single quotes, LogQL syntax). `--gvc` is **not** a flag here.
- Labels: `container`, `gvc`, `location`, `provider`, `replica`, `stream`, `workload`. Special: `container="_accesslog"` for HTTP access logs.
- Filters: `|= "error"` (contains), `!= "debug"` (excludes), `|~ "timeout|crash"` (regex).
- Streaming: `--tail`/`-t`/`-f`. **`--follow` does NOT exist.**
- Limit: `--limit N` (default 30, `0` = unlimited). Time: `--since "1h"`, `--from`, `--to`. Full LogQL: `logql-observability` skill.

### cpln secret create — 12 type-specific commands

`cpln secret create` does **not** exist. Use the type-specific variant (all require `--name`; accept `--description`, `--tag`):

| Type | Command | Required flags |
|---|---|---|
| Opaque | `create-opaque` | `--file` or `--payload` |
| Dictionary | `create-dictionary` | `--entry KEY=VAL` (repeatable) |
| Username/Password | `create-userpass` | `--username`, `--password` |
| AWS | `create-aws` | `--access-key`, `--secret-key` |
| GCP | `create-gcp` | `--file` (service account JSON) |
| Azure SDK | `create-azure-sdk` | `--file` |
| Azure Connector | `create-azure-connector` | `--url`, `--code` |
| Docker | `create-docker` | `--file` |
| ECR | `create-ecr` | `--access-key`, `--secret-key`, `--repo` |
| TLS | `create-tls` | `--key`, `--cert` |
| Key Pair | `create-keypair` | `--secret` |
| NATS | `create-nats` | `--account-id`, `--private-key` |

### cpln workload create

```bash
cpln workload create --name APP --image IMAGE --gvc GVC [flags]
```

Key flags: `--type` (`serverless|standard`, default `standard`), `--port`, `--public`, `--identity`, `--env KEY=VALUE`, `--cpu`, `--memory`/`--mem`, `--volume`, `--container-name`. **`stateful` and `cron` CANNOT be created via CLI flags — use `cpln apply --file`.** For internal images use `//image/NAME:TAG`; ensure `--port` matches the container's listening port.

### cpln workload exec / connect / run

- **exec** — run in an existing replica (`--` separator required): `cpln workload exec APP --gvc GVC -- ls -la` (`--container`, `--location`, `--replica`, `--stdin`/`-i`, `--tty`/`-t`)
- **connect** — open a shell: `cpln workload connect APP --gvc GVC` (`--shell`, default bash)
- **run** — temporary workload + command: `cpln workload run --image IMAGE --gvc GVC -- CMD` (`--clone`, `--rm`, `-i`, `--cpu`, `--memory`)
- **cron run** — one-off execution: `cpln workload cron run --image IMAGE --gvc GVC -- CMD` (`--background`/`-b`, `--timeout`/`-t`)

**Replicas are pods.** Get names with `cpln workload replica get`, then pass explicit `--location`, `--replica`, `--container` to `exec`/`logs`/`cp`/`port-forward` — the CLI otherwise picks the first match silently (risky on multi-location workloads).

### cpln policy add-binding

```bash
cpln policy add-binding POLICY --permission reveal --identity //gvc/GVC/identity/ID
```

`--permission` required; at least one principal flag required; **all flags repeatable** (`--email`, `--serviceaccount`, `--group`, `--identity`) — bind multiple permissions to multiple principals in one command.

### cpln port-forward / cp

```bash
cpln port-forward WORKLOAD [LOCAL:]REMOTE... --gvc GVC   # flags: --address, --location, --replica
cpln cp LOCAL WORKLOAD:PATH --gvc GVC                    # copy into a container; reverse the args (WORKLOAD:PATH LOCAL) to copy out
```

### Migration tools

- `cpln convert --file K8S.yaml` — Kubernetes → Control Plane manifest
- `cpln helm install RELEASE CHART --gvc GVC` — Helm charts (and template catalog installs)
- `cpln stack deploy --compose-file FILE --gvc GVC` — Docker Compose

### Volumeset command verbs

Dedicated subcommand per operation — there is **no** `cpln volumeset command create --type <kind>` form:

| Operation | Command | Risk |
|---|---|---|
| Expand volume | `cpln volumeset expand <ref> --new-size <gb> --locations <loc> [--volume-indexes <idx>]` | Safe |
| Create snapshot | `cpln volumeset snapshot create <ref> --snapshot-name <name> --locations <loc>` | Safe |
| Restore snapshot | `cpln volumeset snapshot restore <ref> --snapshot-name <name> --locations <loc>` | Overwrites volume state |
| Delete snapshot | `cpln volumeset snapshot delete <ref> --snapshot-name <name>` | Destructive |
| Delete volume | `cpln volumeset volume delete <ref> --locations <loc> --volume-indexes <idx>` | Destructive (data loss) |
| Shrink volume | `cpln volumeset shrink <ref> --new-size <gb> --locations <loc>` | **DESTRUCTIVE — permanent data loss** |

`shrink` provisions a new, smaller volume and removes the old one — data is **not** migrated. Safe only with built-in redundancy (Kafka replication; Cassandra/CockroachDB), on `ext4`/`xfs` (not `shared`). Apply the destructive-op confirmation from `rules/cpln-guardrails.md` first. Detail: `stateful-storage` skill.

## Commands that don't exist

| Wrong | Correct |
|---|---|
| `cpln secret create` | `cpln secret create-opaque`, `create-aws`, etc. |
| `cpln <resource> list` | `cpln <resource> get` (no args = list all) |
| `cpln logs --follow` | `cpln logs --tail` (or `-t` / `-f`) |
| `cpln workload log` | `cpln logs '{gvc="GVC", workload="WORKLOAD"}'` |
| `cpln cloudaccount create` | `cpln cloudaccount create-aws`, etc. |
| `cpln mk8s create` | `cpln apply --file mk8s-manifest.yaml` |
| `cpln apply` (no `--file`) | `cpln apply --file manifest.yaml` |
| `cpln workload update --identity X` | `cpln workload update REF --set spec.identityLink=//identity/X` |
| `cpln secret update --data '{}'` | `cpln secret edit REF` or `cpln apply --file` |
| `cpln gvc update --location LOC` | `cpln gvc update REF --set 'spec.staticPlacement.locationLinks+=//location/LOC'` |
| `cpln volumeset command create --type <kind>` | Use the dedicated verb (above) |
| `cpln whoami` | `cpln profile list` / `cpln profile get <profile>` |

## Building & referencing images

`cpln image build` containerizes and pushes to your org's **private (internal) registry** — the same registry you reference in a workload spec as `//image/NAME:TAG`:

```bash
cpln image build --name my-app:v1.0 --push   # builds and pushes → reference as //image/my-app:v1.0
```

Auto-detects a Dockerfile, falls back to buildpacks. All images must be `linux/amd64` (wrong platform = `exec format error`). **In CI/CD `cpln image build` may not work** — Buildx/Docker daemon aren't always present; fall back to plain `docker build` + `docker push` to the org registry.

To **read** what's already in the registry, prefer MCP: `mcp__cpln__list_images` (all images in the org) and `mcp__cpln__get_image` (tags, digest, manifest). There is no create/update/delete-image MCP tool — building (`cpln image build --push`) and cross-org copying (`cpln image copy`) are CLI-exclusive.

Image reference rules in workload specs:

| Source | Reference in spec | Pull secret? |
|---|---|---|
| **Your org's registry (internal)** | `//image/NAME:TAG` — never the `<org>.registry.cpln.io/...` hostname | No |
| **Public Docker Hub** | bare name, no host (`nginx:latest`) — never add `docker.io/` | No |
| **Other public registry** | exact host path (`gcr.io/...`, `ghcr.io/...`) | No |
| **External private registry** (ECR, GCR, ACR, private Docker Hub, another CPLN org) | exact host path | **Yes** — `docker`/`ecr`/`gcp` secret on GVC `spec.pullSecretLinks` |

Full image workflow (buildx fallback, cross-org copy, pull-secret setup): `image` skill.

## Workflow: Deploy a workload

Prefer MCP for the GVC + workload steps (`mcp__cpln__create_gvc`, `mcp__cpln__create_workload`, then poll `mcp__cpln__get_workload_deployments`); only the image build is CLI-exclusive. The CLI runbook below is the fallback (or the CI/CD path):

```bash
cpln gvc create --name my-gvc --location aws-us-west-2 --location gcp-us-east1
cpln image build --name my-app:v1.0 --push
cpln workload create --name my-app --gvc my-gvc --image //image/my-app:v1.0 --port 8080 --public
cpln workload get-deployments my-app --gvc my-gvc   # verify readiness
```

## Workflow: Grant secret access (3 steps)

The 3-step rule (identity + policy + reference) is in `rules/cpln-guardrails.md`. Prefer MCP: `mcp__cpln__create_secret`, then `mcp__cpln__workload_reveal_secret` (composite — ensures the workload has an identity and creates/updates the reveal policy in one call), then edit the workload spec to reference it. The CLI workflow below is the fallback:

```bash
# 1. Secret
cpln secret create-opaque --name db-password --file ./db-password.txt

# 2. Identity, assigned to the workload
cpln identity create --name my-app-identity --gvc my-gvc
cpln workload update my-app --gvc my-gvc --set spec.identityLink=//identity/my-app-identity

# 3. Policy granting reveal
cpln policy create --name secret-access --target-kind secret --resource db-password
cpln policy add-binding secret-access \
  --identity //gvc/my-gvc/identity/my-app-identity --permission reveal

# Reference the secret in the workload
cpln workload update my-app --gvc my-gvc \
  --set spec.containers.main.env.DB_PASSWORD.value=cpln://secret/db-password.payload
```

## Workflow: GitOps with cpln apply

```bash
# 1. Export existing resources (yaml-slim strips server-side metadata)
cpln gvc get my-gvc -o yaml-slim > manifests/gvc.yaml
cpln workload get my-app --gvc my-gvc -o yaml-slim > manifests/workload.yaml

# 2. Edit in version control. 3. Apply EVERYTHING IN ONE CALL — let cpln resolve order
cpln apply --file ./manifests/ --gvc my-gvc --ready
```

Idempotent — run on every push. `--ready` blocks until healthy. Apply once, not file-by-file.

## Workflow: Rename or clone (names are immutable)

No `rename` exists.

**Preferred — `clone`** (`workload`, `policy`, `identity`, `mk8s`, `auditctx`); duplicates spec only:

```bash
cpln workload clone old-name --name new-name --gvc my-gvc   # 1. clone
cpln workload get-deployments new-name --gvc my-gvc         # 2. verify healthy
cpln workload delete old-name --gvc my-gvc                  # 3. delete old ONLY after verify
```

**Fallback — `get -o yaml-slim` → edit → apply** (when changing more than the name):

```bash
cpln workload get old-name --gvc my-gvc -o yaml-slim > new.yaml
cpln apply --file new.yaml --gvc my-gvc --ready
cpln workload delete old-name --gvc my-gvc
```

Renaming changes the internal hostname (`<workload>.<gvc>.cpln.local`) and public URL (`<workload>.<gvc>.cpln.app`). Update everything referencing the old name: domain routes (`spec.ports[].routes[].workloadLink`), policy `targetLinks`/`targetQuery`, identity bindings, internal-DNS callers, external clients. Never delete the old workload before the new one is verified healthy.

## Workflow: Debug a failing workload

```bash
cpln logs '{gvc="my-gvc", workload="my-app"}' --org my-org             # 1. logs
cpln logs '{gvc="my-gvc", workload="my-app"}' --org my-org --tail      # 2. stream
cpln logs '{gvc="my-gvc", workload="my-app"} |= "error"' --org my-org  # 3. filter (LogQL, not a shell pipe)
cpln workload exec my-app --gvc my-gvc -- env | grep CPLN              # 4. exec
cpln workload connect my-app --gvc my-gvc                              # 5. shell
cpln port-forward my-app 8080:8080 --gvc my-gvc                        # 6. port-forward
```

**Cron workloads — query logs per execution, not per workload.** A plain `{gvc=, workload=}` query mixes every past run. Each execution runs in a separate replica with a unique `replica` ID: use `cpln workload get-deployments <name> --gvc <gvc> -o json` to enumerate `status.jobExecutions[]`, then scope logs with the `replica` label + time window. Full pattern: `logql-observability` skill.

## Platform rules & integration

Platform-wide rules are **not duplicated here** — scale-to-zero/autoscaling, production defaults/probes, Template Catalog first, destructive ops, secrets, firewall all live in `rules/cpln-guardrails.md` and their dedicated skills (`autoscaling-capacity`, `workload-security`, `template-catalog`). The MCP tool router also lives in the kernel; before authoring any apply YAML / CI/CD manifest / API body, call `get_resource_schema`.

IaC: Terraform (`controlplane-com/cpln` provider), Pulumi (`@pulumiverse/cpln`), K8s Operator (`k8s-operator` skill).

## Reference

- Platform guardrails & resource model: `rules/cpln-guardrails.md`
- [Control Plane Docs](https://docs.controlplane.com) · [AI page index](https://docs.controlplane.com/llms.txt) · [CLI Reference](https://docs.controlplane.com/cli-reference/overview.md)
