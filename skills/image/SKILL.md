---
name: image
description: "Builds, pushes, and manages container images on Control Plane. Use when the user asks about Docker build, image registry, tags, digests, Dockerfile, buildpacks, pull secrets, ECR/GCR/Docker Hub, or image permissions."
---

# Control Plane Images

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Every org gets a private registry at `ORG.registry.cpln.io` — a standard Docker registry (`docker login`/`push`/`pull`/`search` all work). Pushing a tag automatically creates an **image resource** named `NAME:TAG` in the org (read-only `repository`, `tag`, `digest`, `manifest` fields; only metadata tags are editable). There is no create/build/push over MCP or the API — `POST /org/ORG/image` returns 403 "You can create an image only by pushing"; build, push, and copy are CLI-exclusive. The recurring failures are a wrong reference form, a non-`linux/amd64` image (`exec format error`), and a missing or mismatched pull secret.

## Image references

| Source | Reference in workload spec | Pull secret |
|---|---|---|
| Your org's registry (preferred) | `//image/NAME:TAG` (long form `/org/ORG/image/NAME:TAG`) | No — automatic |
| Your org's registry (hostname form) | `ORG.registry.cpln.io/NAME:TAG` — the API rewrites it to the link form on write | No — automatic |
| Another Control Plane org | `OTHER-ORG.registry.cpln.io/NAME:TAG` — stays a literal external reference | Yes (`docker`) |
| Public registry | Exact string: `nginx:latest`, `ghcr.io/owner/app:v1` — **never add a `docker.io/` prefix** | No |
| Private external registry (ECR, GCR/GAR, private Docker Hub, ACR...) | Full host path, e.g. `ACCOUNT.dkr.ecr.REGION.amazonaws.com/app:v1` | Yes |

- "Image name" always includes the tag (`my-app:v1.0`); a missing tag means `:latest`. Name and tag each max 128 chars; at most two `:` (the second only for a registry port); digest pinning `NAME@sha256:HEX` is supported.
- Link references (`/...`) must point into the same org — other orgs are reached only via their registry hostname, which is why they need a pull secret.

## Build and push

`cpln image build` is a **local build wrapper, not a remote build** — every mode needs a Docker daemon. `--name NAME:TAG` is required (it aborts without a tag). With a Dockerfile (`--dockerfile PATH`, or auto-detected at `DIR/Dockerfile`) it shells out to `docker buildx build` (legacy `docker build` fallback; multi-platform still requires Buildx). With no Dockerfile it downloads the `pack` CLI and runs buildpacks (arguments after `--` pass through to `pack`). Other flags: `--push`, `--dir` (default `.`), `--platform` (default `linux/amd64`), `--no-cache`, `--builder`/`-B`, `--buildpack`/`-b`, `--env`/`--env-file` (build-time only, NOT runtime), `--trust-builder`. Multi-platform builds (comma-separated `--platform`) require `--push` — the local daemon cannot load a multi-arch manifest.

```bash
cpln image build --name my-app:v1.0 --push --org my-org   # reference as //image/my-app:v1.0
```

`--push` configures registry auth itself (no separate login step) but hard-errors unless `docker-credential-cpln` is on PATH (installed with the CLI). For a Docker-native flow instead:

```bash
cpln image docker-login --org my-org   # registers the docker-credential-cpln helper in ~/.docker/config.json
docker buildx build --platform=linux/amd64 -t my-org.registry.cpln.io/my-app:v1.0 .
docker push my-org.registry.cpln.io/my-app:v1.0
```

`docker-login` stores no secret — Docker resolves a live token from `CPLN_TOKEN` or the profile on every call. **CI/CD is a different flow** (`gitops-cicd` skill): runners with a Docker daemon can use either path above; daemonless runners (kaniko, buildah) push directly to the registry — it accepts any OCI client with username the **literal string `<token>`** and a service-account key as password. **All images must be `linux/amd64`**; nothing checks the architecture at push or deploy — a wrong-arch image fails at container start with `exec format error`.

### Buildpacks (no Dockerfile)

Default builder `heroku/builder:24_linux-amd64`. A `Procfile` (one line: `web: START-COMMAND`) defines the start command; servers must bind `0.0.0.0` and listen on `$PORT`.

