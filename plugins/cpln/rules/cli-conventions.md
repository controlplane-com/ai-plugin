---
description: cpln CLI command structure, conventions, and patterns — prevents hallucinated commands and flags
alwaysApply: true
---

# cpln CLI Conventions

**Never write a cpln command from memory.** Verify with `cpln <command> --help` or `mcp__cpln__cpln_suggest`.

## Command Structure

All resource commands follow this pattern:

```
cpln <resource> <action> [REF] [--flags]
```

Standalone commands break this pattern: `cpln apply`, `cpln delete`, `cpln logs`, `cpln port-forward`, `cpln cp`, `cpln convert`, `cpln login`.

## Building and Referencing Images

`cpln image build` is the primary way to containerize and push images to your org's private registry:

```bash
cpln image build --name my-app:v1.0 --push
```

- Auto-detects Dockerfile in current directory. If no Dockerfile, auto-detects buildpacks.
- Default platform: `linux/amd64`. All images must be linux/amd64 — wrong platform causes `exec format error`.
- `--push` pushes to your org's private registry. Without it, the image is only built locally.
- Override builder: `--builder`/`-B`. Override buildpack: `--buildpack`/`-b`.
- Build context directory: `--dir` (default: `.`). Skip cache: `--no-cache`.
- Buildx fallback: single-platform builds fall back to legacy `docker build` when Buildx is unavailable; multi-platform builds require Buildx. See the **cpln-image** skill (Common Gotchas) for version history and details.

**Image reference rules in workload specs:**

| Source | Reference Format | Example |
|--------|-----------------|---------|
| Org registry | `//image/NAME:TAG` | `//image/my-app:v1.0` |
| External registry | Exact image string | `nginx:latest`, `gcr.io/project/image:tag` |

**NEVER** prefix external images with `docker.io/`. Use `nginx:latest`, not `docker.io/library/nginx:latest`. The hostname `<org>.registry.cpln.io` is only for `docker login`, never in workload specs.

## Shared Flags

Available on nearly every command. Never list these per-command — they're always there.

- **Context**: `--profile`, `--org`, `--gvc`
- **Output**: `--output`/`-o` (text|json|yaml|json-slim|yaml-slim|tf|crd|names), `--color`, `--ts` (iso|local|age), `--max` (default: 50)
- **Request**: `--token`, `--endpoint`, `--insecure`/`-k`
- **Debug**: `--verbose`/`-v`, `--debug`/`-d`

**Always use `yaml-slim` / `json-slim` for round-tripping.** When you `get` a resource to edit and re-apply, use `-o yaml-slim` (not plain `yaml`). Plain `yaml`/`json` include server-side fields (`status`, `id`, `created`, `lastModified`, `links`) that cause `cpln apply` to fail or produce noisy diffs. The slim variants strip those fields and emit only the apply-safe shape.

**`--org`** is on ~90% of commands. **`--gvc`** is on all subcommands of GVC-scoped resources (workload, identity, volumeset) plus helm, stack, apply, convert, cp, delete, and port-forward. It is NOT a flag on `cpln logs` — the GVC is specified inside the LogQL query.

Environment overrides: `CPLN_TOKEN`, `CPLN_ORG`, `CPLN_GVC`, `CPLN_PROFILE`.

## Standard CRUD Operations

Most resources support these actions with consistent flags:

| Action | Syntax | Notes |
|--------|--------|-------|
| **List** | `cpln <resource> get` | No args = list all. **There is NO `list` subcommand.** |
| **Get** | `cpln <resource> get REF` | |
| **Create** | `cpln <resource> create --name NAME` | Also: `--description`, `--tag K=V` |
| **Delete** | `cpln <resource> delete REF...` | Supports multiple refs |
| **Edit** | `cpln <resource> edit REF` | Opens YAML in editor. Flag: `--replace` |
| **Patch** | `cpln <resource> patch REF --file FILE` | |
| **Tag** | `cpln <resource> tag REF... --tag K=V` | Remove: `--remove-tag K` |
| **Update** | `cpln <resource> update REF --set PROP=VAL` | Also: `--unset PROP` |
| **Clone** | `cpln <resource> clone REF --name NEW` | Duplicates spec only (no status/IDs). Preferred over get/edit/apply for renames. |
| **Audit** | `cpln <resource> audit [REF]` | Flags: `--since`, `--from`, `--to` (accept ISO 8601, duration, or `now-<duration>`) |
| **Query** | `cpln <resource> query` | See query section below |

Also: `access-report REF`, `eventlog REF`, `permissions` (no args).

### Query

The `query` subcommand filters resources by tags, properties, or relations:

