---
name: cpln-environment-promotion
description: "Promotes workloads across dev/staging/production environments on Control Plane. Use when the user asks about environment promotion, deploying to production, rollback, blue-green deployment, canary release, image promotion, or multi-environment workflows. Covers org-based and GVC-based strategies, image tagging, cross-org sharing, and CI/CD integration."
version: 1.0.0
---

# Environment Promotion

Patterns for promoting workloads across development, staging, and production environments on Control Plane.

## Promotion Patterns Overview

| Pattern | Isolation | Image sharing | Best for |
|:---|:---|:---|:---|
| Org-based (recommended) | Strongest — separate orgs per environment | Pull secret or `cpln image copy` | Production workloads, compliance-sensitive teams |
| GVC-based | Moderate — separate GVCs within one org | Shared registry, no pull secret needed | Small teams, rapid iteration |
| Image-based | Varies | Copy or re-tag images across orgs | One-time promotions, hotfixes |
| Manifest-based | Varies | Same manifests applied to different orgs/GVCs | GitOps workflows with `cpln apply` |

### Decision guide

- **Org-based** is the documented best practice. Each environment maps to a separate org, so GVCs and workloads can share names across environments without collision. Policies, secrets, and access controls are fully isolated.
- **GVC-based** works when a single team owns all environments and stronger isolation is not required. Images in the same org's registry are accessible to all GVCs without pull secrets.
- A common CI/CD pattern combines org-based isolation with manifest-based promotion via `cpln apply`.

## Org-Based Promotion

Each environment is a separate Control Plane org (e.g., `my-org-dev`, `my-org-staging`, `my-org-prod`). The same YAML manifests can be applied to different orgs with environment-specific secrets.

### Setup

1. Create an org per environment
2. Create matching GVCs and workloads in each org (names can be identical)
3. Configure environment-specific secrets in each org
4. Set up cross-org image access (pull secret or image copy)

### Cross-org image access

Two approaches exist for using a dev org's image in staging/production:

#### Option A: Pull secret (continuous access)

Create a service account in the source org with image pull permission, generate a key, create a Docker secret in the target org, and attach it to the target GVC:

```bash
# Source org: create service account and policy
cpln serviceaccount create --name image-puller --org my-org-dev
cpln policy create --name image-pull-policy \
  --target-kind image --all --org my-org-dev
cpln policy add-binding image-pull-policy \
  --serviceaccount image-puller --permission pull --org my-org-dev

# Source org: generate key
cpln serviceaccount add-key image-puller \
  --description "Cross-org image pull" --org my-org-dev
# Save the "key" value from output
```

Create `docker-config.json` (username is the literal string `<token>`):

```json
{
  "auths": {
    "my-org-dev.registry.cpln.io": {
      "username": "<token>",
      "password": "SERVICE_ACCOUNT_KEY_VALUE"
    }
  }
}
```

```bash
# Target org: create secret and attach to GVC
cpln secret create-docker --name dev-registry-pull \
  --file docker-config.json --org my-org-staging
cpln gvc update my-gvc \
  --set spec.pullSecretLinks+=dev-registry-pull --org my-org-staging
```

Reference the source org's image in the target workload:

```yaml
spec:
  containers:
    - name: main
      image: my-org-dev.registry.cpln.io/my-app:v1.0
```

#### Option B: Image copy (one-time promotions)

```bash
# Simple copy (default profile has access to both orgs)
cpln image copy my-app:v1.0 --to-org my-org-staging

# Different credentials per org
cpln image copy my-app:v1.0 \
  --to-org my-org-staging --to-profile staging-profile

# CI/CD with cleanup
cpln image copy my-app:$COMMIT_SHA \
  --to-org my-org-prod --to-profile prod-profile --cleanup
```

After copying, the image exists in the target org's registry and can be referenced as `//image/my-app:v1.0` (no pull secret needed).

### `cpln image copy` flags

| Flag | Purpose |
|:---|:---|
| `--to-org` | Target org (required) |
| `--to-name` | Rename image during copy (e.g., `--to-name renamed-app:v1`) |
| `--to-profile` | Profile for the destination org's credentials |
| `--cleanup` | Remove local images after copy (useful in CI/CD) |

