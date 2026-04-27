---
name: cpln-image
description: "Builds, pushes, pulls, and manages container images on Control Plane. Use when the user asks about Docker build, image registry, image tags, Dockerfile, buildpacks, pull secrets, private registry, ECR/GCR/DockerHub integration, cross-org image sharing, or image permissions. Covers image reference formats, buildpack conventions, tagging strategies, and platform requirements."
version: 1.0.0
---

# Control Plane Images

Reference for working with container images on Control Plane: where they live, how to refer to them, and which subcommand does what. For build workflows (Dockerfile, buildpacks per language) see `skills/image/building.md`. For private-registry auth, cross-org sharing, and image permissions see `skills/image/registry-auth.md`.

## Image Reference Formats

| Scope | Format | Example |
|:---|:---|:---|
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

## Pulling Images

How pulls are authenticated depends on where the image lives.

| Source | Pull secret? | Notes |
|:---|:---|:---|
| Same-org private registry | No | Reference as `//image/NAME:TAG` — pulls automatically |
| Public registries (Docker Hub, public GHCR, etc.) | No | Use exact reference, no `docker.io/` prefix |
| Private registries (ECR, GCR, ACR, GAR, Docker Hub private, other Control Plane orgs) | Yes | Attach to GVC via `spec.pullSecretLinks` — only `docker`, `ecr`, `gcp` secret types work |

For private-registry auth setup, cross-org sharing, and example pull-secret manifests, see `skills/image/registry-auth.md`.

## Tags, Digests, and Dynamic Redeployment

### Tags

Human-readable labels pointing to a specific image version: `my-app:v1.0.0` (semver), `my-app:latest` (mutable — avoid in production), `my-app:abc123` (commit SHA).

### Digests

Immutable SHA256 hashes that uniquely identify an image: `my-app@sha256:3fe719...`. Pinning to a digest guarantees the same bytes forever — ideal for production.

### `supportDynamicTags`

Workload option that triggers automatic redeployment when a tag's underlying digest changes. Useful for CI/CD pipelines that keep pushing to the same tag, security-patch auto-rollout on base images, dev/canary using a mutable tag. **Caution:** mutable tags in production are discouraged — prefer immutable version tags or digests.

### Updating a workload's image

```bash
cpln workload update WORKLOAD \
  --set spec.containers.<container-name>.image=//image/my-app:v1.0 \
  --gvc my-gvc \
  --org my-org
```

The container name varies per workload — look it up with `cpln workload get WORKLOAD -o yaml-slim` and find `spec.containers[].name`.

## `cpln image` Subcommand Reference

| Subcommand | Purpose |
|:---|:---|
| `cpln image build` | Build (and optionally push) via Dockerfile or buildpacks. Details: `skills/image/building.md` |
| `cpln image copy` | Copy an image from one org to another. Details: `skills/image/registry-auth.md` |
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
- **Never prefix external images with `docker.io/`.** Use the exact reference (`nginx:latest`, not `docker.io/library/nginx:latest`).
- **Never use `<own-org>.registry.cpln.io/...` in workload specs.** Use `//image/NAME:TAG` instead. The registry hostname form is only for `docker login`, `docker push`, and `docker pull`.
- **Pull secrets attach at the GVC level**, not per workload. `spec.pullSecretLinks` on the GVC.
- **Only `docker`, `ecr`, and `gcp` secret types work as pull secrets.** Other secret types are for application config, not image auth.
- **`cpln image build` prefers `docker buildx build` but falls back to legacy `docker build` when Buildx is unavailable** (fallback added in cpln CLI v3.9.0; v3.7.2 introduced the Buildx call). Multi-platform builds (comma-separated `--platform` values) still require Buildx and fail if it's missing.
- **Service account Docker login uses `<token>` as the literal username** and the service account key as the password. This is easy to get wrong.
- **Build-time env vars from `--env`/`--env-file` are NOT available at runtime.** Use workload env vars for runtime config.
- **Python buildpacks require a Procfile** for web servers — there is no auto-detection.
- **`cpln image tag` manages metadata tags** (`key=value` labels attached to the image resource), not Docker image version tags like `v1.0` vs `latest`. Docker tags are set at build time via `--name my-app:v1.0`.
- **Image names in Control Plane terminology always include the tag** — `my-app:v1.0`, not just `my-app`.

## Quick Reference

### MCP Tools

- `mcp__cpln__list_images` — List images in an org.
- `mcp__cpln__get_image` — Inspect a specific image including manifest, layers, and platform.
- `mcp__cpln__cpln_resource_operation` — Generic CRUD for images (use `kind: image`).

There is no MCP tool for `cpln image build` or `cpln image copy` — use the CLI directly.

### CLI Commands

- `cpln image build --name NAME:TAG --push` — Build and push to org registry.
- `cpln image copy NAME:TAG --to-org TARGET` — Cross-org copy.
- `cpln image docker-login` — Authenticate Docker to your org's registry.
- `cpln image get` — List all images in the org.

### Related Skills

- **cpln-cli** — General CLI conventions and shared flags.
- **cpln-access-control** — Image policies (`pull`, `create`, `manage`).
- **cpln-environment-promotion** — Patterns for moving images between dev/staging/prod orgs.

### Linked Reference Docs

- `skills/image/building.md` — `cpln image build`, Dockerfile, buildpacks per language, platform requirements.
- `skills/image/registry-auth.md` — Private registry auth, cross-org pull-secret + copy workflows, image permissions/policies.

## Documentation

For the latest reference, see:

- [Image Reference](https://docs.controlplane.com/reference/image.md) — Full reference including permissions and policy examples
- [Push an Image](https://docs.controlplane.com/guides/push-image.md) — Full push workflow with Buildx
- [Pull an Image](https://docs.controlplane.com/guides/pull-image.md) — Pull secret configuration for public and private registries
- [Copy an Image](https://docs.controlplane.com/guides/copy-image.md) — Cross-org copy workflow
- [Buildpacks Guide](https://docs.controlplane.com/guides/buildpacks.md) — Language-specific buildpack details
- [CLI Image Commands](https://docs.controlplane.com/cli-reference/commands/image.md) — Full CLI reference for all image subcommands
