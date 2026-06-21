---
name: migrate-k8s
description: Migrate Kubernetes manifests, Docker Compose projects, or Helm charts to Control Plane
argument-hint: "[path-to-manifest-or-directory] [--from k8s|compose|helm]"
---

Migrate the Kubernetes, Docker Compose, or Helm source the user pointed to onto Control Plane.

Use the **cpln-k8s-migrator** agent — it loads the `migration-patterns` skill (the canonical conversion reference) and carries the migration end to end:

1. Identify the source and pick the converter (CLI-only, no MCP equivalent): `cpln convert` for Kubernetes manifests (pipe `helm template` output in for a Helm chart), `cpln stack` for Docker Compose, or `cpln helm` to deploy a chart that already renders Control Plane resources.
2. Convert to a file and review it — diff the source against the output for what the converter changed or silently dropped (pinned scaling, `envFrom`, init containers, NetworkPolicy/RBAC, minimal sizing).
3. Provision in dependency order, MCP-first via the typed `create_*` tools (GVC, then secrets, identities, volumesets, workloads, domains); fall back to `cpln apply -f` when MCP is unavailable or in CI/CD.
4. Verify every workload is ready across its locations and report the canonical endpoint — never a constructed URL.

If the org or target GVC isn't named, ask — never guess.
