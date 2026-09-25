---
name: setup-secret
description: Secret access wiring and manifest authoring. Use when a workload needs to read a secret, the user asks to create a secret or generate secret YAML, configure a pull secret, or fix a deployment paused on a secret reference.
---

# Secret Access Setup

A workload reads a secret only when three things are in place. Miss one and the value is silently absent, or the deployment pauses on the unresolved reference.

| Step | What must be true | Without it |
|---|---|---|
| **Identity** | an identity linked to the workload (`spec.identityLink`) | the workload reads nothing |
| **Policy** | a policy granting that identity `reveal` on the secret | the reference resolves to empty |
| **Reference** | `cpln://secret/NAME` or `cpln://secret/NAME.KEY` in env or a volume | nothing to read |

`reveal`, not `view`: `view` shows metadata only. This is the most common mistake.

## Creating and rotating

`mcp__cpln__create_secret` creates secrets without a value passing through the chat, and `mcp__cpln__rotate_secret` rotates them; their descriptions cover both paths. Values Control Plane generates and values the user enters belong in separate secrets. Confirm a secret exists (`get_resource`, kind "secret") before anything references it.

## Wiring access

- **`deploy_app`** wires all three steps for the references in its env.
- **`grant_workload_secret_access`** (`gvc`, `workloadName`, `secretName`) creates the identity if missing (default `{gvc}-{workloadName}`), links it, and creates or updates a `reveal` policy (default `{gvc}-{workloadName}-secrets-policy`). It does not add the reference. The workload must exist first: create it (its deployment pauses on the reference), then grant, and it resumes.
- **By hand:** `create_identity`, `update_workload` to set `spec.identityLink`, then `create_policy` with target kind `secret` and a `reveal` binding for the identity (`access-control` skill).
- Identities are GVC-scoped: one per workload, shareable within a GVC, never across GVCs.

## References

| Type | Keys | Example |
|---|---|---|
| opaque | `payload` | `cpln://secret/api-key.payload` |
| userpass | `username`, `password` | `cpln://secret/creds.password` |
| tls | `key`, `cert`, `chain` | `cpln://secret/web-tls.cert` |
| keypair | `secretKey`, `publicKey`, `passphrase` | `cpln://secret/deploy-key.secretKey` |
| dictionary | user-defined | `cpln://secret/cfg.DB_HOST` |
| aws / ecr | `accessKey`, `secretKey`, `roleArn`, `externalId` | `cpln://secret/aws.accessKey` |

Inject as an env var or a volume (`{ uri: "cpln://secret/NAME", path: "/secrets/x" }`). Secret mounts are read-only, at most 15 volumes per container, and `/dev`, `/dev/log`, `/tmp`, `/var`, and `/var/log` are rejected. A workload reads a secret when it starts, so a value changed any way other than `rotate_secret` needs a redeploy.

## Pull secrets need no identity or policy

To pull from a private registry, add a secret of type `docker`, `ecr`, or `gcp` to the GVC's `spec.pullSecretLinks`, and every workload in that GVC can pull. The user enters the registry credentials through the Console link from `create_secret`.

## Manifests for CLI and GitOps users

Users who keep secrets as code may want a manifest instead of the Console link. Write it with UPPERCASE placeholders, then tell them to fill it in locally, apply it with `cpln apply -f secret.yaml --org ORG` or the Console's cpln apply button, keep the filled file out of git, and delete it after. Never ask for the real value, and never apply the file yourself.

`data` has a fixed shape per type. The trap: for `docker`, `gcp`, and `azure-sdk`, `data` is one JSON string, never a YAML mapping.

```yaml
kind: secret
name: my-registry
type: docker
data: >-
  {"auths":{"REGISTRY_HOST":{"username":"USERNAME","password":"PASSWORD"}}}
```

| `type` | `data` | Validation |
|---|---|---|
| `opaque` | `{payload, encoding?}` | `payload` valid base64 when `encoding: base64` (default `plain`) |
| `dictionary` | object of string values | keys match `[-._a-zA-Z0-9]+` |
| `userpass` | `{username, password, encoding?}` | none |
| `tls` | `{cert, key?, chain?}` | `cert` and `key` valid PEM |
| `keypair` | `{secretKey, publicKey?, passphrase?}` | `secretKey` a valid PEM private key |
| `aws` | `{accessKey, secretKey, roleArn?, externalId?}` | `accessKey` starts with `AKIA`, `roleArn` with `arn:` |
| `ecr` | aws fields plus `repos` (1 to 20) | each `ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com[/REPO]` |
| `azure-connector` | `{url, code}` | `url` is https |
| `nats-account` | `{accountId, privateKey}` | `accountId` a public nkey (`A…`), `privateKey` a seed (`SA…`) |
| `docker` | **JSON string** | parses with an `auths` object keyed by registry host |
| `gcp` | **JSON string** | a full service-account key: `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`, `auth_provider_x509_cert_url`, `client_x509_cert_url` |
| `azure-sdk` | **JSON string** | `subscriptionId`, `tenantId`, `clientId` (UUIDs) and `clientSecret` |

`get_resource_schema` (kind "secret") has the apply schema and REST endpoints.

## Verify

- `get_resource` (kind "workload"): `spec.identityLink` is set and the env or volume reads `cpln://secret/…`.
- `get_resource` (kind "policy"): the binding grants `reveal` to that identity.

## Common mistakes

- A YAML mapping as `data` on a docker, gcp, or azure-sdk secret.
- No `identityLink` on the workload, or `view` instead of `reveal`.
- The bare secret name instead of `cpln://secret/NAME`.
- Granting before the workload exists, or sharing an identity across GVCs.
- An identity and policy for a pull secret, which needs only `pullSecretLinks`.
