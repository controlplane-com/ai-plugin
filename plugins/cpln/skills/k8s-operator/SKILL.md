---
name: k8s-operator
description: "Manages Control Plane resources as Kubernetes CRDs. Use when the user asks about the Kubernetes operator, kubectl apply for Control Plane, CRDs, ArgoCD GitOps from a cluster, or exporting resources as K8s manifests."
---

# Kubernetes Operator

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

The operator (Helm chart `cpln-operator`) runs in any Kubernetes cluster and reconciles `cpln.io/v1` custom resources, plus labeled native Secrets, against the platform on a 30-second loop. Reach for it only when resources must live in Git and be reconciled from a cluster (ArgoCD/Flux); for direct provisioning prefer the typed MCP tools, and for pipeline-driven YAML prefer `cpln apply` (`gitops-cicd` skill). The recurring failure is manifest shape: `org`, `gvc`, and `description` sit at the **top level next to `spec`**, not inside it — author the `spec` block with `mcp__cpln__get_resource_schema`, or skip hand-writing entirely by exporting with `-o crd`.

## Install

cert-manager is a hard requirement (the chart ships a self-signed Issuer whose certificate backs the operator's mutating webhook), then the chart, then per-org auth:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.3/cert-manager.yaml
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

helm repo add cpln https://controlplane-com.github.io/k8s-operator
helm install cpln-operator cpln/cpln-operator -n controlplane --create-namespace
kubectl get pods -n controlplane -l app=operator

cpln operator install --serviceaccount k8s-operator --org ORG
```

`cpln operator install` configures **auth only** (the Helm step deploys the operator): it gets-or-creates the service account, adds it to a group (`--serviceaccount-group`, default `superusers` — any other group prints a warning), mints a **new key**, and applies a Secret named after the org in the `controlplane` namespace. Re-running with the same `--serviceaccount` is a no-op; a different name replaces the secret with a fresh key; an org-named secret the operator does not own aborts the install. `--export` prints the Secret YAML for Git instead of applying it — but still creates the service account and key on the platform.

Manual equivalent (one secret per org; multiple orgs = multiple secrets):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ORG                    # must equal the org name
  namespace: controlplane
  labels:
    app.kubernetes.io/managed-by: cpln-operator   # required — the operator only sees labeled Secrets
data:
  token: BASE64_KEY            # echo -n "KEY" | base64; the CLI also stamps a cpln/serviceaccount annotation it uses to detect reuse
```

Tokens are cached in memory per org and never re-read — after rotating a key, `kubectl rollout restart deployment/operator -n controlplane`. Helm values of note: `env.MANAGE_KINDS` (comma list restricting which kinds get controllers), `env.RECONCILE_INTERVAL_SECONDS` (default 30), `env.CPLN_API_URL`.

## CRD shape

```yaml
apiVersion: cpln.io/v1
kind: workload            # kind names are lowercase
metadata:
  name: my-app            # cluster name; annotation cpln.io/name-replacement overrides the platform name
  namespace: default
  annotations:
    cpln.io/resource-policy: keep   # optional: deleting this CR then leaves the platform resource intact
org: ORG                  # required on every CR — there is no default org
gvc: GVC                  # required for gvc-scoped kinds: workload, identity, volumeset
description: my app       # top level, like tags
spec:                     # exact platform spec
  type: serverless
  containers:
    - name: main
      image: nginx:latest
      port: 80
```

Org-scoped kinds: `agent`, `auditctx`, `cloudaccount`, `domain`, `group`, `gvc`, `ipset`, `location`, `org`, `policy`, `serviceaccount`. GVC-scoped: `workload`, `identity`, `volumeset`. Secrets are native v1 Secrets, not CRDs (a `cpln.io/v1 secret` CRD exists but is operator-internal — it holds sync status for native Secrets; never author it). An `mk8scluster` CRD ships but the platform API has no matching endpoint, so mk8s clusters cannot be operator-managed. Recommended layout: one namespace per GVC for gvc-scoped kinds, one per org for org-scoped kinds.

## Secrets (native v1 Secrets)

```yaml
apiVersion: v1
kind: Secret
type: opaque               # the platform secret type, lowercase: opaque, aws, azure-connector, azure-sdk, dictionary, docker, ecr, gcp, keypair, nats-account, tls, userpass
metadata:
  name: my-secret
  namespace: default       # any namespace EXCEPT controlplane (everything there is skipped as operator config)
  labels:
    app.kubernetes.io/managed-by: cpln-operator   # required — unlabeled Secrets are invisible to the operator
  annotations:
    cpln.io/org: ORG       # required — selects the org and its auth secret
data:                      # keys mirror the platform secret's data object
  payload: c2VjcmV0LXZhbHVl
  encoding: cGxhaW4=       # opaque only: plain | base64
```

For `azure-sdk`, `docker`, and `gcp` the platform payload is a single string — put it under one `value` key. Platform tags ride as `cpln.io/`-prefixed annotations. Each synced Secret gets a companion `secrets.cpln.io` CR (same name) carrying sync status and `cpln.io/sync-health-status` / `cpln.io/sync-health-message` annotations — check it when a Secret will not sync.

## How sync behaves

- A mutating webhook stamps every CR (and labeled Secret) with the `cpln.io/sync-protection` finalizer; namespaces labeled `skip-webhook: "true"` are exempt.
- **Local edit (metadata.generation changed):** the operator PUTs the CR to the platform — local state wins.
- **No local edit:** every cycle it pulls platform state into the CR, so console edits appear as CR changes. Under ArgoCD `selfHeal` that registers as drift, Argo restores the Git version, and the operator pushes it back — **Git wins over console edits**.
- **Deleted on the platform:** the CR is deleted from the cluster (with `selfHeal`, Argo re-applies it and the operator re-creates the platform resource).
- **CR deleted:** the platform resource is deleted too, unless annotated `cpln.io/resource-policy: keep`. Deletes blocked by dependent resources retry each cycle — delete children first.
- Failures land in `status.operator.validationError` with the platform error, and retry with exponential backoff (capped at 30s). `status.phase` is `Ready`, `Pending`, `Unhealthy`, or `Suspended`; the platform's own status fields (endpoints, health) are merged into the CR `status`.
- Workloads additionally stream live deployment state over WebSocket into read-only child CRs: `kubectl get deployments.cpln.io` (named `LOCATION.WORKLOAD`), plus `deploymentversions`, `containerstatuses`, and `jobexecutionstatuses` for cron; volumesets get `volumesetstatuslocations` and `persistentvolumestatuses`. Children are owner-referenced and garbage-collected with the parent.

## Exporting existing resources

CRD export is CLI/console-only — no MCP tool emits CRD YAML. Discover and inspect with `mcp__cpln__list_resources` / `mcp__cpln__get_resource`, then:

```bash
cpln workload get my-app --gvc GVC --org ORG -o crd > workload.yaml
cpln gvc get -o crd --org ORG > all-gvcs.yaml        # no name = whole collection, --- separated
```

In the console, every resource has Export, and the create flow has Preview, with a "K8s CRD" option. System fields are stripped and tags become annotations. **Secret export embeds the revealed payload** (base64-encoded, not encrypted) and needs the `reveal` permission — treat the output as sensitive.

## ArgoCD

Works without special configuration: point an Application at a Git path of CRD manifests (or a Helm chart templating them). The chart patches the ArgoCD ConfigMap with per-kind health checks — CR `status.phase` and `validationError` surface as Argo health — when the `argocd` namespace exists at install time; if Argo came later, run `helm upgrade cpln-operator cpln/cpln-operator`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: cpln-resources, namespace: argocd }
spec:
  project: default
  destination: { server: https://kubernetes.default.svc, namespace: NAMESPACE }
  source: { repoURL: "https://github.com/ORG/REPO.git", path: cpln-crds, targetRevision: main }
  syncPolicy:
    automated:
      prune: true      # manifest removed from Git = platform resource deleted (honor resource-policy keep)
      selfHeal: true   # console edits revert to Git
```

## Uninstall

`cpln operator uninstall --org ORG` removes only the auth secret. Before `helm uninstall cpln-operator -n controlplane`, decide the fate of synced resources: annotate CRs `cpln.io/resource-policy: keep` (or delete the CRs you want gone first) — once the operator is gone nothing clears the `cpln.io/sync-protection` finalizer, so leftover CRs stick in Terminating until you strip it (`kubectl patch ... -p '{"metadata":{"finalizers":null}}'`). Platform resources whose CRs were never deleted survive uninstall.

## Verify

- `kubectl get workloads -o yaml` — `status.phase: Ready` and no `status.operator.validationError`.
- `cpln workload get my-app --gvc GVC --org ORG` — the platform side exists and matches.
- `kubectl logs -n controlplane -l app=operator -f` — watch a sync round-trip.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Operator pod not starting, webhook TLS errors | cert-manager missing or certs not issued — `kubectl get pods -n cert-manager`, `kubectl get certificates -n controlplane` |
| Log: "unable to sync resources because the secret ORG could not be found" | Auth secret missing, misnamed, or missing the `managed-by` label (the operator's cache is label-filtered) — re-run `cpln operator install` |
| 401/403 errors after key rotation | The old token is cached — `kubectl rollout restart deployment/operator -n controlplane`; for 403s check the service account's group |
| `validationError`: "CRD resource has no org field" / gvc-scoped kind has no gvc | Add top-level `org` (and `gvc`) — they are not defaulted and do not go in `spec` |
| Secret never syncs, no error anywhere | Missing the label (invisible) or the `cpln.io/org` annotation, or it lives in the `controlplane` namespace (always skipped) — then check the companion `secrets.cpln.io` CR annotations |
| CR stuck Terminating | Platform delete blocked by dependents (delete child resources first) or the operator is gone (strip the `cpln.io/sync-protection` finalizer) |
| Console edits keep reverting | ArgoCD `selfHeal` working as designed — Git is the source of truth; change the manifest instead |
| CRD validation errors on apply | `kubectl explain workload.spec` shows the schema the cluster accepts; regenerate the manifest with `-o crd` |
| `mk8scluster` CR errors with 404 | Expected — the platform API has no mk8scluster path; manage mk8s via `mk8s-byok` instead |

## Quick reference

| Task | Command / tool |
|---|---|
| Author a CRD `spec` block | `mcp__cpln__get_resource_schema` (kind=workload, gvc, ...) |
| Inspect resources before export | `mcp__cpln__list_resources` / `mcp__cpln__get_resource` |
| Configure / remove operator auth | `cpln operator install -s SA --org ORG [--export]` / `cpln operator uninstall --org ORG` |
| Export as CRD manifest | `cpln KIND get [NAME] [--gvc GVC] -o crd`, or console Export / Preview "K8s CRD" |
| Restrict managed kinds | Helm value `env.MANAGE_KINDS: workload,volumeset` |

### Related skills

- **gitops-cicd** — pipelines with `CPLN_TOKEN` + `cpln apply`; choose it over the operator when no cluster-side reconciler is wanted.
- **iac-terraform-pulumi** — the Terraform/Pulumi alternative for declarative management.
- **mk8s-byok** — provisioning a Kubernetes cluster to host the operator (and managing mk8s itself).
- **workload** — the primary skill for what goes inside a workload `spec`.

## Documentation

- [Kubernetes Operator Reference](https://docs.controlplane.com/core/kubernetes-operator.md)
- [Operator Install Guide](https://docs.controlplane.com/guides/cli/cpln-operator.md)
- [Operator source and issues](https://github.com/controlplane-com/k8s-operator)
