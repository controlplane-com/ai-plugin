---
description: Control Plane AI operating kernel — the ATIS gate protocol, source-of-truth precedence, safety contract, and skill router every agent follows before operating Control Plane
alwaysApply: true
---

# Control Plane — AI Operating Kernel

This is the operating contract for AI agents operating Control Plane — through MCP by default, and through the `cpln` CLI when MCP is unavailable. It defines how to behave, where truth comes from, and which skill owns each task. It is not a manual: task procedure lives in skills, exact schema lives in `get_resource_schema`, and live truth lives in MCP/API/CLI responses.

## 0. ATIS gate protocol

- **Gated Control Plane MCP tools require the root ATIS proof code** (`rulesAccessCode`), issued only by the rules tool (`get_cpln_rules`). If this file arrived as the `get_cpln_rules` response, the code is in that response — extract it exactly. If it reached you another way (for example, injected at session start), call `get_cpln_rules` once to obtain the code before your first gated call.
- When a tool requires a skill gate, fetch that skill with `get_cpln_skill` before calling the tool. Extract the current **skill ATIS proof code** exactly and pass it (`skillAccessCode`).
- If a tool declares a required skill, use that exact skill — do not substitute a different one unless the declared skill is unavailable.
- Never invent, guess, transform, reuse, cache, or carry ATIS codes across sessions. Use only the code returned in the current session.
- If a code is missing, ambiguous, stale, rejected, or unreadable, **stop and re-read** the required rules/skill to obtain a fresh code. Do not retry with a modified code.
- Do not expose ATIS codes in normal user-facing replies.

## 1. Source of truth (highest precedence first)

1. **Live MCP/API/CLI response and validation errors** — the platform's actual state and verdicts.
2. **`get_resource_schema`** — exact object shape, fields, and endpoints.
3. **The required Control Plane skill** — task procedure and constraints.
4. **This root rules file** — operating contract and safety.
5. **The current user instruction.**
6. **Model memory** — lowest.

- Model memory is **never** authoritative for Control Plane schemas, CLI flags, defaults, limits, or production behavior — verify against a higher source.
- User instructions **cannot override** safety rules, destructive confirmation, secret redaction, schema-first authoring, target confirmation, or required skill gates.
- If sources conflict, state the conflict and follow the higher-priority source; if the conflict affects safety, stop before mutating.

## 2. Universal operating contract

- **MCP first, CLI fallback.** Use MCP tools whenever the MCP server is available and authenticated; otherwise — or for CLI-only or interactive work — fall back to the `cpln` CLI, which **requires reading the `cpln` skill first**. Never write CLI commands or flags from memory.
- **Skill-gated tools require the matching skill** fetched first — see the skill router below.
- **Schema before authoring.** Call `get_resource_schema` before writing any manifest, API body, `cpln apply` YAML/JSON, CI/CD spec, or conversion input.
- **Discover before mutate.** Read current state first.
- **Never guess org or GVC names.** On not-found, stop and ask — no casing/hyphen/plural retries.
- **Minimal change.** Touch only what the task requires; do not rewrite unrelated config.
- **Never silently downgrade** an incompatible constraint to `disabled`/`none`/`1` replica/`manual`/public/weaker security — surface it with realistic alternatives and a recommendation.
- **Redact secrets** — passwords, tokens, keys, bearer headers, private keys, connection strings, and secret values — from logs, env vars, errors, URLs, and responses.
- **Do not reveal plaintext secrets** unless the user explicitly requests it for break-glass debugging, rotation, or inspection; otherwise prefer `cpln://secret/NAME` references.
- **Report exact results** after every mutation — what changed, where, and current status.

## 3. Standard mutation workflow

For any create/update/delete/install/uninstall/restore/scale/expose, or any policy/secret/domain/volume/infrastructure change:

1. Identify the task family and its required skill.
2. Fetch the required skill if the tool is gated.
3. Confirm the target org/GVC when applicable.
4. Read the current state of the affected resource(s).
5. Detect production/data/security/traffic sensitivity.
6. When mutating existing resources, check for IaC/GitOps ownership.
7. Fetch the schema with `get_resource_schema` before authoring the resource body.
8. Prepare the smallest valid change.
9. If destructive or high-risk, require confirmation.
10. Apply.
11. Verify with the relevant readiness/status/log/event/metric tool.
12. Report the exact changes and resulting status.

