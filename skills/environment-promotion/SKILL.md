---
name: environment-promotion
description: "Promotes workloads across dev/staging/production on Control Plane. Use when the user asks about environment promotion, org-per-environment, cross-org image pulls, image promotion, deploying to production, or rollback."
---

# Environment Promotion

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Control Plane has **no built-in promote or rollback primitive** — promotion is applying the same artifacts (image + manifests) to the next environment. Two topologies exist: **org-per-environment (the documented best practice)** and GVC-per-environment. The recurring failure is image access: a staging/prod org cannot pull the dev org's images until you either copy the image or wire up a cross-org pull secret.

## Choosing a topology

| Topology | Isolation | Image sharing | Best for |
|---|---|---|---|
| **Org per environment** (recommended) | Strongest — policies, secrets, users, audit fully separate | `cpln image copy` or cross-org pull secret | Production, compliance-sensitive teams |
| **GVC per environment** (one org) | Weak — shared org policies and access | Same org registry; no pull secret needed | Small teams, rapid iteration |

With org-per-environment, GVCs and workloads keep **identical names** in every org, so the same manifests apply unchanged — no environment suffixes in resource names. Org creation is account-level: Console, or `cpln org create --accountId ID --invitee EMAIL`.

## Promoting manifests

Keep manifests in git and apply them per environment — `cpln apply` is idempotent (PUT upsert) and resolves resource ordering:

```bash
cpln apply --file ./manifests/ --org my-org-staging --gvc my-gvc --ready   # org-per-env: same files, next org
cpln apply --file ./manifests/ --org my-org --gvc staging-gvc --ready     # gvc-per-env: same files, next GVC
```

- Bootstrap manifests from a live environment with `cpln <resource> get REF -o yaml-slim` (plain `yaml` output breaks apply).
- Environment differences (env vars, scaling, firewall) belong in the manifests per environment — or patch after apply with `mcp__cpln__update_workload` / `mcp__cpln__update_gvc` (both PATCH semantics).
- For IaC-based promotion, export live resources to Terraform: `mcp__cpln__export_terraform` (one self link, or bulk by path depth — a whole GVC or org), `mcp__cpln__export_terraform_batch` (full profile, up to 100 explicit links), `mcp__cpln__convert_to_terraform` (manifest to HCL, dry-run validated). An unsupported kind is rejected with the supported list.

## Sharing images across orgs

### Option A — copy the image (one-time promotions)

```bash
cpln image copy my-app:abc1234 --to-org my-org-prod              # same credentials for both orgs
cpln image copy my-app:abc1234 --to-org my-org-prod --to-profile prod-profile --cleanup
```

CLI-only (no MCP tool); requires a running Docker daemon — it docker-logins both registries, then pulls, tags, pushes. `--to-name` renames during copy; `--cleanup` removes the local images (use in CI). Needs `pull` permission on the source image and `create` on images in the target org. After the copy the target references it as `//image/my-app:abc1234` — no pull secret.

### Option B — cross-org pull secret (continuous access)

The target org pulls directly from the source org's registry. Four steps:

1. **Source org — puller credentials**: `mcp__cpln__add_key_to_service_account` (creates the service account if missing; the key is shown **once**).
2. **Source org — grant pull**: `mcp__cpln__create_policy` with `targetKind: image`, `targetAll: true` (or `targetQuery` by repository), `addPermissions: ["pull"]`, `addServiceAccounts: [LINK]` — bindings go in the create call.
3. **Target org — docker secret**: `mcp__cpln__create_secret_docker` with `dockerConfigJson` — the username is the **literal string `<token>`** (the registry rejects anything else; the password is the service-account key):

```json
{ "auths": { "my-org-dev.registry.cpln.io": { "username": "<token>", "password": "SERVICE_ACCOUNT_KEY" } } }
```

4. **Target org — attach to the GVC**: `mcp__cpln__update_gvc` with `pullSecretLinks: ["//secret/dev-registry-pull"]` (merged with existing), then reference the image by its **full registry hostname** in the workload spec:

```yaml
spec:
  containers:
    - name: main
      image: my-org-dev.registry.cpln.io/my-app:abc1234
```

CLI fallback for the same four steps:

```bash
cpln serviceaccount create --name image-puller --org my-org-dev                            # CLI does NOT auto-create on add-key
cpln serviceaccount add-key image-puller --description "cross-org pull" --org my-org-dev   # save the key
cpln policy create --name image-pull --target-kind image --all --org my-org-dev
cpln policy add-binding image-pull --serviceaccount image-puller --permission pull --org my-org-dev
cpln secret create-docker --name dev-registry-pull --file docker-config.json --org my-org-prod
cpln gvc update my-gvc --set 'spec.pullSecretLinks+=//secret/dev-registry-pull' --org my-org-prod
```

