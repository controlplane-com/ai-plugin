---
name: stateful-storage
description: "Creates persistent storage for stateful workloads on Control Plane. Use when the user asks about volumes, volume sets, disks, mounting storage, snapshots, volume expansion, filesystems, shared storage, or backups."
---

# Stateful Storage & VolumeSets

A **VolumeSet** is GVC-scoped persistent storage for workloads. The `workload` skill covers the basics (stateful type, reserved mount paths, the 15-volume limit, create-then-verify); this skill is the full volume-set detail. The one trap that drives most rework: **`fileSystemType` and `performanceClass` are immutable** (a PATCH that changes either returns HTTP 400) — to change either you must create a new volumeset, and the old data does not carry over. Choose both at creation.

**Most databases don't need this skill:** `mcp__cpln__add_database` installs Postgres, MySQL, MariaDB, MongoDB, or Redis with the volume set and generated credentials wired, and the `template-catalog` skill covers the rest. An app that only needs a data directory passes `storage` to `mcp__cpln__deploy_app`, which creates and mounts the volume set and picks the workload type. Hand-build only for anything else.

## Filesystem types and performance classes

| Filesystem | Access | Workloads | Volumes provisioned | Snapshots / shrink / copy / delete-volume |
|---|---|---|---|---|
| `ext4` | read-write-once | one stateful/vm workload | one per replica, per location | yes |
| `xfs` | read-write-once | one stateful/vm workload | one per replica, per location | yes |
| `shared` | read-write-many | any workload type, many at once | one per location (shared by all replicas) | no — expand only |

| Performance class | Min | Max | Filesystems |
|---|---|---|---|
| `general-purpose-ssd` | 10 GB | 65536 GB | ext4, xfs |
| `high-throughput-ssd` | 200 GB | 65536 GB | ext4, xfs |
| `shared` | 10 GB | 65536 GB | shared (auto-set) |

When `fileSystemType: shared`, `performanceClass` is **auto-set to `shared`** — do not specify another. Data is **per-location** and never replicated across locations; for cross-location redundancy, replicate at the application layer (e.g. WAL streaming).

## Create a volumeset

`mcp__cpln__mount_volumeset_to_workload` creates the volume set when given a size and mounts it in the same call (see Mount below); `mcp__cpln__create_volumeset` (needs `?toolsets=full`) creates one alone. MCP create/mount tools default `fileSystemType` to **xfs** and `performanceClass` to `general-purpose-ssd`; the raw API/`cpln apply` default is **ext4**. YAML for IaC / CLI fallback:

```yaml
kind: volumeset
name: pg-data
gvc: GVC
spec:
  fileSystemType: ext4
  performanceClass: general-purpose-ssd
  initialCapacity: 20          # GB; within the class min/max and <= autoscaling.maxCapacity
  autoscaling:
    maxCapacity: 100
    minFreePercentage: 20      # 1-100
    scalingFactor: 1.5         # >= 1.1
  snapshots:
    schedule: "0 2 * * *"      # cron; no more than once per hour
    retentionDuration: 7d      # float + d/h/m; tool default 7d
```

Apply with `cpln apply -f volumeset.yaml --gvc GVC`. Update mutable fields (capacity, autoscaling, snapshot policy, tags) with `mcp__cpln__update_volumeset`.

### Autoscaling

**Reactive**: a background job checks volumes about once a minute; when free space falls below `minFreePercentage` it resizes the volume to hold current usage at that margin, scaled up: `new_capacity = ceil(usedGB / (1 - minFreePercentage/100) * scalingFactor)`, capped at `maxCapacity`. Both fields are required, or autoscaling does nothing.

**Predictive** runs the same formula on *projected* usage (from the recent growth rate) to expand ahead of demand; the larger of the reactive and predictive targets wins. Requires `minFreePercentage > 0` and `scalingFactor >= 1.1`:

```yaml
  autoscaling:
    maxCapacity: 200
    minFreePercentage: 20
    scalingFactor: 1.5
    predictive:
      enabled: true            # default false
      lookbackHours: 24        # 1-168
      projectionHours: 6       # 1-72
      minDataPoints: 10        # 2-100
      minGrowthRateGBPerHour: 0.01
      scalingFactor: 1.2       # >= 1.1; defaults to the parent scalingFactor
```

## Mount to a workload

