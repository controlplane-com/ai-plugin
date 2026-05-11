# Image Registry Auth, Cross-Org Sharing, and Permissions

Companion to `skills/image/SKILL.md`. Read this when authenticating to a private registry, sharing images across orgs, or writing image-scoped policies.

## The Private Registry

Each Control Plane org gets its own isolated private image registry at `ORG.registry.cpln.io`.

**Benefits:**
- No pull secrets needed when workloads reference images in the same org
- Lower latency (images cached at each workload deployment location)
- Built-in access control via Control Plane policies
- Automatic authentication when using `cpln image build --push`

### Authenticating Docker to the registry

```bash
cpln image docker-login --org my-org
```

Authenticates your local Docker client to the org's registry using your current `cpln` profile. Required before running `docker push` or `docker pull` against the registry directly.

### Service account Docker login (CI/CD)

When using a service account key as credentials, the username is the **literal string** `<token>` and the password is the key:

```bash
echo "$SERVICE_ACCOUNT_KEY" | docker login my-org.registry.cpln.io -u '<token>' --password-stdin
```

Store the service account key securely — rotate it with `cpln serviceaccount add-key` and delete compromised keys immediately.

## Pull Secrets for Private Registries

Private registries (Docker Hub private, ECR, GCR, ACR, GAR, GHCR, other Control Plane orgs) require a pull secret attached to the GVC. Only three secret types work as pull secrets:

| Secret type | Use for |
|:---|:---|
| `docker` | Docker Hub, GHCR, ACR, GAR, other Control Plane orgs |
| `ecr` | Amazon ECR (dedicated type — handles IAM role assumption) |
| `gcp` | Google Container Registry (via GCP service account JSON) |

**Attaching a pull secret to a GVC:**

```bash
cpln gvc update my-gvc \
  --set spec.pullSecretLinks+=my-pull-secret \
  --org my-org
```

Pull secrets live at the **GVC level** — once attached, they apply to all workloads in that GVC. You cannot attach pull secrets to individual workloads.

## Cross-Org Image Sharing