**Prerequisite:** Docker must be installed. The CLI uses Docker to pull, tag, and push the image.

## GVC-Based Promotion

Separate GVCs within the same org act as environments (e.g., `dev-gvc`, `staging-gvc`, `prod-gvc`). All GVCs share the org's image registry.

### Promotion workflow

1. Build and push image to the org's registry
2. Deploy to dev GVC by applying manifests with `--gvc dev-gvc`
3. Promote by applying the same manifests with `--gvc staging-gvc` (update image tag)

```bash
# Deploy to dev
cpln apply --file ./manifests/ --gvc dev-gvc --org my-org

# Promote to staging (same manifests, different GVC)
cpln apply --file ./manifests/ --gvc staging-gvc --org my-org
```

No pull secrets or image copies needed — all GVCs access the same registry.

### Limitations

- Weaker isolation: all environments share the same org's policies and access controls
- Risk of accidental cross-environment changes
- Not recommended for production workloads that require strict separation

## Image Tagging Strategies

| Strategy | Format | Pros | Cons |
|:---|:---|:---|:---|
| Git SHA | `my-app:abc1234` | Immutable, traceable to exact commit | Not human-readable |
| Semver | `my-app:v1.2.3` | Clear version progression | Requires version management |
| Environment tag | `my-app:staging` | Simple promotion (re-tag) | Mutable, not reproducible |
| Build number | `my-app:build-456` | Sequential, CI-friendly | No commit traceability |

### Best practices

- **Use immutable tags (git SHA or semver) for production.** Mutable tags like `latest` or `staging` make rollbacks unreliable.
- **Pin images by digest for maximum reproducibility:** `my-app@sha256:3fe719...`
- **`supportDynamicTags`** is a workload option that triggers automatic redeployment when a tag's underlying digest changes. Useful for dev environments with mutable tags — avoid in production.
- **Image names in Control Plane always include the tag** (e.g., `my-app:v1.0`, not just `my-app`).

## CI/CD Pipeline Integration

### Typical promotion flow

```
Build image ─> Deploy to dev ─> [Approve] ─> Deploy to staging ─> [Approve] ─> Deploy to prod
     │              │                              │                                │
     └─ Push to     └─ cpln apply                  └─ cpln image copy              └─ cpln apply
        dev org        --gvc dev-gvc                  + cpln apply                    --org prod-org
```

### GitHub Actions example (org-based promotion)

```yaml
name: Build and Deploy
on:
  push:
    branches: [main]

env:
  CPLN_TOKEN: ${{ secrets.CPLN_TOKEN }}

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm install -g @controlplane/cli
      - run: cpln profile create automation --default

      - name: Build and push image
        env:
          CPLN_ORG: my-org-dev
        run: cpln image build --name my-app:${{ github.sha }} --push

      - name: Deploy to dev
        env:
          CPLN_ORG: my-org-dev
        run: cpln apply --file ./manifests/ --gvc my-gvc --ready

  deploy-staging:
    needs: build
    runs-on: ubuntu-latest
    environment: staging  # Requires approval in GitHub
    steps:
      - uses: actions/checkout@v4
      - run: npm install -g @controlplane/cli
      - run: cpln profile create automation --default

      - name: Copy image to staging org
        env:
          CPLN_TOKEN: ${{ secrets.CPLN_TOKEN }}
          CPLN_ORG: my-org-dev
        run: |
          cpln image copy my-app:${{ github.sha }} \
            --to-org my-org-staging --cleanup

      - name: Deploy to staging
        env:
          CPLN_ORG: my-org-staging
          CPLN_TOKEN: ${{ secrets.CPLN_TOKEN_STAGING }}
        run: cpln apply --file ./manifests/ --gvc my-gvc --ready

  deploy-prod:
    needs: deploy-staging
    runs-on: ubuntu-latest
    environment: production  # Requires approval in GitHub
    steps:
      - uses: actions/checkout@v4
      - run: npm install -g @controlplane/cli
      - run: cpln profile create automation --default

      - name: Copy image to prod org
        env:
          CPLN_TOKEN: ${{ secrets.CPLN_TOKEN }}
          CPLN_ORG: my-org-dev
        run: |
          cpln image copy my-app:${{ github.sha }} \
            --to-org my-org-prod --cleanup

      - name: Deploy to prod
        env:
          CPLN_ORG: my-org-prod
          CPLN_TOKEN: ${{ secrets.CPLN_TOKEN_PROD }}
        run: cpln apply --file ./manifests/ --gvc my-gvc --ready
```