| Language | Detected by | Notes |
|---|---|---|
| Node.js | `package.json` + a lockfile | No lockfile means not detected; start from `scripts.start`, `server.js`, or Procfile |
| Python | `requirements.txt`, `uv.lock`, or `poetry.lock` | **Procfile REQUIRED** — without it the image builds but exits immediately |
| Go | `go.mod` (main package in root) | |
| Java | `pom.xml`, or `build.gradle` + `gradlew` | Spring Boot auto-detected; other frameworks need a Procfile |
| Ruby | `Gemfile` + `Gemfile.lock` | Rails auto-detected; non-Rails needs a Procfile |
| PHP | `composer.json` + `composer.lock` | **Procfile REQUIRED** |
| Rust | NOT in the default builder | Add `-b docker.io/paketocommunity/rust` |
| C# / .NET | NOT in the default builder | Use `-B paketobuildpacks/builder-jammy-base`; set `ASPNETCORE_URLS=http://0.0.0.0:$PORT` |

## Pulling

- **Same org:** automatic. The platform injects a managed `default-registry` credential into every GVC namespace — never create a pull secret for your own org's images.
- **Public images:** no setup.
- **Private registries (including other Control Plane orgs):** attach a secret to the **GVC** at `spec.pullSecretLinks` — it applies to all workloads in the GVC; there is no per-workload attachment. Only three secret types work as pull secrets: `docker` (Docker Hub, GHCR, ACR, GAR, other Control Plane orgs — matched to images by registry host in its `auths`), `ecr` (its `repos` list must contain the image's repository; credentials are exchanged for ECR tokens and refreshed automatically), and `gcp` (matched only for images under its own project: `gcr.io/PROJECT/...` or `REGION-docker.pkg.dev/PROJECT/...`).
- **Failures are silent:** a linked secret of the wrong type, or one that fails to materialize, is skipped at deploy with no configuration-time error — the symptom is only an image-pull failure on the replica.

Attach with `mcp__cpln__update_gvc` (`pullSecretLinks` is **merged** with existing links; `removePullSecretLinks` removes; an empty list clears all). Create the secret with `mcp__cpln__create_secret_docker` (single `dockerConfigJson` string — for another Control Plane org use username `<token>` and a service-account key as password), `mcp__cpln__create_secret_ecr`, or `mcp__cpln__create_secret_gcp`. CLI fallback: `cpln gvc update GVC --set 'spec.pullSecretLinks+=//secret/NAME' --org ORG`. The full cross-org setup (source-org service account, pull policy, target-org secret, GVC) is in the `environment-promotion` skill; `cpln image copy NAME:TAG --to-org ORG2 [--to-name NEW] [--to-profile P] [--cleanup]` is the one-time alternative — it docker-logins both orgs, then pulls, retags, and pushes through the **local Docker daemon** (needs `pull` on the source, `create` on the destination).

## Permissions

| Permission | Grants | Implies |
|---|---|---|
| `create` | Create an image — **this is the push permission** | `pull` |
| `pull` | Pull an image (docker pull, cross-org access) | `view` |
| `edit` | Modify the image resource — only metadata tags can change | `view` |
| `delete` | Delete an image | — |
| `view` | Read-only access | — |
| `manage` | Full access | all of the above |

**Registry authorization is repository-granular.** When the registry checks a docker push or pull it evaluates the permission against `REPOSITORY:*` (tag wildcarded, no resource link) — so a policy whose `targetLinks` list specific `NAME:TAG` images **never authorizes a docker push or pull**. Scope registry policies to all images, or use a `targetQuery` on the `repository` property (`mcp__cpln__create_policy` with `targetKind: image`; image queries support `name`, `id`, `tag`, `digest`, `repository`, `created`, `lastModified`). Tag-specific `targetLinks` only gate API operations on that image record (view/edit/delete).

## Tags, digests, and redeployment

Pushing an existing tag again **updates the same image resource** (new digest, same name) — but running workloads do not follow it by default:

- **`supportDynamicTags: false` (default):** the reference is resolved at container start. Serverless pods pull on every start; standard/stateful/cron pods may reuse a node-cached image for any non-`latest` tag — so `cpln workload force-redeployment` after a same-tag push is **not guaranteed** to pick up the new content on every node.
- **`supportDynamicTags: true`:** the platform re-resolves every container tag to a digest about every 5 minutes and on each workload change, records the result in `status.resolvedImages` (digest, per-platform manifests, `errorMessages`), and when a digest changes patches the workload — rolling out new pods pinned to `IMAGE@sha256:...`. Digest-pinned references are skipped.

For production, prefer immutable tags (commit SHA, semver) or digest pinning; reserve `supportDynamicTags` for dev/staging convenience.

## CLI subcommands

`build`, `copy`, `docker-login`, `get [REF...]` (no ref lists all), `delete REF...`, `edit`, `patch`, `query` (`--prop repository=my-app`), `tag` (**metadata** key=value tags on the image resource, NOT docker version tags), `permissions`, `access-report`, `audit`. There is **no `cpln image push` or `pull`** — push via `build --push` or `docker push` after `docker-login`. Verify flags with `cpln image SUBCOMMAND --help` before authoring commands.

## Verify

- After a push: `mcp__cpln__get_resource` (kind="image", name="NAME:TAG") — check `digest` and `lastModified`; `mcp__cpln__list_resources` (kind="image") to list.
- After a workload image change: `mcp__cpln__list_deployments` for per-location readiness; with dynamic tags, inspect `status.resolvedImages` via `mcp__cpln__get_resource` (kind="workload") for `errorMessages` and the resolved digest.
- CLI fallback (CI/CD): `CPLN_TOKEN` + `cpln image get NAME:TAG --org ORG -o json`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `exec format error` at start | Wrong architecture — rebuild with `--platform linux/amd64` |
| `docker login` returns "First, grant docker access... cpln image docker-login" | Username was not the literal `<token>` — run `cpln image docker-login`, or login with `-u '<token>'` |
| Push/pull 401 "Not authorized to push/pull" | Principal lacks `create` (push) or `pull` on the repository — and tag-scoped `targetLinks` policies never match; use all-images or a `repository` targetQuery |
| `cpln image build --push` errors about `docker-credential-cpln` | Helper not on PATH — reinstall the CLI, or build with plain docker after `docker-login` |
| `Cannot connect to the Docker daemon` | `cpln image build`/`copy` need a local daemon — in CI use the daemonless flow (`gitops-cicd` skill) |
| Image pull fails although a pull secret is linked | Wrong secret type (only docker/ecr/gcp work) or host mismatch (`auths` key, ECR `repos` entry, GCP project) — bad secrets are skipped silently |
| Same-tag push not picked up | Expected with `supportDynamicTags: false` — see Tags and redeployment above |
| `status.resolvedImages.errorMessages`: "unable to parse image" | Resolver limitation for single-segment images with non-alphanumeric tags (`nginx:1.25`) — reference it as `library/nginx:1.25` |
| `errorMessages`: "Backing off due to a rate-limit" | Upstream registry returned 429 to tag resolution — wait, or authenticate the registry via a pull secret |
| Buildpack image builds but exits immediately | Missing `Procfile` (required for Python and PHP; no web-server auto-detection) |

## Quick reference

MCP tools — images are list/get/delete only; there is no create-, update-, build-, push-, or copy-image tool:

- `mcp__cpln__list_resources` / `mcp__cpln__get_resource` (kind="image") — list, or inspect tags/digest/manifest.
- `mcp__cpln__delete_resource` (kind="image", name="NAME:TAG") — removes that image record from the org (destructive).
- `mcp__cpln__update_gvc` — attach pull secrets; `mcp__cpln__create_secret_docker` / `mcp__cpln__create_secret_ecr` / `mcp__cpln__create_secret_gcp` — create them.
- `mcp__cpln__update_workload` — change a container's image; `mcp__cpln__get_resource_schema` (kind="image") for the exact resource shape.

### Related skills

- **workload** — the primary skill: container spec, where the image reference lives.
- **gitops-cicd** — building and pushing from CI: runner capability, daemonless builders, service-account auth.
- **environment-promotion** — cross-org image sharing and promotion workflows.
- **access-control** — policy mechanics behind image permissions.
- **cpln** — CLI conventions and shared flags.

## Documentation

- [Image Reference](https://docs.controlplane.com/reference/image.md) — resource, permissions, dynamic tags
- [Push an Image](https://docs.controlplane.com/guides/push-image.md) | [Pull an Image](https://docs.controlplane.com/guides/pull-image.md) | [Copy an Image](https://docs.controlplane.com/guides/copy-image.md)
- [Buildpacks Guide](https://docs.controlplane.com/guides/buildpacks.md) — per-language detail
- [CLI Image Commands](https://docs.controlplane.com/cli-reference/commands/image.md)