Images are org-scoped. To use an image from another org (e.g., dev org's image in staging), you have two options:

### Option 1: Pull secret (preferred for continuous access)

#### Step 1: Source-org service account with image-pull permission

```bash
# Create a service account in the source org
cpln serviceaccount create --name image-puller --org dev-org

# Create a policy granting pull permission on ALL images in the source org
cpln policy create --name image-pull-policy \
  --target-kind image \
  --all \
  --org dev-org

# Bind the service account to the policy with pull permission
cpln policy add-binding image-pull-policy \
  --serviceaccount image-puller \
  --permission pull \
  --org dev-org
```

To restrict the policy to specific images instead of all images, replace `--all` with `--resource <image-name:image-tag>` (one flag per image). Image names always include the tag — `my-app:v1.0` or `nginx:latest`.

Adding the service account to the `superusers` group also works but grants full org access — a scoped policy is preferred.

#### Step 2: Generate a service account key

```bash
cpln serviceaccount add-key image-puller \
  --description "Cross-org image pull key" \
  --org dev-org
```

Output (extract the `key` value):

```json
{
  "description": "Cross-org image pull key",
  "created": "2026-04-07T...",
  "key": "SERVICE_ACCOUNT_KEY_VALUE"
}
```

#### Step 3: Create a Docker secret in the target org

Create `docker-config.json` using the service account key:

```json
{
  "auths": {
    "dev-org.registry.cpln.io": {
      "username": "<token>",
      "password": "SERVICE_ACCOUNT_KEY_VALUE"
    }
  }
}
```

The username is the literal string `<token>` — do not replace it with the token itself.

```bash
cpln secret create-docker --name dev-registry-pull \
  --file docker-config.json \
  --org staging-org
```

#### Step 4: Add the pull secret to the target GVC

```bash
cpln gvc update staging-gvc \
  --set spec.pullSecretLinks+=dev-registry-pull \
  --org staging-org
```

#### Step 5: Point the target workload at the source org's image

The reference format for another org's registry is `<source-org>.registry.cpln.io/<image-name>:<image-tag>`. Two ways to update:

**Option A: Update the workload in place**

Look up the container name first (`cpln workload get <workload> --gvc <gvc> --org <org> -o yaml-slim`, find `spec.containers[].name`), then:

```bash
cpln workload update my-app \
  --set spec.containers.<container-name>.image="dev-org.registry.cpln.io/my-app:v1.0" \
  --gvc staging-gvc \
  --org staging-org
```

**Option B: Export, edit, and `cpln apply` (GitOps-friendly)**

```bash
# 1. Export the current workload to a file
cpln workload get my-app \
  --gvc staging-gvc \
  --org staging-org \
  -o yaml-slim > manifests/workloads/my-app.yaml

# 2. Edit — change the container image to the source org's registry:
#    spec:
#      containers:
#        - name: main
#          image: dev-org.registry.cpln.io/my-app:v1.0

# 3. Apply
cpln apply --file manifests/workloads/my-app.yaml \
  --gvc staging-gvc \
  --org staging-org
```

Option B is preferred for GitOps workflows — the manifest is version-controlled and auditable.

### Option 2: Copy image (one-time promotions)

`cpln image copy` requires access to both source and destination orgs. Before running:

1. Check existing profiles with `cpln profile get`.
2. Ensure you have a profile with credentials for the source org (default profile or `CPLN_PROFILE`) and one for the destination org.
3. Create or update profiles as needed:

```bash
# Create a profile (interactive login in a browser)
cpln profile create source-profile --login --org dev-org --default
cpln profile create dest-profile --login --org staging-org

# Or update an existing profile with the correct org
cpln profile update existing-profile --org staging-org
```

Profiles store the org/GVC context and (for `--login`) a user session. For service account auth, set `CPLN_TOKEN` as an environment variable — it overrides the profile's auth.

If the default profile has access to both orgs (e.g., a user belonging to both), copy directly:

```bash
cpln image copy my-app:v1.0 --to-org staging-org
```

If the orgs use different credentials, use `--to-profile` for the destination:

```bash
cpln image copy my-app:v1.0 --to-org staging-org --to-profile dest-profile
```

The default profile is used for the source org. `--to-profile` specifies credentials for the destination.

If you hit an authorization error, verify each profile's principal has the required permissions: `pull` on images in the source org, `push` (or `create`) on images in the destination.

#### `cpln image copy` flags

| Flag | Purpose |
|:---|:---|
| `--to-org` | Target org to copy the image to (required) |
| `--to-name` | Rename the image during copy (e.g., `--to-name renamed-app:v1`) |
| `--to-profile` | Profile to use for accessing the destination org |
| `--cleanup` | Remove the pulled and retagged local images after a successful copy (useful in CI/CD to save disk) |

#### Examples

```bash
# Simple cross-org copy
cpln image copy my-app:v1 --to-org destination-org

# Rename during copy
cpln image copy my-app:v1 --to-org destination-org --to-name renamed-app:v1

# Use a different profile for the destination
cpln image copy my-app:v1 --to-org destination-org --to-profile dest-profile

# CI/CD with cleanup
cpln image copy my-app:$CI_COMMIT_SHA --to-org prod-org --to-profile prod-profile --cleanup
```

## Image Permissions and Policies

Image-specific permissions for Control Plane policies:

| Permission | Description | Implies |
|:---|:---|:---|
| `create` | Create or push an image | `pull` |
| `delete` | Delete an image | — |
| `edit` | Modify image metadata (only tags) | `view` |
| `manage` | Full access | `create`, `delete`, `edit`, `manage`, `pull`, `view` |
| `pull` | Pull an image | `view` |
| `view` | Read-only access | — |

### Minimum policy for push

Bind the `create` permission to the principal pushing the image. Target all images (`--all`) or use a `targetQuery` with `property: repository`.

```bash
cpln policy create --name image-push-policy \
  --target-kind image \
  --all \
  --org my-org

cpln policy add-binding image-push-policy \
  --serviceaccount ci-deployer \
  --permission create \
  --org my-org
```

### Minimum policy for pull

Bind the `pull` permission the same way. For scoped pull policies that target specific image names (not all images), use `cpln apply` with a YAML manifest that includes a `targetQuery`:

```yaml
kind: policy
name: pull-specific-images
description: Pull access to the my-app image
targetKind: image
targetLinks: []
targetQuery:
  kind: image
  fetch: items
  spec:
    match: all
    terms:
      - op: '='
        property: repository
        value: my-app
bindings:
  - permissions:
      - pull
    principalLinks:
      - /org/my-org/serviceaccount/image-puller
```

Apply with:

```bash
cpln apply --file pull-policy.yaml --org my-org
```

The `property: repository` field must be exactly that value — it's the only supported property for image queries. Principal links can reference users (`/org/ORG/user/EMAIL`) or service accounts (`/org/ORG/serviceaccount/NAME`).
