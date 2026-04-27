---
name: cpln-stateful-storage
description: "Creates persistent storage for stateful workloads on Control Plane. Use when the user asks about volumes, volume sets, disk, mounting storage, snapshots, volume expansion, ext4/xfs filesystem, shared storage, or backup patterns for stateful containers."
version: 1.0.0
---

# Stateful Storage & VolumeSets

## VolumeSet Overview

A **VolumeSet** provides persistent block or shared storage for workloads within a GVC. Three filesystem types are available:

| Filesystem | Workloads | Volumes Created | Snapshots | Best For |
|:---|:---|:---|:---:|:---|
| **ext4** | One workload only | One per replica per location | Yes | General-purpose databases |
| **xfs** | One workload only | One per replica per location | Yes | Large files, high throughput |
| **shared** | Multiple workloads | One per location | No | Shared file storage across workloads |

**Key constraints:**
- Filesystem type is **immutable** after creation
- ext4/xfs volume sets are locked to a single workload
- Data is **per-location** — volumes do not replicate across locations
- VolumeSet is GVC-scoped

## Performance Classes

| Class | Min Size | Max Size | Filesystem Compatibility |
|:---|:---|:---|:---|
| `general-purpose-ssd` | 10 GB | 65,536 GB | ext4, xfs |
| `high-throughput-ssd` | 200 GB | 65,536 GB | ext4, xfs |
| `shared` | 10 GB | 65,536 GB | shared only (auto-set) |

Performance class is **immutable** after creation. Throughput and IOPS vary by cloud provider.

When `fileSystemType` is `shared`, performance class is **automatically set to `shared`** — do not specify another class.

## VolumeSet Configuration

### CLI Creation

```bash
cpln volumeset create \
  --name my-data \
  --gvc my-gvc \
  --file-system-type ext4 \
  --performance-class general-purpose-ssd \
  --initial-capacity 20 \
  --enable-autoscaling \
  --max-capacity 100 \
  --min-free-percentage 20 \
  --scaling-factor 1.5 \
  --retention-duration 7d \
  --schedule "0 2 * * *"
```

### YAML Manifest

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

Apply with: `cpln apply -f volumeset.yaml --gvc my-gvc`

### Autoscaling

**Reactive scaling** triggers when free space drops below `minFreePercentage`:

```
newCapacity = usedGB / (1 - minFreePercentage/100) × scalingFactor
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

### Requirements

| Filesystem | Required Workload Type | Volumes per Workload |
|:---|:---|:---|
| ext4 / xfs | **Stateful** | Up to 15 |
| shared | Any type | Up to 15 |

Volume URI format: `cpln://volumeset/VOLUMESET_NAME`

**Reserved mount paths** (cannot be used): `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`

**Recovery policy** on volume mount: `retain` (default) keeps existing volume data when a new replica is created; `recycle` starts fresh.

### MCP Tool

Use `mcp__cpln__mount_volumeset_to_workload` to attach a volumeset:
- Creates the volumeset if it does not exist
- Defaults: mount path `/mnt/{volumesetName}`, filesystem `xfs`, class `general-purpose-ssd`
- **Workload type is immutable** — switching to stateful requires deleting and recreating the workload

### YAML Example — Stateful Workload with Volume

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

### Stateful Workload Features

- **Stable replica identities:** `{workloadName}-{replicaIndex}` (e.g., `my-database-0`)
- **Stable hostnames:** `{replicaIdentity}.{workloadName}`
- **Replica-direct endpoints:** Enable via `spec.loadBalancer.replicaDirect: true`
- **No Capacity AI** — use `minCpu`/`minMemory` instead

### Migrating an existing workload to stateful (destructive — confirm first)

A serverless or standard workload cannot be converted to stateful in place — workload type is immutable. Adding a volume to such a workload requires **delete + recreate as stateful**. This is destructive: the existing workload is removed, traffic 5xx's during the recreate window, and any in-memory or non-persistent state is lost.

This case is governed by the destructive-ops guardrail in `rules/cpln-guardrails.md` — **stop and get explicit confirmation before any delete**, regardless of permission mode.

Safe sequence once the user confirms:

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

# 4. Delete the old workload (destructive — already confirmed by the user above)
cpln workload delete <workload> --gvc <gvc>

# 5. Apply the new stateful manifest. Tell the user upfront this typically takes
#    2–5 min (volumeset provision + container schedule).
#
#    Use `--ready` with the safety-net wrapper from rules/cpln-guardrails.md:
#    --ready handles the success path; the watcher kicks in only past the
#    expected window AND only on confirmed terminal container errors. This is
#    a first-deploy of a freshly-recreated workload, so plain `--ready` alone
#    is the wrong choice — if the new manifest is misconfigured (wrong DSN,
#    bad image tag, missing secret), --ready will sit through its full default
#    timeout while the container is already dead.
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