Same-org images never need a pull secret — the platform injects a default registry credential for the org's own registry automatically.

## Image tags across environments

- **Promote immutable tags** (git SHA `my-app:abc1234` or semver `my-app:v1.2.3`) — promote the exact artifact you tested; mutable tags (`latest`, `staging`) make rollback unreliable. Digest pins (`my-app@sha256:...`) are maximally reproducible.
- **`supportDynamicTags`** (workload spec, default `false`): redeploys the workload automatically when a tag's underlying digest changes (within ~5 minutes) — useful for dev environments on mutable tags, wrong for production promotion.

## CI/CD promotion pipeline

The CLI is the primary interface in pipelines; `CPLN_TOKEN` alone is enough (no profile needed — see the `cpln` skill). The shape that works:

```yaml
# Build once in dev, then per stage: copy the image + apply the manifests
- run: cpln image build --name my-app:${{ github.sha }} --push     # CPLN_TOKEN + CPLN_ORG=my-org-dev
- run: cpln apply --file ./manifests/ --gvc my-gvc --ready

# staging / prod stages (gate each with environment approvals):
- run: cpln image copy my-app:${{ github.sha }} --to-org my-org-prod --cleanup   # dev-org token
- run: cpln apply --file ./manifests/ --gvc my-gvc --org my-org-prod --ready     # prod-org token
```

- **One service-account token per org** — a dev-org token must not be able to touch prod; the copy step runs with source-org credentials plus a `--to-profile` (or pre-run `cpln image docker-login`) for the target.
- **`--ready` gates promotion** — it polls until workloads are healthy (5s interval, up to 5 min) and fails the job otherwise.
- Approval gates (GitHub environments, GitLab manual jobs) go between stages. Full pipeline setup, npm install (`@controlplane/cli`), runners: `gitops-cicd` skill.

## Rollback

There is no deployment-history rollback — rolling back means **re-pointing the workload at the previous known-good image** (keep the previous tag in git history or your pipeline metadata):

```bash
cpln workload update my-app --set spec.containers.main.image=//image/my-app:v1.1.0 --gvc my-gvc --org my-org
cpln workload get-deployments my-app --gvc my-gvc --org my-org    # verify every location reports ready
```

- MCP path: `mcp__cpln__get_resource` (kind="workload") to record the current image, `mcp__cpln__update_workload` (`containers: [{name, image}]` — merged by container name), then poll `mcp__cpln__list_deployments` until ready.
- Org-per-environment: confirm the older image still exists in **this** org's registry first (`mcp__cpln__list_resources` kind="image") — it may only have been copied forward once.
- **Restart without changing the image**: `cpln workload force-redeployment my-app --gvc GVC` — it PATCHes a `cpln/deployTimestamp` tag with the current time, producing a rolling restart. No MCP equivalent; `mcp__cpln__update_workload` setting that same tag replicates it.
- Helm-managed releases are the exception with real revision history: `cpln helm rollback RELEASE [REVISION]`.

## Quick reference — MCP tools

| Tool | Purpose |
|---|---|
| `mcp__cpln__create_gvc` / `mcp__cpln__create_workload` | Stand up the target environment |
| `mcp__cpln__update_workload` / `mcp__cpln__update_gvc` | Patch image, env, scaling, `pullSecretLinks` (PATCH semantics) |
| `mcp__cpln__add_key_to_service_account` | Puller credentials in the source org (auto-creates the SA; key shown once) |
| `mcp__cpln__create_policy` | Grant `pull` on images, binding included in the create call |
| `mcp__cpln__create_secret_docker` | Docker secret from `dockerConfigJson` (username `<token>`) |
| `mcp__cpln__list_deployments` | Verify a promotion or rollback is ready per location |
| `mcp__cpln__export_terraform` / `_batch` / `mcp__cpln__convert_to_terraform` | Export live environments to IaC |

**CLI fallback** (read the `cpln` skill first; CI/CD uses `CPLN_TOKEN` + `cpln apply --ready`): `cpln image copy` and `cpln image build --push` are CLI-only — no MCP equivalent.

## Related skills

| Need | Skill |
|---|---|
| Image building, registries, pull-secret detail | `image` |
| Pipeline setup, runners, service-account auth | `gitops-cicd` |
| Terraform / Pulumi promotion | `iac-terraform-pulumi` |
| Per-environment secrets and RBAC | `access-control` |

## Documentation

- [Environment Promotion Guide](https://docs.controlplane.com/guides/environment-promotion.md)
- [Copy an Image Guide](https://docs.controlplane.com/guides/copy-image.md)
- [cpln apply Guide](https://docs.controlplane.com/guides/cpln-apply.md)
