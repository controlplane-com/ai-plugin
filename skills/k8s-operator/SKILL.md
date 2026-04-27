---
name: cpln-k8s-operator
description: "Manages Control Plane resources as Kubernetes CRDs and sets up ArgoCD GitOps. Use when the user asks about the Control Plane Kubernetes operator, CRDs, custom resources, ArgoCD integration, managing Control Plane from a k8s cluster, or converting YAML to CRD format."
version: 1.0.0
---

# Kubernetes Operator Patterns

The Control Plane Kubernetes Operator lets you manage platform resources as Kubernetes Custom Resource Definitions (CRDs) from within any Kubernetes cluster.

## Where to Get It

| Resource         | Location                                                              |
| :--------------- | :-------------------------------------------------------------------- |
| Source code      | `https://github.com/controlplane-com/k8s-operator`                    |
| Helm chart repo  | `https://controlplane-com.github.io/k8s-operator`                     |
| Install guide    | `https://docs.controlplane.com/guides/cli/cpln-operator.md`           |
| Reference        | `https://docs.controlplane.com/core/kubernetes-operator.md`           |

## Prerequisites

1. **Kubernetes cluster v1.19+** — managed (EKS/GKE/AKS), self-hosted, or local (`kind`, `minikube`, Docker Desktop).
2. **`kubectl`** — configured and able to reach the cluster (`kubectl cluster-info`).
3. **Helm v3.0+** — used to deploy the operator chart.
4. **`cpln` CLI** — required for the recommended auth flow (`cpln operator install`).
5. **Control Plane org + permissions** — ability to create service accounts, a key, and edit the `superusers` group (or another group with the permissions the operator needs).

## Install

The operator deployment and its authentication secret are installed in the `controlplane` namespace.

### Step 1 — Install cert-manager (webhook certificates)

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.3/cert-manager.yaml
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s
```

### Step 2 — Install the operator (Helm)

```bash
helm repo add cpln https://controlplane-com.github.io/k8s-operator
helm repo update

helm install cpln-operator cpln/cpln-operator \
  -n controlplane \
  --create-namespace

# Verify
kubectl get pods -n controlplane -l app=operator
```

### Step 3 — Configure authentication

**Recommended (CLI):** `cpln operator install` creates (or reuses) a service account, adds it to `superusers`, generates a key, and applies a Kubernetes Secret named after the org in the `controlplane` namespace.

```bash
cpln operator install \
  --serviceaccount k8s-operator \
  --org YOUR_ORG_NAME
```

Flags (from `cpln/src/commands/operator.ts`):
- `--serviceaccount` / `-s` (required) — service account name; created if it doesn't exist.
- `--serviceaccount-group` / `-g` (default `superusers`) — group to assign the service account to. Any other value prints a warning.
- `--export` — write the Secret YAML to stdout instead of applying it (useful for GitOps).

**Manual:** create the service account, add it to a group, generate a key, then apply a Secret with this shape (the operator watches for the label):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: YOUR_ORG_NAME
  namespace: controlplane
  labels:
    app.kubernetes.io/managed-by: cpln-operator
  annotations:
    cpln.io/service-account: k8s-operator
data:
  token: BASE64_ENCODED_KEY   # echo -n "YOUR_KEY" | base64
```

### Step 4 — Deploy your first resource

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cpln.io/v1
kind: gvc
metadata:
  name: my-gvc
  namespace: default
org: YOUR_ORG_NAME
description: my-gvc
spec:
  staticPlacement:
    locationLinks:
      - //location/aws-eu-central-1
EOF

kubectl get gvcs
cpln gvc get my-gvc --org YOUR_ORG_NAME   # confirm it synced
```

## Uninstall

```bash
# Remove the auth secret (or: kubectl delete secret YOUR_ORG_NAME -n controlplane)
cpln operator uninstall --org YOUR_ORG_NAME

# Remove the operator
helm uninstall cpln-operator -n controlplane

# Optional: remove cert-manager
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.3/cert-manager.yaml
```

Uninstalling the operator does **not** delete Control Plane resources it previously created.

## CRD Structure

**Critical:** CRD structure differs from standard Control Plane manifests. The `org`, `gvc`, and `description` fields are at the **top level**, NOT inside `spec`.

```yaml
apiVersion: cpln.io/v1
kind: workload
metadata:
  name: my-app
  namespace: default