```bash
cpln workload query --match all --tag environment=production --tag region=europe
cpln workload query --match any --rel gvc=my-first-gvc --rel gvc=my-second-gvc
cpln workload query --property name=my-workload
```

| Flag | Description |
|------|-------------|
| `--match` | How conditions combine: `all` (default), `any`, `none`. Single value, not repeatable. |
| `--tag KEY=VALUE` | Filter by tag. Repeatable. |
| `--property`/`--prop` NAME=VALUE | Filter by property, e.g. `name=X`, `status.phase=running`. Repeatable. |
| `--rel` KIND=VALUE | Filter by relation, e.g. `gvc=my-gvc`. Repeatable. |

Some `create` commands (gvc, policy, group) accept `--query-match`, `--query-tag`, `--query-property`, `--query-rel` for dynamic targeting.

## Resource Command Map

| Resource | Scope | CRUD | Non-Standard Subcommands |
|----------|-------|------|--------------------------|
| **workload** | gvc | Full | `connect`, `exec`, `run`, `cron` (get/run/start/stop), `replica` (get/stop), `force-redeployment`, `get-deployments`, `open`, `start`, `stop` |
| **gvc** | org | Full | `add-location`, `remove-location`, `delete-all-workloads` |
| **secret** | org | **No generic create** | 12 type-specific create commands (see below), `reveal` |
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
| **profile** | local | get, delete, update | `login`, `set-default`, `token`. Note: `update` creates if not exists (alias: `create`) |
| **helm** | gvc | get | `install`, `upgrade`, `template`, `rollback`, `uninstall`, `list`, `history` |
| **stack** | gvc | — | `deploy`, `manifest`, `rm` |
| **location** | org | Partial | `install`, `uninstall` |
| **auditctx** | org | Full (no delete) | — |
| **quota** | org | get, edit, patch | — |
| **task** | org | get, delete | `complete`, `get-mine` |
| **account** | org | get only | — |
| **rest** | org | get, create, delete, edit, patch | `post`, `put` |
| **operator** | — | — | `install`, `uninstall` |

**Scope**: org = needs `--org`, gvc = needs `--org` + `--gvc`, local = no API call.

## Non-Standard Commands

### cpln apply / cpln delete

```bash
cpln apply --file ./manifests/ --gvc <gvc> --ready    # apply DIRECTORY — cpln resolves resource order automatically
cpln apply --file all.yaml --ready                    # apply MULTI-DOC file (resources separated by ---) — same
cpln apply --file workload-update.yaml --ready        # apply ONE resource — for incremental updates only
cpln delete --file manifest.yaml                       # delete resources in file
```

**For multi-resource deploys, apply once via a directory or multi-doc file.** `cpln apply` walks the inter-resource dependency graph automatically when given multiple resources at once. **Splitting into multiple apply calls reintroduces the ordering problem cpln apply was designed to solve** — workloads referencing secrets that haven't been applied yet, identity bindings before the identity exists, policies referencing missing target resources. Single-file applies are for *incremental updates to ONE existing resource*, not for initial multi-resource deploys.

**Two approaches when applying a multi-resource bundle, depending on GVC scope:**

- **Single-GVC bundle** (most common): all GVC-scoped resources target the same GVC. Pass `--gvc <gvc>` on the apply call; it fills in the GVC for every GVC-scoped resource in the bundle that doesn't declare one inline.
  ```bash
  cpln apply --file ./manifests/ --gvc prod --ready
  ```
- **Per-resource GVC declaration** (use when resources span multiple GVCs, or when manifests should be self-describing): declare the target GVC inline on each GVC-scoped resource via a top-level `gvc:` field — same indentation level as `kind`, `name`, `description`, `tags`. Apply the bundle **without** `--gvc`; cpln routes each resource to its declared GVC.
  ```yaml
  kind: workload
  name: my-app
  gvc: prod                # ← target GVC declared inline
  description: My app
  spec: { ... }
  ---
  kind: workload
  name: my-app
  gvc: staging             # ← same name, different GVC — routed correctly
  description: Staging mirror
  spec: { ... }
  ---
  kind: secret             # ← org-scoped resources ignore the gvc field/flag
  type: opaque
  name: shared-secret
  data: { payload: ... }
  ```
  ```bash
  cpln apply --file ./manifests/ --ready
  ```

Org-scoped resources (`secret`, `policy`, `domain`, `image`, `agent`, `group`, `cloudaccount`, `serviceaccount`, `ipset`, `mk8s`) ignore the gvc field/flag — they live at the org level. GVC-scoped resources (`workload`, `identity`, `volumeset`) are the ones the gvc flag/field controls.

`--file`/`-f` is **required** on both. `--ready` blocks until healthy (recommended for CI/CD). `--k8s` auto-converts Kubernetes manifests inline. Supports stdin: `--file -`.