# 6. ONE conclusive sanity check — not a polling loop.
#    Run this ONLY after the wait above completed successfully. If the watcher
#    killed the apply or --ready exited non-zero, skip to diagnosis below —
#    do not wait again.
cpln workload get <workload> --gvc <gvc>
```

If the watcher killed the apply, or `--ready` exited non-zero, or step 6 reveals an unhealthy state, the next move is **diagnose** — `cpln workload get-deployments <workload> --gvc <gvc>` (shows the failed deployment with exact error), `cpln logs '{gvc="<gvc>", workload="<workload>"}' --org <org>` for stderr where most startup failures land, and re-read the manifest for the culprit the error message points at (DSN format, secret refs, port, image tag, env). **Then fix and re-apply with the safety net wrapped again** — re-applying a broken manifest plain costs more wall-clock and obscures the actual issue. Restore from `<workload>.bak.yaml` if the new deploy is unrecoverable.

For waits on operations that lack a `--ready` flag (e.g. verifying after `cpln workload force-redeployment`), use a shell-level wait loop with `timeout`, never an AI polling loop:

```bash
# Wait up to 5 minutes for the workload to be healthy after force-redeployment.
# One tool call, one result. Bounded so it can't hang. AI tokens during wait ≈ 0.
timeout 300 bash -c 'until cpln workload get <name> --gvc <gvc> -o json | jq -e ".status.healthCheck.status == true" >/dev/null 2>&1; do sleep 10; done' && echo "ready" || echo "timeout"
```

For app-layer verification (the workload's HTTP endpoint becoming reachable):

```bash
curl --retry 30 --retry-delay 5 --retry-connrefused -fsS https://<workload>.<gvc>.cpln.app/healthz
```

Inputs the AI must confirm with the user before step 4:

- The exact public URL that will return errors during the cutover window
- Whether any other workload calls this one via internal DNS — those callers will fail until step 5 completes
- Whether the workload has runtime state worth draining first (in-flight requests, in-memory caches that don't exist on the new instance)
- That losing whatever's currently in the (non-persistent) container at delete time is acceptable

## Snapshot Management

Snapshots are available for **ext4 and xfs** only. Not available for shared filesystem.

### Automatic Snapshots

Configure in volumeset spec:
```yaml
snapshots:
  createFinalSnapshot: true
  retentionDuration: 7d        # Supports: Nd, Nh, Nm (days/hours/minutes)
  schedule: "0 */6 * * *"      # Cron expression, minimum once per hour
```

### CLI Commands

```bash
# Create a snapshot
cpln volumeset snapshot create my-data \
  --gvc my-gvc \
  --snapshot-name backup-2026-04-11 \
  --location aws-us-east-2 \
  --volume-index 0

# List snapshots
cpln volumeset snapshot get my-data --gvc my-gvc

# Restore from snapshot (creates new volume — unsaved data is lost)
cpln volumeset snapshot restore my-data \
  --gvc my-gvc \
  --snapshot-name backup-2026-04-11 \
  --location aws-us-east-2 \
  --volume-index 0

# Delete a snapshot
cpln volumeset snapshot delete my-data \
  --gvc my-gvc \
  --snapshot-name backup-2026-04-11 \
  --location aws-us-east-2 \
  --volume-index 0
```

**Tags on snapshots:** Use `--tag key=value` on create for organizing snapshots.

## Volume Expansion & Shrink

### Expand

Increase volume size (allowed once every 6 hours):

```bash
cpln volumeset expand my-data \
  --gvc my-gvc \
  --new-size 50 \
  --location aws-us-east-2 \
  --volume-index 0
```

Use `--timeout-seconds` to override the default 600s wait.

### Shrink

**WARNING: Shrink causes permanent data loss.** Only available for ext4/xfs.

```bash
cpln volumeset shrink my-data \
  --gvc my-gvc \
  --new-size 10 \
  --location aws-us-east-2 \
  --volume-index 0
```

## Volume Management

```bash
# List volumes for a volumeset
cpln volumeset volume get my-data --gvc my-gvc

# Filter by location
cpln volumeset volume get my-data --gvc my-gvc --location aws-us-east-2

# Delete a specific volume (permanent data loss)
cpln volumeset volume delete my-data \
  --gvc my-gvc \
  --location aws-us-east-2 \
  --volume-index 0
```

## Common Patterns

### PostgreSQL with ext4

```bash
# 1. Create volumeset
cpln volumeset create \
  --name pg-data --gvc my-gvc \
  --file-system-type ext4 \
  --initial-capacity 20 \
  --enable-autoscaling --max-capacity 200 \
  --min-free-percentage 20 --scaling-factor 1.5 \
  --retention-duration 7d --schedule "0 2 * * *"

