---
name: iac-terraform-pulumi
description: "Manages Control Plane resources with Terraform or Pulumi. Use when the user asks about the Terraform or Pulumi provider, infrastructure as code, IaC, exporting resources to HCL, terraform import, state, or drift."
---

# Infrastructure as Code — Terraform & Pulumi

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

Control Plane has one Terraform provider, `controlplane-com/cpln`. The Pulumi provider (`@pulumiverse/cpln`, published by pulumiverse) is bridged from it, so coverage, semantics, and auth are identical — only the casing changes. The platform also runs a hosted terraform-exporter that converts live resources or schema-validated manifests into provider-correct HCL, reachable through MCP tools and `cpln KIND get -o tf`. The common failure is hand-writing HCL from memory: the nested block shapes are deep and version-specific, and resources that already exist get re-created instead of imported. Generate the HCL, then edit it.

## Choosing an approach

| Approach | Syntax | State | Best for |
|----------|--------|-------|----------|
| Terraform | HCL | Terraform state (use a remote backend) | plan/apply lifecycle, drift detection |
| Pulumi | TypeScript, Python, Go, C# | Pulumi Cloud or self-managed backend | the same lifecycle in a general-purpose language |
| `cpln apply` | YAML/JSON manifests | none — the API is the source of truth | GitOps and CI/CD pipelines (gitops-cicd skill) |
| K8s operator | CRDs | cluster reconcile loop | ArgoCD/Flux shops (k8s-operator skill) |

Pick one owner per resource. A resource managed by Terraform and also edited via console or `cpln apply` shows permanent drift — every `terraform apply` reverts the out-of-band change.

## Provider setup and authentication

```hcl
terraform {
  required_providers {
    cpln = { source = "controlplane-com/cpln" }
  }
}

provider "cpln" {}  # configurable entirely via env vars
```

| Provider arg / Pulumi config key | Env var | Notes |
|----------------------------------|---------|-------|
| `org` / `cpln:org` | `CPLN_ORG` | required |
| `token` / `cpln:token` | `CPLN_TOKEN` | service account token for CI/CD |
| `profile` / `cpln:profile` | `CPLN_PROFILE` | local dev: reuse a `cpln login` profile |
| `endpoint` / `cpln:endpoint` | `CPLN_ENDPOINT` | default `https://api.cpln.io` |
| `refresh_token` / `cpln:refreshToken` | `CPLN_REFRESH_TOKEN` | needed only to create an org or update org `auth_config` |

The same env vars drive the `cpln` CLI, Terraform, and Pulumi, so one CI/CD secret serves all three. Create the service account and scope it with a policy (access-control skill); pipeline wiring lives in gitops-cicd.

Pulumi packages: npm `@pulumiverse/cpln`, PyPI `pulumiverse_cpln`, Go `github.com/pulumiverse/pulumi-cpln/sdk/go/cpln`, NuGet `Pulumiverse.Cpln`.

## Coverage

24 resources, all `cpln_` prefixed: agent, audit_context, catalog_template, cloud_account, custom_location, domain, domain_route, group, gvc, helm_release, identity, ipset, location, mk8s, mk8s_kubeconfig, org, org_logging, org_tracing, policy, secret, service_account, service_account_key, volume_set, workload. Data sources: cloud_account, gvc, helm_template, image, images, location, locations, org, secret, workload. Pulumi exposes the same 24 resources in PascalCase (e.g. `CatalogTemplate`).