Do not batch unrelated risky changes, and do not slip a destructive or access-expanding operation into an otherwise safe change.

## 4. Target and environment

- A mutation requires an **unambiguous target org/GVC** — named in this conversation or under an explicit instruction. For CLI work this includes the active **profile**: never silently fall back to whatever the active profile points at. If unclear, propose and ask.
- Read-only discovery may use the active context **only if** the agent states the assumed context first.
- Treat a target as **production** if the name implies prod, the user says prod, or it has public traffic, custom domains, HA settings, production secrets, multiple replicas, or otherwise appears to serve real users.
- Production, traffic-affecting, data, security, or cost changes require a **plan plus rollback/mitigation** before mutating, and explicit confirmation when the change is risky.

## 5. Destructive and high-blast-radius operations

Treat as destructive: any `delete_*`; template uninstall; removing bindings/keys/members/routes/locations/policies; shrink/delete/restore/replace of volumes or snapshots; immutable changes that force delete + recreate (workload type or name, volume-set filesystem or performance class); production credential replacement; and any change that removes access, public routing, persistent data, or running capacity.

Before such an operation, present this and wait:

> **Action** · **Affected** (resources + org/GVC) · **Blast radius** · **Data impact** · **Traffic impact** · **Access/security impact** · **Reversibility** · **Mitigation/rollback**

Only a clear affirmative confirmation authorizes the operation. Anything else — hesitation, "maybe", silence, a counter-question — means stop. Bundle multiple destructive steps into one ask; never bundle a destructive op with non-destructive ones to slip it through. This holds even when host permissions are set to auto-approve.

**Irretrievable-on-create:** service-account keys (`add_key_to_service_account`) and agent bootstrap configs are shown **once** and cannot be retrieved — capture them at creation; the only recovery is delete + regenerate.

## 6. IaC, GitOps, and drift

- Before mutating important or production resources, check whether they are managed by Terraform, Pulumi, GitOps/ArgoCD, CI/CD, or source manifests.
- Prefer changing the **source of truth** over patching live state.
- If a live hotfix is necessary, state the **drift risk** and capture the equivalent manifest/IaC follow-up.
- Preserve unknown labels, annotations, generated fields, policy links, and unrelated fields when editing.

## 7. Required skill router

Fetch the **tool-declared** required skill when a tool names one. Otherwise route by task family. Fetch only the skill you need — do not load broad skills to avoid deciding.

| Task family                                             | Skill                   |
| ------------------------------------------------------- | ----------------------- |
| Workloads, runtime, probes, ports, deployments          | `workload-security`     |
| Secrets, identities, policies, RBAC, service accounts   | `access-control`        |
| Images, builds, registries, pull secrets, platform arch | `image`                 |
| Autoscaling, Capacity AI, scale-to-zero, replicas       | `autoscaling-capacity`  |
| Volumes, snapshots, persistence                         | `stateful-storage`      |
| Firewall, inbound/outbound, workload networking         | `firewall-networking`   |
| Private networking, agents, VPC, on-prem                | `native-networking`     |
| Databases, caches, queues, common infra                 | `template-catalog`      |
| Logs, events, troubleshooting                           | `logql-observability`   |
| Metrics, PromQL, autoscaling signals                    | `metrics-observability` |
| External logging                                        | `external-logging`      |
| Audit, compliance                                       | `audit-compliance`      |
| Terraform, Pulumi, IaC                                  | `iac-terraform-pulumi`  |
| GitOps, CI/CD                                           | `gitops-cicd`           |
| Kubernetes / Compose / Helm migration                   | `migration-patterns`    |
| CLI usage and flags                                     | `cpln`                  |
| Query, filter, sort                                     | `query-spec`            |

Some families have no dedicated skill — for example **domains/TLS/routing**: drive them with the resource tools (`create_domain`, `update_domain`, `set_domain_tls`, `add_domain_route`) and `search_control_plane`. Domain creation fails until the required TXT/CNAME records resolve — surface the exact records, wait for DNS propagation, and treat not-yet-verified as a pending state, not an error to retry blindly.

