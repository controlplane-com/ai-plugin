---
name: troubleshoot
description: Diagnose and fix a Control Plane workload that is unhealthy or not working correctly
argument-hint: "[workload-name] [--gvc gvc-name]"
---

Diagnose and fix the Control Plane workload the user named.

Use the **cpln-workload-troubleshooter** agent — it loads the `workload-troubleshooting` skill (the full failure catalog) and works read-only first:

1. Gather state — per-location deployments and readiness, events, and logs.
2. Map the symptom to its root cause: OOMKilled, image pull, secret access, port mismatch, firewall, health probes, resource limits, autoscaling, termination, volumes, service-to-service, or dedicated load balancer.
3. Present each issue as **what's wrong** (with evidence), **why**, and **the exact fix**.
4. Apply only after I approve, then re-check readiness across locations and confirm the endpoint responds.

If no workload was named, ask for it (and the GVC) — never guess.
