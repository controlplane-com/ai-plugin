---
description: Validation constraints for Control Plane volume set manifests. Consult when generating or modifying volume set YAML to avoid creation/update failures.
alwaysApply: false
---

# Volume Set Manifest Validation Reference

Guardrails for generating correct volume set manifests. For full field details, inspect an existing volume set with `cpln volumeset get VOLUMESET --gvc GVC -o yaml`.

## Scope and Binding

- Volume sets are **GVC-scoped**
- `ext4`/`xfs`: one volume per replica, binds to at most one stateful workload
- `shared`: one volume per location, can attach to any number of workloads
- Mount in workload via volume URI: `cpln://volumeset/VOLUMESET_NAME`
- Volume set `performanceClass` is **immutable** after creation

## Complete Volume Set YAML Structure

```yaml
kind: volumeset
name: my-volumeset
gvc: my-gvc                            # parent GVC (local tools only, ignored by server)
description: Database storage
tags:
  app: postgres
spec:
  fileSystemType: ext4                  # "ext4" (default), "xfs", or "shared"
  initialCapacity: 50                   # required, in GB, integer, min 10
  performanceClass: general-purpose-ssd # required for ext4/xfs, auto-set for shared
  storageClassSuffix: custom            # optional, BYOK only, regex: ^[a-zA-Z][0-9a-zA-Z\-_]*$
  autoscaling:
    maxCapacity: 500                    # in GB, integer, min 10
    minFreePercentage: 20              # 1-100
    scalingFactor: 1.5                 # min 1.1
    predictive:
      enabled: true
      lookbackHours: 48                # 1-168 (1 week), default 24
      projectionHours: 12              # 1-72, default 6
      minDataPoints: 10                # 2-100, integer, default 10
      minGrowthRateGBPerHour: 0.1      # min 0, default 0.01
      scalingFactor: 1.2               # min 1.1, inherits parent if not set
  snapshots:
    createFinalSnapshot: true          # boolean, default true — auto-snapshot before volume deletion
    retentionDuration: "7d"            # regex: ^([0-9]+(\.[0-9]+)?[dhm])$ (day/hour/minute)
    schedule: "0 2 * * *"             # cron, min frequency: once per hour
  mountOptions:                        # shared filesystem only
    resources:
      minCpu: "500m"                   # default 500m
      maxCpu: "2000m"                  # default 2000m
      minMemory: "1Gi"                 # default 1Gi
      maxMemory: "2Gi"                 # default 2Gi
  customEncryption:                    # AWS only, ext4/xfs only
    regions:
      aws-us-east-1:
        keyId: "arn:aws:kms:us-east-1:123456789012:key/KEY_ID"
```

## File System Types

| Feature | ext4 | xfs | shared |
|:---|:---|:---|:---|
| Access mode | read-write-once | read-write-once | read-write-many |
| Binding | 1 stateful workload | 1 stateful workload | Any number of workloads |
| Volumes per | 1 per replica | 1 per replica | 1 per location |
| Snapshots | Yes | Yes | No |
| shrinkVolume | Yes | Yes | No |
| deleteVolume | Yes | Yes | No |
| restoreVolume | Yes | Yes | No |
| customEncryption | Yes | Yes | No |

## Performance Classes

| Class | Min Capacity | Max Capacity |
|:---|:---|:---|
| `general-purpose-ssd` | 10 GB | 65,536 GB |
| `high-throughput-ssd` | 200 GB | 65,536 GB |
| `shared` | 10 GB | 65,536 GB |

- `shared` performance class is auto-set when `fileSystemType: shared` — do not set manually for other types
- Performance class is **immutable** after creation
- `initialCapacity` must be within the performance class min/max range
- `autoscaling.maxCapacity` must also be within the performance class range

## Autoscaling Constraints

- `maxCapacity`: integer, min 10, must be within performance class limits
- `initialCapacity` cannot exceed `autoscaling.maxCapacity`
- `minFreePercentage`: 1-100
- `scalingFactor`: min 1.1
- When `predictive.enabled: true`, both `minFreePercentage` and `scalingFactor` (>= 1.1) are required

