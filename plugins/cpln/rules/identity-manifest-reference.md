---
description: Validation constraints for Control Plane identity manifests. Consult when generating or modifying identity YAML to avoid creation/update failures.
alwaysApply: false
---

# Identity Manifest Validation Reference

Guardrails for generating correct identity manifests. For full field details, inspect an existing identity with `cpln identity get IDENTITY --gvc GVC -o yaml`.

## Scope and Assignment

- Identities are **GVC-scoped** — they cannot be shared across GVCs
- A workload can have exactly **one** identity
- An identity can be shared across multiple workloads within the same GVC
- One cloud account per provider per identity (one AWS + one GCP + one Azure, not two AWS)
- Assign to workload: `--set spec.identityLink=//identity/NAME`

## Complete Identity YAML Structure

```yaml
kind: identity
name: my-identity
gvc: my-gvc                            # parent GVC (used by local tools, ignored by server)
description: Multi-cloud access identity
tags:
  team: platform

# AWS — exactly one of roleName or policyRefs (xor)
aws:
  cloudAccountLink: /org/my-org/cloudaccount/aws-prod  # required
  policyRefs:                           # xor with roleName
    - "aws::arn:aws:iam::123456789012:policy/S3ReadOnly"
  trustPolicy:                          # optional, cannot combine with roleName
    Version: "2012-10-17"
    Statement:
      - Effect: Allow
        Principal:
          Service: ec2.amazonaws.com
        Action: sts:AssumeRole
  # roleName: MyExistingRole            # xor with policyRefs, max 64 chars

# GCP — exactly one of serviceAccount or bindings (xor)
gcp:
  cloudAccountLink: /org/my-org/cloudaccount/gcp-prod  # required
  bindings:                             # xor with serviceAccount
    - resource: "projects/my-project"   # optional, defaults to project
      roles:                            # min 1 role
        - roles/storage.objectViewer
        - roles/bigquery.dataViewer
  scopes:                               # default: [https://www.googleapis.com/auth/cloud-platform]
    - https://www.googleapis.com/auth/cloud-platform
  # serviceAccount: sa@proj.iam.gserviceaccount.com  # xor with bindings, must end .gserviceaccount.com

# Azure
azure:
  cloudAccountLink: /org/my-org/cloudaccount/azure-prod  # required
  roleAssignments:                      # optional
    - scope: "/subscriptions/SUB_ID/resourceGroups/my-rg"  # optional, defaults to subscription
      roles:                            # min 1 role
        - Reader
        - "Storage Blob Data Reader"

# NATS NGS
ngs:
  cloudAccountLink: /org/my-org/cloudaccount/nats-prod  # required
  pub:
    allow: ["orders.*", "users.>"]
    deny: ["orders.sensitive.*"]
  sub:
    allow: ["orders.*"]
  resp:
    max: 1                              # -1 = no limit
    ttl: "30s"                          # format: #ms, #s, #m, #h
  subs: -1                              # max subscriptions per connection, -1 = no limit
  data: -1                              # max bytes, -1 = no limit
  payload: -1                           # max message payload, -1 = no limit

# Network Resources (Cloud Wormhole) — max 50
networkResources:
  - name: database-server               # required, unique across network + native resources
    agentLink: /org/my-org/agent/db-agent  # optional
    IPs: ["10.0.1.100"]                 # 1-5 IPv4 addresses, xor with FQDN
    # FQDN: db.internal.company.com     # xor with IPs, auto-lowercased
    resolverIP: "10.0.1.1"             # optional IPv4
    ports: [5432]                       # 1-10 ports, range 0-65535, required

# Native Network Resources — max 50
nativeNetworkResources:
  - name: aws-rds-proxy                 # required, unique across network + native resources
    FQDN: rds-proxy.amazonaws.com       # optional
    ports: [5432]                       # 1-10 ports, range 0-65535, required
    awsPrivateLink:                     # xor with gcpServiceConnect
      endpointServiceName: "com.amazonaws.vpce.us-east-1.vpce-svc-12345"
    # gcpServiceConnect:                # xor with awsPrivateLink
    #   targetService: "projects/P/regions/R/serviceAttachments/S"
```

## AWS Identity Constraints

- `cloudAccountLink` is required
- `roleName` and `policyRefs` are mutually exclusive (xor) — provide exactly one
- `roleName` and `trustPolicy` are mutually exclusive (oxor)
- `roleName`: max 64 chars, regex `^([a-zA-Z0-9/+=,.@_-])+$`
- `policyRefs`: regex `^(aws::)?([a-zA-Z0-9/+=,.@_-])+$`
- `trustPolicy.Version` defaults to `"2012-10-17"`

## GCP Identity Constraints

