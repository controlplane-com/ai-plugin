---
description: Control Plane platform entry point and guardrails — product overview, resource model, decision guidance, and rules that prevent common production failures
alwaysApply: true
---

# Control Plane Platform

Control Plane is a hybrid platform for deploying and managing containerized workloads across AWS, GCP, Azure, and private clouds from a unified interface. It abstracts cloud provider differences behind a consistent API, CLI (`cpln`), Console UI, Terraform provider, Pulumi provider, and MCP Server. PCI DSS Level 1 and SOC 2 Type II compliant.

## Resource Hierarchy

```
Org (Organization) — top-level isolation boundary, globally unique name
├── Principals: Users, Groups, Service Accounts           (org-scoped)
├── Governance: Policies, Quotas                          (org-scoped)
├── Infrastructure: Cloud Accounts, Agents, Locations     (org-scoped)
├── Assets: Secrets (12 types), Images, Domains           (org-scoped)
└── GVC (Global Virtual Cloud) — deployment environment
    ├── Workloads (1+ containers, four types)             (GVC-scoped)
    ├── Identities (cloud access, secrets, private networks) (GVC-scoped)
    └── Volume Sets (persistent storage)                  (GVC-scoped)
```

- **Org-scoped**: Secrets, Domains, Cloud Accounts, Agents, Policies, Images
- **GVC-scoped**: Workloads, Identities, Volume Sets
- A workload can reference secrets from its parent org but only volume sets and identities from its own GVC
- Pull secrets are configured at the **GVC level**, not per workload. Only Docker, ECR, and GCP secret types supported.
- One identity per workload, but identities can be shared across multiple workloads within the same GVC. One cloud account per provider per identity (one AWS + one GCP + one Azure, not two AWS).

## Platform Capabilities

| Capability | When to use | Deeper guidance (skill) |
|---|---|---|
| **Workloads** — Deploy containers as serverless, standard, cron, or stateful | Primary deployment unit — most users start here | `autoscaling-capacity`, `workload-security` |
| **Template Catalog** — 30+ templates (Postgres, Redis, Kafka, MongoDB, etc.) | Need a database, queue, or common service — install instead of building from scratch | `template-catalog` |
| **Secrets** — 12 types with identity-based access control | Store credentials, certificates, config. Requires 3-step access (see below) | `access-control` |
| **Images** — Build, push, copy container images | Containerize apps for deployment. Use `cpln image build --push` | `image` |
| **Managed Kubernetes (mk8s)** — Provision K8s clusters across providers | Need a full K8s cluster; teams deploy INTO mk8s clusters | `mk8s-byok` |
| **CPLN Platform (BYOK)** — Register existing K8s clusters as locations | Already have Kubernetes — want Control Plane workload management on top | `mk8s-byok` |
| **Agents** — Secure tunnels to private networks (VPCs, on-prem) | Workloads need to reach private TCP endpoints behind firewalls | `native-networking` |
| **Domains** — Custom domain routing with auto-TLS | Expose workloads on your own domain | Domain configurator agent |
| **External Logging** — Ship logs to S3, Datadog, Coralogix, etc. | Compliance, long-term retention, or external log analysis | `external-logging` |
| **MCP Server** — 80+ tools for AI agents | AI-assisted infrastructure management | — |

## When to Use What

| Scenario | Use |
|---|---|
| One-off deployments, visual exploration | Console UI |
| GitOps, CI/CD automation, reproducible deployments | CLI with `cpln apply` |
| Infrastructure as code, team collaboration, state management | Terraform / Pulumi |
| Debugging, interactive exploration | CLI (`exec`, `logs`, `connect`) |
| AI-assisted infrastructure management | MCP Server |

## Guardrails

These rules prevent real production failures. Every item below has caused incidents.

### Org / Profile / GVC Confirmation (ask before mutating)

