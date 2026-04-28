---
name: cpln-cli
description: "Writes cpln CLI commands and workflows for deploying and managing workloads on Control Plane. Use when the user asks about cpln login, cpln apply, cpln workload, deploying via CLI, container debugging with cpln exec/logs, or any cpln resource command. Covers CLI setup, authentication, resource management, deployment workflows, and interactive debugging."
version: 1.0.0
---

# cpln CLI

This skill extends `rules/cli-conventions.md` (always loaded) with setup, workflows, and practical examples. Conventions covers command structure, shared flags, the resource command map, and hallucination traps. This skill covers **how to use those commands** to get things done.

## Setup

```bash
# Interactive login (opens browser)
cpln login

# Set default org and GVC so you don't need --org and --gvc on every command
cpln profile update default --org my-org --gvc my-gvc
```

For CI/CD (non-interactive), set environment variables via your platform's secrets management:

| Variable | Purpose |
|---|---|
| `CPLN_TOKEN` | Service account key (generate with `cpln serviceaccount add-key`) |
| `CPLN_ORG` | Default organization |
| `CPLN_GVC` | Default GVC |
| `CPLN_PROFILE` | Profile override |

Never pass tokens via `--token` flags — they leak into logs and shell history.

Override per-command: `--org other-org`, `--gvc other-gvc`, `--profile production`.

## Quick Command Lookup

For flag details and the full resource command map, see `rules/cli-conventions.md`. This table maps common tasks to commands:

| Task | Command |
|---|---|
| Deploy from YAML/JSON | `cpln apply --file manifest.yaml --ready` |
| Create workload | `cpln workload create --name APP --image IMAGE --gvc GVC --port PORT` |
| Create GVC | `cpln gvc create --name GVC --location aws-us-east-1` |
| Create secret | `cpln secret create-opaque --name SECRET --file data.txt` (use `--file -` for stdin) |
| Create policy | `cpln policy create --name POLICY --target-kind secret --resource SECRET` |
| Bind permission to policy | `cpln policy add-binding POLICY --permission reveal --identity LINK` |
| Create identity | `cpln identity create --name ID --gvc GVC` |
| View logs | `cpln logs '{gvc="GVC", workload="WL"}' --org ORG` |
| Exec into container | `cpln workload exec WL --gvc GVC -- COMMAND` |
| Interactive shell | `cpln workload connect WL --gvc GVC` |
| Port forward | `cpln port-forward WL 8080:8080 --gvc GVC` |
| Export as YAML | `cpln workload get WL --gvc GVC -o yaml-slim > wl.yaml` (always use `yaml-slim` for re-apply — see Workflow: Rename) |
| Clone / rename a resource | `cpln workload clone OLD --name NEW --gvc GVC` (also: `policy`, `identity`, `mk8s`, `auditctx`) |
| Build & push image | `cpln image build --name IMAGE:TAG --push` |
| Copy files to container | `cpln cp LOCAL WORKLOAD:PATH --gvc GVC` |
| Run one-off command | `cpln workload cron run --image IMG --gvc GVC -- CMD` |
| Deploy Helm chart | `cpln helm install RELEASE CHART --gvc GVC` |
| Deploy Docker Compose | `cpln stack deploy --compose-file FILE --gvc GVC` |

## Workflow: Deploy a Workload

```bash
# 1. Create a GVC with locations
cpln gvc create --name my-gvc \
  --location aws-us-west-2 \
  --location gcp-us-east1

# 2. Build and push an image
cpln image build --name my-app:v1.0 --push

# 3. Create a workload
cpln workload create --name my-app \
  --gvc my-gvc \
  --image //image/my-app:v1.0 \
  --port 8080 \
  --public

# 4. Verify
cpln workload get my-app --gvc my-gvc
```

For external images, use the exact reference: `nginx:latest`, `gcr.io/project/image:tag`. Never prefix with `docker.io/`.

## Workflow: Grant Secret Access (3 required steps)

The 3-step rule (identity + policy + reference) is defined in **rules/cpln-guardrails.md → Secret Access**. The CLI workflow that satisfies it:

```bash
# 1. Create a secret (payload is loaded from a file; use - for stdin)
cpln secret create-opaque --name db-password --file ./db-password.txt
# or from stdin: printf '%s' "my-secret-value" | cpln secret create-opaque --name db-password --file -

# 2. Create an identity and assign it to the workload
cpln identity create --name my-app-identity --gvc my-gvc
cpln workload update my-app --gvc my-gvc \
  --set spec.identityLink=//identity/my-app-identity

# 3. Create a policy granting reveal permission
cpln policy create --name secret-access \
  --target-kind secret \
  --resource db-password
cpln policy add-binding secret-access \
  --identity //gvc/my-gvc/identity/my-app-identity \
  --permission reveal

# Inject the secret into the workload
cpln workload update my-app --gvc my-gvc \
  --set spec.containers.main.env.DB_PASSWORD.value=cpln://secret/db-password.payload

# ALWAYS verify the injection landed — --set exits 0 even if the container name
# doesn't match, silently writing to a path that doesn't exist in the spec.
cpln workload get my-app --gvc my-gvc -o json \
  | jq '.spec.containers[] | select(.name == "main") | .env'
# If DB_PASSWORD is absent from the output, the container name was wrong.
# Re-run with the correct name from: cpln workload get my-app --gvc my-gvc -o json | jq '[.spec.containers[].name]'
```

## Workflow: GitOps with cpln apply

```bash
# 1. Export existing resources as templates (yaml-slim strips server-side metadata)
cpln gvc get my-gvc -o yaml-slim > manifests/gvc.yaml
cpln workload get my-app --gvc my-gvc -o yaml-slim > manifests/workload.yaml
cpln secret get my-secret -o yaml-slim > manifests/secret.yaml
cpln identity get my-identity --gvc my-gvc -o yaml-slim > manifests/identity.yaml
cpln policy get my-policy -o yaml-slim > manifests/policy.yaml

# 2. Edit manifests in version control

# 3. Apply EVERYTHING IN ONE CALL — let cpln resolve the dependency order
cpln apply --file ./manifests/ --gvc my-gvc --ready
# OR if all resources are in one multi-doc YAML file:
cpln apply --file all-resources.yaml --gvc my-gvc --ready
```

**Apply once, not file-by-file.** `cpln apply` walks the inter-resource dependency graph automatically when given a directory or a multi-doc YAML file (resources separated by `---`). Splitting into multiple apply calls — `cpln apply secret.yaml; cpln apply workload.yaml` — reintroduces the ordering problem cpln apply was designed to solve: workloads referencing secrets that haven't been applied yet, identity bindings before the identity exists, policies referencing missing target resources, etc.

