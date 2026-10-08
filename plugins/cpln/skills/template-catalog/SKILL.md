---
name: template-catalog
description: "Recommends and installs templates from the Control Plane Template Catalog. Use when the user wants a self-hosted component or product: a database, cache, queue, search engine, object storage, gateway, AI tool, analytics, auth, security, automation, observability, or developer tool, a self-hosted replacement for a product they name, or asks what templates exist."
---

# Template Catalog

Production-tested charts (Helm under the hood) for databases, caches, queues, search, storage, AI tools, analytics, auth, security, automation, observability, developer tools, and gateways, with storage, firewall, and HA variants wired. A catalog template is the default for any common component; a custom workload needs a hard reason, such as an extension or image the template cannot take. An app the user asks you to build, such as a blog, a wiki, or a shop, is written (`create-app` skill), not replaced by a template; install one for it only when the user names it.

**Postgres, MySQL, MariaDB, MongoDB, or Redis: `add_database` by default.** In one call it generates the credentials, lets the listed workloads connect, and waits until the database is ready. Use the install steps below for these only when the user needs a setting `add_database` does not take, such as backups, a connection pooler, an admin UI, or custom resources, creating the credentials secret with `create_secret` first. Calling `add_database` again with a new `allowWorkloads` changes who can connect by reapplying the installed template: the password, version, and storage stay as installed, but changes made outside its values, such as volume snapshot settings, are reset. Tell the user that before reapplying. The HA and multi-location variants (`postgres-highly-available`, `mongodb-cluster`, and the rest) go through the install steps.

## Find the right template

Call `browse_templates` with `query` naming the capability or product needed. When the user describes a goal or a problem rather than a component ("my site is slow", "users should sign in with Google"), decide the capability it needs and search for that ("cache for database queries", "identity provider with Google login"); a goal searched in the user's own words ranks poorly. Recommend the result with what it does and why it fits. Take the first result unless its confidence is low or one of its `pickInsteadIf` needs matches the user; then use the template that entry names. A low-confidence first result is a guess: search again naming the capability, or ask the user about their goal. Each result also names its `variants` (the same software in other topologies), `related` templates (a `companion` is often installed alongside), and `includes` (bundled templates that install with it, never separately). Without `query`, `browse_templates` lists the catalog and its categories, or one `category`.

## Credentials: create the prerequisite secret first

- Every search result and `get_template` list the template's prerequisites. A required secret comes with its `secretType`, its `keys`, and the `valuesPath` that takes its name; an optional one names the values that turn it on (`when`).
- A missing secret does not fail the install: the release installs and the workload **wedges silently**, with no logs. So `install_template` and `upgrade_template` refuse, creating nothing, while the release would read a required secret that does not exist or has another type (they render it to confirm the read). A secret named inside a list, such as a list of users, is not checked.
- `values` key names differ per template (secret names, resources, access scope): copy them from `get_template`, never from memory.
- Create it with `create_secret` before installing: `values: "generate"` for passwords nobody needs to know, `values: "user"` for a key the user already has (they type it into the Console). Then put its name in `values`.
- Never write a password or key into `values`: values pass through the chat and are stored in the release. A template that still takes a secret value directly in `values` (`get_template` says when its example values do) is installed from the Console, or with `cpln helm install -f` and a values file the user fills in locally.

## Install (MCP)

1. `get_template <name>`: copy the example `values.yaml`; set the prerequisite secret names, replica count, resources, storage size, and access scope. It also returns the README's important notes. When a prerequisite has a `when` condition or the values are unclear, read the README's prerequisites with `get_template` and `readmeSection: "prerequisites"`; a README without that section answers with the sections it has.
2. `install_template` with `dryRun: true`: renders the resources the install would create, without applying anything, and lists in `missingSecrets` the required secrets the release reads that are still missing.
3. `install_template` with a unique release `name` (immutable) and the `values` YAML (at most 128 KiB). **Omit `gvc` only for a template that creates its own** (`createsGvc` in the search result and `get_template`); every other template needs an existing `gvc`, and a multi-location template's `locations` must be locations that GVC already has.
4. Installs are asynchronous: wait with `get_installed_template` and `waitSeconds`. Its token needs `reveal` on the release's state secret.

## Configure and upgrade