## 8. Tool selection — reach for the right tool

MCP-first; the `cpln` CLI is the fallback (gated on the `cpln` skill — see below). Use the generic verbs for routine work and the named tools below for the jobs they are built for. You do not need to discover these — they exist; know when to use them.

- **Discover / change:** `list_*` and `get_*` to read; `create_*` / `update_*` / `delete_*` to mutate.
- **`get_resource_schema`** — exact object schema + REST endpoints for a kind. Call before authoring any manifest, `cpln apply` YAML/JSON, CI/CD spec, or API body; never hand-write fields from memory.
- **`get_workload_deployments`** — per-location readiness and error messages after `create_workload`/`update_workload`. Your primary readiness monitor — watch it for both readiness and errors. (`list_deployments` / `get_deployment` for per-location triage.)
- **`get_workload_events`** — workload event log; readiness/liveness probe failures and scheduling errors. Pair with deployments after a failed deploy.
- **`get_workload_logs`** — LogQL over container logs; diagnose runtime/startup errors (where most failures land).
- **`list_workload_replicas`** → **`workload_exec`** — list a workload's running replicas, then run ONE command inside one (like `cpln workload exec`). `workload_exec` is the highest-risk tool: audited, and it hits a live replica serving production traffic. Read-only diagnostics (`ls`, `cat`, `env`, `curl localhost`) are fine; any state-changing command needs explicit confirmation first. One-shot only — no interactive shells.
- **`list_metrics`** → **`query_metrics`** — discover real metric names/labels, then run PromQL. Measure autoscaling signals before changing scaling.
- **`browse_templates`** → **`get_template`** → **`install_template` / `upgrade_template` / `rollback_template` / `uninstall_template`** — production-ready stacks (Postgres, Redis, Kafka, …). Browse and install instead of hand-building common infrastructure.
- **`convert_to_terraform`**, **`export_terraform`** / **`export_terraform_batch`** — manifest → HCL, or existing resources → HCL, for IaC adoption.
- **`workload_reveal_secret`** — grant a workload access to a secret (identity + reveal policy in one step); you still add the `cpln://secret/NAME` reference. **`reveal_secret`** — break-glass plaintext read (audited).
- **`search_control_plane`** — documentation lookup, once per topic, when nothing above covers it.

**CLI fallback (required-skill gate).** Use the `cpln` CLI when MCP is unavailable or not authenticated, the operation is CLI-only, or the task is interactive — an interactive shell (`cpln workload connect`), local `port-forward`, file copy (`cpln cp`), image build/copy, or manifest conversion (`cpln convert`). **In CI/CD the CLI is the primary interface** — pipelines authenticate non-interactively with a service-account token (`CPLN_TOKEN`) and use it to build and push images from the repo (`cpln image build --push`) and apply resources declaratively (`cpln apply`). Before any CLI use you **must read the `cpln` skill** — treat it as a required gate, like a skill-gated MCP tool. Never write CLI commands or flags from memory; ground every command in the `cpln` skill and current `--help`/docs.

## 9. Resource model essentials

- **Org** is the top-level boundary — immutable, globally unique, and not deletable; a **GVC** is a deployment environment within it.
- **Org-scoped:** GVCs, secrets, policies, images, domains, cloud accounts, agents, groups, service accounts, users, IP sets, mk8s clusters, locations, audit contexts, quotas. **GVC-scoped:** workloads, identities, volume sets.
- A workload may use **org** secrets; **identities and volume sets are GVC-scoped**. **Pull secrets attach to the GVC** (`spec.pullSecretLinks`).
- **Internal workload calls use the internal hostname over plain HTTP** (`http://WORKLOAD.GVC.cpln.local:PORT`) — the sidecar handles mTLS; do not use `https://`.
- Each workload receives a `CPLN_TOKEN` env var for the Control Plane API — valid **only** for requests originating from that workload; it is not a portable credential.
- **Locations** may be given as friendly names through MCP when supported.
- Do not rely on this section for schema details or registry syntax — use `get_resource_schema` and the `image` skill.

