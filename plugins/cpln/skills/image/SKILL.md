---
name: image
description: "Builds, pushes, and manages container images on Control Plane. Use when the user asks about Docker build, remote build, image registry, tags, digests, Dockerfile, buildpacks, pull secrets, ECR/GCR, or image permissions."
---

# Control Plane Images

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads work on every profile via the generic `list_resources` / `get_resource` tools; `delete_resource` is on every profile except `readonly`.

Every org gets a private registry at `ORG.registry.cpln.io` — a standard Docker registry (`docker login`/`push`/`pull`/`search` all work). Pushing a tag automatically creates an **image resource** named `NAME:TAG` in the org (read-only `repository`, `tag`, `digest`, `manifest` fields; only metadata tags are editable). An image resource is never created directly — `POST /org/ORG/image` returns 403 "You can create an image only by pushing" — but a **build** can run on Control Plane instead of local Docker (`cpln image build --remote`), which is the answer whenever there is no Docker daemon. The recurring failures are a wrong reference form, a non-`linux/amd64` image (`exec format error`), and a missing or mismatched pull secret.

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

`--name NAME:TAG` is required — the command aborts without a tag. Everything else follows from **where the build runs**: no Docker daemon on this machine or runner means `--remote`.

| | Local (default) | Remote (`--remote`) |
|---|---|---|
| **Runs on** | Your machine or runner — `docker buildx build` (legacy `docker build` fallback), or `pack` when there is no Dockerfile | Control Plane's build service |
| **Needs** | A Docker daemon; `docker-credential-cpln` on PATH for `--push` | The CLI token and org — no daemon, no buildx, no `pack`, no credential helper |
| **Source** | `--dir` (default `.`); Dockerfile auto-detected at `DIR/Dockerfile` or given with `--dockerfile PATH` | `--dir` (uploaded) **or** `--repo <https URL>` + optional `--branch` — mutually exclusive |
| **Build method** | Dockerfile, else buildpacks (`--builder`/`-B`, `--buildpack`/`-b`; args after `--` go to `pack`) | Auto-detected — Dockerfile when present, otherwise a generated build. Not selectable |
| **Push** | Only with `--push` | Always, to the org registry — `--push` is **rejected** |
| **Platform** | `--platform`, default `linux/amd64`; a multi-platform list needs buildx **and** `--push` | Always `linux/amd64` — `--platform` is **rejected** |
| **Build-time env** | `--env` / `--env-file` — build-time only, **never** runtime | **Not supported yet** — `--env` / `--env-file` are **rejected** with `--remote` |

Both need `create` on `image` in the target org. **Rejected with `--remote`:** `--dockerfile`, `--builder`/`-B`, `--buildpack`/`-b`, `--env`, `--env-file`, `--trust-builder`, `--trust-extra-buildpacks`, `--platform`, `--push`. **Remote-only** (they error without `--remote`): `--repo`, `--branch`, `--detach`.

### Remote builds (`--remote`)

```bash
cpln image build --name my-app:v1.0 --remote --org my-org                      # upload and build the current folder
cpln image build --name my-app:v1.0 --remote --repo https://github.com/o/a --branch main
cpln image build --name my-app:v1.0 --remote --detach                          # returns a build id, does not watch
```

- **Folder upload** honors `.dockerignore` at the folder root, or `.gitignore` when there is no `.dockerignore`. Caps: 500 MB, 20,000 files, 20,000 directories. `.git`, `node_modules`, `__pycache__`, `.venv`, `venv`, `.mypy_cache`, `.pytest_cache`, `.ruff_cache`, `.DS_Store`, `Thumbs.db`, `desktop.ini` are always excluded (re-include with a `!` rule); `Dockerfile` and `.dockerignore` are force-included. **A symlink pointing outside the folder fails the build.** Rebuilds of the same image NAME upload only changed files — `--no-cache` forces a full re-upload.
- **`--repo` takes `github.com` and `gitlab.com` HTTPS URLs only.** An SSH remote or a URL with embedded credentials is rejected; any other host needs support@controlplane.com.
- **A private repo builds through the org's git connection, set up once.** The first build that needs it opens a browser to an authorization URL and then continues on its own; in a **non-interactive shell the CLI prints the URL and exits** — authorize, then re-run. The link is single-use and expires shortly. Later builds are silent.
- **Watching is not the build.** Logs stream until the push. `Ctrl+C` stops watching and **the build keeps running remotely** — check it with `cpln image get NAME:TAG`. The CLI also gives up watching after 20 minutes, which is not a failure either.

