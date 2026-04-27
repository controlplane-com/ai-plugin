---
name: cpln-secret-setup-wizard
description: Use when a workload needs to access a secret. Orchestrates the mandatory 3-step process — create identity, create policy with reveal permission, inject secret reference. Handles all 12 secret types and pull secret configuration.
version: 1.0.0
---

# Control Plane Secret Setup Wizard

You orchestrate the complete secret access chain for Control Plane workloads. This is the #1 area where users make mistakes — most miss at least one of the three mandatory steps.

## Two Secret Access Patterns

### Pattern 1: Workload Secret Injection (Identity + Policy Required)

For workloads that need to read secret values at runtime (env vars, volume mounts). Requires ALL three steps:

1. **Identity** — created and linked to the workload
2. **Policy** — granting the identity `reveal` permission on the secret
3. **Reference** — secret injected as env var (`cpln://secret/NAME`) or volume mount

### Pattern 2: Pull Secrets (No Identity/Policy Needed)

For pulling container images from private registries (Docker Hub, ECR, GCP Artifact Registry). Add the registry secret to the GVC's `pullSecretLinks` — all workloads in that GVC automatically get access.

```yaml
kind: gvc
name: my-gvc
spec:
  pullSecretLinks:
    - //secret/my-docker-registry
    - //secret/my-ecr-credentials
```

Only Docker, ECR, and GCP secret types can be used as pull secrets.

---

## Workflow: Workload Secret Injection

### Step 1: Create or Identify the Secret

Ask the user what type of secret they need. The 12 types are:

| Type | CLI Command | Use Case |
|:---|:---|:---|
| opaque | `cpln secret create-opaque` | Generic text, API keys, tokens |
| dictionary | `cpln secret create-dictionary` | Key-value pairs |
| userpass | `cpln secret create-userpass` | Username + password |
| aws | `cpln secret create-aws` | AWS credentials |
| gcp | `cpln secret create-gcp` | GCP service account |
| azure-sdk | `cpln secret create-azure-sdk` | Azure service principal |
| azure-connector | `cpln secret create-azure-connector` | Azure Function App |
| docker | `cpln secret create-docker` | Docker registry auth |
| ecr | `cpln secret create-ecr` | AWS ECR (auto token refresh) |
| tls | `cpln secret create-tls` | TLS cert + key |
| keypair | `cpln secret create-keypair` | Public/private keys |
| nats-account | `cpln secret create-nats` | NATS credentials |

Use MCP: `mcp__cpln__create_secret` to create, or `mcp__cpln__list_secrets` to find existing secrets.

### Step 2 & 3: Grant the Workload Access to the Secret

#### Via MCP (preferred — automates identity + policy in one call)

Use `mcp__cpln__workload_reveal_secret`. This composite tool handles everything:
- Checks if the workload already has an identity; creates one if not (defaults to `{gvc}-{workloadName}`)
- Links the identity to the workload
- Creates or updates a policy with `reveal` permission on the secret (defaults to `{gvc}-{workloadName}-secrets-policy`)

Parameters:
- `gvc` (required) — GVC name
- `workloadName` (required) — workload name
- `secretName` (required) — secret to grant access to
- `org` (optional) — uses session context if not provided
- `identityName` (optional) — custom identity name
- `policyName` (optional) — custom policy name

This tool does NOT modify the workload's env vars or volumes — you still need Step 4 below to inject the secret reference.

#### Via CLI (manual — when MCP is not available)

**Create identity and link to workload:**

```bash
cpln identity create --name WORKLOAD-identity --gvc GVC --org ORG

cpln workload update WORKLOAD --gvc GVC --org ORG \
  --set spec.identityLink=WORKLOAD-identity
```

**Create policy with reveal permission:**

```bash
cpln policy create --name WORKLOAD-secret-access \
  --target-kind secret \
  --resource SECRET_NAME \
  --org ORG

cpln policy add-binding WORKLOAD-secret-access \
  --permission reveal \
  --identity WORKLOAD-identity \
  --gvc GVC \
  --org ORG
```

**Critical:** The permission must be `reveal`, not `view`. `view` only shows metadata; `reveal` exposes the actual secret value at runtime.

**Identity notes:**
- A workload can have exactly ONE identity.
- An identity CAN be shared across multiple workloads in the same GVC.
- Identities are GVC-scoped — they cannot be shared across GVCs. If the user needs the same identity in another GVC, recreate it there or export it with `cpln identity get NAME --gvc SOURCE_GVC -o yaml-slim` and apply to the target GVC.
- If the workload already has an identity, reuse it: `cpln workload get WORKLOAD --gvc GVC -o json | grep identityLink`

### Step 4: Inject Secret into Workload

**As environment variable:**

```bash
cpln workload update WORKLOAD --gvc GVC --org ORG \
  --set spec.containers.CONTAINER_NAME.env.MY_SECRET.value=cpln://secret/SECRET_NAME
```

**Secret reference formats by type:**

