---
name: cpln-cloud-identity-setup
description: Use when a workload needs credential-free access to cloud resources (e.g. AWS S3, GCP Cloud SQL, Azure services, NATS NGS) or private network resources via agents. Guides through cloud account registration, identity creation, cloud access configuration, and provider-specific setup for AWS, GCP, Azure, and NATS NGS.
version: 1.0.0
---

# Control Plane Cloud Identity Setup

You guide users through setting up credential-free cloud access (Universal Cloud Identity) for Control Plane workloads. This eliminates embedded credentials by using platform-managed identities that federate with cloud provider IAM.

## Prerequisites

Before starting, confirm with the user:

- Which cloud provider(s) or service(s) they need to access (AWS, GCP, Azure, NATS NGS)
- What cloud resources the workload needs (S3, Cloud SQL, Azure Blob, NATS messaging, etc.)
- Which org and GVC the workload is in
- Whether they already have a cloud account registered in Control Plane (`cpln cloudaccount get --org ORG`)

## Key Constraints

- **One cloud account per provider per identity** — an identity can have one AWS + one GCP + one Azure + one NGS, but NOT two of the same provider
- **Identities are GVC-scoped** — they cannot be shared across GVCs. If multiple GVCs need the same cloud access, recreate the identity with the same spec in each GVC
- **One identity per workload** — but an identity can be shared across multiple workloads within the same GVC
- **Order matters**: cloud account must exist before configuring identity cloud access

## Step 1: Get Provider-Specific Setup Instructions

Each cloud provider has a `--how` flag that outputs the exact steps needed on the cloud provider side before registering the account in Control Plane:

```bash
# AWS — shows trust policy, Control Plane AWS account ID, external ID, required IAM permissions
cpln cloudaccount create-aws --how --org my-org

# GCP — shows Control Plane service account to add as IAM principal, required roles
cpln cloudaccount create-gcp --how --org my-org

# Azure — shows steps to create the Function App and deploy the connector
cpln cloudaccount create-azure --how --org my-org
```

**Always run `--how` first.** The output contains org-specific values (account IDs, external IDs, service account emails) that are required for the cloud-side setup. Do not guess these values.

Use the MCP tools for the same information:

- `mcp__cpln__get_cloud_account_setup_guide` (pass `provider`: `aws`, `gcp`, or `azure`)

## Step 2: Cloud-Provider-Side Setup

### AWS

Based on the `--how` output:

1. Create an IAM role (e.g., `cpln-my-org`) in the AWS account
2. Attach the trust policy from the `--how` output — it grants Control Plane's AWS account permission to assume the role with the correct external ID
3. Attach a custom policy (e.g., `cpln-connector`) with the permissions listed in the `--how` output — this lets Control Plane create and manage IAM roles for identities
4. Attach the AWS managed `ReadOnlyAccess` policy
5. Note the role ARN (e.g., `arn:aws:iam::123456789012:role/cpln-my-org`)

### GCP

Based on the `--how` output:

1. Go to IAM in GCP Console
2. Add the Control Plane service account (shown in `--how` output) as a principal
3. Assign the following roles:
   - **Viewer** (read-only)
   - **Project IAM Admin** (manage IAM)
   - **Service Account Admin** (create/delete service accounts)
   - **Service Account Token Creator** (generate tokens)
4. If identities will access specific services, the Control Plane service account also needs the **Admin role** for each service (e.g., `roles/storage.admin` for Cloud Storage)
5. Note the GCP project ID

### Azure (Connector)

Based on the `--how` output:

1. Create a Function App in Azure
2. Download and deploy the Control Plane connector package to the Function App
3. Set the Function App as **Owner** of the subscription
4. Get the Function URL and the function code (found under Function Keys for the `iam-broker` function)

### NATS NGS

1. Create a NATS account secret (type `nats-account`) containing your NATS account credentials
2. The secret name will be referenced when creating the NGS cloud account

## Step 3: Register Cloud Account in Control Plane

After completing the cloud-provider-side setup, register the cloud account:

```bash
# AWS — requires the role ARN from step 2
cpln cloudaccount create-aws \
  --name my-aws-account \
  --role-arn "arn:aws:iam::123456789012:role/cpln-my-org" \
  --org my-org

# GCP — requires the project ID
cpln cloudaccount create-gcp \
  --name my-gcp-account \
  --project-id my-gcp-project \
  --org my-org

# Azure (Connector) — first create the secret, then the cloud account
cpln secret create-azure-connector \
  --name my-azure-connector-secret \
  --url "https://my-func-app.azurewebsites.net/api/iam-broker" \
  --code "FUNCTION_CODE_FROM_AZURE" \
  --org my-org

cpln cloudaccount create-azure \
  --name my-azure-account \
  --secret my-azure-connector-secret \
  --org my-org

# NGS — requires a nats-account secret
cpln cloudaccount create-ngs \
  --name my-ngs-account \
  --secret my-nats-account-secret \
  --org my-org
```

Via MCP: `mcp__cpln__create_cloud_account`

**Additional MCP tools for cloud account management:**

