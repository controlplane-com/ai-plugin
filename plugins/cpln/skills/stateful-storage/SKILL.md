---
name: stateful-storage
description: "Creates persistent storage for stateful workloads on Control Plane. Use when the user asks about volumes, volume sets, disks, mounting storage, snapshots, volume expansion, filesystems, shared storage, or backups."
---

# Stateful Storage & VolumeSets

> **Tool availability:** the snapshot tools (`create_volumeset_snapshot`, `list_volumeset_snapshots`, `restore_volumeset_snapshot`, `delete_volumeset_snapshot`), `shrink_volumeset`, and `delete_volumeset_volume` are in the `full` MCP toolset; `create_volumeset`, `update_volumeset`, `mount_volumeset_to_workload`, `expand_volumeset`, and the generic `list_resources`/`get_resource`/`delete_resource` reads are in `core`. If a `full` tool is not advertised, reconnect the MCP server with `?toolsets=full` or use the `cpln` CLI fallback.

A **VolumeSet** is GVC-scoped persistent storage for workloads. The `workload` skill covers the basics (stateful type, reserved mount paths, the 15-volume limit, create-then-verify); this skill is the full volume-set detail. The one trap that drives most rework: **`fileSystemType` and `performanceClass` are immutable** (a PATCH that changes either returns HTTP 400) — to change either you must create a new volumeset, and the old data does not carry over. Choose both at creation.

**Most databases don't need this skill:** `template-catalog` installs Postgres, Redis, MySQL, MongoDB, and more with the volumeset, snapshots, and credentials already wired — hand-build only for a custom app or an unsupported engine.

## Filesystem types and performance classes

| Filesystem | Access | Workloads | Volumes provisioned | Snapshots / shrink / delete-volume |
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

Use `mcp__cpln__create_volumeset` (MCP create/mount tools default `fileSystemType` to **xfs** and `performanceClass` to `general-purpose-ssd`; the raw API/`cpln apply` default is **ext4**). YAML for IaC / CLI fallback:

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
- `recoveryPolicy`: `retain` (default — reuse an existing volume's data on a new replica) or `recycle` (start fresh).
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

Snapshots are **ext4/xfs only — never `shared`**. Automatic policy lives in `spec.snapshots`: `createFinalSnapshot` (default `true` — a snapshot is taken before any volume in the set is deleted), `retentionDuration`, and `schedule` (cron whose minute field must be a single concrete value, so no more than once per hour). Manual: `mcp__cpln__create_volumeset_snapshot`, `list_volumeset_snapshots`, `restore_volumeset_snapshot`, `delete_volumeset_snapshot`. A restore creates a **new volume** and discards everything written since the snapshot.

## Resize and delete volumes

- **Expand** — live, no downtime, all filesystems. Throttled to **4 expansions per volume per rolling 24 hours**; the 5th returns **HTTP 429** and a brief wait does not help (the oldest expansion must age out of the window). `mcp__cpln__expand_volumeset`.
- **Shrink** (ext4/xfs only) — data is migrated to the new smaller volume via an online presync + final delta sync, and the replica restarts during the swap. The platform **rejects the shrink with HTTP 400 when known used bytes (+5% metadata headroom) would not fit**; data is only lost if used bytes genuinely exceed the new capacity. Floor is the class minimum (10 / 200 GB). `mcp__cpln__shrink_volumeset`.
- **Delete a volume** (ext4/xfs only) — permanent loss of that volume's data. `mcp__cpln__delete_volumeset_volume`.

Shrink, volume-delete, snapshot-delete, and restore are destructive: **snapshot first** as the recovery net, then confirm the blast radius (the destructive-ops guardrail returns an impact preview before executing).

## Shared filesystem

A `shared` volumeset is mounted read-write by many workloads at once but supports only expand — no snapshots, shrink, or volume-delete. Each mount point is provisioned its own CPU/memory; tune with `mountOptions.resources` (defaults `minCpu 500m`, `maxCpu 2000m`, `minMemory 1Gi`, `maxMemory 2Gi`; max/min at most 4000m and 4096Mi apart, ratio at most 4:1):

```yaml
spec:
  fileSystemType: shared       # performanceClass auto-set to "shared"
  initialCapacity: 50
  mountOptions:
    resources: { minCpu: 500m, maxCpu: 2000m, minMemory: 1Gi, maxMemory: 2Gi }
```

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
- After mounting, poll `mcp__cpln__list_deployments` until ready and confirm the container's volume is mounted at the expected path.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| 400 mounting a volumeset | ext4/xfs on a serverless/standard workload | Use a `stateful` or `vm` workload (recreate to change type) |
| 400 "performanceClass / fileSystemType is immutable" | Tried to change either on update | Create a new volumeset; migrate data via snapshot/restore |
| 400 on mount with a path | Path is reserved (`/dev`, `/tmp`, `/var`, ...) | Mount elsewhere (e.g. `/data`, `/mnt/...`) |
| HTTP 429 on expand | 4 expansions on that volume in the last 24 h | Wait for the oldest to age out; plan larger steps |
| 400 on shrink | New size cannot hold used bytes (+5%) | Shrink less, or free space / snapshot then rebuild |
| Snapshot fields rejected | Volumeset is `shared` | Snapshots need ext4/xfs |
| Deployment stuck after mount | Volume provisioning (2-5 min on first deploy) | Poll `list_deployments`; check `get_workload_logs` if it stays unready |

## MCP tools quick reference

| Tool | Purpose | Tier |
|---|---|---|
| `mcp__cpln__create_volumeset` | Create a volumeset | core |
| `mcp__cpln__update_volumeset` | Update mutable fields (capacity, autoscaling, snapshots, tags) | core |
| `mcp__cpln__mount_volumeset_to_workload` | Mount to a workload (creates the volumeset if missing) | core |
| `mcp__cpln__expand_volumeset` | Grow a volume (4 / 24 h limit) | core |
| `mcp__cpln__shrink_volumeset` | Shrink a volume (ext4/xfs) | full |
| `mcp__cpln__delete_volumeset_volume` | Delete one volume (ext4/xfs) | full |
| `mcp__cpln__create_volumeset_snapshot` | Point-in-time snapshot | full |
| `mcp__cpln__list_volumeset_snapshots` | List snapshots | full |
| `mcp__cpln__restore_volumeset_snapshot` | Restore a snapshot to a new volume | full |
| `mcp__cpln__delete_volumeset_snapshot` | Delete a snapshot | full |
| `mcp__cpln__get_resource` / `list_resources` / `delete_resource` (kind `volumeset`) | Read / list / delete a volumeset | core |

CLI fallback (CI/CD via a service-account `CPLN_TOKEN`): `cpln volumeset create|get|update|delete|expand|shrink`, `cpln volumeset snapshot create|get|restore|delete`, `cpln volumeset volume get|delete`; `expand`/`shrink` need `--new-size` (`--location`/`--volume-index` optional), and `cpln apply -f` for YAML.

## Related skills

| Skill | For |
|---|---|
| `workload` | Workload types, the deploy-and-verify flow, load-balancer/`replicaDirect` config |
| `template-catalog` | Postgres, Redis, and other databases that provision volumesets for you |
| `firewall-networking` | Outbound rules for cloud-bucket volumes (`s3://`, `gs://`, `azureblob://`) |

## Documentation

- [Volume Set Reference](https://docs.controlplane.com/reference/volumeset.md)
- [Workload Volumes](https://docs.controlplane.com/reference/workload/volumes.md)
- [CLI volumeset Commands](https://docs.controlplane.com/cli-reference/commands/volumeset.md)
