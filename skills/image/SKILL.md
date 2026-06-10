---
name: image
description: "Builds, pushes, and manages container images on Control Plane. Use when the user asks about Docker build, image registry, tags, Dockerfile, buildpacks, pull secrets, private registries, ECR/GCR/DockerHub, or image sharing and permissions."
---

# Control Plane Images

Reference for working with container images on Control Plane: where they live, how to refer to them, how to build/push them, and how to share them across orgs. MCP image reads use the generic resource tools — `mcp__cpln__list_resources` (kind="image") and `mcp__cpln__get_resource` (kind="image") — and removal uses `mcp__cpln__delete_resource` (kind="image"); build, push, and copy are CLI-exclusive.

## Image Reference Formats

| Scope | Format | Example |
|---|---|---|
| Same org's private registry (preferred) | `//image/IMAGE-NAME:IMAGE-TAG` | `//image/my-app:v1.0` |
| Same org's private registry (explicit) | `ORG.registry.cpln.io/IMAGE-NAME:IMAGE-TAG` | `my-org.registry.cpln.io/my-app:v1.0` |
| Another Control Plane org's registry | `OTHER-ORG.registry.cpln.io/IMAGE-NAME:IMAGE-TAG` | `dev-org.registry.cpln.io/my-app:v1.0` |
| Public image (Docker Hub) | `IMAGE-NAME:IMAGE-TAG` | `nginx:latest` |
| Google Container Registry | `gcr.io/PROJECT/IMAGE:TAG` | `gcr.io/my-project/my-app:v1` |
| Amazon ECR | `ACCOUNT.dkr.ecr.REGION.amazonaws.com/IMAGE:TAG` | `123456789.dkr.ecr.us-east-1.amazonaws.com/my-app:v1` |

### Critical rules

- **In workload specs, always use `//image/NAME:TAG` for images in your own org's registry.** Do not use `<own-org>.registry.cpln.io/...` in workload specs — that form is only for `docker login` / `docker push` workflows.
- **Never add `docker.io/` prefix to external images.** Use the exact string (`nginx:latest`, not `docker.io/library/nginx:latest`).
- **Image names always include the tag** in Control Plane terminology. When someone says "image name", they mean `image-name:image-tag` (e.g., `my-app:v1.0`), not the name alone.

## Building & Pushing

Building and pushing are **CLI-exclusive** — there is no create- or update-image MCP tool (`delete_resource` with kind="image" exists for removal). Verify a build afterward with `mcp__cpln__get_resource` (kind="image") (inspect tags, digest, manifest); CLI fallback when MCP is unavailable: `cpln image get my-app:v1.0 --org my-org -o json`.

**Before authoring any `cpln image build` command, run `cpln image build --help` to verify flags and defaults.**

| Path | When to use |
|---|---|
| `cpln image build` | Default. Handles Dockerfile + buildpack workflows, authenticates to the org's private registry automatically, pushes in one step. |
| Direct `docker buildx build` | Buildx-only features (multi-platform manifests, advanced cache backends) or a Docker-native pipeline. |

### Option A: `cpln image build` (recommended)

**Required flag:** `--name IMAGE-NAME:IMAGE-TAG`.

**Common flags:**
- `--push` — push to your org's private registry after build.
- `--dockerfile PATH` — path to Dockerfile (default: `./Dockerfile`). If set, buildpacks are not used.
- `--dir PATH` — directory containing the application (default: `.`).
- `--no-cache` — build without using cached layers.
- `--platform linux/amd64` — target platform (default: `linux/amd64`).
- `--builder` / `-B` — buildpack builder image (default: `heroku/builder:24_linux-amd64`).
- `--buildpack` / `-b` — specific buildpack (repeatable).
- `--env KEY=VALUE` / `-e` — build-time env var (repeatable, NOT available at runtime).
- `--env-file PATH` — file with build-time env vars.
- Context flags: `--org`, `--profile`.

```bash
cpln image build --name my-app:v1.0 --push --org my-org
```

### Option B: Docker CLI directly

