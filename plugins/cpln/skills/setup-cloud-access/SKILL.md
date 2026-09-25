---
name: setup-cloud-access
description: Credential-free cloud access (Universal Cloud Identity) for a Control Plane workload. Use when a workload needs AWS, GCP, Azure, or NATS NGS resources without embedded keys, or asks to register a cloud account.
---

# Cloud Access Setup (Universal Cloud Identity)

> **Tool availability:** `create_cloud_account`, `update_cloud_account`, and `how_to_create_cloud_account` need `?toolsets=full`; `grant_cloud_access` is core.

A workload reads cloud resources with **no embedded keys**: a GVC-scoped **identity** carries a per-provider cloud-access block that federates with the provider's IAM, and Control Plane vends short-lived credentials at runtime. Cloud SDKs (boto3, google-cloud, @azure/sdk) pick them up automatically — no SDK config.

## The chain

**One call once the cloud account exists:** `mcp__cpln__grant_cloud_access` (`workload`, `provider`, `cloudAccount`, and the provider block from step 3) ensures the workload's identity, attaches the cloud account to it, and waits for `status.<provider>.usable`. Steps 3 and 4 below are what it does, for hand-built setups.

| Step | What must be true | Without it |
|---|---|---|
| **1. Cloud account** | a `cloud_account` (org-wide) maps to the provider, registered after the cloud-side IAM setup | identity can't federate |
| **2. Identity cloud block** | the identity carries an `aws`/`gcp`/`azure`/`ngs` block linking that cloud account | no credentials vended |
| **3. Workload link** | the identity is attached to the workload (`spec.identityLink`) | workload has no identity |

Order is strict: the cloud account must exist **before** the identity's cloud block references it.

## Key constraints

- **Identities are GVC-scoped** — one per workload, shareable within a GVC, never across GVCs. Same access in another GVC = recreate the identity there.
- **One cloud account per provider per identity** — one AWS + one GCP + one Azure + one NGS is fine; two AWS on one identity is not.
- **Cloud accounts are org-scoped** — always pass `org`.
- **Provider is immutable** — to switch providers, delete and recreate the cloud account.

## Step 1 — Cloud-side IAM setup

Each provider needs IAM configured **on the provider side first** so Control Plane can assume a role / impersonate a service account. Run the per-provider how-to to get the org-specific values (Control Plane's AWS account ID + external ID, the GCP service-account email, the Azure Function-App connector steps) — **never guess these**:

- `how_to_create_cloud_account` with `provider: aws` (`cloudAccountName`, `awsAccountId`, `roleArn`) — trust policy, account ID, external ID, the IAM permissions for the `cpln-connector` policy. Create an IAM role with that trust policy + connector policy + `ReadOnlyAccess`; note the **role ARN**.
- `how_to_create_cloud_account` with `provider: gcp` (`projectId`) — add the shown service account as an IAM principal with **Viewer, Project IAM Admin, Service Account Admin, Service Account Token Creator** (plus the service Admin role, e.g. `roles/storage.admin`, for each resource type identities will use); note the **project ID**.
- `how_to_create_cloud_account` with `provider: azure` (`subscriptionId`, `resourceGroupName`, `storageAccountName`, `locationName`, `functionAppName`) — create a Function App, deploy the connector, make it subscription **Owner**, capture the Function URL + `iam-broker` code into an `azure-connector` secret.
- `how_to_create_cloud_account` with `provider: ngs` (`secretName`) — create a `nats-account` secret holding your NATS account credentials.

CLI fallback: `cpln cloudaccount create-<provider> --how --org ORG`.

## Step 2 — Register the cloud account

`create_cloud_account` (`provider` = `aws`/`gcp`/`azure`/`ngs`), passing the value the provider needs:

| Provider | Required field |
|---|---|
| aws | `roleArn` (the role ARN from step 1) |
| gcp | `projectId` |
| azure | `secretLink` to an existing `azure-connector` secret (created by the user) |
| ngs | `secretLink` to an existing `nats-account` secret (created by the user) |

`status.usable` stays `false` until the cloud-side IAM exists. `update_cloud_account` edits the data block / tags (provider stays immutable). CLI fallback: `cpln cloudaccount create-aws|create-gcp|create-azure|create-ngs`.

## Step 3 — Identity with a cloud-access block

`create_identity` (or `update_identity` on an existing one) accepts the per-provider block directly — pass `aws`, `gcp`, `azure`, or `ngs`. On update each block **replaces wholesale**; `removeCloudIdentities: ["aws"]` detaches one. Every block needs `cloudAccountLink: //cloudaccount/NAME`. The pattern per provider:

- **aws** — Control Plane creates a new IAM role with `policyRefs` (managed = `aws::AmazonS3ReadOnlyAccess`, custom = bare name; chars `a-zA-Z0-9/+=,.@_-` only — **never full ARNs**), **xor** `roleName` to reuse a role. Optional `trustPolicy` (only alongside `policyRefs`).
- **gcp** — creates a service account with `bindings` (`resource` + `roles` like `roles/storage.objectViewer`; omit `resource` = project), **xor** `serviceAccount` to reuse one. Optional `scopes`.
- **azure** — creates a managed identity with `roleAssignments` (`scope` + `roles`; omit `scope` = subscription).
- **ngs** — scoped NATS creds: `pub`/`sub` `allow`/`deny` subjects (`*` single, `>` multi-level), `resp.max`/`resp.ttl`, and `subs`/`data`/`payload` limits (`-1` = no limit).

```yaml
spec:
  aws:
    cloudAccountLink: //cloudaccount/my-aws
    policyRefs: ["aws::AmazonS3ReadOnlyAccess", "MyCustomPolicy"]
```

CLI fallback (MCP unavailable / CI-CD): `cpln identity get NAME --gvc GVC -o yaml-slim > id.yaml`, add the block under `spec`, `cpln apply -f id.yaml`. Confirm the exact shape with `get_resource_schema` (kind `identity`) before authoring YAML by hand.

## Step 4 — Link to the workload and verify

`update_workload` sets `spec.identityLink = //identity/NAME` (CLI: `cpln workload update NAME --set spec.identityLink=//identity/NAME`).

Read the identity back with `get_resource` (kind `identity`): `status.<provider>.usable` must be `true`; if `false`, read `status.<provider>.lastError`. Cloud CLIs are usually absent from production containers, so a missing `aws`/`gcloud`/`az` does **not** mean access is broken — the SDK path still works.

## Private-network resources

Reaching a private VPC / on-prem endpoint is a different mechanism on the **same identity**: a `networkResources` (agent/wormhole) or `nativeNetworkResources` (AWS PrivateLink / GCP PSC) array, not a cloud-access block. For the agent deployment walkthrough use **setup-agent**; for the comparison, producer-side setup, and the resource schema use **native-networking**.

## Common mistakes

- **Cloud block before the cloud account** — register the account first; the link won't resolve otherwise.
- **Skipping the how-to** — the org-specific account/external IDs and SA email are required and can't be guessed.
- **Full ARN in AWS `policyRefs`** — use the policy name with an optional `aws::` prefix, no colons.
- **Both `policyRefs` + `roleName` (AWS) or `bindings` + `serviceAccount` (GCP)** — exactly one.
- **Not checking `status.<provider>.usable`** — verify `true` before linking to the workload.
- **Confusing cloud access with secret access** — cloud access is the identity's `aws`/`gcp`/`azure`/`ngs` block; secret access is a `reveal` policy on a `cpln://secret/` reference (see **setup-secret**).
- **Sharing an identity across GVCs** — recreate it per GVC.