**Before running any `cpln` command that mutates state** — `create`, `delete`, `update`, `apply`, `patch`, `edit`, `add-binding`, `remove-binding`, `add-key`, `force-redeployment`, `clone`, `image build --push`, secret create-* variants, `add-location` / `remove-location`, etc. — the target **org**, **profile**, and (where applicable) **GVC** must be unambiguously established. If any is missing, **stop and ask before acting. Never silently fall back to whatever the active CLI profile happens to point at.**

Context is considered "established" only if one of these is true:

- The user named the org / profile / GVC in the **current** request
- The user named them earlier in **this same conversation**
- The MCP server's `set_context` was already called this session
- The user gave an explicit, unambiguous instruction like "use my default profile" or "use my dev environment"

If any of those is unclear, ask. Propose what looks right and request confirmation in this shape:

> Before I run this, I want to confirm the target. Your active profile appears to be `<name>` (org: `<org>`, GVC: `<gvc>`). Should I use that, or a different org / profile / GVC?

For **read-only** commands (`get`, `query`, `audit`, `logs`, `permissions`, `access-report`, `eventlog`), defaulting to the active profile is acceptable — but **announce the target before running**: *"Using profile `<name>` → org `<org>`, GVC `<gvc>`…"* — so the user can correct course before output is produced.

**Why this rule exists.** Operating on the wrong org or GVC has caused production deletes, cross-environment secret leaks, and accidental cross-tenant changes. The cost of asking is one extra turn; the cost of acting on the wrong context is irreversible.

### Secret Access (3 mandatory steps)

A workload CANNOT access secrets without ALL three:

1. **Identity** created and assigned to the workload (`--set spec.identityLink=//identity/NAME`)
2. **Policy** granting the identity `reveal` permission on the target secret
3. **Reference** in workload env vars as `cpln://secret/SECRET_NAME`

Missing any one step = silent failure at runtime. This is the #1 support issue.

### Image Rules

- **NEVER** prefix external images with `docker.io/`. Use `nginx:latest`, not `docker.io/library/nginx:latest`.
- Your own org's registry: use `//image/NAME:TAG` in workload specs. `<own-org>.registry.cpln.io/...` is only for `docker login` / `docker push`, never in specs.
- Another Control Plane org's registry: use the hostname form `<other-org>.registry.cpln.io/NAME:TAG` in workload specs (cross-org pull). See the **cpln-image** skill for the full reference table.
- All images must be `linux/amd64`. Wrong platform causes `exec format error`.
- Port in workload spec must match the port the container actually listens on.

### Firewall Defaults

- **Internal** (workload-to-workload): `none` — all blocked. Set to `same-gvc`, `same-org`, or `workload-list`.
- **External inbound**: disabled. Add CIDR addresses (`0.0.0.0/0` for all).
- **External outbound**: disabled. Add CIDRs or hostnames (hostname: ports 80, 443, 445 only).

### Workload Type Constraints

- **Scale to zero**: Serverless with `rps` or `concurrency` only. Cron cannot scale to zero.
- **Capacity AI**: NOT with Stateful workloads, CPU autoscaling, or multi-metric.
- **Cron**: Deploys to ALL GVC locations, no overrides. Cannot expose ports.
- **Workload type is immutable** after creation. Changing type requires delete + recreate.

### Destructive Operations — Always Confirm With Blast Radius

Some operations cannot be undone, or have effects that reach beyond the resource being changed. **Before any destructive operation listed below, the AI MUST present a structured summary AND wait for explicit user confirmation — even when permissions are set to bypass / auto-approve.** Permission mode is about Claude Code's tool-prompt UX; this rule is conversation-level safety and is independent. Bypass permissions does NOT authorize destructive product operations.

**Always destructive (data or resource loss):**

- Any `cpln <resource> delete` — workloads, GVCs, secrets, policies, identities, volumesets, domains, images, etc.
- `cpln gvc delete-all-workloads`
- `cpln volumeset shrink` — provisions a new smaller volume, the old one is permanently deleted with all data
- `cpln volumeset snapshot delete`, `cpln volumeset volume delete`

**Service-disrupting (blast radius extends to users / dependents):**