Verify Buildx first (`docker buildx version`). If missing, install the [Docker Buildx plugin](https://docs.docker.com/build/install-buildx/) or substitute `docker build` (single-platform only).

```bash
# 1. Authenticate Docker to your org's registry
cpln image docker-login --org my-org

# 2. Build targeting linux/amd64
docker buildx build --platform=linux/amd64 \
  -t my-org.registry.cpln.io/my-app:v1.0 .

# 3. Push
docker push my-org.registry.cpln.io/my-app:v1.0
```

### Platform requirement: `linux/amd64`

All Control Plane managed locations run `linux/amd64`; wrong platform causes `exec format error` at runtime. `cpln image build` defaults to `linux/amd64` (safe on Apple Silicon). For direct `docker buildx build`, always pass `--platform=linux/amd64`.

### Buildpacks (no Dockerfile)

Cloud Native Buildpacks auto-detect your application language and produce an optimized image — no Dockerfile needed. Good for standard frameworks; use a Dockerfile for custom system packages or build steps. Default builder: `heroku/builder:24_linux-amd64` (override with `-B`/`--builder` for Paketo, Google Cloud Buildpacks, or community builders).

**Build-time env vars** set with `--env`/`--env-file` are available only during the build — NOT at runtime. Use workload env vars for runtime config.

**Procfile** — single-line file in the project root, required for some languages:

```
web: <start-command>
```

Per-language notes (all build with `cpln image build --name my-app:v1.0 --push --org my-org` unless a builder/buildpack override is shown):

- **Node.js** — Detect: `package.json` + a lockfile (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`). Start command auto-detected from `index.js`, `server.js`, `scripts.start`, or `Procfile`. Pin via `engines.node`. Pitfall: missing lockfile → not detected.
- **Python** — Detect: `requirements.txt` (pip), `uv.lock` (uv, also needs `.python-version`), or `poetry.lock` (Poetry). **Procfile REQUIRED** (no web-server auto-detection). Server must bind `0.0.0.0` and listen on `$PORT`. Poetry non-packaged apps need `package-mode = false` in `pyproject.toml`. Pitfall: no Procfile → builds but exits immediately.
- **Go** — Detect: `go.mod` in root; `main` package must be in root. Compiled binary used automatically.
- **Java (Maven)** — Detect: `pom.xml`; runs `mvn package`. Spring Boot auto-detected; other frameworks need a `Procfile`. Bind `0.0.0.0`, listen on `$PORT`.
- **Java (Gradle)** — Detect: `build.gradle` / `build.gradle.kts` + `gradlew` wrapper; runs `./gradlew build`. Spring Boot auto-detected; other frameworks need a `Procfile`. Bind `0.0.0.0`, listen on `$PORT`.
- **Ruby** — Detect: `Gemfile` + `Gemfile.lock`. Rails auto-detected (Procfile recommended); non-Rails requires a `Procfile`. Must listen on `$PORT`.
- **PHP** — Detect: `composer.json` + `composer.lock`. **Procfile REQUIRED.**
- **Rust** — NOT supported by the default builder. Detect: `Cargo.toml`, `Cargo.lock`, binary target; `cargo build --release`; listen on `$PORT`. Build: `... -b docker.io/paketocommunity/rust`.
- **C# / .NET** — NOT supported by the default builder. Detect: `.csproj`, `.fsproj`, or `.sln`; runs `dotnet publish` (Release). Bind `0.0.0.0`, set `ASPNETCORE_URLS=http://0.0.0.0:$PORT`. Build: `... -B paketobuildpacks/builder-jammy-base`.

## Pulling Images

Pull auth depends on where the image lives.

| Source | Pull secret? | Notes |
|---|---|---|
| Same-org private registry | No | Reference as `//image/NAME:TAG` — pulls automatically |
| Public registries (Docker Hub, public GHCR, etc.) | No | Use exact reference, no `docker.io/` prefix |
| Private registries (ECR, GCR, ACR, GAR, Docker Hub private, other Control Plane orgs) | Yes | Attach to GVC via `spec.pullSecretLinks` — only `docker`, `ecr`, `gcp` secret types work |

## Private Registry Auth & Cross-Org Sharing

Each org gets its own isolated private registry at `ORG.registry.cpln.io`: no pull secrets for same-org images, lower latency (cached at each deployment location), built-in policy access control, automatic auth via `cpln image build --push`.

### Authenticating Docker to the registry

```bash
cpln image docker-login --org my-org
```

Authenticates your local Docker client using your current `cpln` profile. Required before `docker push`/`docker pull` directly against the registry.

**Service account login (CI/CD):** when using a service account key as credentials, the username is the **literal string** `<token>` and the password is the key. Rotate keys with `cpln serviceaccount add-key`; delete compromised keys immediately.

```bash
echo "$SERVICE_ACCOUNT_KEY" | docker login my-org.registry.cpln.io -u '<token>' --password-stdin
```

### Pull secrets for private registries

Private registries (Docker Hub private, ECR, GCR, ACR, GAR, GHCR, other Control Plane orgs) require a pull secret attached to the GVC. Only three secret types work:

| Secret type | Use for |
|---|---|
| `docker` | Docker Hub, GHCR, ACR, GAR, other Control Plane orgs |
| `ecr` | Amazon ECR (dedicated type — handles IAM role assumption) |
| `gcp` | Google Container Registry (via GCP service account JSON) |

Pull secrets live at the **GVC level** — once attached they apply to all workloads in that GVC; you cannot attach them per-workload. Attach via `mcp__cpln__update_gvc` (merges into `spec.pullSecretLinks`, preserving existing links; read first with `mcp__cpln__get_resource` (kind="gvc") for rollback). CLI fallback (MCP unavailable, or CI/CD):

```bash
cpln gvc update my-gvc --set spec.pullSecretLinks+=my-pull-secret --org my-org
```

### Cross-org sharing

Images are org-scoped. To use another org's image (e.g., dev's image in staging), choose one option.

**Option 1: Pull secret (preferred for continuous access).**

1. **Source-org service account with pull access.** Create the SA + first key with `mcp__cpln__add_key_to_service_account` (creates the SA if absent, optional group), then grant access with `mcp__cpln__create_policy` (target kind `image`, target all or specific links, bind the SA principal with permission `pull`); amend later via `mcp__cpln__get_resource` (kind="policy") + `mcp__cpln__update_policy`. CLI fallback:

   ```bash
   cpln serviceaccount create --name image-puller --org dev-org
   cpln policy create --name image-pull-policy --target-kind image --all --org dev-org
   cpln policy add-binding image-pull-policy --serviceaccount image-puller --permission pull --org dev-org
   ```

   To scope to specific images, replace `--all` with `--resource <image-name:image-tag>` (one per image; names include the tag). Adding the SA to `superusers` also works but grants full org access — prefer a scoped policy.

2. **Service account key.** If you used `mcp__cpln__add_key_to_service_account` above, grab the `key` from its response. CLI fallback (extract the `key` value from the JSON output):

   ```bash
   cpln serviceaccount add-key image-puller --description "Cross-org image pull key" --org dev-org
   ```

3. **Docker secret in the target org.** Prefer `mcp__cpln__create_secret_docker`. It takes a single `dockerConfigJson` field — the full `~/.docker/config.json` contents (an `auths` object) passed as a string, e.g. `{"auths": {"dev-org.registry.cpln.io": {"username": "<token>", "password": "SERVICE_ACCOUNT_KEY_VALUE", "email": "ops@example.com"}}}`. The username is the literal string `<token>` — do not replace it with the token itself. CLI fallback uses a `docker-config.json` with the same `<token>` username:

   ```bash
   cpln secret create-docker --name dev-registry-pull --file docker-config.json --org staging-org
   ```

4. **Add the pull secret to the target GVC** — `mcp__cpln__update_gvc` (see "Pull secrets" above), or `cpln gvc update staging-gvc --set spec.pullSecretLinks+=dev-registry-pull --org staging-org`.

5. **Point the target workload at the source image** (`<source-org>.registry.cpln.io/<image-name>:<image-tag>`). Either PATCH in place with `mcp__cpln__update_workload` (read first with `mcp__cpln__get_resource` (kind="workload") to find `spec.containers[].name`), or export → edit → `cpln apply` (GitOps-friendly, version-controlled). CLI in-place fallback (look up the container name first via `cpln workload get ... -o yaml-slim`):

   ```bash
   cpln workload update my-app \
     --set spec.containers.<container-name>.image="dev-org.registry.cpln.io/my-app:v1.0" \
     --gvc staging-gvc --org staging-org
   ```

**Option 2: Copy image (one-time promotions).** `cpln image copy` needs access to both orgs. Check profiles with `cpln profile get`; ensure a source-org profile (default or `CPLN_PROFILE`) and a destination-org profile exist (`cpln profile create NAME --login --org ORG`, or `cpln profile update`). For service account auth, set `CPLN_TOKEN` (overrides profile auth). If the default profile reaches both orgs, copy directly; otherwise pass `--to-profile` for the destination. On an authorization error, verify `pull` on source images and `push`/`create` on the destination.

| Flag | Purpose |
|---|---|
| `--to-org` | Target org to copy the image to (required) |
| `--to-name` | Rename the image during copy (e.g., `--to-name renamed-app:v1`) |
| `--to-profile` | Profile for the destination org |
| `--cleanup` | Remove pulled/retagged local images after success (CI/CD disk savings) |

```bash
cpln image copy my-app:v1 --to-org staging-org --to-profile dest-profile --cleanup
```

### Image permissions and policies

| Permission | Description | Implies |
|---|---|---|
| `create` | Create or push an image | `pull` |
| `delete` | Delete an image | — |
| `edit` | Modify image metadata (only tags) | `view` |
| `manage` | Full access | `create`, `delete`, `edit`, `manage`, `pull`, `view` |
| `pull` | Pull an image | `view` |
| `view` | Read-only access | — |

**Push** needs `create` bound to the pushing principal; **pull** needs `pull`. Prefer `mcp__cpln__create_policy` (target kind `image`, target all, binding with the permission bound to the CI/puller principal); amend via `mcp__cpln__get_resource` (kind="policy") + `mcp__cpln__update_policy` (`addBindings` to merge). Discover grantable permissions with `mcp__cpln__get_permissions`. CLI fallback:

```bash
cpln policy create --name image-push-policy --target-kind image --all --org my-org
cpln policy add-binding image-push-policy --serviceaccount ci-deployer --permission create --org my-org
```

For policies scoped to specific image names by `targetQuery` (a property-match the typed MCP tool can't express), call `mcp__cpln__get_resource_schema` for the `policy` kind, then `cpln apply` a manifest:

```yaml
kind: policy
name: pull-specific-images
description: Pull access to the my-app image
targetKind: image
targetLinks: []
targetQuery:
  kind: image
  fetch: items
  spec:
    match: all
    terms:
      - op: '='
        property: repository
        value: my-app
bindings:
  - permissions:
      - pull
    principalLinks:
      - /org/my-org/serviceaccount/image-puller
```

`property: repository` matches by repository name; image queries also support `name`, `id`, `tag`, `digest`, `created`, and `lastModified`. Principal links reference users (`/org/ORG/user/EMAIL`) or service accounts (`/org/ORG/serviceaccount/NAME`).

## Tags, Digests, and Dynamic Redeployment

### Tags

Human-readable labels pointing to a specific image version: `my-app:v1.0.0` (semver), `my-app:latest` (mutable — avoid in production), `my-app:abc123` (commit SHA).

### Digests

Immutable SHA256 hashes that uniquely identify an image: `my-app@sha256:3fe719...`. Pinning to a digest guarantees the same bytes forever — ideal for production.

### `supportDynamicTags`

Workload option that triggers automatic redeployment when a tag's underlying digest changes. Useful for CI/CD pipelines that keep pushing to the same tag, security-patch auto-rollout on base images, dev/canary using a mutable tag. **Caution:** mutable tags in production are discouraged — prefer immutable version tags or digests.

### Updating a workload's image

Use `mcp__cpln__update_workload` (PATCH — change only the container image); read first with `mcp__cpln__get_resource` (kind="workload") to find the container name (`spec.containers[].name` — varies per workload) and capture state for rollback. CLI fallback (MCP unavailable, or CI/CD): `cpln workload update WORKLOAD --set spec.containers.<container-name>.image=//image/my-app:v1.0 --gvc GVC --org ORG`.

## `cpln image` Subcommand Reference

| Subcommand | Purpose |
|---|---|
| `cpln image build` | Build (and optionally push) via Dockerfile or buildpacks |
| `cpln image copy` | Copy an image from one org to another |
| `cpln image get` | List all images or inspect specific ones |
| `cpln image delete` | Delete one or more images |
| `cpln image docker-login` | Authenticate Docker to the org's private registry |
| `cpln image tag` | Manage **metadata** tags (key=value), NOT Docker image version tags |
| `cpln image edit` | Edit image metadata as YAML in an editor |
| `cpln image patch` | Update image metadata from an input file |
| `cpln image query` | Find images by query |
| `cpln image permissions` | Show grantable permissions for the image kind |
| `cpln image access-report` | Show the access report for an image |
| `cpln image audit` | Retrieve audit trail events for an image |

**There is no `cpln image push` or `cpln image pull` subcommand.** Push is done via `cpln image build --push` or `docker push` after `cpln image docker-login`. Pulls happen automatically when workloads reference images, or via `docker pull` after login.

**Before authoring any `cpln` command, run `cpln <subcommand> --help` to verify flags and required args.**

## Gotchas

- **`linux/amd64` is mandatory.** Wrong platform causes `exec format error`. Apple Silicon users must target `linux/amd64` — `cpln image build` does this by default.
- **`cpln image build` prefers `docker buildx build` but falls back to legacy `docker build` when Buildx is unavailable** (fallback added in cpln CLI v3.9.0; v3.7.2 introduced the Buildx call). Multi-platform builds (comma-separated `--platform` values) still require Buildx and fail if it's missing.
- **Build-time env vars from `--env`/`--env-file` are NOT available at runtime.** Use workload env vars for runtime config.
- **Python buildpacks require a Procfile** for web servers — there is no auto-detection.
- **`cpln image tag` manages metadata tags** (`key=value` labels attached to the image resource), not Docker image version tags like `v1.0` vs `latest`. Docker tags are set at build time via `--name my-app:v1.0`.

## Quick Reference

### MCP Tools

- `mcp__cpln__list_resources` (kind="image") — List images in an org (read).
- `mcp__cpln__get_resource` (kind="image") — Inspect a specific image including tags, digest, and manifest details (read).
- `mcp__cpln__delete_resource` (kind="image") — Delete one or more images (destructive).

Over MCP, images are list/get/delete only — there is no create- or update-image tool: build and push via `cpln image build --push` (CLI, exclusive), copy across orgs via `cpln image copy` (CLI). For workload image updates, use `mcp__cpln__update_workload`.

### CLI Commands

- `cpln image build --name NAME:TAG --push` — Build and push to org registry.
- `cpln image copy NAME:TAG --to-org TARGET` — Cross-org copy.
- `cpln image docker-login` — Authenticate Docker to your org's registry.
- `cpln image get` — List all images in the org.

### Related Skills

- **cpln-workload** — Start here: the primary workload skill (types, defaults, spec shape) that routes here for image detail.
- **cpln** — General CLI conventions and shared flags.
- **cpln-access-control** — Image policies (`pull`, `create`, `manage`).
- **cpln-environment-promotion** — Patterns for moving images between dev/staging/prod orgs.

## Documentation

For the latest reference, see:

- [Image Reference](https://docs.controlplane.com/reference/image.md) — Full reference including permissions and policy examples
- [Push an Image](https://docs.controlplane.com/guides/push-image.md) — Full push workflow with Buildx
- [Pull an Image](https://docs.controlplane.com/guides/pull-image.md) — Pull secret configuration for public and private registries
- [Copy an Image](https://docs.controlplane.com/guides/copy-image.md) — Cross-org copy workflow
- [Buildpacks Guide](https://docs.controlplane.com/guides/buildpacks.md) — Language-specific buildpack details
- [CLI Image Commands](https://docs.controlplane.com/cli-reference/commands/image.md) — Full CLI reference for all image subcommands