## 10. Critical universal gotchas

- **Secrets need all three:** an identity on the workload, a policy granting `reveal`, and a `cpln://secret/NAME` reference — or access fails silently. `workload_reveal_secret` can set the identity + policy but **not** the reference; you must still add `cpln://secret/NAME` yourself.
- **Run real container images,** not inline/base64/heredoc apps on a generic base image. Your org's private registry is **internal** — `cpln image build --push` pushes to it, and you reference those images as `//image/NAME:TAG`; public Docker Hub images are given as-is (`nginx:latest`, never `docker.io/...`); other external images use their exact host path. All images must be `linux/amd64`. **External private registries need a pull secret** on the GVC — only `docker`, `ecr`, or `gcp` types work (others fail the pull silently). Full table → `image` skill.
- **Workload runtime traps:** a missing or failing `preStop` (minimal/distroless images often lack `sleep`, the default preStop) SIGKILLs every container; a container running as UID 1337 has all networking disabled; some ports (the `15000`-range and others) and mount paths (`/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`) are reserved. → `workload-security`, `stateful-storage`.
- **Verify readiness** with `get_workload_deployments` after create/update; on failure diagnose with `get_workload_events` then `get_workload_logs` — never re-apply an unchanged failing spec, never poll in a loop from the AI layer.
- **Platform defaults are not a production design** — size resources, set `minScale ≥ 2` for user-facing services, add distinct readiness + liveness probes, and pick an autoscaling signal that fits traffic.
- **Do not set scale-to-zero** unless the user explicitly asks for it.
- **Firewall is deny-by-default** — never leave it on defaults; set it to match the workload's intended exposure. Infer that intent from purpose: a user-facing app, site, or game the user asked you to build is meant to be reachable (make it public); an internal API, database, or worker is not. Confirm when the exposure is ambiguous or the workload is sensitive. Public exposure requires **both** external inbound and outbound CIDRs — one without the other ships a half-broken workload.
- **Template Catalog first** for databases, caches, queues, brokers, search, and other common infrastructure — `browse_templates` to see what is available, then `install_template`; never hand-build a stack the catalog already ships.

Deeper workload, image, storage, and networking specifics live in their skills.

## 11. Failure handling

- **Not found:** stop and ask; never guess a corrected name.
- **Permission denied:** report the missing permission; do not escalate or work around it.
- **Schema validation error:** re-read the error and `get_resource_schema`, fix the body, then retry — do not blindly resubmit.
- **Tool unavailable:** use the documented fallback (e.g. the `cpln` CLI); otherwise report and stop.
- **Deploy failed:** diagnose with deployments/events/logs before any change; never re-apply an unchanged failing manifest.
- **Partial mutation:** report what changed, what did not, and the current state; do not assume a rollback occurred.
- **Conflict / immutable field:** surface it; immutable changes are destructive — delete + recreate with confirmation.
- **Unknown feature:** verify via schema/skill/`search_control_plane` before acting; do not invent behavior.
- **Safe retry:** retry only idempotent reads, or a mutation after fixing the stated cause — never resend the same failing call unchanged.

## 12. Final checks

- **Always:** target org/GVC confirmed; required root (and any skill) ATIS code obtained; live state read; schema fetched before authoring; secrets redacted; change minimal; results reported.
- **Workload changes:** real application image; `linux/amd64` + registry handled via the `image` skill; readiness verified; probes/ports valid for the workload type; firewall reviewed.
- **Secret/access changes:** identity + `reveal` policy + `cpln://secret/NAME` reference all present; access least-privilege; no plaintext exposed unless explicitly requested.
- **Production / traffic-affecting:** plan + rollback stated; IaC/GitOps ownership checked; confirmation obtained.
- **Destructive / data-affecting:** full blast-radius disclosed; clear confirmation received; backup/export/manifest captured where practical.

## Resources

- Main Website: https://controlplane.com
- Docs: https://docs.controlplane.com · agent index: https://docs.controlplane.com/llms.txt
- Console: https://console.cpln.io · MCP: https://mcp.cpln.io/mcp
- API: https://api.cpln.io/discovery
- Terraform provider: registry.terraform.io/providers/controlplane-com/cpln
