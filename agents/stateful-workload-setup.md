---
name: cpln-stateful-workload-setup
description: Use when a user needs persistent storage on Control Plane. Guides through filesystem selection, volumeset creation, stateful workload setup, volume mounting, and backup configuration. Redirects to template-catalog for common databases.
version: 1.0.0
---

# Control Plane Stateful Workload Setup

You guide users through creating workloads with persistent storage. This involves coordinated steps — wrong filesystem type or workload type causes deployment failures that are hard to diagnose.

**Operational discipline (read before any action):**

- **Long waits are normal here.** Stateful workload first-deploy takes 2–5 min (volumeset provisioning + container schedule). **Tell the user the expected range upfront** before starting any apply.
- **`cpln apply --ready` is the default wait — but for first-deploys of newly-recreated stateful workloads, wrap it with the patience-windowed safety net from `rules/cpln-guardrails.md`.** Plain `--ready` blocks until ready or its default timeout, which on a misconfigured first-deploy can mean waiting minutes through a container that's already terminally errored. The safety net runs `--ready` in the background, sleeps the expected window (3 min for stateful first-deploys), then watches for confirmed container failures and kills the apply early if found. For repeat deploys of an already-healthy workload (image bump, env tweak), plain `--ready` is fine on its own.
- **Never poll readiness from the AI layer.** All waits stay at the shell level — one tool call, one final result. AI-driven polling burns thousands of tokens per cycle for no diagnostic value.
- **Adding a volume to an existing serverless/standard workload is destructive** — workload type is immutable, so it requires delete + recreate as stateful. Surface the blast radius and get explicit user confirmation per the **"Destructive Operations"** rule in `rules/cpln-guardrails.md`, even when permissions are on bypass. See `skills/stateful-storage/SKILL.md` → "Migrating an existing workload to stateful" for the safe sequence.
- **Autoscaling for single-writer data layers** (SQLite, single-volume Postgres, etc.): one writer + one volume mount usually means `min=max=1`. If the user asked for concurrency or RPS scaling on such a workload, surface the constraint per the **"Constraint Conflicts"** rule and present alternatives — don't silently downgrade to `disabled`.

## Three Use Cases

### Use Case 1: Database (PostgreSQL, MySQL, MongoDB, etc.)

**Recommend the **cpln-template-catalog** skill first.** Production-ready database templates handle volumeset creation, workload configuration, backups, and credentials automatically.

Supported databases include `postgres`, `postgres-highly-available`, `postgis`, `mysql`, `mariadb`, `mongodb`, `cockroachdb`, `tidb`, `clickhouse`, `redis`, and `redis-cluster`. See the **cpln-template-catalog** skill for the full list and exact install commands (templates install from the cloned `controlplane-com/templates` repo via local path).

If the user needs manual setup (custom configuration, unsupported database, or specific requirements), continue with Step 1 using **ext4** filesystem and **stateful** workload type.

### Use Case 2: Shared File Storage

For file uploads, shared assets, or data accessed by multiple workloads simultaneously.

- Filesystem: **shared**
- Workload type: **any** (serverless, standard, or stateful)
- No snapshots available — implement application-level backups

### Use Case 3: Custom Stateful Application

Ask the user about their access patterns:

| Pattern | Recommended Filesystem |
|:---|:---|
| General-purpose database or key-value store | ext4 |
| Large files, high throughput (media, logs) | xfs |
| Multiple workloads reading/writing same files | shared |

Both ext4 and xfs require **stateful** workload type.

---

## Workflow

### Step 1: Create the VolumeSet

> **Skip this step** if using `mcp__cpln__mount_volumeset_to_workload` in Step 3 — it creates the volumeset automatically.

#### Via CLI

**ext4/xfs:**

```bash
cpln volumeset create \
  --name my-data \
  --gvc my-gvc \
  --file-system-type ext4 \
  --performance-class general-purpose-ssd \
  --initial-capacity 20 \
  --enable-autoscaling \
  --max-capacity 200 \
  --min-free-percentage 20 \
  --scaling-factor 1.5 \
  --retention-duration 7d \
  --schedule "0 2 * * *"
```

**Shared:**

```bash
cpln volumeset create \
  --name shared-uploads \
  --gvc my-gvc \
  --file-system-type shared \
  --performance-class shared \
  --initial-capacity 50
```

Shared filesystem does not support `--schedule`, `--retention-duration`, or snapshot flags.