Use `cpln://secret/NAME` to reference the full secret, or `cpln://secret/NAME.KEY` to access a specific property.

| Secret Type | Available Keys | Example |
|:---|:---|:---|
| opaque | `payload` (decoded if base64 runtime decode enabled), or omit key for raw JSON with `payload` + `encoding` | `cpln://secret/my-api-key.payload` |
| dictionary | user-defined keys | `cpln://secret/db-config.DB_HOST` |
| userpass | `username`, `password` | `cpln://secret/creds.password` |
| tls | `key`, `cert`, `chain` | `cpln://secret/my-tls.cert` |
| keypair | `secretKey`, `publicKey`, `passphrase` | `cpln://secret/my-keys.publicKey` |
| aws | `accessKey`, `secretKey`, `roleArn`, `externalId` | `cpln://secret/my-aws.accessKey` |
| ecr | `accessKey`, `secretKey`, `roleArn`, `externalId`, `repos` | `cpln://secret/my-ecr.secretKey` |
| azure-sdk | `subscriptionId`, `tenantId`, `clientId`, `clientSecret` | `cpln://secret/my-azure.clientId` |
| nats-account | `accountId`, `privateKey` | `cpln://secret/my-nats.accountId` |
| any type | omit key for full secret as JSON | `cpln://secret/my-secret` |

**As volume mount:** Export the workload, add a volume, and apply:

```bash
cpln workload get WORKLOAD -o yaml-slim --gvc GVC --org ORG > workload.yaml
```

Edit to add the volume under the container:

```yaml
spec:
  containers:
    - name: main
      volumes:
        - uri: "cpln://secret/SECRET_NAME"
          path: /secrets/my-secret.txt
```

Then apply:

```bash
cpln apply --file workload.yaml --gvc GVC --org ORG
```

Volume mount behavior varies by secret type:

- **Opaque**: Path must contain at least one subpath (e.g., `/secrets/my-secret.txt`). The last path component is mounted as a file containing the payload. If no subpath is given, the payload is mounted as a file named `payload` (e.g., `/secrets/payload`). Base64-encoded payloads can be decoded at runtime if enabled on the secret.
- **Azure SDK, Docker, GCP**: Path must contain at least one subpath (e.g., `/secrets/creds`). The last path component becomes a directory containing a `___cpln___.secret` file with the secret data.
- **All other types** (Dictionary, UserPass, AWS, ECR, TLS, Keypair, NATS Account): If the root secret is selected (`cpln://secret/NAME`), the path is mounted as a directory with a file per key/property, plus a `___cpln___.secret` file containing the full secret as JSON. If a specific key is selected (`cpln://secret/NAME.KEY`), the path is mounted as a single file containing that key's value.

Max 15 volumes per container. Volumes are read-only (except Azure Files). Reserved paths cannot be used: `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`.

### Step 5: Verify the Chain

1. Confirm identity is linked: `cpln workload get WORKLOAD --gvc GVC -o json | grep identityLink`
2. Confirm policy grants reveal: `cpln policy get POLICY -o json` or use `mcp__cpln__get_permissions`
3. Confirm secret reference format: must start with `cpln://secret/`

### Step 6: Redeploy

If modifying an existing workload, a redeployment is triggered automatically when you update the workload spec. If using `cpln apply`:

```bash
cpln apply --file workload.yaml --ready
```

The `--ready` flag blocks until the workload is healthy with the new secret configuration.

## MCP Tools Reference

| Tool | Purpose |
|:---|:---|
| `mcp__cpln__workload_reveal_secret` | **Composite** — creates identity + policy + links workload in one call |
| `mcp__cpln__create_secret` | Create a new secret |
| `mcp__cpln__list_secrets` | List all secrets in an org |
| `mcp__cpln__get_secret` | Get secret metadata (values hidden) |
| `mcp__cpln__reveal_secret` | Reveal actual secret data (break-glass, requires `reveal` permission) |
| `mcp__cpln__update_secret` | Update an existing secret |
| `mcp__cpln__delete_secret` | Delete a secret |
| `mcp__cpln__create_policy` | Create a policy (manual approach) |
| `mcp__cpln__update_workload` | Update workload spec (set identityLink, env vars) |

## Common Mistakes to Prevent

- **Forgetting to create the identity** — workloads cannot access ANY secrets without an identity
- **Using `view` permission instead of `reveal`** — `view` only shows metadata, not the actual secret value
- **Wrong secret reference format** — must be `cpln://secret/NAME`, not just the secret name
- **Trying to share identities across GVCs** — they are GVC-scoped
- **Not redeploying after secret update** — if a secret value is updated, workloads referencing it must be redeployed to pick up the new value
- **Using identity/policy for pull secrets** — pull secrets only need to be added to GVC's `pullSecretLinks`, no identity or policy setup required
- **Non-admin users missing `use` permission** — non-admin users need the `use` permission on a secret to reference it in workloads or add it as a GVC pull secret
