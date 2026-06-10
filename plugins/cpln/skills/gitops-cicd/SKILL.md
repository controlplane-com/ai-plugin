---
name: gitops-cicd
description: "Sets up CI/CD pipelines and GitOps workflows for Control Plane. Use when the user asks about GitHub Actions, GitLab CI, Bitbucket Pipelines, CircleCI, automated deployment, cpln apply in CI, or service account tokens for pipelines."
---

# GitOps & CI/CD Patterns

In CI/CD the **CLI is the primary interface** — pipelines authenticate non-interactively with a service-account `CPLN_TOKEN`, build and push images with `cpln image build --push`, and apply manifests with `cpln apply --ready`. The MCP tools are for the authoring and verification work around the pipeline: discover manifest shapes before you write them (`mcp__cpln__get_resource_schema`), generate or import Terraform for IaC pipelines (`mcp__cpln__export_terraform`, `mcp__cpln__convert_to_terraform`), and confirm a deploy landed (`mcp__cpln__list_deployments`).

## Service Account Authentication

All CI/CD pipelines require a service account for non-interactive authentication.

### 1. Create a service account and generate a key

The fastest path is the MCP tool `mcp__cpln__add_key_to_service_account` — it creates the service account if it does not exist, adds a key, and can add it to a group in one call. The CLI equivalent, useful when scripting key rotation inside the pipeline itself:

```bash
cpln serviceaccount create --name ci-deployer --org my-org
cpln serviceaccount add-key ci-deployer --description "CI/CD pipeline key" --org my-org
```

The `add-key` command requires `--description` and outputs JSON:

```json
{
  "description": "CI/CD pipeline key",
  "created": "2026-04-06T21:32:10.351Z",
  "key": "SERVICE_ACCOUNT_KEY_VALUE"
}
```

Extract the value from the `key` property — that is the service account key. Store it as a **secret** in your CI/CD platform's settings (e.g., GitHub Actions secrets, GitLab CI/CD variables, Bitbucket repository variables). Never pass tokens via CLI flags or `export` statements in pipeline scripts — they can leak into logs and shell history.

### 2. Create a default profile

Create a default profile for the CLI session. Environment variables (`CPLN_TOKEN`, `CPLN_ORG`, `CPLN_GVC`) override values in the profile, so the profile can stay empty — it just anchors the session:

```bash
cpln profile create automation --default
```

If no profile exists but `CPLN_TOKEN` is set, the CLI falls back to an implicit `anonymous` profile, but creating one explicitly matches the pattern in the official [CI/CD guide](https://docs.controlplane.com/cli-reference/ci-cd-development/ci-cd.md).

### 3. Configure environment variables

Set these in your CI/CD platform's settings (not in the pipeline script):

| Variable     |  Required   | Secret | Purpose                                         |
| :----------- | :---------: | :----: | :---------------------------------------------- |
| `CPLN_TOKEN` |     Yes     |  Yes   | Service account token for authentication        |
| `CPLN_ORG`   | Recommended |   No   | Target organization                             |
| `CPLN_GVC`   |  Optional   |   No   | Target GVC (if pipeline targets a specific GVC) |

**Priority order:** `--org`/`--gvc` flags override environment variables, which override profile defaults.

## Applying Manifests

Before you commit a manifest to the repo, confirm its shape with `mcp__cpln__get_resource_schema` for the kind you are authoring (workload, gvc, identity, policy, …) so the YAML/JSON is schema-valid on the first `cpln apply`. The pipeline itself then applies with the CLI.

The `cpln apply` command handles resource ordering automatically. You do not need to worry about applying resources in a specific order — the CLI resolves dependencies internally.

You can pass:

- A single YAML/JSON file: `cpln apply --file workload.yaml`
- A file with multiple resources separated by `---`: `cpln apply --file all-resources.yaml`
- A directory of manifest files: `cpln apply --file ./manifests/`
- A directory with nested subdirectories: `cpln apply --file ./infrastructure/`

Add `--ready` to block until workloads are healthy:

```bash
cpln apply --file ./manifests/ --ready
```

For an out-of-band readiness check — for example a post-deploy verification step or an agent confirming a rollout from outside the pipeline — use `mcp__cpln__list_deployments`; it reports per-location readiness for the workload.

## GitHub Actions Example

```yaml
name: Deploy to Control Plane
on:
  push:
    branches: [main]

env:
  CPLN_TOKEN: ${{ secrets.CPLN_TOKEN }}
  CPLN_ORG: ${{ vars.CPLN_ORG }}

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install cpln CLI
        run: npm install -g @controlplane/cli

      - name: Configure profile
        run: cpln profile create automation --default

      - name: Build and push image
        run: cpln image build --name my-app:${{ github.sha }} --push

      - name: Deploy
        run: cpln apply --file ./manifests/ --ready
```

## CI/CD Example Repositories

Control Plane provides example repositories for popular CI/CD platforms:

### Using CLI

- [GitHub Actions](https://github.com/controlplane-com/github-actions-example-cli)
- [GitLab CI](https://gitlab.com/controlplane-com/gitlab-pipeline-example-cli)
- [Bitbucket Pipelines](https://bitbucket.org/controlplane-com/bitbucket-pipeline-example-cli)
- [CircleCI](https://github.com/controlplane-com/circle-ci-pipeline-example-cli)
- [Google Cloud Build](https://github.com/controlplane-com/google-cloud-build-example-cli)

### Using Terraform

To seed a Terraform-based pipeline, generate HCL with the MCP tools instead of hand-writing it: `mcp__cpln__export_terraform` emits HCL (and optional `import {}` blocks) for resources that already exist in an org, and `mcp__cpln__convert_to_terraform` turns a manifest you authored into schema-validated HCL.

- [GitHub Actions](https://github.com/controlplane-com/github-actions-example-terraform)
- [GitLab CI](https://gitlab.com/controlplane-com/gitlab-pipeline-example-terraform)
- [Bitbucket Pipelines](https://bitbucket.org/controlplane-com/bitbucket-pipeline-example-terraform)

Full guide: https://docs.controlplane.com/guides/gitops.md

## Documentation

For the latest reference, see:

- [GitOps Guide](https://docs.controlplane.com/guides/gitops.md)
- [CI/CD Guide](https://docs.controlplane.com/cli-reference/ci-cd-development/ci-cd.md)
- [Container Image CI/CD](https://docs.controlplane.com/cli-reference/ci-cd-development/container-image.md)
- [cpln apply Guide](https://docs.controlplane.com/guides/cpln-apply.md)
- [Create Service Account](https://docs.controlplane.com/guides/create-service-account.md)