org: my-org           # Top level, NOT in spec
gvc: my-gvc           # Top level, NOT in spec
description: My app   # Top level, NOT in spec
spec:
  type: serverless
  containers:
    - name: main
      image: nginx:latest
      port: 80
```

## Secret CRD Requirements

Secrets have additional label and annotation requirements:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  labels:
    app.kubernetes.io/managed-by: cpln-operator    # REQUIRED
  annotations:
    cpln.io/org: my-org                            # REQUIRED
data:
  payload: base64-encoded-value
```

Both are required: the label tells the operator to watch the secret, and the annotation specifies the target org. Missing the label makes the operator skip the secret; missing the annotation causes sync failure.

## Supported Resource Types

Agent, AuditCtx, CloudAccount, Domain, Group, GVC, Identity, IPSet, Location, MK8s, Org, Policy, Secret, ServiceAccount, VolumeSet, Workload

## Export Existing Resources as CRDs

```bash
cpln workload get my-app --gvc my-gvc -o crd > workload-crd.yaml
cpln gvc get my-gvc -o crd > gvc-crd.yaml
cpln secret get my-secret -o crd > secret-crd.yaml
```

## Deletion Protection

Prevent accidental deletion of resources managed by the operator:

```yaml
metadata:
  annotations:
    cpln.io/resource-policy: keep
```

When enabled, deleting the CRD from Kubernetes does NOT delete the resource in Control Plane.

## ArgoCD Integration

1. Install the operator in your cluster
2. Store CRD manifests in a Git repository
3. Point ArgoCD Application at the repo directory
4. ArgoCD syncs CRDs → operator reconciles with Control Plane

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cpln-resources
spec:
  source:
    repoURL: https://github.com/my-org/infrastructure
    path: cpln-crds
  destination:
    namespace: your-namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Gotchas

- Putting `org`/`gvc` inside `spec` instead of top level
- Missing `managed-by` label on Secrets
- Missing `cpln.io/org` annotation on Secrets
- Not organizing resources by namespace (one per GVC or one per org is recommended)
- Forgetting deletion protection on production resources

### Troubleshooting

| Symptom                                   | Check                                                                                           |
| :---------------------------------------- | :---------------------------------------------------------------------------------------------- |
| Operator pods not starting                | `kubectl get pods -n cert-manager` and `kubectl get certificates -n controlplane` — webhook certs must be ready. |
| Resources not syncing                     | `kubectl logs -n controlplane -l app=operator -f`; confirm `kubectl get secrets -n controlplane` lists a secret named after your org. |
| Permission denied errors                  | Service account must belong to `superusers` or a group with equivalent policies. Re-run `cpln operator install` to reset auth. |
| CRD validation errors                     | `kubectl explain gvc.spec` / `kubectl explain workload.spec` to inspect the schema the cluster actually accepts. |
| Secret CRD not syncing                    | Secrets use native `v1/Secret` objects, not CRDs. Check the label and `cpln.io/org` annotation. |
| `controlplane` namespace missing          | `kubectl create namespace controlplane` (Helm install creates it via `--create-namespace`).     |

## Quick Reference

### CLI Commands

- `cpln operator install` — Install or upgrade the operator in a cluster.
- `cpln operator uninstall` — Remove the operator and CRDs.
- `cpln <resource> get <name> -o crd` — Export an existing resource as a CRD manifest.

### Related Skills

- **cpln-mk8s-byok** — Provisioning a Kubernetes cluster to install the operator into.
- **cpln-gitops-cicd** — Using the operator with ArgoCD or Flux for GitOps workflows.

### External Links

- [Operator source & issues](https://github.com/controlplane-com/k8s-operator)
- [Helm repo](https://controlplane-com.github.io/k8s-operator)
- [ArgoCD docs](https://argo-cd.readthedocs.io/en/stable/getting_started/)
- [cert-manager docs](https://cert-manager.io/)

## Documentation

For the latest reference, see:

- [Kubernetes Operator Reference](https://docs.controlplane.com/core/kubernetes-operator.md)
- [cpln operator Install Guide](https://docs.controlplane.com/guides/cli/cpln-operator.md)