- `cloudAccountLink` is required
- `serviceAccount` and `bindings` are mutually exclusive (xor) — provide exactly one
- `serviceAccount` must end with `.gserviceaccount.com` and be a valid email
- `bindings[].roles` must match `^roles\/([a-zA-Z0-9])+(\.([a-zA-Z0-9])+)?$`, min 1 role
- `scopes` defaults to `["https://www.googleapis.com/auth/cloud-platform"]`

## Azure Identity Constraints

- `cloudAccountLink` is required
- `roleAssignments` is optional
- Each assignment needs `roles` with min 1 role
- `scope` is optional — omit to default to the subscription

## Network Resource Constraints

- `IPs` and `FQDN` are mutually exclusive (xor)
- `IPs`: 1-5 IPv4 addresses, must be unique
- `ports`: 1-10 ports, range 0-65535, required, must be unique and sorted
- Max 50 network resources per identity
- Names/FQDNs must be unique across both `networkResources` and `nativeNetworkResources`
## Native Network Resource Constraints

- `awsPrivateLink` and `gcpServiceConnect` are mutually exclusive (xor)
- `gcpServiceConnect.targetService` must match `projects/*/regions/*/serviceAttachments/*`
- Max 50 native network resources per identity

## Common Validation Errors

| Error | Fix |
|:---|:---|
| Both roleName and policyRefs set | Use exactly one: `roleName` to reuse existing role, `policyRefs` to create new |
| Both serviceAccount and bindings set | Use exactly one: `serviceAccount` for existing SA, `bindings` to create new |
| serviceAccount not ending in .gserviceaccount.com | Must be a valid GCP service account email |
| Missing cloudAccountLink | Required for every cloud provider section (aws, gcp, azure, ngs) |
| Both IPs and FQDN on network resource | Use exactly one: `IPs` for static addresses, `FQDN` for DNS name |
| Duplicate Name/FQDN across resources | Names must be unique across networkResources and nativeNetworkResources |
| Both awsPrivateLink and gcpServiceConnect | Use exactly one per native network resource |
| Two AWS accounts in same identity | One cloud account per provider per identity |
| Identity not assigned to workload | Use `--set spec.identityLink=//identity/NAME` on the workload |
| Missing policy for secret access | Identity needs a policy granting `reveal` on the target secret |

## Example: AWS Identity with Policy Refs

```yaml
kind: identity
name: s3-reader
gvc: production
aws:
  cloudAccountLink: /org/my-org/cloudaccount/aws-prod
  policyRefs:
    - "aws::arn:aws:iam::123456789012:policy/S3ReadOnly"
```

## Example: GCP Identity with Bindings

```yaml
kind: identity
name: gcp-data-reader
gvc: production
gcp:
  cloudAccountLink: /org/my-org/cloudaccount/gcp-prod
  bindings:
    - resource: "projects/my-project"
      roles:
        - roles/storage.objectViewer
        - roles/bigquery.dataViewer
```

## Example: Azure Identity

```yaml
kind: identity
name: azure-reader
gvc: production
azure:
  cloudAccountLink: /org/my-org/cloudaccount/azure-prod
  roleAssignments:
    - roles: [Reader, "Storage Blob Data Reader"]
```

## Example: Network Resource (Cloud Wormhole)

```yaml
kind: identity
name: db-access
gvc: production
networkResources:
  - name: postgres-primary
    agentLink: /org/my-org/agent/vpc-agent
    FQDN: postgres.internal.company.com
    ports: [5432]
```

## MCP Tools

| Tool | Purpose |
|:---|:---|
| `mcp__cpln__list_identities` | List all identities in a GVC (requires `gvc`) |
| `mcp__cpln__get_identity` | Get identity details including network resources (requires `gvc`, `name`) |
| `mcp__cpln__create_identity` | Create an identity. Accepts `name`, `description`, `tags`, and optionally `networkResources` / `nativeNetworkResources` arrays |
| `mcp__cpln__update_identity` | Update description/tags; optionally replace the full `networkResources` / `nativeNetworkResources` arrays |
| `mcp__cpln__delete_identity` | Delete an identity (irreversible) |
| `mcp__cpln__list_identity_network_resources` | List both agent-based and cloud-native resources on an identity |
| `mcp__cpln__add_identity_network_resource` | Add a single agent-based (cloud wormhole) resource |
| `mcp__cpln__add_identity_native_network_resource` | Add a single PrivateLink / PSC resource |
| `mcp__cpln__remove_identity_network_resource` | Remove a resource by name (matches across both arrays) |

Notes:
- Use the atomic `add_*` / `remove_*` tools for one-off changes; use `update_identity` with a full array for bulk replacement.
- MCP tools do **not** configure cloud provider sections (`aws`, `gcp`, `azure`, `ngs`, `memcacheAccess`, `spicedbAccess`). Use `cpln apply` with a YAML manifest for those.
