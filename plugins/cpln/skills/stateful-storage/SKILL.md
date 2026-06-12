---
name: stateful-storage
description: "Creates persistent storage for stateful workloads on Control Plane. Use when the user asks about volumes, volume sets, disks, mounting storage, snapshots, volume expansion, filesystems, shared storage, or backups."
---

# Stateful Storage & VolumeSets

> **Tool availability:** some MCP tools named here live in the `full` toolset profile — if one is not advertised on this connection, tell the user to reconnect the MCP server with `?toolsets=full` (or use the `cpln` CLI fallback). Reads and deletes work on every profile via the generic `list_resources` / `get_resource` / `delete_resource` tools.

The `workload` skill covers persistent-storage basics (stateful type, filesystem/perf-class immutability, reserved mount paths, the 15-volume limit, snapshot-before-destructive, the create→verify flow). This skill is the full volume-set detail. MCP-first throughout; CLI is the fallback when the MCP server is unavailable or in CI/CD driven by a service-account `CPLN_TOKEN`.

## VolumeSet Overview

A **VolumeSet** provides persistent block or shared storage for workloads within a GVC (GVC-scoped). Three filesystem types:

| Filesystem | Workloads | Volumes Created | Snapshots | Best For |
|---|---|---|---|---|
| **ext4** | One workload only | One per replica per location | Yes | General-purpose databases |
| **xfs** | One workload only | One per replica per location | Yes | Large files, high throughput |
| **shared** | Multiple workloads | One per location | No | Shared file storage across workloads |

Filesystem type is **immutable** after creation. ext4/xfs lock to a single workload. Data is **per-location** — volumes do not replicate across locations.

## Performance Classes

| Class | Min Size | Max Size | Filesystem |
|---|---|---|---|
| `general-purpose-ssd` | 10 GB | 65,536 GB | ext4, xfs |
| `high-throughput-ssd` | 200 GB | 65,536 GB | ext4, xfs |
| `shared` | 10 GB | 65,536 GB | shared only (auto-set) |

Performance class is **immutable** after creation; throughput/IOPS vary by cloud provider. When `fileSystemType` is `shared`, performance class is **automatically set to `shared`** — do not specify another class.

## VolumeSet lifecycle

Prefer the MCP tools: `mcp__cpln__create_volumeset` (performance class, filesystem, initial capacity, snapshot policy, autoscaling), `mcp__cpln__get_resource` (kind="volumeset"), `mcp__cpln__list_resources` (kind="volumeset"), `mcp__cpln__update_volumeset` (mutable fields only — filesystem and performance class are immutable). CLI fallback: `cpln volumeset` / `cpln apply`.

### YAML Manifest (fallback / IaC)

```yaml
kind: volumeset
name: my-data
gvc: my-gvc
spec:
  fileSystemType: ext4
  initialCapacity: 20
  performanceClass: general-purpose-ssd
  autoscaling:
    maxCapacity: 100
    minFreePercentage: 20
    scalingFactor: 1.5
  snapshots:
    createFinalSnapshot: true
    retentionDuration: 7d
    schedule: "0 2 * * *"
```

Apply with `cpln apply -f volumeset.yaml --gvc my-gvc`. CLI flags mirror these fields (`--file-system-type`, `--performance-class`, `--initial-capacity`, `--enable-autoscaling`, `--max-capacity`, `--min-free-percentage`, `--scaling-factor`, `--retention-duration`, `--schedule`).

### Autoscaling

**Reactive scaling** keeps at least `minFreePercentage` free, growing the volume when free space falls below that target:

```
newCapacity = currentCapacity × scalingFactor
```

Capped at `maxCapacity`. `scalingFactor` minimum is **1.1**.

**Predictive scaling** proactively expands before space runs low. Requires `minFreePercentage > 0` and `scalingFactor >= 1.1`:

```yaml
autoscaling:
  maxCapacity: 200
  minFreePercentage: 20
  scalingFactor: 1.5
  predictive:
    enabled: true
    lookbackHours: 24       # 1-168
    projectionHours: 6      # 1-72
    minDataPoints: 10       # 2-100
    minGrowthRateGBPerHour: 0.01
    scalingFactor: 1.2      # >= 1.1, defaults to parent scalingFactor
```

The system uses whichever target is larger (reactive vs. predictive).

## Mounting Volumes to Workloads

| Filesystem | Required Workload Type | Volumes per container |
|---|---|---|
| ext4 / xfs | **Stateful or VM** | Up to 15 |
| shared | Any type | Up to 15 |

Volume URI: `cpln://volumeset/VOLUMESET_NAME`. **Reserved mount paths** (rejected): `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`.

**Recovery policy** on mount: `retain` (default) keeps existing volume data when a new replica is created; `recycle` starts fresh.