- `cpln policy remove-binding` — can break workload secret or cloud access at runtime
- `cpln serviceaccount remove-key` — can break CI/CD pipelines or live workloads using that key
- `cpln group remove-member` — can lock users out of resources
- `cpln gvc remove-location` — forces redeployment of any workloads in that location

**Implicit destructive — immutability traps that force a hidden delete:**

These changes look like edits but require a delete + recreate underneath. Treat them with the same care as an explicit delete:

- **Orgs are immutable** — cannot be deleted; removal requires Control Plane support
- **Workload type is immutable** (serverless / standard / cron / stateful) — changing type requires delete + recreate
- **Workload name is immutable** — renaming requires `clone` (preferred) or get → edit → apply → delete-old
- **Volumeset filesystem type and performance class are immutable** — changing requires delete + recreate (data loss)
- **`cpln apply` of a manifest with a renamed resource creates a new one** — the old must be deleted manually

When delete + recreate is the only path, the AI must:

1. **Capture the current state first.** `cpln <resource> get NAME -o yaml-slim > <name>.bak.yaml` so a roll-back exists. Never delete a resource you cannot reconstruct.
2. **Reuse the same name on recreate** unless the user explicitly wants a new name. Preserves the public URL (`<workload>.<gvc>.cpln.app`), internal DNS callers (`<workload>.<gvc>.cpln.local`), domain routes, policy `targetLinks`, identity bindings, and external consumers.
3. **Confirm before deleting.** The user authorized the *goal* ("add storage"), not the *technique* ("delete and recreate"). Those are separate decisions.

**Required confirmation shape — output exactly this structure:**

> I need to run a destructive operation:
>
> - **Action**: `<exact command(s)>`
> - **Affected**: `<resource name and kind>` in `<org>` / `<gvc>`
> - **Blast radius**: `<who/what is impacted — running traffic, in-flight requests, downstream callers, data on disk, CI/CD pipelines, public URLs>`
> - **Reversibility**: `<reversible via X / not reversible>`
> - **Mitigation**: `<what I've done to make this safer — captured manifest as <file>.bak.yaml; will reuse same name; etc.>`
>
> Confirm to proceed.

If the answer is anything other than an unambiguous yes, **do not proceed**. "Maybe later", "I'll think about it", silence, or any clarifying counter-question all mean stop.

If a single user task requires several destructive operations, ask once at the start with the full plan enumerated — don't death-by-a-thousand-prompts. But do not bundle a destructive op with non-destructive ones to make it slip through; surface it explicitly.

**Why this rule exists.** Acting on the wrong resource — or on the right resource at the wrong moment — has caused production data loss and user-visible downtime. The cost of one extra round-trip is trivial; the cost of an unintended destructive action is sometimes irreversible. The AI must never assume that authorization for a *goal* extends to authorization for a destructive *means*.

### Constraint Conflicts — Surface, Don't Silently Default

While configuring a resource, the AI may hit a compatibility constraint that blocks the user's stated or implied intent. Examples on Control Plane:

- The user asks for concurrency-based autoscaling on a workload that turned out to be `stateful` (concurrency autoscaling has different rules for stateful)
- The user asks for `shared` filesystem on a volumeset they also want to snapshot (snapshots aren't supported on `shared`)
- The user asks for scale-to-zero on a `cron` workload (cron can't scale to zero)
- The user asks for Capacity AI on a workload using CPU autoscaling or multi-metric (mutually exclusive)
- The user requests a feature only available on certain providers, locations, or workload types

When this happens, the AI MUST surface the constraint and present alternatives — **never silently downgrade to a "safe-looking" default like `disabled`, `none`, `1 replica`, or `manual` without articulating it.** A conservative default is often the worst production choice (e.g. `disabled` autoscaling on a workload with bursty traffic ships an under-provisioning bug; `1 replica` on a public service ships a single-point-of-failure).

**Required shape — output exactly this structure:**

> I hit a constraint configuring `<resource>`:
>
> - **You asked for**: `<original intent>`
> - **Constraint**: `<exact technical limitation, citing the rule from `cpln-guardrails.md` "Workload Type Constraints" or the relevant skill>`
> - **Realistic alternatives that fit your goal**:
>   - **`<value>`** — `<what it does, where it fits, tradeoff>`
>   - **`<value>`** — `<...>`
>   - **`<value>`** — `<...>`
> - **My recommendation**: `<option>` because `<reasoning grounded in this project's context — workload purpose, traffic pattern, data shape (e.g. single-writer SQLite), downstream consumers, replica count implications>`.
>
> Which would you like? Or would you like to revisit the upstream choice that introduced the constraint (e.g. switching workload type)?

The last clause matters — sometimes the right answer is to back out of an earlier choice. If the user picked `stateful` because they thought they needed it but actually didn't, the AI should offer that escape hatch instead of constraint-thrashing downstream.

Even when the conservative default IS the right answer for this project (e.g. `min=max=1 replicas` for a single-writer SQLite-backed app), **say so explicitly with the reasoning** — don't apply it silently. The user must see that the AI considered the alternatives, not that it punted.

**Anti-patterns to avoid:**

- Picking `disabled` / `none` / `1 replica` / `manual` and proceeding without comment
- Picking a value that satisfies the schema without considering whether it fits the workload's actual purpose
- Skipping the alternatives enumeration and asking "what would you like?" — the user often doesn't know the option space; the AI does and should reduce it before asking
- Same constraint conflict hitting twice in a row on related fields — surface the upstream issue ("your choice of stateful keeps blocking what you're asking for; do you actually need stateful, or were you really after persistence?")
- Padding the response with reassurance ("don't worry, this is fine") instead of substantive tradeoff analysis

**Why this rule exists.** Producing a syntactically valid manifest is not the goal — producing a manifest that does what the user wants is. Silent downgrades look like progress but ship misconfigured resources. A constraint conflict surfaced at design time costs one round-trip; the same error discovered in production costs an outage. The AI's value is precisely in reducing the option space and articulating tradeoffs the user can't be expected to know — punting to a default is the opposite of that value.

### Long-Running Operations — Don't Poll From the AI Layer

Some Control Plane operations take minutes: stateful workload provisioning (volumeset attach + container schedule), large image pushes, mk8s cluster creation, GVC location adds. **Never burn tokens by polling status from the AI layer in a loop.** Each AI-driven poll re-reads the conversation context, re-issues a tool call, and consumes thousands of tokens per cycle. Twenty polls of a stateful workload coming up burns dollars in input cost for zero diagnostic value over what one final check provides.

**Default wait is `cpln apply --file <m>.yaml --ready`.** Simple, blocks inside the CLI, AI tokens during the wait ≈ 0, returns the CLI's own readiness verdict. Use this for the common case — routine deploys, config tweaks on healthy workloads, anything where the failure surface is small.

**The one gap to know about:** `--ready` blocks until *ready or its default timeout* — it does NOT fail fast when a container has terminally errored on startup (exit code != 0, image pull error, crashloop, fatal in user code). On a misconfigured first-deploy, plain `--ready` will sit through its full default timeout (typically minutes) while the container is already dead. That's wasted wall-clock and obscures the actual failure.

**Use a "patience-windowed safety net" for first-deploys / risky applies / re-applies after a recent failure.** Pattern: run `cpln apply --ready` in the background, sleep the *expected* wait time for this workload type (so we don't peek before the workload has had legitimate time to come up), then watch for *confirmed* terminal container errors only — killing the apply early if found. If the workload is still legitimately starting past the window, the watcher leaves it alone and `--ready` continues to its natural conclusion.

```bash
# Apply with --ready in the background — handles the happy path correctly
cpln apply --file <manifest>.yaml --gvc <gvc> --ready &
APPLY_PID=$!

# Patience window — set to the EXPECTED wait for this workload type (see table below).
# No checks before this; --ready handles the normal success path.
PATIENCE=120     # seconds; bump for stateful first-deploys (300+) etc.

sleep $PATIENCE

# Past the window. Watch every 30s for CONFIRMED terminal failures only —
# "still pending" is not a failure, only explicit error states are. If the
# container is still legitimately starting, --ready stays in charge.
while kill -0 $APPLY_PID 2>/dev/null; do
  MSG=$(cpln workload get <name> --gvc <gvc> -o json 2>/dev/null \
    | jq -r "[.status.versions[-1].containers[]?.message // empty] | join(\" | \")")
  if echo "$MSG" | grep -qiE "exitcode: [^0]|fatal|startup failed|crashloop|imagepullbackoff|imagepullerror|errimagepull"; then
    echo "FAILED: $MSG"; kill $APPLY_PID 2>/dev/null; exit 2
  fi
  sleep 30
done

# Apply exited naturally — collect its exit code
wait $APPLY_PID
RC=$?
[ $RC -eq 0 ] && echo "READY" || echo "APPLY_EXIT_$RC"
exit $RC
```

Three exit conditions: `0` = ready (proceed), `2` = watcher killed the apply on confirmed terminal failure (diagnose immediately, see hard rule below), `non-zero from --ready itself` = CLI-reported failure or timeout (also diagnose).

**When to wrap, when not to:**

| Situation | Plain `--ready` | Use the safety net |
|---|---|---|
| Bumping image tag on a workload that's been healthy for a while | ✅ | — |
| Updating env vars on a healthy workload | ✅ | — |
| Re-applying after a small config tweak | ✅ | — |
| **First-deploy of a brand-new workload** | — | ✅ |
| **First-deploy of a stateful workload** (volumeset + container schedule) | — | ✅ |
| **Newly-built image with no prior deploy of that tag** | — | ✅ |
| **Re-applying after a recent failure** ("I just fixed the DSN, let's try again") | — | ✅ |
| Migrating workload type (delete + recreate as stateful) | — | ✅ |

**Other waits — patterns unchanged from the previous rule:**

- **`curl --retry` for app-layer verification** (HTTP endpoint reachable after deploy):
  ```bash
  curl --retry 30 --retry-delay 5 --retry-connrefused -fsS https://<workload>.<gvc>.cpln.app/healthz
  ```
- **`timeout … bash -c 'until …'`** for ops with no `--ready` flag at all (e.g. `force-redeployment`, post-`workload update` verifications):
  ```bash
  timeout 600 bash -c 'until cpln workload get <name> --gvc <gvc> -o json | jq -e ".status.healthCheck.status == true" >/dev/null 2>&1; do sleep 10; done' && echo "ready" || echo "timeout"
  ```
- **Background execution** — `Bash` with `run_in_background: true` only when the AI has genuinely independent prep work to do during the wait. Not for "looking busy."

**Hard rule — on FAILED, killed, or timeout: diagnose, don't re-wait.**

When the safety net kills the apply (exit 2), or `--ready` itself exits non-zero, or `cpln workload get-deployments` shows a failed deployment:

- **Do not** re-apply the same manifest hoping it'll work this time.
- **Do** fetch the failure context in one breath: `cpln workload get-deployments <name> --gvc <gvc>` (shows the failed deployment + exact error), `cpln logs '{gvc="<gvc>", workload="<name>"}' --org <org>` for stderr where most startup failures land, and re-read the manifest for the culprit the error points at (DSN format, secret references, port, image tag, env values).
- **Then fix and re-apply** with the safety net wrapped (because we're now in the "re-applying after a recent failure" row of the table above).

After a successful `READY` exit, the AI may issue **one** follow-up sanity check to confirm the desired state landed. If that single check surfaces an unexpected state, diagnose — never another wait.

**Set expectations upfront for waits >90s.** Tell the user the expected range *before* starting. Demo audiences and operators both hate silent multi-minute pauses. Reference table:

| Operation | Typical wait |
|---|---|
| Serverless workload first deploy | 30–90s |
| Standard workload first deploy | 30–90s |
| **Stateful workload first deploy (volumeset provision + container)** | **2–5 min** |
| `cpln workload force-redeployment` | 30–90s (existing replica replaced) |
| Volumeset expand | 30–60s (live, no downtime) |
| Large image push (1GB+) | 1–5 min |
| New GVC + first workload (cold path) | 1–3 min |
| mk8s cluster provisioning | 10–30+ min (always background or skip) |

**Why this rule exists.** AI-driven polling loops are the most expensive thing the AI can do for the least value. The CLI already knows how to wait — let it. Polls also produce noisy log output that pollutes context for downstream operations.

### CLI Command Accuracy

**Never write a cpln command from memory.** See `rules/cli-conventions.md` for CLI structure, resource command map, and hallucination traps.

### Best Practices

- For waits: see the **"Long-Running Operations"** rule above. First-deploys → apply without `--ready` then a fail-fast shell wait. Repeat deploys of known-good workloads → `cpln apply --file manifest.yaml --ready` is fine. Never plain polling from the AI layer.
- Location format: `<provider>-<region>` — e.g. `aws-us-west-2`, `gcp-us-east1`, `azure-eastus2`.
- Use service account keys (not user tokens) in CI/CD. Generate with `cpln serviceaccount add-key`.
- Don't set `spec.identityLink` unless the workload needs secret access, cloud access, or private network access.
- Internal DNS: `WORKLOAD_NAME.GVC_NAME.cpln.local:PORT` for same-GVC communication.
- All internal traffic is automatically mTLS-encrypted.
- Every workload receives a `CPLN_TOKEN` env var for authenticating to the Control Plane API from within the workload. The token is only valid when the request originates from the workload it was injected in.

## Boundaries

| Action | CLI / API / Terraform | Console only |
|---|:-:|:-:|
| Create/manage orgs, GVCs, workloads, secrets, policies | Yes | Yes |
| Push container images | Yes (CLI) | No |
| Configure domains and routing | Yes | Yes |
| Manage billing and payment methods | No | Yes |
| View Grafana metrics dashboards | No | Yes |
| Interactive debugging (exec, connect, logs) | Yes (CLI) | Yes |
| Install templates from catalog | Yes | Yes |

## Verification Checklist

Before submitting work with Control Plane:

- [ ] **Target org / profile / GVC was confirmed by the user** (not silently defaulted from the active CLI profile)
- [ ] **Any destructive or service-disrupting operation was confirmed by the user with full blast radius disclosed** — including implicit deletes triggered by immutable-field changes (workload type, name, volumeset filesystem)
- [ ] **No silent downgrades to conservative defaults** — every constraint conflict was surfaced with realistic alternatives, a project-grounded recommendation, and explicit user choice (autoscaling strategy, replica counts, filesystem type, etc.)
- [ ] **Waits used CLI-native blocking or shell-level wait loops, never AI-layer polling** — `--ready` on apply, `timeout … until …` for ops without a wait flag, `curl --retry` for app-layer verification. At most ONE follow-up sanity check after the wait returned.
- [ ] GVC exists and includes all required locations
- [ ] Workload image accessible (external URL or pushed to org registry with `//image/NAME:TAG`)
- [ ] Port number matches the container's exposed port
- [ ] Workload type is correct (serverless/standard/cron/stateful)
- [ ] Firewall rules allow required inbound/outbound traffic
- [ ] Identity created and assigned if workload needs secret or cloud access
- [ ] Policy grants identity `reveal` permission on target secrets
- [ ] Secret references use `cpln://secret/SECRET_NAME`
- [ ] Autoscaling strategy compatible with workload type
- [ ] Images built for `linux/amd64`
- [ ] Service account keys in CI/CD (not user tokens)
- [ ] No `docker.io/` prefix on external images
- [ ] `cpln apply --ready` used for deployments

## Resources

- Docs: https://docs.controlplane.com
- Full page index (for AI agents): https://docs.controlplane.com/llms.txt
- CLI conventions: `rules/cli-conventions.md`
- Console: https://console.cpln.io
- MCP Server: https://mcp.cpln.io/mcp
- API: https://api.cpln.io
- Terraform: registry.terraform.io/providers/controlplane-com/cpln
