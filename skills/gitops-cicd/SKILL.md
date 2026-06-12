---
name: gitops-cicd
description: "Sets up CI/CD pipelines and GitOps for Control Plane. Use when the user asks about GitHub Actions, GitLab CI, Bitbucket, CircleCI, building images in CI, kaniko, cpln apply in pipelines, or service-account tokens for CI."
---

# GitOps & CI/CD

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

In pipelines the **CLI is the primary interface**: authenticate with a service-account key in `CPLN_TOKEN` (no profile needed), push an image, `cpln apply --ready` the manifests. MCP tools do the work around the pipeline — `mcp__cpln__get_resource_schema` before authoring manifests, `mcp__cpln__list_deployments` to confirm a deploy landed. The usual failure is image builds: `cpln image build` runs the build **locally through Docker**, so on runners without a Docker daemon it cannot work — pick the build flow by runner capability, not by habit.

## Service-account authentication

```bash
cpln serviceaccount create --name ci-deployer --org ORG
cpln serviceaccount add-key ci-deployer --description "ci key" --org ORG   # --description is required
```

The JSON response's `key` value is the credential — store it as a masked/secret variable in the CI platform. MCP: `mcp__cpln__add_key_to_service_account` does both steps (and creates the service account if missing).

Grant least privilege (`access-control` skill): pushing images needs `create` on the `image` kind; `cpln apply` needs create/edit on every kind the manifests contain. `cpln group add-member superusers --serviceaccount ci-deployer` works but grants full org access — prefer a scoped policy (`mcp__cpln__create_policy`).

Set in the platform's variable settings, never inline in scripts:

| Variable | Role |
|---|---|
| `CPLN_TOKEN` | Service-account key (secret/masked) |
| `CPLN_ORG` | Target org |
| `CPLN_GVC` | Target GVC, when the pipeline targets one |
| `CPLN_SKIP_UPDATE_CHECK=1` | Silence CLI update checks in logs |

With `CPLN_TOKEN` set the CLI runs a profile-less session; resolution is flag, then env var, then profile (`cpln` skill). The official example repos persist the token instead — `cpln profile update default --token "$CPLN_TOKEN"` (`create` is an alias of `update`) — either works. Never pass `--token` on ad-hoc commands and never echo the token.

## Installing the CLI on runners