Use `mcp__cpln__mount_volumeset_to_workload` to attach — it mounts into the **first container** and creates the volumeset if missing (defaults: mount path `/mnt/{volumesetName}`, filesystem `xfs`, class `general-purpose-ssd`; size/filesystem/class are create-only and ignored when the volumeset already exists). ext4/xfs (read-write-once) require a **stateful or vm** workload; shared mounts on any type. Workload type is immutable — switching requires delete + recreate (see migration sequence below).

### Stateful Workload Features

- **Stable replica identities:** `{workloadName}-{replicaIndex}` (e.g., `my-database-0`)
- **Stable hostnames:** `{replicaIdentity}.{workloadName}`
- **Replica-direct endpoints:** enable `spec.loadBalancer.replicaDirect: true` via `mcp__cpln__configure_workload_load_balancer`
- **No Capacity AI** — use `minCpu`/`minMemory` instead

### Migrating an existing workload to stateful (destructive — confirm first)

Workload type is immutable, so adding an ext4/xfs volume to a serverless/standard workload requires **delete + recreate as stateful** (vm workloads can also mount ext4/xfs volumesets, but a service migrates to stateful). This is destructive — the workload is removed, traffic 5xx's during the recreate window, and any in-memory/non-persistent state is lost. Governed by the destructive-ops guardrail in `rules/cpln-guardrails.md`: **stop and get explicit confirmation before any delete, regardless of permission mode.**

Confirm with the user before step 4:
- The exact public URL that will return errors during the cutover window
- Whether any other workload calls this one via internal DNS — those callers fail until step 5 completes
- Whether the workload has runtime state worth draining first (in-flight requests, in-memory caches absent on the new instance)
- That losing whatever's in the (non-persistent) container at delete time is acceptable

Safe sequence once confirmed:

```bash
# 1. Capture the current spec — your roll-back artifact
cpln workload get <workload> --gvc <gvc> -o yaml-slim > <workload>.bak.yaml

# 2. Build the new manifest from the backup:
#    - Change spec.type from "serverless" / "standard" to "stateful"
#    - Add the volume mount under spec.containers[<container>].volumes
#    - Keep the SAME name (preserves public URL, internal DNS, domain routes,
#      policy targetLinks, identity bindings, external consumers)
#    - Keep all other spec fields (image, identityLink, env, ports, etc.) intact

# 3. Apply the volumeset first (it must exist before the workload references it)
cpln apply --file <volumeset>.yaml --gvc <gvc>

# 4. Delete the old workload (destructive — already confirmed above)
cpln workload delete <workload> --gvc <gvc>

# 5. Apply the new stateful manifest. Tell the user upfront this typically takes
#    2–5 min (volumeset provision + container schedule).
#
#    Use `--ready` with the safety-net wrapper from rules/cpln-guardrails.md:
#    --ready handles the success path; the watcher kicks in only past the
#    expected window AND only on confirmed terminal container errors. Plain
#    `--ready` alone is wrong for a fresh recreate — if the manifest is
#    misconfigured (wrong DSN, bad image tag, missing secret), --ready sits
#    through its full timeout while the container is already dead.
cpln apply --file <workload>.yaml --gvc <gvc> --ready &
APPLY_PID=$!

PATIENCE=180   # 3 min — typical stateful first-deploy is 2–5 min
sleep $PATIENCE

while kill -0 $APPLY_PID 2>/dev/null; do
  MSG=$(cpln workload get <workload> --gvc <gvc> -o json 2>/dev/null \
    | jq -r "[.status.versions[-1].containers[]?.message // empty] | join(\" | \")")
  if echo "$MSG" | grep -qiE "exitcode: [^0]|fatal|startup failed|crashloop|imagepullbackoff|imagepullerror|errimagepull"; then
    echo "FAILED: $MSG"; kill $APPLY_PID 2>/dev/null; break
  fi
  sleep 30
done
wait $APPLY_PID

# 6. ONE conclusive sanity check — not a polling loop. Run ONLY after the wait
#    above completed successfully. If the watcher killed the apply or --ready
#    exited non-zero, skip to diagnosis — do not wait again.
cpln workload get <workload> --gvc <gvc>
```

If the watcher killed the apply, `--ready` exited non-zero, or step 6 shows an unhealthy state, **diagnose** — `mcp__cpln__list_deployments` (failed deployment + exact error; CLI `cpln workload get-deployments <workload> --gvc <gvc>`), `mcp__cpln__get_workload_logs` for stderr where most startup failures land (CLI `cpln logs '{gvc="<gvc>", workload="<workload>"}' --org <org>`), and re-read the manifest for the culprit the error points at (DSN, secret refs, port, image tag, env). **Then fix and re-apply with the safety net wrapped again** — re-applying a broken manifest plain costs more wall-clock and obscures the issue. Restore from `<workload>.bak.yaml` if unrecoverable.