Reconfigure with `upgrade_template`: pass `name` plus the new `version` and/or `values`. **`values` REPLACES the release's values entirely — there is no reuse-merge** — so start from the current values, never a partial. `template` and `gvc` are immutable and read from the installed release, so you don't pass them. Roll back with `rollback_template` (needs `?toolsets=full`) or `cpln helm rollback`.

Access scope lives in `values` under a per-template key (`internal_access.type`, `internalAccess.type`, `internalAllowType`, or `firewall.internal_inboundAllowType`), with values `same-gvc` (default), `same-org`, `workload-list` plus a `workloads:` list, and `none` on a few.

## CLI fallback (CI/CD)

When MCP is unavailable, or in pipelines with a service-account `CPLN_TOKEN`, use `cpln helm` against the OCI registry `oci://ghcr.io/controlplane-com/templates/<TEMPLATE>` (the slug is the template name):

```bash
cpln helm install my-pg oci://ghcr.io/controlplane-com/templates/postgres --version 3.4.1 -f values.yaml \
  --state-tag cpln/marketplace=true \
  --state-tag cpln/marketplace-template=postgres \
  --state-tag cpln/marketplace-template-version=3.4.1 \
  --state-tag cpln/marketplace-gvc=my-gvc
cpln helm template my-pg oci://ghcr.io/controlplane-com/templates/postgres -f values.yaml # preview rendered resources
cpln helm list                                  # releases in the org
cpln helm get values <RELEASE> --all            # currently applied values
cpln helm upgrade <RELEASE> oci://... -f values.yaml --state-tag cpln/marketplace-template-version=<NEW_VERSION>
cpln helm history <RELEASE>                      # revision numbers, for rollback
cpln helm rollback <RELEASE> [<REVISION>]        # previous revision if omitted
cpln helm uninstall <RELEASE>
```

**The four `--state-tag` flags are not optional.** `install_template` and the Console apply them; a raw `cpln helm install` does not. They go on the release state secret, and without them the release is an ordinary Helm release: the Console lists it under **Helm Releases** rather than the Template Catalog's **Releases** page, and neither the Terraform `cpln_catalog_template` resource nor the Pulumi `CatalogTemplate` resource will manage it (both require `cpln/marketplace`, `cpln/marketplace-template`, and `cpln/marketplace-template-version` to exist). Omit `cpln/marketplace-gvc` for a `createsGvc` template. State tags carry over between revisions, so an upgrade only needs to restate `cpln/marketplace-template-version`. Pin `--version` on a tagged install: omitting it resolves to latest, which leaves you with no version to put in `cpln/marketplace-template-version`.

Reference `values.yaml` for any template lives in the [templates repo](https://github.com/controlplane-com/templates) at `<template>/versions/<version>/values.yaml`.

## Connection details and backups

- An installed service is reachable in its GVC at `<release>-<component>.<gvc>.cpln.local:<port>`, for example `my-pg-postgres.<gvc>.cpln.local:5432`; the exact names are in the `get_installed_template` resources. Workloads read the credentials as `cpln://secret/NAME.KEY` from the prerequisite secret.
- Backups need the optional prerequisites `get_template` lists for them, such as a bucket, a cloud account, and on AWS a bucket-scoped IAM policy, referenced in the `values` backup block.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `rollback_template` not found | core profile | reconnect `?toolsets=full` or use `cpln helm rollback` |
| Upgrade lost settings | `values` replaces, not merges | re-supply full values from `cpln helm get values --all` |
| Install failed / release stuck | partial apply, bad values, or unready workloads | inspect `get_installed_template` and `cpln helm history`; fix values and `upgrade_template`, or `uninstall` and reinstall |
| Workloads pending after install | image pull / firewall / resources | `diagnose_workload`, then the `workload-troubleshooting` skill |
| Install succeeded, database never starts, logs empty | the prerequisite secret did not exist at install | create it with `create_secret` (or use `add_database`), then `upgrade_template` or reinstall |
| CLI-installed release missing from the Console's Template Catalog | `cpln/marketplace*` state tags never set | re-run the upgrade with the chart and all four tags: `cpln helm upgrade <RELEASE> oci://ghcr.io/controlplane-com/templates/<T> --version <V> -f values.yaml --state-tag cpln/marketplace=true --state-tag cpln/marketplace-template=<T> --state-tag cpln/marketplace-template-version=<V> --state-tag cpln/marketplace-gvc=<GVC>` (the chart argument is mandatory; `cpln helm upgrade <RELEASE>` alone is rejected) |
