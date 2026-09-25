---
description: Control Plane operating guide for AI agents. The platform facts tools do not enforce or report, the high-impact approval rule, secrets beyond the core rules, targets, CLI fallback, and failure handling. Read it when a task goes beyond what the job tools cover.
alwaysApply: false
---

# Control Plane Operating Guide

The core rules arrive with every MCP connection. This guide holds only what they and the tool descriptions leave out.

## Approval for high-impact actions

A destructive call needs the user's explicit approval after you say what it removes or breaks. Three kinds need a fresh yes that answers the stated blast radius, even when the opening message already asked:

- **Cascades:** deleting a GVC removes every workload and identity in it; the platform refuses while a volume set remains.
- **Data loss:** deleting, shrinking, or restoring volumes and snapshots; uninstalling a template release deletes its volume data.
- **Production targets:** a name that says so, or public traffic, custom domains, several replicas, or real users.

Also destructive: removing bindings, members, routes, locations, or policies; changing a workload's type or name, or a volume set's filesystem or performance class, which means delete and recreate. Hesitation, "maybe", or a counter-question is not approval. A resource you created by mistake this session, and only that, you remove and report.

## Reads

Read the current state before an `update_*` or `delete_resource` call, especially where a field replaces a list or object wholesale. Job tools read state themselves: call them directly and treat their result as the verification.

The tag `cpln/managedByTerraform: "true"` marks a resource Terraform or Pulumi owns, and their next apply reverts a live change. Tell the user before changing one, prefer a change to their code, and after a hotfix they approve, offer the matching code change. Without the tag, ask whether GitOps owns a production resource before changing it.

## Secrets

- Keep generated values and user-entered values in separate secrets, so none is half filled.
- Access needs three things, and a missing one fails silently: an identity on the workload, a policy granting `reveal` (not `view`), and a `cpln://secret/NAME.KEY` reference. `deploy_app` wires all three for its env; `grant_workload_secret_access` sets the identity and policy once the workload exists.
- CLI and GitOps users may want a manifest: UPPERCASE placeholders they fill locally, then `cpln apply`. Never apply a file holding a placeholder. On the CLI a value goes in a file, never an inline flag.
- Service-account keys and agent bootstrap configs are shown once, in the Console: `add_key_to_service_account` and `create_agent` (full profile) return the link.
- Redact passwords, tokens, keys, connection strings, and bearer headers from anything you repeat.

## Targets

- Never create a GVC without locations the user chose. The org's location list is the authority: it includes BYOK locations with operator-chosen names, so never substitute a cloud region for one.
- A production change needs a plan and a rollback stated before it runs.
- Create only what the task needs. When something it depends on is missing (the workload a domain routes to, the secret a reference names), ask which existing one to use; never create a placeholder.

## Platform facts the tools do not check

- **App vs workload:** an app is the code or image; a workload is the resource that runs it.
- **Internal calls** use plain HTTP to `http://WORKLOAD.GVC.cpln.local:PORT`; the sidecar adds mTLS, so `https://` fails.
- **`CPLN_TOKEN`** inside a workload works only from that workload, against `CPLN_ENDPOINT`.
- **Images:** run a real image, never an app inlined into a base image. A private external registry needs a GVC pull secret of type `docker`, `ecr`, or `gcp`; any other type fails the pull silently.
- **Shutdown:** the default `preStop` runs `sleep`; an image without it, or a failing custom `preStop`, kills every container at once. A container running as UID 1337 bypasses the mesh, losing mTLS and firewall enforcement.
- **Hand-written specs:** ports go in `containers[].ports`, never the deprecated `port`; custom domains use the Domain resource, never the GVC's deprecated `spec.domain`.
- **Domains** stay pending until their DNS records resolve. Pending is a wait, not an error to retry.
- **Public** needs both an external inbound and an external outbound CIDR.
- **Reachability:** after ready, a real HTTP GET of the canonical URL settles it. 2xx, 3xx, 401, and 403 mean serving; a timeout points at firewall inbound; a TLS or DNS error means propagation, so wait. Never claim reachability without a response.
- **App code:** before changing an app's code, `get_app_files` with the NAME from `//image/NAME:TAG` says where the code lives. Never rewrite an app from scratch under an existing name.
- **Other databases, caches, queues, and search** come from the Template Catalog, never built by hand.

## CLI and profiles

Use the `cpln` CLI when MCP is unavailable, for CLI-only work (`cpln workload connect`, port-forward, `cpln cp`, a local-folder build, `cpln image copy`, `cpln convert`), and in CI/CD with a service-account `CPLN_TOKEN`. Every command comes from the `cpln` skill and `--help`, never from memory. When a tool covers the action, call it rather than handing the user a command; when none covers a field, use the CLI or say what is missing.

`?toolsets=` on the MCP URL picks the tools: `core` (default), `mk8s`, `full`, or `readonly`. When a task needs a tool this connection lacks, tell the user which profile to reconnect with.

## Failures

- **Not found:** stop and ask; never try a corrected name. **Permission denied:** report it; never work around it.
- **Validation error:** fix what it names, then retry; never resend an unchanged call.
- **A client-side safety block** (not a Control Plane error) is usually transient: retry once.
- **Partial mutation:** report what changed, what did not, and the current state.
- **An immutable field** changes only by delete and recreate, which needs approval.
