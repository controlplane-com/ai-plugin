---
name: cpln
description: "Writes cpln CLI commands and workflows for Control Plane. Use when the user asks about cpln login, cpln apply, cpln workload, CLI or CI/CD deploys, container debugging with cpln exec/logs, or any cpln resource command."
---

# cpln CLI

**MCP first; the CLI is the fallback** — use it when the MCP server is unavailable or unauthenticated, for the CLI-only operations below, and for interactive debugging or scripted GitOps. **In CI/CD the CLI is the primary interface** — pipelines authenticate with a service-account key in `CPLN_TOKEN`, build/push images (`cpln image build --push`), and apply resources (`cpln apply --ready`). Platform rules (resource model, secrets, destructive ops, production defaults, scale-to-zero, firewall) live in `rules/cpln-guardrails.md`; this skill is the CLI mechanics.

**Never write a `cpln` command from memory.** Verify every verb and flag with `cpln <command> --help` before quoting it. If a command isn't in the resource command map below, assume it isn't real.

## CLI-only operations

No MCP equivalent — the CLI's primary job:

| Command | Purpose |
|---|---|
| `cpln image build` | Build a container image (Dockerfile or buildpacks) and push to the org registry |
| `cpln image copy` | Copy an image between orgs |
| `cpln port-forward` | Forward local ports to a running workload |
| `cpln convert` | Convert Kubernetes manifests to Control Plane specs (Compose is `cpln stack`) |
| `cpln cp` | Copy files in or out of a running container |
| `cpln apply` | Scripted GitOps — declarative create-or-update from files |

Interactive TTY sessions (`workload connect`, `exec -it`) and streamed logs (`cpln logs --tail`) are also CLI-only — MCP's `workload_exec` / `get_workload_logs` cover one-shot commands and log fetches. Everything else — discovery and CRUD — prefer the MCP tools (generic `mcp__cpln__list_resources` / `get_resource` / `delete_resource` with a `kind`, typed `create_*`/`update_*` for mutations).

When no MCP tool covers a resource, field, or sub-endpoint, use the `cpln` CLI for that piece (ground the command in this skill and `--help`) or tell the user what is missing. The raw-API escape hatch (`cpln_api_request`) is disabled by default — it bypasses the typed tools' pre-call validation.

## Setup & auth

```bash
cpln login                                       # interactive (opens a browser); creates the "default" profile
cpln profile update default --org ORG --gvc GVC  # set defaults ("update" creates the profile if missing)
```

**CI/CD needs no profile.** With `CPLN_TOKEN` set (service-account key, from `cpln serviceaccount add-key`), the CLI runs a profile-less session against `api.cpln.io`. Add `CPLN_ORG` / `CPLN_GVC` for defaults and `CPLN_SKIP_UPDATE_CHECK=1` to silence update checks. Resolution everywhere is **flag, then env var, then profile**: `--org` beats `CPLN_ORG` beats the profile default — same for `--gvc`/`CPLN_GVC`, `--profile`/`CPLN_PROFILE`, `--endpoint`/`CPLN_ENDPOINT`, `--token`/`CPLN_TOKEN`. Profiles live in `~/.config/cpln` (override with `CPLN_HOME`).