| Tool | Action |
|:---|:---|
| `mcp__cpln__list_cloud_accounts` | List all cloud accounts in an organization |
| `mcp__cpln__get_cloud_account` | Get detailed info about a specific cloud account |
| `mcp__cpln__create_cloud_account` | Create a cloud account (aws, gcp, azure, or ngs) |
| `mcp__cpln__get_cloud_account_setup_guide` | Get provider-specific setup instructions |
| `mcp__cpln__delete_cloud_account` | Delete a cloud account (irreversible) |

Verify the cloud account was created:

```bash
cpln cloudaccount get my-aws-account --org my-org -o yaml
```

## Step 4: Create Identity and Configure Cloud Access

First, create the identity:

```bash
cpln identity create --name my-app-identity --gvc my-gvc --org my-org
```

Then configure cloud access on the identity. The `cpln identity create` command creates an empty identity without cloud access — the spec must be edited and applied separately.

**Via CLI: Export, edit, and apply**

```bash
# Export identity as YAML
cpln identity get my-app-identity --gvc my-gvc --org my-org -o yaml-slim > identity.yaml
```

Edit the file to add the cloud access configuration under `spec`:

**AWS example** — Control Plane creates a new IAM role in your AWS account with the specified policies:

```yaml
kind: identity
name: my-app-identity
spec:
  aws:
    cloudAccountLink: //cloudaccount/my-aws-account
    policyRefs:
      - "aws::AmazonS3ReadOnlyAccess"
      - "MyCustomPolicy"
```

`policyRefs` values use the policy name with an optional `aws::` prefix for AWS-managed policies (e.g., `aws::AmazonS3ReadOnlyAccess`) or the custom policy name without a prefix. The format only allows `a-zA-Z0-9/+=,.@_-` characters — do NOT use full ARN format with colons.

Alternatively, use `roleName` to reuse an existing IAM role (max 64 chars, same character restrictions). You must use exactly one of `policyRefs` or `roleName`, not both. An optional `trustPolicy` can be added alongside `policyRefs` (but not alongside `roleName`).

**GCP example** — Control Plane creates a new service account in your GCP project with the specified role bindings:

```yaml
kind: identity
name: my-app-identity
spec:
  gcp:
    cloudAccountLink: //cloudaccount/my-gcp-account
    bindings:
      - resource: "projects/my-gcp-project"
        roles:
          - "roles/storage.objectViewer"
          - "roles/bigquery.dataViewer"
```

Use `bindings` to assign roles on specific resources (if `resource` is omitted, it defaults to the project itself). Alternatively, use `serviceAccount` to reuse an existing GCP service account (must end in `.gserviceaccount.com`). You must use exactly one of `bindings` or `serviceAccount`, not both. GCP roles must match the format `roles/serviceName.roleName` (e.g., `roles/storage.objectViewer`). An optional `scopes` field defaults to `["https://www.googleapis.com/auth/cloud-platform"]`.

**Azure example** — Control Plane creates a managed identity with the specified role assignments:

```yaml
kind: identity
name: my-app-identity
spec:
  azure:
    cloudAccountLink: //cloudaccount/my-azure-account
    roleAssignments:
      - scope: "/subscriptions/SUB_ID/resourceGroups/my-rg"
        roles:
          - "Reader"
          - "Storage Blob Data Reader"
```

Each `roleAssignments` entry requires at least one role. The `scope` field is optional — if omitted, it defaults to the subscription itself.

**NGS example** — scoped NATS credentials automatically supplied at runtime:

```yaml
kind: identity
name: my-app-identity
spec:
  ngs:
    cloudAccountLink: //cloudaccount/my-ngs-account
    pub:
      allow: ["orders.*", "users.>"]
      deny: ["orders.sensitive.*"]
    sub:
      allow: ["orders.*", "users.>"]
    resp:
      max: 1
      ttl: "30s"
    subs: 100
    data: 1048576
    payload: 65536
```

Permission subjects use NATS subject syntax (`*` for single-level wildcard, `>` for multi-level). `resp.max` is the number of responses allowed on the replyTo subject (-1 = no limit). `resp.ttl` is the deadline format: `#ms`, `#s`, `#m`, or `#h`. Limits `subs`, `data`, `payload` default to -1 (no limit).

Apply the updated identity:

```bash
cpln apply --file identity.yaml --gvc my-gvc --org my-org
```

**Via MCP:** The typed `mcp__cpln__create_identity` / `mcp__cpln__update_identity` tools do **not** accept `aws` / `gcp` / `azure` / `ngs` sections — only `name`, `description`, `tags`, `networkResources`, `nativeNetworkResources`. To set cloud access via MCP, use the generic `mcp__cpln__cpln_resource_operation` tool with a PATCH, e.g.:

```json
{
  "kind": "identity",
  "operation": "patch",
  "org": "my-org",
  "gvc": "my-gvc",
  "name": "my-app-identity",
  "body": {
    "aws": {
      "cloudAccountLink": "//cloudaccount/my-aws-account",
      "policyRefs": ["aws::AmazonS3ReadOnlyAccess"]
    }
  }
}
```