Mount with `mcp__cpln__mount_volumeset_to_workload` — it attaches to the **first container** and creates the volumeset if missing (create-only defaults, ignored when the volumeset already exists: path `/mnt/{volumesetName}`, filesystem `xfs`, class `general-purpose-ssd`). Volume URI is `cpln://volumeset/VOLUMESET`.

- **ext4/xfs require a `stateful` or `vm` workload** (mounting on serverless/standard returns HTTP 400); `shared` mounts on any type. Workload type is immutable — see "Migrating to stateful" below.
- Up to **15 volumes** per container. **Reserved mount paths** (rejected): `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`.
- `path` is required for non-vm workloads and rejected for `vm` (VM disks use `name`/`bus`/`bootOrder` instead).
- Stateful workloads give each replica a stable index and its own volume; `spec.loadBalancer.replicaDirect` (stateful-only) exposes per-replica endpoints — see the `workload` skill.

```yaml
kind: workload
name: pg
gvc: GVC
spec:
  type: stateful
  containers:
    - name: postgres
      image: //image/postgres:16
      ports:
        - number: 5432
          protocol: tcp        # http | http2 | grpc | tcp — a DB is tcp, not http
      volumes:
        - uri: cpln://volumeset/pg-data
          path: /var/lib/postgresql/data
```

## Snapshots

Snapshots are **ext4/xfs only, never `shared`**. Automatic policy lives in `spec.snapshots`: `createFinalSnapshot` (default `true`: a snapshot is taken before any volume in the set is deleted), `retentionDuration`, and `schedule` (cron whose minute field must be a single concrete value, so no more than once per hour). Manual: `mcp__cpln__run_volumeset_command` with `createVolumeSnapshot`, `restoreVolume`, or `deleteVolumeSnapshot`; `mcp__cpln__get_resource` (kind `volumeset`) lists them. A restore creates a **new volume** and discards everything written since the snapshot.

## Resize and delete volumes

Each of these is one `mcp__cpln__run_volumeset_command` call on a volume picked by `location` and `volumeIndex`; it returns a command id that `get_command` follows until the command completes.

- **Expand** (`expandVolume`) is live, with no downtime, on every filesystem, at most 4 times per volume per rolling 24 hours.
- **Shrink** (`shrinkVolume`, ext4/xfs only): data is migrated to the new smaller volume via an online presync + final delta sync, and the replica restarts during the swap. The platform **refuses the shrink with HTTP 400 below the volume set's `initialCapacity`, below used bytes plus 5% metadata headroom, or when it cannot read the volume's used bytes**, and a shrink that fails keeps the old volume. Floor is the class minimum (10 / 200 GB).
- **Delete a volume** (`deleteVolume`, ext4/xfs only): permanent loss of that volume's data.
- **Copy** (`copyVolume`, ext4/xfs only): copies the volume to the same `volumeIndex` in `targetLocation`, of this volume set or of `targetVolumeSet` (`//volumeset/<name>`, `//gvc/<gvc>/volumeset/<name>`, or `/org/<org>/gvc/<gvc>/volumeset/<name>`, same org, needs `exec.copyVolume` on it). The device already at the destination is **deleted and replaced**, so `acknowledgeDestinationVolumeDeletion: true` is always required. Within one volume set the target location must differ from the source. Both locations run the command, and `get_command` shows each side's stage.

Shrink, volume-delete, snapshot-delete, restore, and copy are destructive: **snapshot first** as the recovery net (for a copy, snapshot the destination volume; the source is unchanged), then present the blast radius and get the user's approval before the call (it runs at once, with no server-side preview).

## Shared filesystem

A `shared` volumeset is mounted read-write by many workloads at once but supports only expand (no snapshots, shrink, copy, or volume-delete). Each mount point is provisioned its own CPU/memory, tuned with `mountOptions.resources`:

```yaml
spec:
  fileSystemType: shared       # performanceClass auto-set to "shared"
  initialCapacity: 50
  mountOptions:
    resources: { minCpu: 500m, maxCpu: 2000m, minMemory: 1Gi, maxMemory: 2Gi }
```

**Every `mountOptions.resources` bound is validated, and hand-written values usually violate it.** Defaults are `minCpu 500m`, `maxCpu 2000m`, `minMemory 1Gi`, `maxMemory 2Gi`. The rules:

- `maxCpu / minCpu` at most **4**, and `maxCpu - minCpu` at most **4000m**
- `maxMemory / minMemory` at most **4**, and `maxMemory - minMemory` at most **4096Mi**
- **Omitting a bound does not skip the check.** The default fills in for whichever side you leave out: `maxCpu: 4000m` alone is compared against the default `minCpu: 500m` (8:1) and rejected, and `minCpu: 100m` alone is compared against the default `maxCpu: 2000m` (20:1) and rejected the same way.