# 2. Mount to workload (or use mcp__cpln__mount_volumeset_to_workload)
# Volume path: /var/lib/postgresql/data
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

### Backup Workflow

```bash
# 1. Create a named snapshot before maintenance
cpln volumeset snapshot create my-data \
  --gvc my-gvc --snapshot-name pre-migration \
  --location aws-us-east-2 --volume-index 0

# 2. Perform maintenance / migration

# 3. If rollback needed — restore snapshot
cpln volumeset snapshot restore my-data \
  --gvc my-gvc --snapshot-name pre-migration \
  --location aws-us-east-2 --volume-index 0
```

## Shared Filesystem Mount Resources

Shared filesystem volumes consume CPU and memory per mount point. Configure via:

```yaml
spec:
  fileSystemType: shared
  initialCapacity: 50
  # performanceClass is auto-set to "shared" — do not specify another class
  mountOptions:
    resources:
      minCpu: 50m
      maxCpu: 200m
      minMemory: 64Mi
      maxMemory: 256Mi
```

Resource constraints: `maxCpu` and `minCpu` at most 4000m apart with ratio >= 1:4. Same for memory (4096Mi apart, ratio >= 1:4).

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
- Requires a **CSI-compatible storage driver** installed on the cluster
- Storage classes must follow the naming convention: `{performanceClass}-{fileSystemType}`
  - Example: `general-purpose-ssd-ext4`, `high-throughput-ssd-xfs`
- Use `spec.storageClassSuffix` to select alternative storage classes
  - Constructed as: `{performanceClass}-{fileSystemType}-{suffix}`
  - Falls back to class without suffix if not found

## Gotchas & Best Practices

- **Filesystem is immutable** — choose ext4, xfs, or shared carefully at creation time
- **Performance class is immutable** — cannot change after creation
- **ext4/xfs lock to one workload** — plan your volumeset-to-workload mapping
- **Data is per-location** — no automatic cross-location replication
- **Shared has no snapshots** — implement application-level backups
- **Shrink destroys data** — always snapshot before shrinking
- **Expand throttled** — once every 6 hours per volume
- **Workload type is immutable** — switching type (e.g. serverless → stateful to add a volume) requires **delete + recreate**, which is destructive. This is an "implicit destructive" case under the destructive-ops guardrail in `rules/cpln-guardrails.md` — surface the blast radius and get explicit user confirmation before deleting, even when permissions are on bypass. See "Migrating an existing workload to stateful" below for the safe sequence.
- **Snapshot restore creates a new volume** — unsaved data since snapshot is lost

## Quick Reference

### MCP Tools

| Tool | Purpose |
|:---|:---|
| `mcp__cpln__mount_volumeset_to_workload` | Mount volumeset to workload (creates volumeset if needed) |
| `mcp__cpln__delete_volumeset` | Delete a volumeset |
| `mcp__cpln__list_volumesets` | List volumesets in a GVC |
| `mcp__cpln__get_volumeset` | Get volumeset details |
| `mcp__cpln__expand_volumeset` | Increase volume capacity |
| `mcp__cpln__shrink_volumeset` | Decrease volume capacity (data loss) |
| `mcp__cpln__delete_volumeset_volume` | Delete a specific volume (data loss) |
| `mcp__cpln__create_volumeset_snapshot` | Create a point-in-time snapshot |
| `mcp__cpln__delete_volumeset_snapshot` | Delete a snapshot |
| `mcp__cpln__restore_volumeset_snapshot` | Restore volume from snapshot |

### CLI Commands

| Command | Purpose |
|:---|:---|
| `cpln volumeset create` | Create a new volumeset |
| `cpln volumeset get` | Get volumeset details |
| `cpln volumeset update` | Update volumeset configuration |
| `cpln volumeset delete` | Delete a volumeset |
| `cpln volumeset expand` | Increase volume size |
| `cpln volumeset shrink` | Decrease volume size (data loss) |
| `cpln volumeset volume get` | List volumes |
| `cpln volumeset volume delete` | Delete a volume |
| `cpln volumeset snapshot create` | Create a snapshot |
| `cpln volumeset snapshot get` | List snapshots |
| `cpln volumeset snapshot restore` | Restore from snapshot |
| `cpln volumeset snapshot delete` | Delete a snapshot |

### Cross-References

- **Template Catalog skill** — database templates use volumesets for persistent storage
- **Firewall skill** — cloud storage volumes (S3, GCS, Azure Blob) require outbound firewall rules

## Documentation

For the latest reference, see:

- [Volume Set Reference](https://docs.controlplane.com/reference/volumeset.md)
- [Workload Volumes Reference](https://docs.controlplane.com/reference/workload/volumes.md)
- [CLI volumeset Commands](https://docs.controlplane.com/cli-reference/commands/volumeset.md)
- [Workload Types Reference](https://docs.controlplane.com/reference/workload/types.md)