### Key CI/CD patterns

- **One `CPLN_TOKEN` per org** — each org should have its own service account
- **Create a default profile to anchor the session**: `cpln profile create automation --default`. `CPLN_TOKEN` alone also works (the CLI falls back to an implicit `anonymous` profile), but an explicit profile matches the pattern in the CI/CD guide
- **`cpln apply --ready`** blocks until workloads are healthy — use in pipelines to gate promotion
- **`--cleanup` on `cpln image copy`** saves disk in CI runners
- **GitHub Environments** with required reviewers enforce approval gates between stages

## Rollback Strategies

### Re-deploy a previous image tag

The simplest rollback: update the workload to point at the previous known-good image.

```bash
# Update the container image to a previous version
cpln workload update my-app \
  --set spec.containers.main.image=//image/my-app:v1.1.0 \
  --gvc my-gvc --org my-org
```

Or use the get-edit-apply workflow for GitOps:

```bash
# Export, edit image reference, re-apply
cpln workload get my-app --gvc my-gvc --org my-org -o yaml-slim > workload.yaml
# Edit image in workload.yaml to previous version
cpln apply --file workload.yaml --gvc my-gvc --org my-org
```

### Force redeployment

Restart workload replicas without changing the image (useful when the underlying image digest changed or for transient issues):

```bash
cpln workload force-redeployment my-app --gvc my-gvc --org my-org
```

This sets a `cpln/deployTimestamp` tag on the workload, triggering a rolling restart.

### Check deployment history

```bash
# View recent deployments
cpln workload get-deployments my-app --gvc my-gvc --org my-org
```

### Rollback checklist

1. Identify the last known-good image tag (check git history or deployment logs)
2. Update the workload image to that tag
3. Verify the rollback with health checks
4. If using org-based promotion, ensure the image still exists in the target org's registry

## Quick Reference

### CLI commands

| Command | Purpose |
|:---|:---|
| `cpln apply --file MANIFEST --gvc GVC --org ORG` | Apply manifests to a target environment |
| `cpln apply --file MANIFEST --gvc GVC --org ORG --ready` | Apply and wait for healthy deployment |
| `cpln image copy IMAGE:TAG --to-org TARGET_ORG` | Copy image between orgs |
| `cpln image copy IMAGE:TAG --to-org ORG --to-profile PROFILE --cleanup` | Copy with auth and cleanup |
| `cpln workload update WL --set spec.containers.NAME.image=IMAGE --gvc GVC` | Update workload image |
| `cpln workload force-redeployment WL --gvc GVC --org ORG` | Force rolling restart |
| `cpln workload get WL --gvc GVC --org ORG -o yaml-slim` | Export workload manifest |
| `cpln image build --name IMAGE:TAG --push --org ORG` | Build and push image |

### MCP tools

| Tool | Purpose |
|:---|:---|
| `mcp__cpln__update_workload` | Update workload properties (including image) |
| `mcp__cpln__get_workload` | Get workload details and current image |
| `mcp__cpln__get_workload_deployments` | View deployment history |
| `mcp__cpln__list_images` | List images in an org |
| `mcp__cpln__get_image` | Get image details |

**Note:** No MCP tool exists for image copy — use the CLI directly.

### Related skills

- [cpln-image](../image/SKILL.md) — Image building, pushing, pulling, tagging, and cross-org sharing
- [cpln-gitops-cicd](../gitops-cicd/SKILL.md) — CI/CD pipeline setup, service account auth, and manifest application

## Documentation

For the latest reference, see:

- [Environment Promotion Guide](https://docs.controlplane.com/guides/environment-promotion.md)
- [Copy an Image Guide](https://docs.controlplane.com/guides/copy-image.md)
- [cpln apply Guide](https://docs.controlplane.com/guides/cpln-apply.md)
- [Image Reference](https://docs.controlplane.com/reference/image.md)