Raising a ceiling means raising its floor with it: `minCpu 1000m` / `maxCpu 4000m` passes, `minCpu 500m` / `maxCpu 4000m` does not. The rejection reads `"spec.mountOptions.resources" failed custom validation because The ratio between maxCpu and minCpu must be less than 4:1`; the check is actually `> 4`, so an exact 4:1 spread (the defaults) is accepted. The block is accepted on ext4/xfs volumesets too, and validated the same way, but only `shared` provisions mount points that use it.

## Custom encryption (AWS only)

Volumes are encrypted by default. To use your own AWS KMS keys on ext4/xfs volumes (not `shared`, not BYOK):

```yaml
spec:
  customEncryption:
    regions:
      aws-us-east-1:           # format: {cloud-provider}-{region}
        keyId: "arn:aws:kms:us-east-1:123456789:key/KEY_ID"
```

The `keyId` is injected as the EBS storage-class `kmsKeyId`. The KMS key policy **must grant Control Plane's AWS account `arn:aws:iam::957753459089:root`** the volume-encryption permissions (`Decrypt`, `Encrypt`, `GenerateDataKey`, `CreateGrant`, etc.); the key is immutable once a volume exists.

## BYOK storage classes

On self-hosted clusters, volumes use the storage class `{performanceClass}-{fileSystemType}` (e.g. `general-purpose-ssd-ext4`) and the cluster needs a CSI-compatible driver. `spec.storageClassSuffix` selects an alternative `{performanceClass}-{fileSystemType}-{suffix}`, falling back to the unsuffixed class if it is not found.

## Migrating a workload to stateful

Workload type is immutable, so adding an ext4/xfs volume to a serverless/standard workload means **delete + recreate as `stateful`** — destructive. Before deleting, confirm with the user: the public URL that 5xx's during the cutover, any internal callers that fail until recreate, runtime/in-memory state lost at delete, and that the recreate typically takes 2-5 min. Sequence: capture the spec (`cpln workload get WORKLOAD --gvc GVC -o yaml-slim > bak.yaml`) as a rollback artifact; apply the volumeset; delete the old workload; apply the new manifest with `spec.type: stateful` + the volume mount, **keeping the same name** to preserve URL/DNS/policy/identity links. For the deploy-wait pattern, see the `workload` skill.

## Verify

- `mcp__cpln__get_resource` (kind `volumeset`): `status.locations[].volumes[]` show per-volume `currentSize`, `currentBytesUsed`, `lifecycle` (expect `bound`), and snapshot counts; `status.usedByWorkload` names the bound workload.
- After mounting, wait with `mcp__cpln__list_deployments` and `waitSeconds` until ready, and confirm the container's volume is mounted at the expected path.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| 400 mounting a volumeset | ext4/xfs on a serverless/standard workload | Use a `stateful` or `vm` workload (recreate to change type) |
| 400 "performanceClass / fileSystemType is immutable" | Tried to change either on update | Create a new volumeset; migrate data via snapshot/restore |
| 400 on mount with a path | Path is reserved (`/dev`, `/tmp`, `/var`, ...) | Mount elsewhere (e.g. `/data`, `/mnt/...`) |
| HTTP 429 on expand | 4 expansions on that volume in the last 24 h | Wait for the oldest to age out; plan larger steps |
| 400 on shrink | New size cannot hold used bytes (+5%) | Shrink less, or free space / snapshot then rebuild |
| 400 "The ratio between maxCpu and minCpu must be less than 4:1" (same for memory) | `mountOptions.resources` spread past 4:1 or past 4000m / 4096Mi, counting the default that fills any bound you left out | Raise `minCpu` / `minMemory` or lower `maxCpu` / `maxMemory`, and always set both bounds of a pair |
| 400 "Workload X references non-existent volume sets" | The volumeset in the same apply failed its own validation. `cpln apply` reports every failure and does not stop at the first, so the workload PUT still ran | Fix the volumeset error above it and re-apply the bundle; the ordering is already correct |
| Snapshot fields rejected | Volumeset is `shared` | Snapshots need ext4/xfs |
| Deployment stuck after mount | Volume provisioning (2 to 5 min on first deploy) | `list_deployments` with `waitSeconds`; `diagnose_workload` if it stays unready |