Replace the `aws` block with `gcp`, `azure`, or `ngs` as needed; the body mirrors the YAML `spec` content shown above.

After applying, verify the identity's cloud access status:

```bash
cpln identity get my-app-identity --gvc my-gvc --org my-org -o yaml
```

Check `status.aws.usable` (or `status.gcp.usable`, `status.azure.usable`) — it should be `true`. If `false`, check `status.<provider>.lastError` for details.

## Step 5: Link Identity to Workload

```bash
cpln workload update my-app \
  --set spec.identityLink=//identity/my-app-identity \
  --gvc my-gvc \
  --org my-org
```

## Step 6: Verify Cloud Access

From within the workload, cloud SDKs automatically pick up credentials through the Control Plane credential vending process — no SDK configuration needed.

To verify, check the identity status first:

```bash
cpln identity get my-app-identity --gvc my-gvc --org my-org -o yaml
```

Confirm `status.<provider>.usable` is `true`. If `false`, check `status.<provider>.lastError` for details.

If the workload's container has cloud provider CLIs installed, you can also test directly:

```bash
# AWS (only if aws cli is in the container)
cpln workload exec my-app --gvc my-gvc --org my-org -- aws s3 ls

# GCP (only if gcloud is in the container)
cpln workload exec my-app --gvc my-gvc --org my-org -- gcloud storage ls
```

Note: cloud CLIs are often not present in production containers. The absence of `aws`, `gcloud`, or `az` commands does not mean cloud access is broken — it just means the CLI isn't installed. The application code using cloud SDKs (boto3, google-cloud, @azure/sdk, etc.) will still work. If the workload has multiple containers, use `--container <container-name>` to exec into the correct one.

If cloud access is not working, check:

1. The identity's `status.<provider>.usable` field is `true`
2. The identity is linked to the workload (`spec.identityLink`)
3. The cloud-provider-side IAM role/service account has the correct permissions
4. The cloud account itself is properly configured

## Private Network Access (Agents / Cloud Wormholes)

If the workload needs to reach resources in a private network (VPC, on-prem, data center), configure **network resources** on the identity. This requires a Control Plane Agent deployed in the target network.

For full agent deployment (creation, bootstrap, K8s/Docker/cloud-VM installation, HA, troubleshooting) and the MCP tools for managing network resources on an identity, use the **cpln-agent-setup** skill. The snippets below are a brief reference for cases where you only need to add network resources to an existing identity.

### Network resource types

**FQDN-based** — single hostname:

```yaml
spec:
  networkResources:
    - name: database-server
      agentLink: /org/my-org/agent/my-agent
      FQDN: "database.internal.company.com"
      ports: [5432]
```

The workload connects using `database-server:5432` (the `name` field becomes the hostname). If the resource uses TLS, the workload must use the FQDN directly, not the `name`.

**IP-based** — one to five IP addresses:

```yaml
spec:
  networkResources:
    - name: db-cluster
      agentLink: /org/my-org/agent/my-agent
      IPs: ["10.0.1.100", "10.0.1.101"]
      ports: [5432, 3306]
```

Limits: 1-5 IPs per resource, 1-10 ports per resource (range 0-65535). Cannot use both `FQDN` and `IPs` on the same network resource. An optional `resolverIP` field (IPv4) can specify a custom DNS resolver for FQDN-based resources.

### Native network resources (no agent needed)

For AWS PrivateLink and GCP Private Service Connect, use `nativeNetworkResources` — these don't require an agent:

```yaml
spec:
  nativeNetworkResources:
    - name: rds-endpoint
      FQDN: "rds-proxy.endpoint.us-east-1.amazonaws.com"
      ports: [5432]
      awsPrivateLink:
        endpointServiceName: "com.amazonaws.vpce.us-east-1.vpce-svc-12345678"
```

See the [Native Networking Setup](https://docs.controlplane.com/guides/native-networking/native-networking-setup.md) guide for full configuration.

## Common Mistakes

- **Running cloud account creation before the cloud-side setup** — the `--how` flag must be run first to get the org-specific values
- **Using `cpln cloudaccount create`** — this command does not exist. Use `create-aws`, `create-gcp`, `create-azure`, or `create-ngs`
- **Configuring identity cloud access before the cloud account exists** — the cloud account must be registered first
- **Using both `policyRefs` and `roleName` on AWS** — pick one, not both
- **Using both `bindings` and `serviceAccount` on GCP** — pick one, not both
- **Missing Admin role on GCP** — if the identity needs Cloud Storage access, Control Plane's service account must have `roles/storage.admin` in the GCP project
- **Trying to assign two cloud accounts of the same provider** — one AWS + one GCP + one NGS is fine, two AWS accounts on one identity is not
- **Not checking `status.<provider>.usable`** — after creating, verify it shows `true` before linking to a workload
- **Confusing cloud access with secret access** — both use identities, but cloud access is for AWS/GCP/Azure APIs (configured in identity spec), while secret access is for `cpln://secret/` references (configured via policy with `reveal` permission)
- **Missing `--org` flag on cloud account commands** — cloud accounts are org-scoped, always specify `--org`