## Predictive Scaling Constraints

- Supplements reactive scaling — whichever target is larger wins
- `lookbackHours`: 1-168 (default 24)
- `projectionHours`: 1-72 (default 6)
- `minDataPoints`: 2-100, integer (default 10)
- `minGrowthRateGBPerHour`: min 0 (default 0.01)
- `predictive.scalingFactor`: min 1.1, inherits parent `scalingFactor` if omitted

## Snapshot Constraints

- `createFinalSnapshot`: boolean, default `true` — automatically creates a snapshot before any volume in the set is deleted
- `retentionDuration`: floating point + unit (`d`, `h`, `m`), e.g., `7d`, `12h`, `30m`
- `schedule`: cron expression, cannot be more frequent than once per hour
- Snapshots NOT supported for `shared` filesystem

## Mount Options (shared only)

- `minCpu`/`maxCpu`: ratio must be at most 1:4, difference at most 4000m
- `minMemory`/`maxMemory`: ratio must be at most 1:4, difference at most 4096Mi
- `maxCpu` must be >= `minCpu`, `maxMemory` must be >= `minMemory`

## Custom Encryption (AWS only)

- Only supported for `ext4` and `xfs` — NOT `shared`
- Region format: `aws-{region}` (e.g., `aws-us-east-1`)
- `keyId`: full ARN of AWS KMS key
- Key is immutable per volume — cannot change encryption key after volume creation
- Regions not listed use AWS default encryption

## Volume Expansion

- Volumes can only be expanded once every 6 hours
- Cannot expand to a smaller size — use `shrinkVolume` for that (causes data loss)

## Common Validation Errors

| Error | Fix |
|:---|:---|
| initialCapacity below min | `general-purpose-ssd` min 10 GB, `high-throughput-ssd` min 200 GB |
| initialCapacity exceeds maxCapacity | `initialCapacity` must be <= `autoscaling.maxCapacity` |
| Missing performanceClass for ext4/xfs | Required for non-shared file systems |
| shared performanceClass with ext4/xfs | `shared` performance class only works with `shared` filesystem |
| Predictive without minFreePercentage | Both `minFreePercentage` and `scalingFactor` required when predictive is enabled |
| scalingFactor below 1.1 | Minimum scaling factor is 1.1 |
| Snapshots on shared filesystem | Snapshots are not supported for shared volumes |
| Mount options on ext4/xfs | `mountOptions` only applies to shared filesystem |
| shrinkVolume on shared | Only ext4 and xfs support shrink/delete/restore/snapshot commands |
| customEncryption on shared | Custom encryption only for ext4 and xfs |
| Mount resource ratio exceeded | minCpu/maxCpu and minMemory/maxMemory ratio must be at most 1:4 |

## Example: Database Volume (ext4)

```yaml
kind: volumeset
name: postgres-data
gvc: production
spec:
  fileSystemType: ext4
  initialCapacity: 100
  performanceClass: high-throughput-ssd
  autoscaling:
    maxCapacity: 500
    minFreePercentage: 20
    scalingFactor: 1.5
  snapshots:
    retentionDuration: "7d"
    schedule: "0 2 * * *"
```

## Example: Shared File Storage

```yaml
kind: volumeset
name: shared-uploads
gvc: production
spec:
  fileSystemType: shared
  initialCapacity: 50
  autoscaling:
    maxCapacity: 200
    minFreePercentage: 15
    scalingFactor: 1.5
  mountOptions:
    resources:
      minCpu: "100m"
      maxCpu: "200m"
      minMemory: "128Mi"
      maxMemory: "256Mi"
```

## Mounting in a Workload

```yaml
# In workload spec.containers[].volumes:
volumes:
  - uri: cpln://volumeset/postgres-data
    path: /var/lib/postgresql/data
    recoveryPolicy: retain             # "retain" (default) or "recycle"
```