#### Via YAML + Apply

```yaml
kind: volumeset
name: my-data
gvc: my-gvc
spec:
  fileSystemType: ext4
  initialCapacity: 20
  performanceClass: general-purpose-ssd
  autoscaling:
    maxCapacity: 200
    minFreePercentage: 20
    scalingFactor: 1.5
  snapshots:
    createFinalSnapshot: true
    retentionDuration: 7d
    schedule: "0 2 * * *"
```

```bash
cpln apply -f volumeset.yaml --gvc my-gvc
```

**Key decisions:**

| Parameter | Guidance |
|:---|:---|
| `initialCapacity` | Start with expected data size + 20% headroom |
| `performanceClass` | `general-purpose-ssd` (min 10 GB) for most workloads; `high-throughput-ssd` (min 200 GB) for heavy I/O |
| `autoscaling` | Recommended for production — prevents disk-full outages |
| `snapshots.schedule` | `"0 2 * * *"` = daily at 2 AM; minimum frequency is once per hour |
| `retentionDuration` | `7d` = 7 days; supports `Nd`, `Nh`, `Nm` (days/hours/minutes) |

**Immutable after creation:** filesystem type, performance class.

### Step 2: Create the Workload

#### For ext4/xfs — Must Be Stateful

**Via MCP (preferred):**

Use `mcp__cpln__create_workload` with `type: 'stateful'`:
- `gvc` (required) — GVC name
- `name` (required) — workload name
- `image` (required) — container image
- `type` — set to `'stateful'`
- `cpu`, `memory` — resource allocation
- `port` — container port (if the workload serves traffic)
- `minScale`, `maxScale` — replica count

**Via YAML + Apply** (required for CLI — `cpln workload create` does not support the stateful type):

```yaml
kind: workload
name: my-database
gvc: my-gvc
spec:
  type: stateful
  containers:
    - name: main
      image: //image/myapp:latest
      ports:
        - protocol: http
          number: 5432
      resources:
        cpu: 500m
        memory: 1Gi
  defaultOptions:
    autoscaling:
      minScale: 1
      maxScale: 3
```

```bash
cpln apply -f workload.yaml --gvc my-gvc
```

**Stateful workload features:**
- Stable replica identities: `{workloadName}-{replicaIndex}` (e.g., `my-database-0`)
- Stable hostnames: `{replicaIdentity}.{workloadName}`
- Cannot use Capacity AI — set `minCpu`/`minMemory` for cost optimization
- Rolling updates (not fast switching)

#### For Shared — Any Workload Type

Shared volumes work with serverless, standard, or stateful workloads. Use `mcp__cpln__create_workload` or `cpln workload create` with any type.

### Step 3: Mount the Volume

#### Via MCP (preferred for ext4/xfs on stateful workloads)

Use `mcp__cpln__mount_volumeset_to_workload`:
- `gvc` (required) — GVC name
- `workloadName` (required) — workload name (must be type stateful)
- `volumesetName` (optional) — defaults to `{workloadName}-vol`
- `mountPath` (optional) — defaults to `/mnt/{volumesetName}`
- `size` (optional) — initial capacity in GB (required when creating a new volumeset)
- `fileSystemType` (optional) — `ext4`, `xfs`, or `shared` (default: `xfs`)
- `performanceClass` (optional) — `general-purpose-ssd` or `high-throughput-ssd` (default: `general-purpose-ssd`)
- `description` (optional) — describe the data stored
- `tags` (optional) — key-value pairs for organizing

This tool **creates the volumeset if it does not exist** and mounts it in one call. If using this, skip Step 1.

**Common mount paths:**

| Application | Mount Path |
|:---|:---|
| PostgreSQL | `/var/lib/postgresql/data` |
| MySQL / MariaDB | `/var/lib/mysql` |
| MongoDB | `/data/db` |
| Redis | `/data` |
| Custom app | `/mnt/{volumesetName}` (default) |

#### Via YAML (required for shared on non-stateful workloads)

Export the workload, add the volume, and apply:

```bash
cpln workload get my-workload -o yaml-slim --gvc my-gvc > workload.yaml
```

Add the volume to the container spec:

```yaml
spec:
  containers:
    - name: main
      volumes:
        - uri: cpln://volumeset/my-data
          path: /var/lib/postgresql/data
```

Apply:

```bash
cpln apply -f workload.yaml --gvc my-gvc
```

**Volume constraints:**
- Maximum 15 volumes per workload
- Must use unique absolute paths
- Reserved paths cannot be used: `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log`
- VolumeSet must be in the same GVC as the workload
- ext4/xfs volumesets lock to one workload; shared allows multiple

### Step 4: Verify & Configure Backups

#### Verify Deployment

Check that the workload is running with the volume mounted:

1. Use `mcp__cpln__get_workload_deployments` to check deployment status
2. Use `mcp__cpln__get_workload_events` if there are issues

Or via CLI:

```bash
cpln workload get-deployments my-database --gvc my-gvc
```

#### Configure Snapshots (ext4/xfs Only)

If not configured during volumeset creation, update the volumeset:

```bash
cpln volumeset update my-data --gvc my-gvc \
  --set spec.snapshots.schedule="0 2 * * *" \
  --set spec.snapshots.retentionDuration=7d \
  --set spec.snapshots.createFinalSnapshot=true
```

#### Take a Manual Snapshot

Use `mcp__cpln__create_volumeset_snapshot`:
- `gvc` (required) — GVC name
- `name` (required) — volumeset name
- `location` (required) — location of the volume (e.g., `aws-us-east-2`)
- `volumeIndex` (required) — volume index (usually `0`)
- `snapshotName` (required) — descriptive name for the snapshot

Or via CLI:

```bash
cpln volumeset snapshot create my-data \
  --gvc my-gvc \
  --snapshot-name initial-backup \
  --location aws-us-east-2 \
  --volume-index 0
```

**Shared filesystem does not support snapshots** — implement application-level backups (e.g., `pg_dump`, `mysqldump`).

---

## Quick Path: Two MCP Calls

For the fastest setup with ext4/xfs:

1. **Create workload:** `mcp__cpln__create_workload` with `type: 'stateful'`, `image`, `gvc`, `name`
2. **Create volumeset + mount:** `mcp__cpln__mount_volumeset_to_workload` with `gvc`, `workloadName`, `mountPath`, `size`, `fileSystemType`

The mount tool creates the volumeset automatically if it does not exist.

---

## Common Mistakes to Prevent

- **Using ext4/xfs on a non-stateful workload** — ext4/xfs require stateful workload type. Workload types are immutable — must delete and recreate to switch.
- **Volumeset in wrong GVC** — volumesets are GVC-scoped. The workload and volumeset must be in the same GVC.
- **Undersized initial capacity** — volume expansion is throttled to once every 6 hours. Start with enough headroom or enable autoscaling.
- **No autoscaling in production** — disk-full outages crash databases. Always configure `maxCapacity` and `minFreePercentage`.
- **Expecting cross-location replication** — volumes are per-location. Data does NOT replicate across locations automatically.
- **Shared filesystem with snapshots** — shared does not support snapshots, volume deletion, shrink, or restore.
- **Mounting to reserved paths** — `/dev`, `/dev/log`, `/tmp`, `/var`, `/var/log` cannot be used as mount paths.
- **Exceeding 15 volumes** — maximum 15 volumes per workload.
- **Forgetting minCpu/minMemory on stateful workloads** — Capacity AI is not available for stateful; set resource minimums for cost optimization.

## MCP Tools Reference

| Tool | Purpose |
|:---|:---|
| `mcp__cpln__create_workload` | Create workload (set `type: 'stateful'` for ext4/xfs volumes) |
| `mcp__cpln__mount_volumeset_to_workload` | **Composite** — creates volumeset if needed + mounts to stateful workload |
| `mcp__cpln__update_workload` | Update workload spec (manual volume mounting) |
| `mcp__cpln__get_workload` | Get workload details |
| `mcp__cpln__get_workload_deployments` | Check deployment status |
| `mcp__cpln__get_workload_events` | Diagnose deployment issues |
| `mcp__cpln__get_volumeset` | Get volumeset details |
| `mcp__cpln__list_volumesets` | List volumesets in a GVC |
| `mcp__cpln__expand_volumeset` | Increase volume capacity |
| `mcp__cpln__create_volumeset_snapshot` | Create point-in-time snapshot (ext4/xfs only) |
| `mcp__cpln__restore_volumeset_snapshot` | Restore volume from snapshot (ext4/xfs only) |
| `mcp__cpln__delete_volumeset` | Delete a volumeset (permanent data loss) |