### Local builds

```bash
cpln image build --name my-app:v1.0 --push --org my-org   # reference as //image/my-app:v1.0
```

`--push` configures registry auth itself (no separate login step) but hard-errors unless `docker-credential-cpln` is on PATH (installed with the CLI). For a Docker-native flow instead:

```bash
cpln image docker-login --org my-org   # registers the docker-credential-cpln helper in ~/.docker/config.json
docker buildx build --platform=linux/amd64 -t my-org.registry.cpln.io/my-app:v1.0 .
docker push my-org.registry.cpln.io/my-app:v1.0
```

`docker-login` stores no secret — Docker resolves a live token from `CPLN_TOKEN` or the profile on every call. Daemonless CI builders (kaniko, buildah) can also push straight to the registry — it accepts any OCI client with username the **literal string `<token>`** and a service-account key as password (`gitops-cicd` skill). **All images must be `linux/amd64`**; nothing checks the architecture at push or deploy — a wrong-arch image fails at container start with `exec format error`.

### Buildpacks (local builds only)

`--remote` detects and builds the source itself and never runs `pack`, so nothing here applies to it. Default builder `heroku/builder:24_linux-amd64`. A `Procfile` (one line: `web: START-COMMAND`) defines the start command; servers must bind `0.0.0.0` and listen on `$PORT`.

| Language | Detected by | Trap |
|---|---|---|
| Node.js | `package.json` + a lockfile | No lockfile means not detected; start from `scripts.start`, `server.js`, or Procfile |
| Python, PHP | `requirements.txt` / `uv.lock` / `poetry.lock`; `composer.json` + `composer.lock` | **Procfile REQUIRED** — without it the image builds but exits immediately |
| Go, Java, Ruby | `go.mod`; `pom.xml` or `build.gradle` + `gradlew`; `Gemfile` + `Gemfile.lock` | Spring Boot and Rails auto-detected; anything else needs a Procfile |
| Rust, C# / .NET | NOT in the default builder | Rust: `-b docker.io/paketocommunity/rust`. .NET: `-B paketobuildpacks/builder-jammy-base` plus `ASPNETCORE_URLS=http://0.0.0.0:$PORT` |

## Pulling

