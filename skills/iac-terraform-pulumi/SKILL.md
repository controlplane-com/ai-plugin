---
name: cpln-iac-terraform-pulumi
description: "Manages Control Plane resources with Terraform or Pulumi. Use when the user asks about Terraform provider, Pulumi provider, infrastructure as code, IaC, or managing Control Plane resources declaratively. Covers provider setup, authentication, supported resource types, template catalog integration, and state management."
version: 1.0.0
---

# Infrastructure as Code — Terraform & Pulumi

## IaC Approaches

Control Plane supports three approaches for managing resources as code:

| Approach | Syntax | State Management | Best For |
|----------|--------|------------------|----------|
| **Terraform** | HCL | Terraform state file | Teams already using Terraform, HCL-native workflows |
| **Pulumi** | TypeScript, Python, Go, C# | Pulumi Service or self-managed backends | Teams preferring general-purpose languages |
| **`cpln apply`** | YAML/JSON manifests | No state file (API is source of truth) | GitOps pipelines, simple deployments, CI/CD automation |

### When to Use Each

- **Terraform/Pulumi**: Full lifecycle management with plan/preview, drift detection, dependency graphs, and state tracking. Use for production infrastructure managed by platform teams.
- **`cpln apply`**: Idempotent manifest application without state files. Use for GitOps workflows, CI/CD pipelines, and environments where simplicity is preferred. See the **cpln-gitops-cicd** skill for CI/CD patterns.

## Terraform Provider

### Registry

- **Source**: `controlplane-com/cpln`
- **Registry**: https://registry.terraform.io/providers/controlplane-com/cpln/latest
- **Requires**: Terraform 0.13+

### Provider Configuration

```hcl
terraform {
  required_providers {
    cpln = {
      source = "controlplane-com/cpln"
    }
  }
}

provider "cpln" {
  org = var.org  # Required. Env: CPLN_ORG
}
```

### Authentication

Configure via provider arguments or environment variables:

| Provider Arg | Env Var | Default | Required |
|--------------|---------|---------|----------|
| `org` | `CPLN_ORG` | None | Yes |
| `endpoint` | `CPLN_ENDPOINT` | `https://api.cpln.io` | No |
| `profile` | `CPLN_PROFILE` | Default CLI profile | No |
| `token` | `CPLN_TOKEN` | None | No |
| `refresh_token` | `CPLN_REFRESH_TOKEN` | None | No |

For CI/CD, use a service account token in `CPLN_TOKEN`. See the **cpln-gitops-cicd** skill for service account creation.

### Supported Terraform Resources

All resources registered by the `controlplane-com/cpln` provider. Data sources exist for `cloud_account`, `gvc`, `helm_template`, `image`, `images`, `location`, `locations`, `org`, `secret`, `workload`.

| Resource | Terraform Type |
|----------|----------------|
| Agent | `cpln_agent` |
| Audit Context | `cpln_audit_context` |
| Catalog Template | `cpln_catalog_template` |
| Cloud Account | `cpln_cloud_account` |
| Custom Location | `cpln_custom_location` |
| Domain | `cpln_domain` |
| Domain Route | `cpln_domain_route` |
| Group | `cpln_group` |
| GVC | `cpln_gvc` |
| Helm Release | `cpln_helm_release` |
| Identity | `cpln_identity` |
| IP Set | `cpln_ipset` |
| Location | `cpln_location` |
| Mk8s | `cpln_mk8s` |
| Mk8s Kubeconfig | `cpln_mk8s_kubeconfig` |
| Org | `cpln_org` |
| Org Logging | `cpln_org_logging` |
| Org Tracing | `cpln_org_tracing` |
| Policy | `cpln_policy` |
| Secret | `cpln_secret` (types: `aws`, `azure_connector`, `azure_sdk`, `dictionary`, `docker`, `ecr`, `gcp`, `keypair`, `nats_account`, `opaque`, `tls`, `userpass`) |
| Service Account | `cpln_service_account` |
| Service Account Key | `cpln_service_account_key` |
| Volume Set | `cpln_volume_set` |
| Workload | `cpln_workload` |