**Never pass `--token`** — it leaks into logs and shell history; use `CPLN_TOKEN` or a profile. Inspect context with `cpln profile get` — **there is no `cpln whoami`.** **`cpln profile token` (prints the profile's live access JWT) and `cpln secret reveal` are break-glass** — they expose a live credential or secret plaintext: never suggest them or run them on your own; use them only when the user explicitly asks. Explain any profile state changes so operators can revert them.

## Command structure & shared flags

```
cpln <resource> <action> [REF] [--flags]
```

Standalone (break the pattern): `cpln apply`, `delete`, `logs`, `port-forward`, `cp`, `convert`, `login`. Aliases: `workload`=`w`, `identity`=`id`, `serviceaccount`=`sa`, `location`=`loc`, `stack`=`compose`. Shell completion: `cpln misc install-completion` (bash/zsh/fish).

Flags on nearly every command — never list per-command:
- **Context**: `--profile`, `--org`, `--gvc`
- **Output**: `--output`/`-o` (`text|json|yaml|json-slim|yaml-slim|tf|crd|names`), `--color`, `--ts` (`iso|local|age`), `--max` (default 50; `0` = all)
- **Request**: `--token`, `--endpoint`, `--insecure`/`-k` · **Debug**: `--verbose`/`-v`, `--debug`/`-d`

- **Always use `yaml-slim`/`json-slim` for round-tripping.** Plain `yaml`/`json` include server-side fields (`status`, `id`, `created`, `lastModified`, `links`) that break `cpln apply`.
- **Include `--org` (and `--gvc`) explicitly on every mutation**, even with profile defaults. `--gvc` exists on all subcommands of GVC-scoped resources (workload, identity, volumeset) plus helm, stack, apply, convert, cp, delete, port-forward — but **not** on `cpln logs` (GVC goes inside the LogQL query).
- **Cap lists with `--max`.** Omit only when targeting a specific named resource.

## Standard CRUD

| Action | Syntax | Notes |
|---|---|---|
| **List** | `cpln <resource> get` | No args = list all. **There is NO `list` subcommand.** |
| **Get** | `cpln <resource> get REF...` | |
| **Create** | `cpln <resource> create --name NAME` | Also `--description`, `--tag K=V` |
| **Delete** | `cpln <resource> delete REF...` | Multiple refs |
| **Edit** | `cpln <resource> edit REF` | Opens YAML in `$EDITOR`. `--replace` replaces instead of merging |
| **Patch** | `cpln <resource> patch REF --file FILE` | |
| **Tag** | `cpln <resource> tag REF... --tag K=V` | Remove: `--remove-tag KEY` |
| **Update** | `cpln <resource> update REF --set PROP=VAL` | Also `--unset PROP`; array props take `+=` / `=` / `-=` |
| **Clone** | `cpln <resource> clone REF --name NEW` | Spec only. Not on every kind (map below) |
| **Audit** | `cpln <resource> audit [REF]` | `--since` (default 7d), `--from`/`--to`, `--subject`, `--context` |
| **Query** | `cpln <resource> query` | See below |

Also on most kinds: `access-report REF`, `eventlog REF`, `permissions` (no args). **`eventlog` has the alias `log`** — `cpln workload log` shows platform events, NOT container logs (those come from `cpln logs`).

### Query

```bash
cpln workload query --match all --tag environment=production --tag region=europe
cpln workload query --match any --rel gvc=gvc-a --rel gvc=gvc-b
cpln workload query --property name=my-workload
```

`--match` (`all` default / `any` / `none`); `--tag KEY=VALUE`, `--property`/`--prop NAME=VALUE` (e.g. `status.phase=running`), `--rel KIND=VALUE` — all repeatable. The `gvc`, `policy`, and `group` create commands accept `--query-match`/`--query-tag`/`--query-property`/`--query-rel` (group also `--query-kind user`) for dynamic targeting. Full language: `query-spec` skill.

## Resource command map

Core anti-hallucination reference. **Scope**: org = needs `--org`; gvc = needs `--org` + `--gvc`; local = no API call. "Full" = create, get, delete, edit, patch, tag, update (audit, eventlog, query, access-report, permissions exist nearly everywhere).

| Resource | Scope | CRUD | Non-standard subcommands |
|---|---|---|---|
| **workload** (`w`) | gvc | Full + clone | `connect`, `exec`, `run`, `cron` (get/run/start/stop), `replica` (get/stop), `force-redeployment`, `get-deployments`, `open`, `start`, `stop` |
| **gvc** | org | Full + clone | `add-location`, `remove-location` (both `--location`, repeatable), `delete-all-workloads` |
| **secret** | org | **No generic create**; clone | 12 `create-<type>` commands (below), `reveal` (break-glass) |
| **policy** | org | Full + clone | `add-binding`, `remove-binding` |
| **identity** (`id`) | gvc | Full, **no clone** | — |
| **volumeset** | gvc | Full, no clone | `expand`, `shrink`, `snapshot` (create/delete/get/restore), `volume` (delete/get) |
| **domain** | org | create, delete, edit, patch, tag — **no update**, no clone | — |
| **cloudaccount** | org | **No generic create, no update** | `create-aws`, `create-azure`, `create-gcp`, `create-ngs` |
| **image** | org | get, delete, edit, patch, tag only | `build`, `copy`, `docker-login` |
| **agent** | org | Full, no clone | `info`, `manifest`, `up` |
| **group** | org | Full + clone | `add-member`, `remove-member` (`--email`, `--serviceaccount`) |
| **ipset** | org | Full + clone | `add-location`, `remove-location`, `update-location` |
| **serviceaccount** (`sa`) | org | **No update**; clone | `add-key` (`--description` required), `remove-key` |
| **mk8s** | org | **No create**; clone | `dashboard`, `health`, `join`, `kubeconfig` |
| **user** | org | No create | `invite` (`--email`, optional `--group`) |
| **org** | — | create (needs `--accountId`, `--invitee`); **no delete** | — |
| **profile** | local | get, delete, update (creates if missing; alias `create`) | `login`, `set-default`, `token` |
| **helm** | gvc | — | `install` (alias `apply`), `upgrade`, `uninstall`, `get`, `list`, `history`, `rollback`, `template` |
| **stack** (`compose`) | gvc | — | `deploy` (alias `up`), `manifest`, `rm` (alias `down`) |
| **location** (`loc`) | org | create, delete (BYOK locations only), edit, patch — no update | `install`, `uninstall` |
| **auditctx** | org | Full + clone, **no delete** | — |
| **quota** | org | get, edit, patch | — |
| **task** | org | get, delete | `complete`, `get-mine` |
| **account** | — | get only | — |
| **rest** | — | — | `get`, `post`, `put`, `patch`, `delete`, `create`, `edit` against raw API paths |
| **operator** | local | — | `install`, `uninstall` |

## Non-standard commands

### cpln apply / cpln delete

```bash
cpln apply --file ./manifests/ --gvc GVC --ready   # DIRECTORY — recursive over .yaml/.yml/.json
cpln apply --file all.yaml --ready                 # MULTI-DOC file (resources split by ---)
cpln apply --file - < manifest.yaml                # stdin
cpln delete --file manifest.yaml                   # delete the resources listed in a file
```

**Apply multi-resource deploys in one call** (directory or multi-doc file) — the CLI sorts resources into dependency order before applying: `agent, secret, cloudaccount, gvc, identity, volumeset, policy, workload` (other kinds after); `cpln delete --file` runs the same order reversed. Splitting into multiple calls reintroduces the ordering problem. Apply is a PUT upsert — it prints `Created`/`Updated` per resource. `--ready` polls workloads (5s interval, up to 5 min) until ready. `--k8s` converts Kubernetes manifests inline (Deployment/Secret/ConfigMap/PVC; pull secrets get linked onto the GVC).

GVC targeting for GVC-scoped resources:
- **Single-GVC bundle** (common): pass `--gvc GVC` — it fills in the GVC for every resource that doesn't declare one.
- **Multi-GVC bundle**: declare `gvc:` inline as a top-level field (same level as `kind`/`name`) and omit the flag.
- Inline `gvc:` plus a **different** `--gvc` value = hard error; they must agree.
- Org-scoped resources ignore the GVC field/flag entirely.

```yaml
kind: workload
name: my-app
gvc: prod          # target GVC declared inline
spec: { ... }
```

### cpln logs

```bash
cpln logs '{gvc="GVC", workload="WORKLOAD"}' --org ORG --tail
```

- The query is a **positional argument** (first arg, single quotes, LogQL). `--gvc` is **not** a flag here.
- Labels: `container`, `gvc`, `location`, `provider`, `replica`, `stream`, `workload`. Special: `container="_accesslog"` for HTTP access logs.
- Filters: `|= "error"` (contains), `!= "debug"` (excludes), `|~ "timeout|crash"` (regex).
- Streaming: `--tail` (also `-t`/`-f`). **`--follow` does NOT exist.**
- `--limit N` (default 30; `0` = unlimited, auto-paginates), `--since` (default `1h`), `--from`/`--to`, `--direction forward|backward`, and its own `-o default|raw|jsonl` (`raw` strips labels and timestamps). Full LogQL: `logql-observability` skill.

### cpln secret create — 12 type-specific commands

`cpln secret create` does **not** exist. All variants require `--name`; all accept `--description`, `--tag`:

| Type | Command | Required flags | Optional |
|---|---|---|---|
| Opaque | `create-opaque` | `--file` (**no `--payload` flag**) | `--encoding` (default `base64` — the CLI encodes the file for you, binary-safe; `plain` stores text as-is) |
| Dictionary | `create-dictionary` | `--entry KEY=VAL` (repeatable) | |
| Username/Password | `create-userpass` | `--username`, `--password` | |
| AWS | `create-aws` | `--access-key`, `--secret-key` | `--role-arn`, `--external-id` |
| GCP | `create-gcp` | `--file` (service-account JSON) | |
| Azure SDK | `create-azure-sdk` | `--file` | |
| Azure Connector | `create-azure-connector` | `--url`, `--code` | |
| Docker | `create-docker` | `--file` (docker config.json) | |
| ECR | `create-ecr` | `--access-key`, `--secret-key`, `--repo` | `--role-arn`, `--external-id` |
| TLS | `create-tls` | `--key`, `--cert` | `--chain` |
| Key Pair | `create-keypair` | `--secret` | `--public`, `--passphrase` |
| NATS | `create-nats` | `--account-id`, `--private-key` | |

### cpln workload create

```bash
cpln workload create --name APP --image IMAGE --gvc GVC [flags]
```

`--type` (`serverless|standard`, default `standard`) — **`stateful` and `cron` CANNOT be created via CLI flags; use `cpln apply --file`.** Other flags: `--port` (default 8080 — must match the container's listening port), `--public`, `--identity`, `--env KEY=VALUE`, `--cpu` (default 50m), `--memory`/`--mem` (default 128Mi), `--volume`, `--container-name`, `--inherit-env`. Internal images: `//image/NAME:TAG`.

### Debugging — exec / connect / run / cron / replica

- **exec** — one-shot command in an existing replica: `cpln workload exec APP --gvc GVC -- ls -la`. **The `-- CMD ARG1 ARG2...` part must be last on the line** — every cpln flag (`--container`, `--location`, `--replica`, `--stdin`/`-i`, `--tty`/`-t`, `--quiet`/`-q`) goes before the `--`; everything after it runs in the replica (same rule for `run` and `cron run`)
- **connect** — interactive shell: `cpln workload connect APP --gvc GVC` (`--shell`, default `bash`; same targeting flags)
- **run** — temporary workload + command: `cpln workload run --image IMAGE --gvc GVC -- CMD` (`--clone WORKLOAD`, `--rm`, `-i`, `--cpu`, `--memory`, `--command`/`-c`, `--arg`/`-a`, `--location`)
- **cron run** — one-off execution of a cron workload: `cpln workload cron run --gvc GVC -- CMD` (`--background`/`-b`, `--timeout` default 600s, `--identity`, `--image`, `--env`)
- **cron start** — trigger the job now, optionally overriding `--env`, `--command`, `--arg`, `--active-deadline-seconds`; **cron stop** REF needs `--replica-name` + `--location` (both required); **cron get** REF lists job executions
- **replica get / stop** — list replica names per location; `stop` requires `--replica-name` + `--location`

When `--location` / `--replica` / `--container` are omitted, the CLI defaults to the GVC's first location, the first replica, and the only container (multi-container: the first one with `ports`, else the first) — it prints a "defaulting to" notice. Pass all three explicitly on multi-location or multi-container workloads.

### cpln policy add-binding

```bash
cpln policy add-binding POLICY --permission reveal --identity //gvc/GVC/identity/ID
```

`--permission` required; at least one principal flag required; **all repeatable** (`--email`, `--serviceaccount`, `--group`, `--identity` — name or full link).

### cpln port-forward / cp

```bash
cpln port-forward WORKLOAD [LOCAL:]REMOTE... --gvc GVC   # --address (default localhost), --location, --replica
cpln cp LOCAL WORKLOAD:PATH --gvc GVC                    # reverse the args (WORKLOAD:PATH LOCAL) to copy out; --container, --location, --replica
```

### Migration tools

- `cpln convert --file K8S.yaml` — Kubernetes manifest to Control Plane spec (`--protocol http|http2|grpc|tcp` for container ports)
- `cpln helm install RELEASE CHART --gvc GVC` — Helm charts and template catalog installs (`--wait`, `--timeout` default 300s, `--set`, `--values`)
- `cpln stack deploy --gvc GVC` — Docker Compose from the current directory (`--dir`, `--compose-file` for alternative naming, `--build` default true)

### Volumeset command verbs

Dedicated verb per operation; the flags are **singular** — `--location`, `--volume-index` (plural forms don't exist):

| Operation | Command | Risk |
|---|---|---|
| Expand volume | `cpln volumeset expand REF --new-size GIB [--location LOC] [--volume-index N]` | Safe |
| Create snapshot | `cpln volumeset snapshot create REF --snapshot-name NAME [--location LOC] [--volume-index N]` | Safe |
| Restore snapshot | `cpln volumeset snapshot restore REF --snapshot-name NAME --location LOC --volume-index N` (all required) | Overwrites volume state |
| Delete snapshot | `cpln volumeset snapshot delete REF --snapshot-name NAME` | Destructive |
| Delete volume | `cpln volumeset volume delete REF [--location LOC] [--volume-index N]` | Destructive (data loss) |
| Shrink volume | `cpln volumeset shrink REF --new-size GIB [--location LOC]` | **DESTRUCTIVE — permanent data loss** |

`shrink` provisions a new, smaller volume and removes the old one — data is **not** migrated. Safe only with built-in redundancy (Kafka replication; Cassandra/CockroachDB), on `ext4`/`xfs` (not `shared`). Apply the destructive-op confirmation from `rules/cpln-guardrails.md` first. Detail: `stateful-storage` skill.

## Commands that don't exist

| Wrong | Correct |
|---|---|
| `cpln secret create` | `cpln secret create-opaque`, `create-aws`, etc. |
| `cpln secret create-opaque --payload X` | `--file` only — the CLI has no `--payload` flag (some docs mention one) |
| `cpln <resource> list` | `cpln <resource> get` (no args = list all) |
| `cpln logs --follow` | `cpln logs --tail` (or `-t` / `-f`) |
| `cpln workload log` for container logs | that's the `eventlog` alias (platform events); container logs = `cpln logs '{gvc="GVC", workload="W"}'` |
| `cpln cloudaccount create` | `cpln cloudaccount create-aws` / `create-azure` / `create-gcp` / `create-ngs` |
| `cpln mk8s create` | `cpln apply --file mk8s-manifest.yaml` |
| `cpln workload update REF --identity X` | `cpln workload update REF --set spec.identityLink=//identity/X` |
| `cpln secret update REF --data '{}'` | `cpln secret edit REF` or `cpln apply --file` |
| `cpln gvc update REF --location LOC` | `cpln gvc add-location REF --location LOC` |
| `cpln identity clone` | identity has no clone — `get -o yaml-slim`, edit the name, `cpln apply` |
| `cpln volumeset ... --locations / --volume-indexes` | singular: `--location`, `--volume-index` |
| `cpln whoami` | `cpln profile get` (context) / `cpln account get` |

## Building & referencing images

`cpln image build` builds locally and (with `--push`) pushes to the org's **private registry** — the registry referenced in workload specs as `//image/NAME:TAG`:

```bash
cpln image build --name my-app:v1.0 --push   # reference as //image/my-app:v1.0
```

- **Dockerfile**: auto-detected in `--dir` (default `.`), or pass `--dockerfile PATH`. Built with Docker (buildx when available).
- **Buildpacks**: no Dockerfile means a buildpack build via the `pack` binary (auto-downloaded by the CLI). Default builder `heroku/builder:24_linux-amd64`; `--buildpack` to pin; everything after `--` goes to `pack`.
- `--platform` defaults to `linux/amd64` — the required arch on Control Plane (wrong arch = `exec format error`). Multi-arch lists need buildx and `--push`.
- `--env` here is **build-time only** — never available at runtime. `--no-cache` busts layers.
- **A running Docker daemon is required either way.** On thin CI runners fall back to `docker build` + `docker push` against the org registry (`cpln image docker-login` first).
- Cross-org copy: `cpln image copy NAME:TAG --to-org ORG2 [--to-name NEW] [--to-profile P]` — logs into both registries, then pulls, tags, pushes.

Image reference rules in workload specs:

| Source | Reference in spec | Pull secret? |
|---|---|---|
| **Your org's registry (internal)** | `//image/NAME:TAG` — never the `ORG.registry.cpln.io` hostname | No |
| **Public Docker Hub** | bare name (`nginx:latest`) — never add `docker.io/` | No |
| **Other public registry** | exact host path (`gcr.io/...`, `ghcr.io/...`) | No |
| **External private registry** (ECR, GCR, ACR, private Docker Hub, another CPLN org) | exact host path | **Yes** — `docker`/`ecr`/`gcp` secret on GVC `spec.pullSecretLinks` |

Full image workflow (buildx fallback, cross-org copy, pull-secret setup): `image` skill.

## Workflow: Deploy a workload

The CLI runbook (also the CI/CD path):

```bash
cpln gvc create --name my-gvc --location aws-us-west-2 --org my-org
cpln image build --name my-app:v1.0 --push
cpln workload create --name my-app --gvc my-gvc --image //image/my-app:v1.0 --port 8080 --public
cpln workload get-deployments my-app --gvc my-gvc   # verify readiness
```

## Workflow: Grant secret access (3 steps)

The 3-step rule (identity + policy + reference) and the `workload_reveal_secret` shortcut (identity + policy in one call) are owned by `rules/cpln-guardrails.md`. CLI fallback:

```bash
cpln secret create-opaque --name db-password --file ./db-password.txt --org my-org
cpln identity create --name my-app-identity --gvc my-gvc --org my-org
cpln workload update my-app --gvc my-gvc --set spec.identityLink=//identity/my-app-identity
cpln policy create --name secret-access --target-kind secret --resource db-password --org my-org
cpln policy add-binding secret-access --permission reveal \
  --identity //gvc/my-gvc/identity/my-app-identity --org my-org
cpln workload update my-app --gvc my-gvc \
  --set spec.containers.main.env.DB_PASSWORD.value=cpln://secret/db-password.payload
```

## Workflow: GitOps with cpln apply

```bash
cpln gvc get my-gvc -o yaml-slim > manifests/gvc.yaml              # export (slim strips server fields)
cpln workload get my-app --gvc my-gvc -o yaml-slim > manifests/workload.yaml
cpln apply --file ./manifests/ --gvc my-gvc --ready                # idempotent; run on every push
```

## Workflow: Rename or clone (names are immutable)

No `rename` exists. **Preferred — `clone`** (on workload, gvc, secret, policy, group, ipset, serviceaccount, mk8s, auditctx; duplicates spec only):

```bash
cpln workload clone old-name --name new-name --gvc my-gvc
cpln workload get-deployments new-name --gvc my-gvc      # verify healthy
cpln workload delete old-name --gvc my-gvc               # only after verification
```

Kinds without clone (identity, volumeset, domain, agent): `get -o yaml-slim`, edit the name, `cpln apply`. Renaming a workload changes its internal hostname (`WORKLOAD.GVC.cpln.local`) and public URL — update domain routes (`spec.ports[].routes[].workloadLink`), policy `targetLinks`/`targetQuery`, internal-DNS callers, and external clients. Never delete the old workload before the new one is verified healthy.

## Workflow: Debug a failing workload

```bash
cpln logs '{gvc="my-gvc", workload="my-app"}' --org my-org --tail        # stream logs
cpln logs '{gvc="my-gvc", workload="my-app"} |= "error"' --org my-org    # filter (LogQL, not a shell pipe)
cpln workload exec my-app --gvc my-gvc -- env                            # inspect runtime env
cpln workload connect my-app --gvc my-gvc                                # interactive shell
cpln port-forward my-app 8080:8080 --gvc my-gvc                          # probe locally
```

**Cron workloads — query logs per execution, not per workload.** A plain `{gvc=, workload=}` query mixes every past run. Enumerate executions with `cpln workload cron get NAME --gvc GVC`, then scope the LogQL with the `replica` label plus a time window. Full pattern: `logql-observability` skill.

## Platform rules & integration

Scale-to-zero/autoscaling, production defaults/probes, Template Catalog first, destructive ops, secrets, and firewall rules live in `rules/cpln-guardrails.md` and their dedicated skills — not duplicated here. Before authoring any apply YAML / CI manifest / API body, call `get_resource_schema`. IaC: Terraform (`controlplane-com/cpln` provider), Pulumi (`@pulumiverse/cpln`), K8s Operator (`cpln operator install`).

## Related skills

| Need | Skill |
|---|---|
| Image build details, buildx fallback, pull secrets | `image` |
| LogQL beyond the basics, per-execution cron queries | `logql-observability` |
| Query language (`--match` / `--tag` / `--rel`) | `query-spec` |
| Volumeset semantics and shrink safety | `stateful-storage` |
| K8s / Compose / Helm migration | `migration-patterns` |
| Pipelines and GitOps patterns | `gitops-cicd` |
| Terraform / Pulumi / K8s operator | `iac-terraform-pulumi`, `k8s-operator` |

## Documentation

- Platform guardrails & resource model: `rules/cpln-guardrails.md`
- [Control Plane Docs](https://docs.controlplane.com) · [AI page index](https://docs.controlplane.com/llms.txt) · [CLI Reference](https://docs.controlplane.com/cli-reference/overview.md)