Per-attribute truth is the registry page for that resource — [Terraform Registry](https://registry.terraform.io/providers/controlplane-com/cpln/latest/docs) or [Pulumi Registry](https://www.pulumi.com/registry/packages/cpln) — not memory. One shape worth knowing up front: `cpln_secret` has no `type` argument; set exactly one per-type attribute (`opaque`, `dictionary`, `aws`, `tls`, ...).

## Generate HCL — don't hand-write it

The hosted terraform-exporter produces provider-correct HCL. Route by what you have:

| You have | Use |
|----------|-----|
| Existing resource(s) | `mcp__cpln__export_terraform` — a single self link, or bulk by path depth: `/org/ORG` (whole org), `/org/ORG/KIND` (all of a kind), `/org/ORG/gvc/GVC/workload` (all workloads in the GVC) |
| A known set of links | `mcp__cpln__export_terraform_batch` (full profile) — up to 100 links, merged and de-duplicated; on core, `export_terraform` with path-depth refs covers it |
| A YAML/JSON manifest | `mcp__cpln__convert_to_terraform` — dry-run validated against the API first, so the returned HCL always matches a schema-valid resource; pass `gvc` for GVC-scoped kinds (workload, identity, volumeset) |
| Nothing yet | author the manifest against `mcp__cpln__get_resource_schema`, then convert it |

Set `generateImports` on any of these to also get ready-to-run `terraform import` commands, one per resource with the IDs prefilled — run them after `terraform init` and before the first `terraform apply`, so apply updates the live resources instead of re-creating them. `includeDependencies` (export tools) pulls in referenced resources so the HCL is self-contained.

The exporter emits HCL only. For a Pulumi program, convert the exported HCL with the Pulumi CLI: `pulumi convert --from terraform --language typescript --out DIR` (also python, go, csharp, java, yaml). Conversion translates config, not state — adopt the live resources afterwards per Importing below.

The exporter covers 16 kinds: agent, auditctx, cloudaccount, domain (routes emitted as `cpln_domain_route`), group, gvc, identity, ipset, location, mk8s, org, policy, secret, serviceaccount, volumeset, workload. `mcp__cpln__list_terraform_kinds` (full profile) enumerates them; on core, just attempt the export — an unsupported kind is rejected with the supported list.

**Secrets export as plaintext.** The exporter follows each secret's reveal link and embeds the revealed values in the HCL. The MCP tools refuse a ref that targets secrets — and refuse wholesale any bulk export that pulled secrets in — unless `includeSecretValues: true` is passed, which requires the user's explicit approval first. The values then live in both the `.tf` file and the state file; protect both.

## CLI fallback: -o tf

Without MCP, the same exporter is reachable through the CLI:

```bash
cpln workload get my-app --gvc GVC -o tf > workload.tf   # one resource
cpln workload get --gvc GVC -o tf > workloads.tf         # no ref: every workload in the GVC
cpln gvc get -o tf > gvcs.tf                             # every GVC in the org
```

Differences from the MCP tools: the output is bare `resource` blocks only (write the `terraform {}` and `provider "cpln" {}` blocks yourself), no `terraform import` commands, no dependency closure, and no secret guard — `cpln secret get NAME -o tf` prints revealed plaintext when you hold the reveal permission and silently omits the values when you don't. Multiple explicit refs in one call are not supported with `-o tf`; export per resource or use the no-ref bulk form. The sibling `-o crd` emits Kubernetes CRD YAML for the operator path (k8s-operator skill). For stateless manifests instead of HCL, use `-o yaml-slim` with `cpln apply`.

## Importing existing resources

Resources must land in state before the first apply, or apply tries to re-create them and fails on name conflicts. `generateImports` returns the exact `terraform import` commands to run — after `terraform init`, before the first apply. Hand-written, the ID is the bare name for org-scoped kinds and `GVC:NAME` for GVC-scoped ones:

```bash
terraform import cpln_gvc.prod prod-gvc
terraform import cpln_workload.api prod-gvc:api
```

Each registry page has an Import section with the exact form (composite kinds differ — a domain route imports as `DOMAIN_LINK:PORT:PREFIX`). On Terraform 1.5+ you may hand-write declarative `import {}` blocks instead; the exporter emits commands, not blocks. Pulumi uses the same IDs (`pulumi import cpln:index/workload:Workload api prod-gvc:api` — the provider is bridged), and `pulumi import --from terraform ./terraform.tfstate` adopts a whole existing Terraform state file into a Pulumi stack.

## Catalog templates

`cpln_catalog_template` (Pulumi `CatalogTemplate`) installs marketplace templates with arguments `name`, `template`, `version`, `gvc`, and `values` (a YAML string). Changing `version` or `values` upgrades the release in place. Template selection and values shapes live in the template-catalog skill.

## Verify

- After an export-and-import, `terraform plan` (or `pulumi preview`) must show zero changes — any diff means the HCL drifted from live state; reconcile before committing.
- Drift detection is the same command on a schedule: a non-empty plan means an out-of-band edit.
- After `terraform apply` on a workload, confirm health with `mcp__cpln__list_deployments` or `cpln workload get-deployments WORKLOAD --gvc GVC`.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| First apply wants to create resources that already exist | The import step was skipped — run the `terraform import` commands from `generateImports` (after `terraform init`), then re-plan |
| `Kind "X" is not Terraform-convertible` | The exporter covers the 16 kinds above (image and user are not among them); manage others via `cpln apply` |
| Export refused mentioning plaintext secrets | Re-run with `includeSecretValues: true` only after the user explicitly approves, or narrow the ref to exclude secrets |
| Org create or `auth_config` update fails despite a valid token | Those two operations require `CPLN_REFRESH_TOKEN` |
| Pulumi lacks a feature the Terraform provider just shipped | The bridge tracks Terraform provider releases — upgrade the `@pulumiverse/cpln` package version |

## Quick reference

### MCP tools

- `mcp__cpln__export_terraform` — HCL for existing resources by self link; bulk via path-depth refs; `generateImports`, `includeDependencies`, `includeSecretValues`
- `mcp__cpln__export_terraform_batch` (full profile) — several explicit links merged into one HCL set
- `mcp__cpln__convert_to_terraform` — manifest to HCL, dry-run validated first
- `mcp__cpln__list_terraform_kinds` (full profile) — exporter-supported kinds
- `mcp__cpln__get_resource_schema` — exact API schema when authoring a manifest to convert

CLI fallback: in CI/CD, `CPLN_TOKEN` + `CPLN_ORG` drive `terraform`/`pulumi` directly; `cpln KIND get -o tf` scaffolds HCL from live resources.

### Related skills

| Skill | Use for |
|-------|---------|
| gitops-cicd | pipelines, service account tokens, `cpln apply` workflows |
| k8s-operator | managing resources as Kubernetes CRDs with ArgoCD |
| template-catalog | which template and what values before `cpln_catalog_template` |
| access-control | the service account and policy behind the CI/CD token |

## Documentation

- [IaC Overview](https://docs.controlplane.com/iac/overview.md), [Terraform Provider](https://docs.controlplane.com/iac/terraform.md), [Pulumi Provider](https://docs.controlplane.com/iac/pulumi.md)
- [cpln apply Guide](https://docs.controlplane.com/guides/cpln-apply.md)
- [Terraform examples](https://github.com/controlplane-com/examples/tree/main/terraform); pipeline examples for [GitHub Actions](https://github.com/controlplane-com/github-actions-example-terraform), [GitLab CI](https://gitlab.com/controlplane-com/gitlab-pipeline-example-terraform), and [Bitbucket](https://bitbucket.org/controlplane-com/bitbucket-pipeline-example-terraform)