For waits on operations that lack a `--ready` flag (e.g. after `cpln workload force-redeployment`), use a bounded shell wait, never an AI polling loop:

```bash
# Wait up to 5 minutes for the workload to be healthy. One tool call, bounded.
timeout 300 bash -c 'until cpln workload get <name> --gvc <gvc> -o json | jq -e ".status.healthCheck.status == true" >/dev/null 2>&1; do sleep 10; done' && echo "ready" || echo "timeout"
```

App-layer verification (HTTP endpoint reachable):

```bash
curl --retry 30 --retry-delay 5 --retry-connrefused -fsS https://<workload>.<gvc>.cpln.app/healthz
```

## Snapshot Management

Snapshots are available for **ext4 and xfs only** — never shared.

**Automatic** (volumeset spec):
```yaml
snapshots:
  createFinalSnapshot: true
  retentionDuration: 7d        # Nd / Nh / Nm (days/hours/minutes)
  schedule: "0 */6 * * *"      # cron, minimum once per hour
```

**Manual** — MCP tools:
- `mcp__cpln__create_volumeset_snapshot` — point-in-time snapshot (the safety net before any shrink/restore/volume-delete; `--tag key=value` on the CLI to organize)
- `mcp__cpln__list_volumeset_snapshots` — find a snapshot before restoring (filter by location, volumeIndex, snapshotName)
- `mcp__cpln__restore_volumeset_snapshot` — restore a volume (destructive)
- `mcp__cpln__delete_volumeset_snapshot` — delete a snapshot (destructive — removes a recovery path)

CLI fallback (`cpln volumeset snapshot create|get|restore|delete my-data --gvc my-gvc --snapshot-name NAME --location aws-us-east-2 --volume-index 0`).

## Volume Expansion & Shrink

**Expand** — live, no downtime; all filesystem types. Throttled to **4 expansions per volume per rolling 24 hours** — an HTTP 429 means the window is exhausted, and waiting briefly will NOT help (the oldest expansion must age out). Prefer `mcp__cpln__expand_volumeset`; CLI `cpln volumeset expand my-data --gvc my-gvc --new-size 50 --location aws-us-east-2 --volume-index 0` (`--timeout-seconds` overrides the default 600s wait).

**Shrink** — **ext4/xfs only**; data is preserved via an online presync + final delta sync onto the new smaller volume, but if **used bytes exceed the new capacity the data cannot fit and is lost**. Floor is class-dependent: 10 GB `general-purpose-ssd` / 200 GB `high-throughput-ssd`. Snapshot first with `mcp__cpln__create_volumeset_snapshot`, then `mcp__cpln__shrink_volumeset`; present the blast radius and get explicit confirmation first (`rules/cpln-guardrails.md`). CLI `cpln volumeset shrink my-data --gvc my-gvc --new-size 10 --location aws-us-east-2 --volume-index 0`.

## Volume Management

Inspect via `mcp__cpln__get_resource` (kind="volumeset") — status reports per-location volume counts, bound workload, snapshot counts. To delete a single volume (**permanent data loss, ext4/xfs only**), snapshot first, then `mcp__cpln__delete_volumeset_volume` — destructive, confirm the blast radius first. CLI `cpln volumeset volume get|delete my-data --gvc my-gvc [--location aws-us-east-2] [--volume-index 0]`.

## Common Patterns

### PostgreSQL with ext4

1. Create the volumeset with `mcp__cpln__create_volumeset` (ext4, initial capacity, autoscaling, snapshot policy).
2. Mount it to a stateful workload with `mcp__cpln__mount_volumeset_to_workload` (path `/var/lib/postgresql/data`).

```yaml
kind: workload
name: my-database
gvc: my-gvc
spec:
  type: stateful
  containers:
    - name: postgres
      image: //image/postgres:16
      ports:
        - protocol: http
          number: 5432
      resources:
        cpu: 500m
        memory: 1Gi
      volumes:
        - uri: cpln://volumeset/pg-data
          path: /var/lib/postgresql/data
  defaultOptions:
    autoscaling:
      maxScale: 3
      minScale: 1
```

### Shared File Storage

```yaml
kind: volumeset
name: shared-uploads
gvc: my-gvc
spec:
  fileSystemType: shared
  initialCapacity: 50
  # performanceClass auto-set to "shared" — do not specify another class
```

Multiple workloads can mount `cpln://volumeset/shared-uploads`. Shared volumes only support `expand` — no shrink, no volume delete, no snapshots.

Shared volumes consume CPU/memory per mount point — tune via `mountOptions.resources`:

```yaml
spec:
  fileSystemType: shared
  initialCapacity: 50
  mountOptions:
    resources:
      minCpu: 50m
      maxCpu: 200m
      minMemory: 64Mi
      maxMemory: 256Mi
```

Constraints: `maxCpu`/`minCpu` at most 4000m apart, ratio >= 1:4; memory at most 4096Mi apart, ratio >= 1:4.

### Backup Workflow

1. Before maintenance, take a named snapshot with `mcp__cpln__create_volumeset_snapshot`.
2. Perform the maintenance / migration.
3. If rollback is needed, find the snapshot with `mcp__cpln__list_volumeset_snapshots` and restore with `mcp__cpln__restore_volumeset_snapshot` (destructive — discards everything written since the snapshot; confirm first).

## Custom Encryption (AWS Only)

Encrypt ext4/xfs volumes with AWS KMS:

```yaml
spec:
  fileSystemType: ext4
  customEncryption:
    regions:
      aws-us-east-1:
        keyId: "arn:aws:kms:us-east-1:123456789:key/KEY_ID"
```

- Region format: `aws-{aws-region-name}`
- Not available for shared filesystem or BYOK clusters
- KMS key is immutable once a volume is created

## BYOK Considerations

For Bring Your Own Kubernetes clusters:
- Requires a **CSI-compatible storage driver** on the cluster
- Storage classes follow `{performanceClass}-{fileSystemType}` (e.g. `general-purpose-ssd-ext4`, `high-throughput-ssd-xfs`)
- `spec.storageClassSuffix` selects alternatives — constructed as `{performanceClass}-{fileSystemType}-{suffix}`, falling back to the class without suffix if not found

## Gotchas

- **Filesystem and performance class are immutable** — choose carefully at creation
- **ext4/xfs lock to one workload** — plan the volumeset-to-workload mapping
- **Data is per-location** — no automatic cross-location replication
- **Shared has no snapshots** — implement application-level backups
- **Volume-delete destroys data; shrink loses data when used bytes exceed the new size** — always snapshot first
- **Expand throttled** — 4 expansions per volume per rolling 24 hours (HTTP 429 = window exhausted; brief waits do not help)
- **Snapshot restore creates a new volume** — unsaved data since the snapshot is lost
- **Workload type is immutable** — ext4/xfs volumes need a stateful or vm workload, so switching type (e.g. serverless → stateful to add a volume) requires destructive delete + recreate; confirm the blast radius first (see the migration sequence above)

## Quick Reference — MCP Tools

| Tool | Purpose |
|---|---|
| `mcp__cpln__create_volumeset` | Create a volumeset (filesystem, perf class, capacity, snapshot policy) |
| `mcp__cpln__mount_volumeset_to_workload` | Mount volumeset to workload (creates volumeset if needed) |
| `mcp__cpln__update_volumeset` | Update mutable fields (capacity, snapshot policy, autoscaling, tags) |
| `mcp__cpln__delete_resource` (kind="volumeset") | Delete a volumeset |
| `mcp__cpln__list_resources` (kind="volumeset") | List volumesets in a GVC |
| `mcp__cpln__get_resource` (kind="volumeset") | Get volumeset details (spec + per-location status) |
| `mcp__cpln__expand_volumeset` | Increase volume capacity |
| `mcp__cpln__shrink_volumeset` | Decrease volume capacity (data loss) |
| `mcp__cpln__delete_volumeset_volume` | Delete a specific volume (data loss) |
| `mcp__cpln__create_volumeset_snapshot` | Create a point-in-time snapshot |
| `mcp__cpln__list_volumeset_snapshots` | List snapshots across a volumeset's volumes |
| `mcp__cpln__delete_volumeset_snapshot` | Delete a snapshot |
| `mcp__cpln__restore_volumeset_snapshot` | Restore volume from snapshot |

CLI fallback mirrors these: `cpln volumeset create|get|update|delete|expand|shrink`, `cpln volumeset volume get|delete`, `cpln volumeset snapshot create|get|restore|delete`.

## Cross-References

- **Workload skill** — Start here: the primary workload skill (types, defaults, spec shape) that routes here for storage detail.
- **Template Catalog skill** — database templates use volumesets for persistent storage
- **Firewall skill** — cloud storage volumes (S3, GCS, Azure Blob) require outbound firewall rules

## Documentation

- [Volume Set Reference](https://docs.controlplane.com/reference/volumeset.md)
- [Workload Volumes Reference](https://docs.controlplane.com/reference/workload/volumes.md)
- [CLI volumeset Commands](https://docs.controlplane.com/cli-reference/commands/volumeset.md)
- [Workload Types Reference](https://docs.controlplane.com/reference/workload/types.md)