**Single-file applies are for incremental updates to ONE existing resource** (e.g. `cpln apply --file workload-update.yaml --ready` after editing one workload's spec). Not the right shape for an initial deploy.

**When resources span multiple GVCs** — e.g. promoting the same app to dev, staging, and prod in one repo — declare the target GVC inline on each GVC-scoped resource via a top-level `gvc:` field (same level as `kind` / `name` / `description` / `tags`). Then apply the whole bundle without `--gvc`:

```yaml
kind: workload
name: my-app
gvc: prod          # ← target GVC declared inline
spec: { ... }
---
kind: workload
name: my-app
gvc: staging       # ← same workload name, different GVC — routed correctly
spec: { ... }
```

```bash
cpln apply --file ./manifests/ --ready    # cpln routes each to its declared gvc
```

For single-GVC bundles, the simpler pattern is `cpln apply --file ./manifests/ --gvc <gvc>` — the flag fills in the GVC for any GVC-scoped resource that doesn't declare one. See `rules/cli-conventions.md` → cpln apply for both patterns.

`cpln apply` is idempotent — run on every push. `--ready` blocks until healthy. Supports directories (`--file ./manifests/`), multi-doc YAML files, and stdin (`--file -`).

## Workflow: Rename or Duplicate a Resource

Resource names on Control Plane are **immutable** — there is no `rename` command. Use one of these two patterns.

### Preferred: `clone` (server-side spec duplicate)

`workload`, `policy`, `identity`, `mk8s`, and `auditctx` support a `clone` subcommand. It duplicates only the spec — no `status`, no `id`, no timestamps — so it round-trips cleanly:

```bash
# 1. Clone with the new name
cpln workload clone old-name --name new-name --gvc my-gvc

# 2. Verify the new workload is healthy
cpln workload get new-name --gvc my-gvc

# 3. Delete the old one only after verification
cpln workload delete old-name --gvc my-gvc
```

### Fallback: `get -o yaml-slim` → edit → apply

Use this when you need to change more than the name (e.g., image, env, ports) in one go:

```bash
# Always yaml-slim, never plain yaml — plain yaml includes status/id/timestamps that break apply
cpln workload get old-name --gvc my-gvc -o yaml-slim > new.yaml

# Edit name + any other fields, then apply
cpln apply --file new.yaml --gvc my-gvc --ready

# Delete the old workload
cpln workload delete old-name --gvc my-gvc
```

### What also has to be updated when a workload is renamed

The internal hostname (`<workload>.<gvc>.cpln.local`) and the public URL (`<workload>.<gvc>.cpln.app`) both change. Anything referencing the old name needs updating:

- Domain routes: `spec.ports[].routes[].workloadLink`
- Policies with workload-scoped `targetLinks` or `targetQuery`
- Identity bindings that pin to the workload link
- Other workloads calling it via internal DNS
- External consumers / clients

For multi-workload renames, script the clone/verify/delete loop with a CSV or list of pairs — never delete the old workload before the new one is verified healthy.

## Workflow: Debug a Failing Workload

```bash
# 1. Check logs
cpln logs '{gvc="my-gvc", workload="my-app"}' --org my-org

# 2. Stream logs in real-time
cpln logs '{gvc="my-gvc", workload="my-app"}' --org my-org --tail

# 3. Filter for errors (LogQL filter inside the query, not a shell pipe)
cpln logs '{gvc="my-gvc", workload="my-app"} |= "error"' --org my-org

# 4. Execute a command in the container
cpln workload exec my-app --gvc my-gvc -- env | grep CPLN

# 5. Open interactive shell
cpln workload connect my-app --gvc my-gvc

# 6. Forward a local port to the workload
cpln port-forward my-app 8080:8080 --gvc my-gvc
```

**Debugging a cron workload — query logs by execution, not by workload.** A plain `{gvc=, workload=}` query on a cron workload mixes logs from every past run, burying the failed one. Each execution runs in a separate replica with a unique `replica` ID. Use `cpln workload get-deployments <name> --gvc <gvc> -o json` to enumerate `status.jobExecutions[]` (with `name`, `status`, `startTime`, `completionTime`, `replica`), then scope logs to one execution by adding the `replica` label and bounding by its time window. Full pattern with examples: see **`logql-observability` skill → "Cron Workloads — Per-Execution Logs"**.

## Integration

| Tool | Purpose | Connection |
|---|---|---|
| **MCP Server** | AI agents manage infra via 55+ tools | `https://mcp.cpln.io/mcp` |
| **Terraform** | IaC with state management | `controlplane-com/cpln` provider |
| **Pulumi** | IaC with TS/JS, Python, Go, .NET | `@pulumiverse/cpln` (npm) / `pulumiverse-cpln` (pip) / `github.com/pulumiverse/pulumi-cpln` (Go) |
| **K8s Operator** | Manage cpln resources as K8s CRDs | See `k8s-operator` skill |
| **CI/CD** | Automated deployments | `CPLN_TOKEN` + `cpln apply --ready` |

### Key MCP Tools

| Tool | Purpose |
|---|---|
| `list_workloads` | List workloads in a GVC |
| `get_workload` | Get workload details |
| `create_workload` | Create a new workload |
| `update_workload` | Update workload properties |
| `list_gvcs` | List GVCs in an org |
| `create_gvc` | Create a new GVC |
| `list_secrets` | List secrets in an org |
| `create_secret` | Create a new secret |
| `get_workload_logs` | Query workload logs via LogQL |
| `get_workload_deployments` | View deployment history |
| `cpln_suggest` | Get CLI command suggestions (validates flags) |

## Reference

- CLI conventions & command map: `rules/cli-conventions.md`
- Platform guardrails & resource model: `rules/cpln-guardrails.md`

## Documentation

For the latest reference, see:

- [Control Plane Docs](https://docs.controlplane.com) — root site
- [Full page index for AI agents](https://docs.controlplane.com/llms.txt)
- [Introduction](https://docs.controlplane.com/introduction.md)
- [What is Control Plane?](https://docs.controlplane.com/whatis.md)
- [CLI Reference Overview](https://docs.controlplane.com/cli-reference/overview.md)
- [Reference Overview](https://docs.controlplane.com/reference/overview.md)