### cpln logs

```bash
cpln logs '{gvc="GVC", workload="WORKLOAD"}' --org ORG --tail
```

- Query is a **positional argument** (first arg, in single quotes, LogQL syntax)
- Available labels: `container`, `gvc`, `location`, `provider`, `replica`, `stream`, `workload`
- Special container value: `container="_accesslog"` for HTTP access logs
- Filters: `|= "error"` (contains), `!= "debug"` (excludes), `|~ "timeout|crash"` (regex)
- Streaming: `--tail`/`-t`/`-f`. **`--follow` does NOT exist.**
- Limit: `--limit N` (default: 30, 0 = unlimited with auto-pagination)
- Time range: `--since "1h"`, `--from TIME`, `--to TIME` — `--from`/`--to` accept ISO 8601, a duration (`7d`), or `now-<duration>` (e.g., `--from now-2d --to now-1d`)
- Note: `--gvc` is NOT a flag on this command. The GVC is specified inside the LogQL query.

### cpln secret create — 12 type-specific commands

`cpln secret create` does **NOT** exist. Use the type-specific variant:

| Type | Command | Required Flags |
|------|---------|---------------|
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

All also require `--name` and accept `--description`, `--tag`.

### cpln workload create

```bash
cpln workload create --name APP --image IMAGE --gvc GVC [flags]
```

Key flags: `--type` (serverless|standard, default: standard), `--port`, `--public`, `--identity`, `--env KEY=VALUE`, `--cpu`, `--memory`/`--mem`, `--volume`, `--container-name`.

Note: `stateful` and `cron` types cannot be created via CLI — use `cpln apply --file`.

### cpln workload exec / connect / run

- **exec**: Run command in existing replica. `--` separator required:
  `cpln workload exec APP --gvc GVC -- ls -la`
  Flags: `--container`, `--location`, `--replica`, `--stdin`/`-i`, `--tty`/`-t`

- **connect**: Open shell in existing replica:
  `cpln workload connect APP --gvc GVC`
  Flag: `--shell` (default: bash)

- **run**: Create temporary workload, run command:
  `cpln workload run --image IMAGE --gvc GVC -- CMD`
  Flags: `--clone`, `--rm` (delete after), `--interactive`/`-i`, `--cpu`, `--memory`

- **cron run**: One-off cron execution:
  `cpln workload cron run --image IMAGE --gvc GVC -- CMD`
  Flags: `--background`/`-b`, `--timeout`/`-t`

### cpln policy add-binding

```bash
cpln policy add-binding POLICY --permission reveal --identity //gvc/GVC/identity/ID
```

`--permission` is required. At least one principal flag is required. **All flags are repeatable** — you can bind multiple permissions to multiple principals in a single command:

```bash
cpln policy add-binding my-policy \
  --permission reveal --permission view \
  --email user1@example.com --email user2@example.com \
  --serviceaccount ci-deployer
```

Principal flags: `--email`, `--serviceaccount`, `--group`, `--identity` (all repeatable).

### cpln port-forward

```bash
cpln port-forward WORKLOAD [LOCAL:]REMOTE... --gvc GVC
```

Flags: `--address`, `--location`, `--replica`.

### Migration tools

- `cpln convert --file K8S.yaml` — Kubernetes to Control Plane manifest
- `cpln helm install RELEASE CHART --gvc GVC` — Helm chart management
- `cpln stack deploy --compose-file FILE --gvc GVC` — Docker Compose deployment

## Commands That DON'T Exist

| Wrong | Correct |
|-------|---------|
| `cpln secret create` | `cpln secret create-opaque`, `create-aws`, etc. |
| `cpln <resource> list` | `cpln <resource> get` (no args = list all) |
| `cpln mk8s create` | `cpln apply --file mk8s-manifest.yaml` |
| `cpln logs --follow` | `cpln logs --tail` (or `-t` or `-f`) |
| `cpln workload log` | `cpln logs '{gvc="GVC", workload="WORKLOAD"}'` |
| `cpln cloudaccount create` | `cpln cloudaccount create-aws`, etc. |
| `cpln apply` (no --file) | `cpln apply --file manifest.yaml` |
| `cpln workload update --identity X` | `cpln workload update REF --set spec.identityLink=//identity/X` |
| `cpln secret update --data '{}'` | `cpln secret edit REF` or `cpln apply --file` |
| `cpln gvc update --location LOC` | `cpln gvc update REF --set 'spec.staticPlacement.locationLinks+=//location/LOC'` |

## The Verification Rule

If you haven't verified a command with `cpln <command> --help`, assume it doesn't exist. The CLI is consistent — if something isn't in this file's resource command map, it probably isn't real.
