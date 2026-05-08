# GKE ComputeClasses: Optimize

Designing priority lists, fallback strategy, and consolidation. For CRD/concept basics see [gke-compute-classes-create.md](./gke-compute-classes-create.md); for troubleshooting see [gke-compute-classes-debug.md](./gke-compute-classes-debug.md).

## Priority list design

Priorities are tried **top to bottom**. If an option is unobtainable (e.g. stockout), the cluster autoscaler puts it in a backoff state and tries the next.

### Hard rules

- **Cap at ~10 priorities.** Long lists may never reach the bottom — upper-tier backoffs expire and the list loops back to the top before lower priorities are tried.
- **Don't repeat identical rules.** Repetition does not improve obtainability.
- **Use `priorityScore` (GKE 1.35.2-gke.1842000+) for ties.** Integer 1–1000, higher = preferred. Same-score rules are evaluated together (not strictly sequentially); tie-break is by lowest unit cost. Doesn't reduce provisioning latency. Two hard constraints: (1) **max 3 rules per score**, (2) **if any rule has a score, all rules must** — partial scoring is rejected. See [`assets/equal-priority-tiebreak-compute-class.yaml`](../assets/equal-priority-tiebreak-compute-class.yaml).
- **Tie-breaking on equal options** is by lowest unit cost (cluster autoscaler).

### Flexibility dimensions

A good list varies along several dimensions, not just one:

| Dimension | Example variation |
|-----------|-------------------|
| Zone / location | `us-central1-a`, `-b`, `-c` |
| Machine family / shape | `n4` → `n2` → `c2d` (or `e2`/`n4` as defaults if no preference) |
| Capacity type | Reserved → DWS FlexStart → Spot → On-Demand |
| Wait tolerance (DWS FlexStart) | longer queue tolerance for harder-to-get capacity |

If the user pins to a single family, suggest comparable substitutes. If they specify only Spot fallbacks, ensure at least one On-Demand priority near the bottom — otherwise execution isn't guaranteed.

### CPU vs. accelerator fallback patterns

| Workload type | Spot as fallback for On-Demand? | Spot as fallback for Reserved? |
|---------------|---------------------------------|--------------------------------|
| **CPU** | ❌ Bad — if On-Demand is exhausted in a zone, Spot is too. | n/a |
| **Accelerator** | ⚠️ Limited use | ✅ Reasonable — Spot can fill in even when On-Demand isn't available |

- **Accelerator chip fungibility:** Tuned AI/ML models usually don't port across chip architectures. Vary on **location** and **capacity type** instead. Chip-level fungibility is only safe for small models / tolerant ML jobs.
- **Spot sizing:** Smaller shapes are more obtainable as Spot and less likely to be preempted.

### Bin packing & sizing

- Generally **don't cap VM upper bound.** The autoscaler optimizes bin packing — it won't randomly oversize.
- For aggressive packing, set the cluster's `optimize-utilization` autoscaling profile.

## Fallback timing

Priority traversal is designed to **fast-fail** and move down the list to keep pod scheduling latency low. Actual fallback duration is **not deterministic**, though, and can be substantially longer with NAC: GKE may have to **create a node pool** before it can even test obtainability for that shape, and pool creation itself takes time. Each permutation NAC explores adds latency.

For latency-sensitive workloads, put manual or pre-warmed pools at the top of the list (see Pattern 3) so the fast path doesn't depend on pool creation. Trim NAC-only priorities and avoid near-duplicates so traversal doesn't burn time on shapes that won't change the outcome.

## Provisioning model gotchas

- **DWS FlexStart** is queued. Default queue: ~3 min for GPUs and H4D. Don't expect immediate capacity. Shortening `maxRunDurationSeconds` does **not** improve obtainability.
- **`AnyBestEffort` / "ANY" reservation affinity** has a hidden trap: it falls back to On-Demand at the **GCE level**, bypassing CCC — so your lower-priority CCC entries are never tried. Avoid unless you actually want that.
- **Disk generation constraints (stateful workloads):** Gen 4 VMs require Hyperdisk; Gen 2 require Persistent Disk. Don't mix Gen 4 and Gen 2 in priority lists for workloads with attached PVs. Boot disks aren't affected.

## Consolidation (scale-down)

`spec.autoscalingPolicy` controls how aggressively under-utilized nodes are removed.

```yaml
autoscalingPolicy:
  consolidationDelayMinutes: 1        # how fast candidates are removed
  consolidationThreshold: 0           # CPU utilization threshold (0 = always)
  gpuConsolidationThreshold: 0        # accelerator utilization threshold
```

Tune `consolidationDelayMinutes` upward for workloads that scale up/down frequently to avoid churn.

## ActiveMigration

Reconciles running replicas back toward the top priorities (similar to Karpenter's drift). Throttling honors PDBs.

```yaml
spec:
  activeMigration:
    optimizeRulePriority: true
```

> **Don't enable** for workloads that can't tolerate disruption.

## Pattern 1 — Accelerator obtainability (GPU/TPU)

Casts the widest net for scarce capacity. Cost is secondary.

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: gpu-h200-obtainability
spec:
  nodePoolAutoCreation:
    enabled: true
  priorities:
  # 1. Specific reservation (already paid for)
  - gpu: { count: 8, type: nvidia-h200-141gb }
    machineType: a3-ultragpu-8g
    reservations:
      affinity: Specific
      specific:
      - name: nvidia-h200-141gb-specific
        reservationBlock: { name: nvidia-h200-141gb-block }
    spot: false
  # 2. DWS FlexStart (queued, ~3 min minimum)
  - flexStart: { enabled: true }
    gpu: { count: 8, type: nvidia-h200-141gb }
    machineType: a3-ultragpu-8g
  # 3. Spot (reasonable fallback for accelerators)
  - gpu: { count: 8, type: nvidia-h200-141gb }
    machineType: a3-ultragpu-8g
    spot: true
  # 4. On-Demand
  - gpu: { count: 8, type: nvidia-h200-141gb }
    machineType: a3-ultragpu-8g
    spot: false
```

## Pattern 2 — Cost-optimized batch

Batch / dev-test workloads that tolerate interruption. Spot first, with an On-Demand safety net.

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: cost-optimized-batch
spec:
  nodePoolAutoCreation:
    enabled: true
  priorities:
  - machineFamily: n4
    spot: true
    minCores: 16
  - machineFamily: e2
    spot: true
    minCores: 16
  # Always include an On-Demand floor
  - machineFamily: n4
    spot: false
    minCores: 16
```

## Pattern 3 — Latency-sensitive hybrid

Pre-created pools at the top skip NAC provisioning delay; NAC takes over when those exhaust.

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: latency-sensitive-hybrid
spec:
  nodePoolAutoCreation:
    enabled: true
  priorities:
  - nodepools: ['static-pool-a', 'static-pool-b']
  - machineFamily: c3
    spot: false
    minCores: 32
```

## Where to go next

- CRD shape, manual pool binding, selecting a class: [gke-compute-classes-create.md](./gke-compute-classes-create.md)
- Diagnosing scale-up failures, stockouts, scheduling conflicts: [gke-compute-classes-debug.md](./gke-compute-classes-debug.md)
