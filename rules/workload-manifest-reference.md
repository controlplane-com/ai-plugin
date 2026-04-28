---
description: Validation constraints and type-specific rules for Control Plane workload manifests. Consult when generating or modifying workload YAML to avoid creation/update failures.
alwaysApply: false
---

# Workload Manifest Validation Reference

Guardrails for generating correct workload manifests. For full field details, inspect an existing workload with `cpln workload get WORKLOAD -o yaml`.

## Workload Name

- Max 49 characters
- Cannot end with `-headless`

## Workload Type Feature Matrix

| Feature | serverless | standard | stateful | cron |
|:---|:---|:---|:---|:---|
| Capacity AI default | true | true | always disabled | N/A |
| Scale to zero | rps or concurrency | keda only | keda only | No |
| Ports required | Exactly 1 container, 1 port | 0 or more | 0 or more | Must NOT expose ports |
| Probes | TCP default on port | Disabled default | Disabled default | Ignored |
| `maxConcurrency` | Yes | Ignored | Ignored | N/A |
| `replicaDirect` LB | No | No | Yes (only type) | No |
| `job` spec | Forbidden | Forbidden | Forbidden | Required |
| `timeoutSeconds` max | 600 | 3600 | 3600 | N/A |
| Multi-metric autoscaling | No | Yes (cpu/memory/rps) | Yes (cpu/memory/rps) | N/A |
| Max containers | 8 | 8 | 8 | 8 |

### Autoscaling Metrics by Type

| Metric | serverless | standard | stateful |
|:---|:---|:---|:---|
| `concurrency` | Yes | No | No |
| `cpu` | Yes | Yes | Yes |
| `memory` | Yes | Yes | Yes |
| `rps` | Yes | Yes | Yes |
| `latency` | No | Yes | Yes |
| `keda` | No | Yes | Yes |

### Type-Specific Rules

**Serverless**: Exactly 1 container with ports, only 1 port per container. `PORT` env var must match exposed port if set.

**Standard**: No `concurrency` metric.

**Stateful**: No `concurrency` metric. Capacity AI always disabled. `maxUnavailableReplicas` ignored. Stricter minCpu/minMemory constraints (see below).

**Cron**: `job` required. Probes, autoscaling, timeoutSeconds, capacityAI, debug are all ignored/deleted.

## Resource Validation Constraints

These cause creation/update failures if violated.

| Constraint | Rule |
|:---|:---|
| CPU minimum | 25 millicores |
| Memory minimum | 32 MiB |
| Memory-to-CPU ratio | `memory(MiB) / cpu(millicores)` must be <= 8. Relaxed to 32 with tag `cpln/relaxMemoryToCpuRatio`. |
| minCpu minimum | 25 millicores |
| minMemory minimum | 32 MiB |
| minCpu <= cpu | Cannot exceed `cpu` value |
| minMemory <= memory | Cannot exceed `memory` value |
| Stateful minCpu ratio | cpu / minCpu must be <= 4, difference <= 4000m |
| Stateful minMemory ratio | memory / minMemory must be <= 4, difference <= 4096Mi |
| `port` vs `ports` | Mutually exclusive on the same container |
| Port uniqueness | Port numbers must be unique across ALL containers |
| GPU + Capacity AI | Mutually exclusive |
| Capacity AI + CPU metric | Mutually exclusive |
| Capacity AI + multi-metric | Mutually exclusive |
| `metric` vs `multi` | Mutually exclusive (use one or the other) |
| `target` vs `multi` | Mutually exclusive |
| `target` with keda | Not allowed when metric is `keda` |
| `target` with cpu/memory | Max 100 |
| Volumes | Max 15, unique paths, no path can be a parent of another |

### GPU Resource Requirements

**nvidia t4**: Min CPU 2000m (4000m per GPU if quantity > 1 or memory > 14Gi). Min memory 7Gi per GPU. Max memory 31Gi per GPU. Max CPU 8000m per GPU. Quantity 1-4.

**nvidia a10g**: Min CPU 6000m. Min memory 8Gi. Max memory 62Gi. Max quantity 1.

## Container Name Restrictions

- Reserved names: `istio-proxy`, `queue-proxy`, `istio-validation`, `cpln-envoy-assassin`, `cpln-writer-proxy`, `cpln-reader-proxy`, `cpln-dbaas-config`
- Cannot start with `cpln-` or `debugger-`

## Health Check Timing Ranges

| Field | Range | Default |
|:---|:---|:---|
| `initialDelaySeconds` | 0-600 | 10 |
| `periodSeconds` | 1-600 | 10 |
| `timeoutSeconds` | 1-600 | 1 |
| `successThreshold` | 1-20 | 1 |
| `failureThreshold` | 1-20 | 3 |

Probe types: exactly one of `exec`, `grpc`, `tcpSocket`, `httpGet` (xor constraint).

## Key Defaults

| Field | Default |
|:---|:---|
| `type` | `serverless` |
| `cpu` | `50m` |
| `memory` | `128Mi` |
| `autoscaling.target` | `95` |
| `autoscaling.minScale` | `1` |
| `autoscaling.maxScale` | `5` |
| `autoscaling.scaleToZeroDelay` | `300` (seconds) |
| `autoscaling.maxConcurrency` | `0` (unlimited) |
| `timeoutSeconds` | `5` |
| `terminationGracePeriodSeconds` | `90` (range 0-900) |
| `scalingPolicy` | `OrderedReady` |
| `firewallConfig.internal.inboundAllowType` | `none` |

## Common Validation Errors

| Error | Fix |
|:---|:---|
| `spec.containers[N].resources` present | Remove it — Control Plane does not use Kubernetes-style `resources.requests/limits`. Set `cpu` and `memory` directly on the container object: `cpu: 50m`, `memory: 128Mi`. This returns a 400 with `"resources" is not allowed`. |
| Memory-to-CPU ratio exceeded | 1024Mi memory needs at least 128m CPU (ratio 8:1) |
| GPU with Capacity AI | Disable Capacity AI when using GPU |
| Concurrency on standard/stateful | Use rps, cpu, memory, latency, or keda instead |
| Capacity AI with CPU metric | Switch metric or disable Capacity AI |
| Missing job on cron | Add `spec.job` with `schedule` |
| Job on non-cron | Remove `spec.job` |
| Duplicate port numbers | Port numbers must be unique across all containers |
| `port` and `ports` both set | Use only `ports` |
| minCpu > cpu | minCpu must be <= cpu |
| Stateful minCpu ratio > 4:1 | Increase minCpu or decrease cpu |
| Serverless no ports | Must have exactly 1 container with 1 port |
| Serverless multiple ports | Only 1 port per container allowed |
| PORT env mismatch | PORT env var must match exposed port number |
| Name ends with `-headless` | Choose a different name |
| Container name `cpln-*` | Cannot start with `cpln-` or `debugger-` |
| Target > 100 for cpu/memory | Set target <= 100 for percentage-based metrics |
| Target set with keda | Remove `target` when using keda metric |
| replicaDirect on non-stateful | Only valid for stateful workloads |
| Health check multiple probe types | Use exactly one of exec/grpc/tcpSocket/httpGet |
