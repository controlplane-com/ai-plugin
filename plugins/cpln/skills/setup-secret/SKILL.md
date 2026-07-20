---
name: setup-secret
description: Sets up complete secret access for a Control Plane workload — identity, policy, and reference injection. Use when a workload needs to read a secret, configure a pull secret, or fix a deployment paused on a secret reference.
---

# Secret Access Setup

> **Tool availability:** secrets are read-only through MCP on every profile — `list_resources` / `get_resource` (kind="secret") show existence and metadata, never values. No tool creates, edits, deletes, or reveals a secret: secret data and lifecycle are managed by the user (Console, CLI, Terraform, Pulumi, or the API). `grant_workload_secret_access` (every profile) grants a workload access — it never returns values.

Secret access is the #1 thing users get wrong: a workload reads a secret only when **three** things are all in place. Miss any one and the value is silently absent at runtime — or the deployment pauses on an unresolved reference.

## The mandatory chain

| Step | What must be true | Without it |
|---|---|---|
| **1. Identity** | an identity exists and is linked to the workload (`spec.identityLink`) | workload has no API credential — reads nothing |
| **2. Policy** | a policy grants that identity `reveal` on the secret | reference resolves to empty |
| **3. Reference** | the secret is injected as `cpln://secret/NAME` (env or volume) | nothing to read |

`reveal`, **not** `view` — `view` exposes only metadata. This is the single most common mistake.

## Pull secrets are different — no identity/policy

To pull images from a private registry, don't build the chain. Add the registry secret to the **GVC's** `pullSecretLinks` and every workload in that GVC can pull. Pull secrets are registry credentials — `docker`, `ecr`, or `gcp` types.

```yaml
kind: gvc
spec:
  pullSecretLinks:
    - //secret/my-registry
```

## Workflow

### 1 — Identify the secret

The secret must already exist — the user creates and rotates it through any Control Plane surface: Console, CLI (value-in-a-file, never an inline flag), Terraform, Pulumi, or the API. Confirm it exists with `list_resources` or `get_resource` (kind="secret") before wiring anything; never ask for the value in chat and never invent a placeholder.

### 2 — Grant the workload access

**Preferred — one call.** `grant_workload_secret_access` (`gvc`, `workloadName`, `secretName`) creates the identity if missing (default `{gvc}-{workloadName}`), links it to the workload, and creates/updates a `reveal` policy (default `{gvc}-{workloadName}-secrets-policy`). It never returns secret values, and it does **not** inject the reference — step 3 still applies.

**Manual alternative** (granular control): `create_identity` → `update_workload` to set `spec.identityLink` → `create_policy` (targetKind `secret`, a `reveal` binding naming the identity). Policy shape lives in **access-control**.

**Ordering matters.** The workload must already exist. For a new workload that references a secret: `create_workload` first (its deployment pauses on the unresolved reference), then grant — the deployment resumes.

Identities are **GVC-scoped**: one per workload, shareable across workloads in the same GVC, never across GVCs.

### 3 — Inject the reference

`update_workload` (read current state with `get_resource` first) to add `cpln://secret/NAME` — the whole secret — or `cpln://secret/NAME.KEY` for one property:

| Type | Keys | Example |
|---|---|---|
| opaque | `payload` | `cpln://secret/api-key.payload` |
| userpass | `username`, `password` | `cpln://secret/creds.password` |
| tls | `key`, `cert`, `chain` | `cpln://secret/web-tls.cert` |
| dictionary | user-defined | `cpln://secret/cfg.DB_HOST` |
| aws / ecr | `accessKey`, `secretKey`, `roleArn` | `cpln://secret/aws.accessKey` |

Inject as an **env var** or a **volume mount** (`{ uri: "cpln://secret/NAME", path: "/secrets/x" }`). Mounts are read-only (except Azure Files), max **15** per container, and these knative-reserved paths are rejected: `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`.

### 4 — Verify and redeploy

- `get_resource` (kind="workload") → `spec.identityLink` is set and the env/volume reference reads `cpln://secret/…`.
- `get_resource` (kind="policy") → the binding grants `reveal` to that identity.
- Updating a workload spec redeploys automatically; via CLI use `cpln apply --ready` to block until healthy. **A rotated secret value needs a redeploy** — running replicas keep the old value until then.

## Quick reference — MCP tools

| Tool | Purpose |
|---|---|
| `grant_workload_secret_access` | Composite — identity + `reveal` policy + link, in one call |
| `create_identity` / `create_policy` | Build the access chain manually (granular control) |
| `update_workload` | Set `identityLink`; inject the env / volume reference |
| `list_resources` / `get_resource` (kind="secret") | Confirm a secret exists / read its metadata |

## Common mistakes

- **No identity** — a workload with no `identityLink` reads no secrets.
- **`view` instead of `reveal`** — metadata only, no value.
- **Bad reference** — must be `cpln://secret/NAME`, not the bare name.
- **Granting before the workload exists** — the workload comes first.
- **Sharing an identity across GVCs** — they are GVC-scoped.
- **Over-engineering pull secrets** — registries need only `pullSecretLinks`, no identity/policy.
- **Skipping the redeploy after rotation** — running replicas keep the old value.

## Related skills

| Need | Skill |
|---|---|
| Policy shape, permissions, principals | `access-control` |
| Workload identities, cloud / private-network access | `native-networking` |
| Workload spec, deploy, env vars | `workload` |

## Documentation

- [Secret Reference](https://docs.controlplane.com/reference/secret.md)