- **Same org:** automatic. The platform injects a managed `default-registry` credential into every GVC namespace — never create a pull secret for your own org's images.
- **Public images:** no setup.
- **Private registries (including other Control Plane orgs):** attach a secret to the **GVC** at `spec.pullSecretLinks` — it applies to all workloads in the GVC; there is no per-workload attachment. Only three secret types work as pull secrets: `docker` (Docker Hub, GHCR, ACR, GAR, other Control Plane orgs — matched to images by registry host in its `auths`), `ecr` (its `repos` list must contain the image's repository; credentials are exchanged for ECR tokens and refreshed automatically), and `gcp` (matched only for images under its own project: `gcr.io/PROJECT/...` or `REGION-docker.pkg.dev/PROJECT/...`).
- **Failures are silent:** a linked secret of the wrong type, or one that fails to materialize, is skipped at deploy with no configuration-time error — the symptom is only an image-pull failure on the replica.

Attach with `mcp__cpln__update_gvc` (`pullSecretLinks` is **merged** with existing links; `removePullSecretLinks` removes; an empty list clears all). The registry secret (`docker` — single `dockerConfigJson` string, for another Control Plane org username is the literal `<token>` and the password a service-account key — `ecr`, or `gcp`) must already exist — if it doesn't, offer to draft the manifest for the user to fill and apply (`setup-secret` skill). CLI fallback: `cpln gvc update GVC --set 'spec.pullSecretLinks+=//secret/NAME' --org ORG`. The full cross-org setup (source-org service account, pull policy, target-org secret, GVC) is in the `environment-promotion` skill; `cpln image copy NAME:TAG --to-org ORG2 [--to-name NEW] [--to-profile P] [--cleanup]` is the one-time alternative — it docker-logins both orgs, then pulls, retags, and pushes through the **local Docker daemon** (needs `pull` on the source, `create` on the destination).

## Permissions

| Permission | Grants | Implies |
|---|---|---|
| `create` | Create an image — **this is the push permission** | `pull` |
| `pull` | Pull an image (docker pull, cross-org access) | `view` |
| `edit` | Modify the image resource — only metadata tags can change | `view` |
| `delete` | Delete an image | — |

`view` is read-only; `manage` implies all of the above.

**Registry authorization is repository-granular.** When the registry checks a docker push or pull it evaluates the permission against `REPOSITORY:*` (tag wildcarded, no resource link) — so a policy whose `targetLinks` list specific `NAME:TAG` images **never authorizes a docker push or pull**. Scope registry policies to all images, or use a `targetQuery` on the `repository` property (`mcp__cpln__create_policy` with `targetKind: image`; image queries support `name`, `id`, `tag`, `digest`, `repository`, `created`, `lastModified`). Tag-specific `targetLinks` only gate API operations on that image record (view/edit/delete).

## Tags, digests, and redeployment

Pushing an existing tag again **updates the same image resource** (new digest, same name) — but running workloads do not follow it by default:

- **`supportDynamicTags: false` (default):** the reference is resolved at container start. Serverless pods pull on every start; standard/stateful/cron pods may reuse a node-cached image for any non-`latest` tag — so `cpln workload force-redeployment` after a same-tag push is **not guaranteed** to pick up the new content on every node.
- **`supportDynamicTags: true`:** the platform re-resolves every container tag to a digest about every 5 minutes and on each workload change, records the result in `status.resolvedImages` (digest, per-platform manifests, `errorMessages`), and when a digest changes patches the workload — rolling out new pods pinned to `IMAGE@sha256:...`. Digest-pinned references are skipped.

For production, prefer immutable tags (commit SHA, semver) or digest pinning; reserve `supportDynamicTags` for dev/staging convenience.

## CLI subcommands

`build`, `copy`, `docker-login`, `get [REF...]` (no ref lists all), `delete REF...`, `edit`, `patch`, `query` (`--prop repository=my-app`), `tag` (**metadata** key=value tags on the image resource, NOT docker version tags), `permissions`, `access-report`, `audit`. There is **no `cpln image push` or `pull`** — push via `build --remote`, `build --push`, or `docker push` after `docker-login`. **`copy` has no `--remote` mode and still needs a local Docker daemon.** Verify flags with `cpln image SUBCOMMAND --help` before authoring commands.

## Verify

- After a push: `mcp__cpln__get_resource` (kind="image", name="NAME:TAG") — check `digest` and `lastModified`; `mcp__cpln__list_resources` (kind="image") to list.
- After a workload image change: `mcp__cpln__list_deployments` for per-location readiness; with dynamic tags, inspect `status.resolvedImages` via `mcp__cpln__get_resource` (kind="workload") for `errorMessages` and the resolved digest.
- After a detached or interrupted remote build: `cpln image get NAME:TAG --org ORG` — the image appears only once the build pushes. `mcp__cpln__get_image_build` reads a build's status and log by id.
- CLI fallback (CI/CD): `CPLN_TOKEN` + `cpln image get NAME:TAG --org ORG -o json`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `exec format error` at start | Wrong architecture — rebuild with `--platform linux/amd64` |
| `docker login` returns "First, grant docker access... cpln image docker-login" | Username was not the literal `<token>` — run `cpln image docker-login`, or login with `-u '<token>'` |
| Push/pull 401 "Not authorized to push/pull" | Principal lacks `create` (push) or `pull` on the repository — and tag-scoped `targetLinks` policies never match; use all-images or a `repository` targetQuery |
| `cpln image build --push` errors about `docker-credential-cpln` | Helper not on PATH — reinstall the CLI, build with plain docker after `docker-login`, or use `--remote` (which needs no helper) |
| `Cannot connect to the Docker daemon` | Only local builds need one — add `--remote` to build on Control Plane instead (`copy` still needs a daemon) |
| A flag is rejected together with `--remote` | Expected — the service picks the build method and always pushes `linux/amd64`. Build-time env is not forwarded to a remote build yet; build locally if you need it |
| `--repo` / `--branch` / `--detach` errors | Remote-only flags — add `--remote` (and `--branch` also requires `--repo`) |
| A remote build prints an authorization URL and exits | Non-interactive shell and the org has no git connection yet — open the URL (single-use, expires shortly), authorize, re-run. Only private repos need it |
| Remote build upload rejected — over 500 MB / 20,000 files | Add the large paths to `.dockerignore` (or `.gitignore` if you have no `.dockerignore`) and re-run |
| Image pull fails although a pull secret is linked | Wrong secret type (only docker/ecr/gcp work) or host mismatch (`auths` key, ECR `repos` entry, GCP project) — bad secrets are skipped silently |
| Same-tag push not picked up | Expected with `supportDynamicTags: false` — see Tags and redeployment above |
| `status.resolvedImages.errorMessages`: "unable to parse image" | Resolver limitation for single-segment images with non-alphanumeric tags (`nginx:1.25`) — reference it as `library/nginx:1.25` |
| `errorMessages`: "Backing off due to a rate-limit" | Upstream registry returned 429 to tag resolution — wait, or authenticate the registry via a pull secret |
| Buildpack image builds but exits immediately | Missing `Procfile` (required for Python and PHP; no web-server auto-detection) |

## Quick reference

MCP tools — an image **record** is never created directly (no create-, update-, push-, or copy-image tool); a build is the one write path:

- `mcp__cpln__build_image` — start a build **from a GitHub/GitLab HTTPS repo** and push to the org registry. A build **from a local folder is impossible over MCP** (the server cannot read your filesystem) — route it to `cpln image build --remote --dir PATH`.
- `mcp__cpln__get_image_build` — poll a started build's status and log by the id `build_image` returned.
- `mcp__cpln__list_resources` / `mcp__cpln__get_resource` (kind="image") — list, or inspect tags/digest/manifest.
- `mcp__cpln__delete_resource` (kind="image", name="NAME:TAG") — removes that image record from the org (destructive).
- `mcp__cpln__update_gvc` — attach existing pull secrets (`docker` / `ecr` / `gcp`, created by the user).
- `mcp__cpln__update_workload` — change a container's image; `mcp__cpln__get_resource_schema` (kind="image") for the exact resource shape.

### Related skills

- **workload** (container spec, where the image reference lives) and **gitops-cicd** (building and pushing from CI) are the usual next hops.
- Also: **environment-promotion** (cross-org sharing), **access-control** (policy mechanics), **cpln** (CLI conventions).

## Documentation

- [Image Reference](https://docs.controlplane.com/reference/image.md) — resource, permissions, dynamic tags
- [Build options — local and remote](https://docs.controlplane.com/cli-reference/get-started/images.md#build-options) — the canonical remote-build reference
- [Push an Image](https://docs.controlplane.com/guides/push-image.md) | [Pull an Image](https://docs.controlplane.com/guides/pull-image.md) | [Copy an Image](https://docs.controlplane.com/guides/copy-image.md)
- [CLI Image Commands](https://docs.controlplane.com/cli-reference/commands/image.md) · [Buildpacks Guide](https://docs.controlplane.com/guides/buildpacks.md)