- npm (runner has Node 16+): `npm install -g @controlplane/cli@X.Y.Z` — pin the version. This installs both `cpln` **and** `docker-credential-cpln`.
- Slim or non-Node images: the binary tarball — copy **both** binaries onto PATH. The [containers guide](https://docs.controlplane.com/cli-reference/ci-cd-development/container-image.md) has Dockerfiles for each method, and covers running the CLI inside cron workloads.

## Building images in CI: pick the flow by runner capability

`cpln image build` is a **local build wrapper, not a remote build**: with a Dockerfile (`--dockerfile`, or auto-detected in `--dir`) it shells out to `docker buildx build` (legacy `docker build` fallback); with no Dockerfile it downloads the `pack` CLI and runs buildpacks. Every mode needs a working Docker daemon, and `--push` errors unless `docker-credential-cpln` is on PATH. It configures registry auth itself — no separate `docker-login` step.

| Runner | Build flow |
|---|---|
| Daemon available — GitHub-hosted runners, GitLab with the `docker:dind` service (privileged runners, including gitlab.com SaaS), CircleCI `setup_remote_docker`, Bitbucket `docker` service | `cpln image build --name APP:TAG --push`, or keep an existing docker-native pipeline: login below, then `docker build --platform linux/amd64` + `docker push` (`image` skill, Option B) |
| No daemon — self-managed GitLab runners without privileged mode, locked-down Kubernetes executors | Daemonless builder (kaniko, buildah, rootless BuildKit) pushing straight to the registry; the build job needs no cpln CLI at all |

The org registry is a **standard Docker registry**: `ORG.registry.cpln.io`, username = the literal string `<token>`, password = the service-account key. Any tool that can push an OCI image works:

```bash
echo "$CPLN_TOKEN" | docker login ORG.registry.cpln.io -u '<token>' --password-stdin
```

With the CLI installed, `cpln image docker-login` is the faster equivalent for raw `docker push`/`docker pull` jobs: instead of storing a secret it registers the `docker-credential-cpln` helper for the org registry, and Docker resolves the token from `CPLN_TOKEN` (or the profile) at every later call. Use the raw `docker login` form only where the CLI isn't on the box — kaniko auth files, CLI-less build jobs.

GitLab job without a daemon (kaniko; the runner must be amd64 — kaniko cannot cross-build):

```yaml
build:
  image:
    name: gcr.io/kaniko-project/executor:debug
    entrypoint: [""]
  script:
    - mkdir -p /kaniko/.docker
    - printf '{"auths":{"%s.registry.cpln.io":{"username":"<token>","password":"%s"}}}' "$CPLN_ORG" "$CPLN_TOKEN" > /kaniko/.docker/config.json
    - /kaniko/executor --context "$CI_PROJECT_DIR" --destination "$CPLN_ORG.registry.cpln.io/my-app:$CI_COMMIT_SHORT_SHA"
```

On GitHub, `docker/login-action` + `docker/build-push-action` also work with the same registry/credentials. Images must be `linux/amd64`; buildpack and multi-platform detail in the `image` skill.

**Tag every build uniquely** (`$CI_COMMIT_SHORT_SHA`, `${GITHUB_SHA:0:7}`). Re-pushing the same tag does not redeploy workloads — if a tag must be reused, set `supportDynamicTags` on the workload or run `cpln workload force-redeployment WORKLOAD` after the push.

## Applying manifests

Author YAML against the real shape first: `mcp__cpln__get_resource_schema` for each kind. The pipeline then runs:

```bash
cpln apply --file ./manifests/ --ready
```

- `--file` takes a file, a multi-document YAML (`---`), repeated `--file` flags, a directory (recursed; only `.yaml`/`.yml`/`.json` are picked up), or stdin (`--file -`).
- One invocation sorts everything by kind — agent, secret, cloudaccount, gvc, identity, volumeset, policy, workload, then all remaining kinds — so a workload and its GVC can live in one file in any order. `cpln delete --file` applies the reverse order.
- Apply is an upsert. **Renaming a resource in git creates a new resource**; the old one survives until deleted explicitly.
- A manifest with an inline `gvc:` that differs from `--gvc`/`CPLN_GVC` aborts the whole apply.
- `--ready` waits only for the workloads applied in that run: 5-second polls, three consecutive ready checks to pass, a ~5-minute cap, non-zero exit on timeout — a usable deploy gate.
- Seed the repo from a live resource: `cpln workload get NAME -o yaml-slim > workload.yaml` (strips server-managed fields).
- For Helm-chart-shaped releases, `cpln helm install|upgrade|rollback` tracks revisions — the platform's only rollback primitive (`environment-promotion` skill).

## GitHub Actions example

```yaml
name: deploy
on: { push: { branches: [main] } }
env:
  CPLN_TOKEN: ${{ secrets.CPLN_TOKEN }}
  CPLN_ORG: my-org
  CPLN_GVC: my-gvc
jobs:
  deploy:
    runs-on: ubuntu-latest # GitHub-hosted: Docker daemon available
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22 }
      - run: npm install -g @controlplane/cli@X.Y.Z
      - run: cpln image build --name my-app:${GITHUB_SHA:0:7} --push
      # manifests reference //image/my-app:IMAGE_TAG — substitute per commit
      - run: sed -i "s|IMAGE_TAG|${GITHUB_SHA:0:7}|" manifests/workload.yaml
      - run: cpln apply --file ./manifests/ --ready
```

Official starter repos (CLI): [GitHub Actions](https://github.com/controlplane-com/github-actions-example-cli), [GitLab CI](https://gitlab.com/controlplane-com/gitlab-pipeline-example-cli), [Bitbucket](https://bitbucket.org/controlplane-com/bitbucket-pipeline-example-cli), [CircleCI](https://github.com/controlplane-com/circle-ci-pipeline-example-cli), [Google Cloud Build](https://github.com/controlplane-com/google-cloud-build-example-cli). Terraform pipelines: `iac-terraform-pulumi` skill.

## Verify

- In-pipeline: the `cpln apply --ready` exit code is the deploy gate.
- Out-of-band: `mcp__cpln__list_deployments` for per-location readiness, `mcp__cpln__get_resource` (kind="image") to confirm the push landed. A workload that never goes ready: `workload` skill or the `/cpln:troubleshoot` command.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Cannot connect to the Docker daemon` from `cpln image build` | Runner has no daemon — enable dind/privileged mode, or switch to the daemonless flow above |
| `The docker-credential-cpln command is not accessible` on `--push` | Helper missing from PATH — npm installs it next to `cpln`; binary installs must copy both binaries |
| `docker login` or push gets 401 | Username must be the literal `<token>`; the key is the password; check it wasn't truncated |
| Push rejected for permissions | Pipeline service account lacks `create` on the `image` kind (`access-control`) |
| `cpln apply` 403 on one kind | Service-account policy doesn't cover that kind — grant per-kind create/edit |
| Apply aborts: `--gvc option ... does not match the gvc value` | Inline `gvc:` in a manifest disagrees with `--gvc`/`CPLN_GVC` |
| Pipeline pushed, workload kept the old code | Same tag re-pushed — use unique tags, `supportDynamicTags`, or `cpln workload force-redeployment` |
| `--ready` exits non-zero after ~5 min | Workload never became ready — check `mcp__cpln__list_deployments` and workload events |
| `exec format error` at runtime | Image isn't `linux/amd64` (`image` skill) |

## Quick reference

| Tool | Purpose |
|---|---|
| `mcp__cpln__get_resource_schema` | Manifest shape for any kind before authoring |
| `mcp__cpln__add_key_to_service_account` | Pipeline service account + key in one call |
| `mcp__cpln__create_policy` | Scope the pipeline service account's permissions |
| `mcp__cpln__list_deployments` | Per-location readiness after a deploy |
| `mcp__cpln__export_terraform` / `mcp__cpln__convert_to_terraform` | Seed IaC pipelines from live resources or manifests |

## Related skills

| Skill | When |
|---|---|
| `cpln` | CLI conventions — profile-less sessions, flag/env/profile precedence |
| `image` | Build mechanics, buildpacks, registry auth, pull secrets |
| `environment-promotion` | Moving images/configs across dev/staging/prod, rollback patterns |
| `iac-terraform-pulumi` | Terraform/Pulumi pipelines instead of `cpln apply` |
| `access-control` | Service accounts, groups, policies, least privilege |

## Documentation

- [CI/CD usage](https://docs.controlplane.com/cli-reference/ci-cd-development/ci-cd.md)
- [Using the CLI in containers](https://docs.controlplane.com/cli-reference/ci-cd-development/container-image.md)
- [CI/CD example repos](https://docs.controlplane.com/guides/gitops.md)
- [cpln apply](https://docs.controlplane.com/guides/cpln-apply.md)
- [Create a service account](https://docs.controlplane.com/guides/create-service-account.md)