See the [Terraform Registry](https://registry.terraform.io/providers/controlplane-com/cpln/latest) for per-resource field reference and examples.

### Example: GVC + Workload

```hcl
resource "cpln_gvc" "main" {
  name        = "my-app-gvc"
  description = "Production GVC"

  locations = [
    "aws-us-west-2",
    "gcp-us-east1"
  ]
}

resource "cpln_workload" "app" {
  gvc  = cpln_gvc.main.name
  name = "my-app"
  type = "standard"

  container {
    name   = "main"
    image  = "my-org/my-app:latest"
    cpu    = "50m"
    memory = "128Mi"

    ports {
      number   = 8080
      protocol = "http"
    }
  }

  options {
    capacity_ai     = true
    timeout_seconds = 5

    autoscaling {
      metric    = "disabled"
      target    = 95
      min_scale = 1
      max_scale = 5
    }
  }

  firewall_spec {
    external {
      inbound_allow_cidr = ["0.0.0.0/0"]
    }
  }
}

output "canonical_endpoint" {
  value = cpln_workload.app.status[0].canonical_endpoint
}
```

### Example: Secret + Identity + Policy

`cpln_secret` has no `type` argument — set exactly one of the per-type blocks/attributes (`dictionary`, `opaque`, `tls`, `aws`, `gcp`, `docker`, `keypair`, etc.). `cpln_policy` uses a `binding` block (singular, up to 50 per policy).

```hcl
resource "cpln_secret" "db_credentials" {
  name = "db-credentials"

  dictionary = {
    DB_HOST     = "db.example.com"
    DB_USER     = "app"
    DB_PASSWORD = "secret-value"
  }
}

resource "cpln_identity" "app_identity" {
  gvc  = cpln_gvc.main.name
  name = "app-identity"
}

resource "cpln_policy" "secret_access" {
  name        = "app-secret-access"
  target_kind = "secret"
  target_links = [cpln_secret.db_credentials.name]

  binding {
    permissions     = ["reveal", "use"]
    principal_links = [cpln_identity.app_identity.self_link]
  }
}
```

### Example: Custom Domain + Route

```hcl
resource "cpln_domain" "apex" {
  name = "example.com"

  spec {
    dns_mode = "cname"

    ports {
      number   = 443
      protocol = "http2"
      tls {}
    }
  }
}

resource "cpln_domain" "app" {
  depends_on = [cpln_domain.apex]
  name       = "app.example.com"

  spec {
    dns_mode = "cname"

    ports {
      number   = 443
      protocol = "http2"
      tls {}
    }
  }
}

resource "cpln_domain_route" "route" {
  depends_on    = [cpln_domain.app]
  domain_link   = cpln_domain.app.self_link
  domain_port   = 443
  prefix        = "/"
  workload_link = cpln_workload.app.self_link
}
```

### Upgrading Provider Version

1. Update the version in your `required_providers` block.
2. Run `terraform init -upgrade`.

### Importing Existing Resources

Use `terraform import` to bring existing Control Plane resources under Terraform management. See the Terraform Registry for import syntax per resource type.

## Pulumi Provider

### Registry

- **Registry**: https://www.pulumi.com/registry/packages/cpln
- **Supported languages**: TypeScript/JavaScript, Python, Go, .NET (C#)

### Installation

| Language | Package | Install Command |
|----------|---------|-----------------|
| JS/TS | `@pulumiverse/cpln` | `npm install @pulumiverse/cpln` |
| Python | `pulumiverse-cpln` | `pip install pulumiverse-cpln` |
| Go | `github.com/pulumiverse/pulumi-cpln/sdk/go/cpln` | `go get github.com/pulumiverse/pulumi-cpln/sdk/go/cpln` |
| .NET | `Pulumiverse.Cpln` | `dotnet add package Pulumiverse.Cpln` |

### Provider Configuration

```bash
# Required
pulumi config set cpln:org <your-org>

# Optional
pulumi config set --secret cpln:token <your-token>
pulumi config set cpln:endpoint <api-endpoint-url>
pulumi config set cpln:profile <profile-name>
pulumi config set --secret cpln:refreshToken <your-refresh-token>
```

Uses the same environment variables as Terraform (`CPLN_ORG`, `CPLN_TOKEN`, etc.).

### Example: GVC (TypeScript)

```typescript
import * as cpln from '@pulumiverse/cpln';

const gvc = new cpln.Gvc('my-app', {
  name: 'my-app-gvc',
  locations: ['aws-us-west-2', 'gcp-us-east1'],
});
```

### Example: GVC (Python)

```python
import pulumiverse_cpln as cpln

gvc = cpln.Gvc("my-app",
    name="my-app-gvc",
    locations=["aws-us-west-2", "gcp-us-east1"],
)
```

### Example: GVC (Go)

```go
gvc, err := cpln.NewGvc(ctx, "my-app", &cpln.GvcArgs{
    Name:      pulumi.String("my-app-gvc"),
    Locations: pulumi.StringArray{
        pulumi.String("aws-us-west-2"),
        pulumi.String("gcp-us-east1"),
    },
})
```

### Migrating from Terraform to Pulumi

1. **Convert HCL**: `pulumi convert --from terraform --language typescript --out pulumi-cpln-infra`
2. **Create stack**: `pulumi stack init migrate`
3. **Import state**: `pulumi import --from terraform /path/to/terraform.tfstate`
4. **Review and deploy**: `pulumi up`

See the [Pulumi migration guide](https://www.pulumi.com/docs/iac/adopting-pulumi/migrating-to-pulumi/from-terraform) for details.

## Template Catalog with IaC

Install templates from the Control Plane catalog using Terraform or Pulumi. Templates bundle pre-configured resources (workloads, secrets, etc.) into deployable packages.

### Terraform

```hcl
resource "cpln_catalog_template" "postgres" {
  name     = "my-postgres"
  template = "postgres"
  version  = "1.0.0"
  gvc      = "my-gvc"
  values   = file("${path.module}/values.yaml")
}
```

### Pulumi (TypeScript)

```typescript
import * as cpln from '@pulumiverse/cpln';
import * as fs from 'fs';

const values = fs.readFileSync('values.yaml', 'utf8');

const release = new cpln.CatalogTemplate('postgres', {
  name: 'my-postgres',
  template: 'postgres',
  version: '1.0.0',
  gvc: 'my-gvc',
  values: values,
});
```

### Catalog Template Arguments

| Argument | Description |
|----------|-------------|
| `name` | Unique release name for this installation |
| `template` | Catalog template name (e.g., `postgres`, `cockroachdb`) |
| `version` | Template version to install |
| `gvc` | Target GVC (leave empty if the template creates its own) |
| `values` | YAML-formatted string with template configuration |

### Outputs

After applying, the resource exposes a `resources` attribute with all created Control Plane resources, each containing `kind`, `name`, and `link`.

### Upgrade

Update the `version` and/or `values.yaml`, then re-apply. Only affected workloads are redeployed.

## Best Practices

### State Management

- **Terraform**: Use remote backends (S3, GCS, Terraform Cloud) for team collaboration. Enable state locking.
- **Pulumi**: Use Pulumi Service (default) or self-managed backends. State is stored per stack.
- **Never commit state files** to version control — they may contain sensitive values.

### Secret Handling

- Use `CPLN_TOKEN` environment variable for authentication — never hardcode tokens in HCL/Pulumi code.
- For CI/CD, create a dedicated service account with minimal permissions.
- Mark sensitive Pulumi config with `--secret`: `pulumi config set --secret cpln:token <token>`.
- Terraform marks secret values as sensitive automatically when using the `cpln_secret` resource.

### CI/CD Integration

Terraform and Pulumi integrate with CI/CD platforms. Example repos:

- **GitHub Actions (Terraform)**: https://github.com/controlplane-com/github-actions-example-terraform
- **GitLab CI (Terraform)**: https://gitlab.com/controlplane-com/gitlab-pipeline-example-terraform
- **Bitbucket Pipelines (Terraform)**: https://bitbucket.org/controlplane-com/bitbucket-pipeline-example-terraform

### Drift Detection

- **Terraform**: Run `terraform plan` periodically to detect drift between state and actual resources.
- **Pulumi**: Run `pulumi preview` to detect drift.
- Both tools show a diff of what would change, allowing you to reconcile manually or re-apply.

## Quick Reference

### Provider URLs

| Provider | URL |
|----------|-----|
| Terraform Registry | https://registry.terraform.io/providers/controlplane-com/cpln/latest |
| Pulumi Registry | https://www.pulumi.com/registry/packages/cpln |
| Terraform Examples | https://github.com/controlplane-com/examples/tree/main/terraform |

### Authentication Setup (Any Tool)

```bash
# Environment variables (shared across Terraform, Pulumi, and CLI)
export CPLN_ORG=my-org
export CPLN_TOKEN=<service-account-token>
```

### Scaffold from Existing Resources

The `cpln` CLI can emit existing resources in multiple formats, useful for bootstrapping IaC or `cpln apply` workflows:

```bash
# YAML manifest (for cpln apply / K8s operator)
cpln gvc get my-gvc -o yaml-slim > gvc.yaml
cpln workload get my-app --gvc my-gvc -o yaml-slim > workload.yaml

# Terraform HCL scaffold for an existing resource
cpln workload get my-app --gvc my-gvc -o tf > workload.tf

# Apply manifests (idempotent). --file accepts a file or a directory (recurses YAML/JSON).
cpln apply --file ./manifests/
cpln apply --file ./manifests/ --ready   # block until workloads are ready
```

Supported `-o` formats: `text`, `json`, `yaml`, `json-slim`, `yaml-slim`, `tf`, `crd`, `names`.

### Related Skills

- **cpln-gitops-cicd** — CI/CD pipelines, service account auth, `cpln apply` in pipelines
- **cpln-k8s-operator** — Managing resources as Kubernetes CRDs with ArgoCD
- **cpln-template-catalog** — Template catalog overview, available templates, and values configuration

## Documentation

For the latest reference, see:

- [IaC Overview](https://docs.controlplane.com/iac/overview.md)
- [Terraform Provider](https://docs.controlplane.com/iac/terraform.md)
- [Pulumi Provider](https://docs.controlplane.com/iac/pulumi.md)
- [cpln apply Guide](https://docs.controlplane.com/guides/cpln-apply.md)
- [cpln convert Guide](https://docs.controlplane.com/guides/cli/cpln-convert.md)
