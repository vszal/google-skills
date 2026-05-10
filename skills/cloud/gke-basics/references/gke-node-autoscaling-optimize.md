# GKE Node Autoscaling: Optimize

Tuning node autoscaling for cost, latency, or obtainability: the cluster-wide autoscaling profile, per-class consolidation thresholds and delay (CCC `autoscalingPolicy`), and zone-distribution policy. For enabling CA / NAP / NAC see [gke-node-autoscaling-enable.md](./gke-node-autoscaling-enable.md). For triage when scaling misbehaves see [gke-node-autoscaling-debug.md](./gke-node-autoscaling-debug.md).

> **MCP tools:** `update_cluster`, `update_node_pool`

## Two-layer model

Node autoscaling tuning lives at two layers — pick the most specific one that captures your intent:

| Layer | Granularity | Use when |
|-------|-------------|----------|
| **Cluster autoscaling profile** | Cluster-wide | You want one default behavior across all pools |
| **CCC `autoscalingPolicy`** | Per ComputeClass | Different workloads need different consolidation aggressiveness — one CCC for serving (conservative), another for batch (aggressive) |

CCC `autoscalingPolicy` overrides the profile defaults for nodes that belong to that class. You can mix: most of the cluster on `balanced`, a batch CCC with aggressive consolidation, a serving CCC with longer delay.

## Autoscaling profile (cluster-wide)

A coarse cluster-wide bias for the autoscaler. **Two values:**

| Profile | Behavior | When to use |
|---------|----------|-------------|
| `balanced` (default) | Keeps spare capacity; scales down conservatively. Faster pod scheduling, higher idle cost. | Latency-sensitive serving where pod-pending time matters more than idle node spend. |
| `optimize-utilization` | Aggressively packs pods onto fewer nodes; removes nodes faster when utilization drops. Uses the `gke.io/optimize-utilization-scheduler` for placement. | Cost-driven workloads, batch, dev/test. **Recommended for the golden path.** |

**Set it:**

```bash
gcloud container clusters update my-cluster --location=us-central1 \
  --autoscaling-profile=optimize-utilization
```

> The profile sets cluster-wide consolidation behavior. The CCC `autoscalingPolicy` fields below are the **directly-tunable** equivalent — they expose the same knobs (delay, threshold) at per-class granularity. Use the profile for the cluster default; use `autoscalingPolicy` to deviate per workload.

## Per-class consolidation tuning (`autoscalingPolicy`)

A ComputeClass exposes the consolidation knobs directly, scoped to nodes managed by that class.

```yaml
spec:
  autoscalingPolicy:
    consolidationDelayMinutes: 1     # delay after a node is identified as a candidate
                                     # before it's removed. Floor = 1 (sub-minute can't be expressed).
    consolidationThreshold: 0        # CPU utilization (%) below which a node is a candidate (0 = always)
    gpuConsolidationThreshold: 0     # accelerator-utilization counterpart for GPU nodes
```

**Field semantics:**
- `consolidationDelayMinutes`: how long a node must remain a consolidation candidate before it's actually removed. Higher = less churn; lower = faster cost recovery. **Minimum is 1** — sub-minute consolidation (e.g. Karpenter's `consolidateAfter: 30s`) cannot be expressed.
- `consolidationThreshold`: CPU-utilization threshold. A node below this for the delay window becomes a candidate. `0` ≈ "always a candidate when reschedulable" (most aggressive); higher values protect partially-loaded nodes.
- `gpuConsolidationThreshold`: same shape for GPU utilization on accelerator nodes. Tune separately because GPU bin-packing dynamics differ from CPU.

> **Disruption controls — what consolidation honors.** Both bin-packing consolidation (cost-driven repacking onto fewer nodes) and under-utilization consolidation respect:
> - **PodDisruptionBudgets** — a node is skipped if eviction would breach a PDB.
> - **`cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` annotation** on any pod on the node — pins the node indefinitely.
>
> This means PDBs are the primary tool for bounding disruption during aggressive consolidation: set `maxUnavailable` (or `minAvailable`) on every workload that has SLOs, and consolidation will pace itself accordingly. Reach for `safe-to-evict: "false"` only on individual pods that genuinely cannot be rescheduled (single-replica stateful primaries with no failover) — every annotated pod is a permanent scale-down blocker on whatever node hosts it.

### Tuning by workload type

| Workload | `consolidationDelayMinutes` | `consolidationThreshold` | Rationale |
|----------|-----------------------------|--------------------------|-----------|
| **Serving (latency-sensitive)** | 5–10 | leave default (or low) | Avoid premature consolidation that creates pod-pending latency on the next traffic spike |
| **Batch / dev-test** | 1–2 | 0 | Drain underutilized nodes promptly; preempt-and-retry is cheap |
| **Bursty (frequent up/down)** | 5–15 | leave default | Bumping delay damps churn — every consolidation forces re-provisioning when the next burst arrives |
| **Stateful (DB, broker)** | 10+ | leave default | Pair with PDBs; node churn is expensive when reattachment / rebalance follows |

> **`consolidationDelayMinutes` interacts with `activeMigration`.** If you also enable `activeMigration.optimizeRulePriority: true` (drift back to higher priorities — see [gke-compute-classes-optimize.md](./gke-compute-classes-optimize.md)), keep the delay long enough that consolidation doesn't fight drift. Both honor PDBs, but rapid simultaneous churn from both layers can stack.

> **Cluster maintenance windows don't gate consolidation.** GKE's `--add-maintenance-exclusion-*` flags scope only **upgrades and node auto-repair**, not autoscaler scale-down. Consolidation runs continuously regardless of maintenance windows. To suppress disruption during a quiet window, gate at the workload layer with a scheduled PDB tightening (CronJob toggling `maxUnavailable` to `0` and back) — there is no first-class CCC or cluster knob for time-windowed consolidation suppression.

## Bin packing & sizing

- **Don't try to cap VM upper-bound size.** CCC has `minCores` / `minMemoryGb` / `minCpuPlatform` (lower bounds) but **no `maxCores` / `maxMemoryGb` field** — there's no knob for "don't pick a shape larger than X." The autoscaler optimizes bin packing on its own and won't randomly oversize for the workloads it sees.
- For aggressive packing, set the cluster's `optimize-utilization` autoscaling profile (above) **and** set `consolidationThreshold: 0` on the relevant CCCs.
- Smaller VMs are usually friendlier to bin packing; larger VMs amortize DaemonSet overhead better. The right answer depends on the workload's per-pod resource shape.

> **NAC shape sizing scales with the cluster.** Node Pool Auto-Creation chooses machine sizes based on the **overall cluster size**, biasing larger as the cluster grows so bin packing stays efficient at scale. Small clusters get small NAC pools; large clusters get larger NAC pools. If you need a strict shape for a specific workload, pin it via `machineType` on a CCC priority — `machineFamily` + `minCores` lets NAC scale up the shape, which is usually what you want.

## Zone-distribution policy (`--location-policy`)

For regional clusters with autoscaling, the location policy controls how new nodes are distributed across the cluster's zones:

| Policy | Behavior | When to use |
|--------|----------|-------------|
| `BALANCED` | Keeps node counts roughly even across zones | HA workloads, anything with `topologySpreadConstraints` across zones |
| `ANY` | Picks whichever zone has capacity right now; tolerates skew | **Spot VMs** (Spot capacity is volatile per-zone — `ANY` lets the autoscaler land in whichever zone has Spot available); cost-tolerant batch; broad obtainability requirements |

> **Pick `ANY` for Spot.** The biggest benefit of `ANY` is **obtainability**, not latency: it lets the autoscaler try every zone in parallel and grab whichever one has capacity. For Spot VMs that's the difference between scheduling and `Pending` — Spot capacity is independent per zone and can disappear in one while another has plenty. `BALANCED` will burn backoff slots in zones with no Spot before falling through. Same logic applies to scarce CPU SKUs and accelerator workloads where you don't have a hard zone affinity.

Set on `gcloud container node-pools create` for manual pools. For NAC, set `location.locationPolicy` per priority in the CCC — this controls how NAC-created pools distribute nodes.

```yaml
priorities:
- machineFamily: n4
  spot: true
  minCores: 16
  location:
    locationPolicy: ANY                        # Spot — pick whichever zone has capacity
    zones: ['us-central1-a', 'us-central1-b', 'us-central1-c']
- machineFamily: n4
  spot: false
  minCores: 16
  location:
    locationPolicy: BALANCED                   # OD floor — even distribution for HA
    zones: ['us-central1-a', 'us-central1-b', 'us-central1-c']
```

## Other scale-down blockers (beyond PDBs and `safe-to-evict`)

The disruption-controls callout above covers the two intentional knobs. Several **unintentional** patterns also block consolidation — audit before tuning thresholds aggressively, since none of them are obvious from the CCC spec:

- **Bare pods** (no controller). Have no rescheduler — autoscaler won't evict them.
- **Pods with local storage** (`emptyDir` on local SSD, `hostPath` PVCs). Eviction would lose the data.
- **Pod anti-affinity / topology spread that pins to that node.** If the rule can't be satisfied elsewhere, the pod can't move.
- **`kube-system` pods without a PDB.** Some are CA-protected by default; others are skipped because moving them would cascade.

**Implication:** if you're tuning for low idle cost but a few of these pods sit on every node, your effective consolidation rate drops to the underlying churn of those pods. The [debug doc](./gke-node-autoscaling-debug.md#scale-down-isnt-happening) has commands to find offenders.

## Capacity Buffers — pre-warm capacity for faster scale-up

Cluster autoscaler is reactive: when pending pods appear, it provisions nodes. For latency-sensitive scale-up (traffic spikes, batch surge), the provisioning round-trip — including NAC pool creation when no fitting pool exists — adds seconds-to-minutes of pending time. **Capacity Buffers** ([docs](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/configure-capacity-buffer)) reserve spare capacity ahead of demand so real workloads land on existing nodes immediately.

**Resource:** `CapacityBuffer` (`autoscaling.x-k8s.io/v1beta1`). It's a CRD — kubectl-only, no gcloud surface.

**Two provisioning strategies:**
- `buffer.x-k8s.io/active-capacity` (default) — buffer pods are real, low-priority placeholder pods that get evicted to make room when real workloads arrive. Requires GKE 1.35.2-gke.1842000+.
- `buffer.gke.io/standby-capacity` — nodes are pre-provisioned but kept idle (no pods running on them). Requires GKE 1.35.2-gke.1842002+.

**Two sizing modes:**

| Mode | Field | Use for |
|------|-------|---------|
| Fixed | `replicas: <N>` | Constant warm capacity (e.g. always keep 3 GPU nodes ready) |
| Dynamic | `percentage: <%>` + `scalableRef: <Deployment>` | Buffer scales with the workload (e.g. 20% headroom on top of current replicas). PodTemplate-only buffers can't use percentage. |

**Example — fixed buffer for a serving CCC:**

```yaml
apiVersion: v1
kind: PodTemplate
metadata:
  name: buffer-unit-template
  namespace: serving
template:
  spec:
    nodeSelector:
      cloud.google.com/compute-class: serving-class    # buffer matches the CCC
    containers:
    - name: pause
      image: registry.k8s.io/pause:3.10
      resources:
        requests:
          cpu: "4"
          memory: "16Gi"
---
apiVersion: autoscaling.x-k8s.io/v1beta1
kind: CapacityBuffer
metadata:
  name: serving-buffer
  namespace: serving
spec:
  podTemplateRef:
    name: buffer-unit-template
  replicas: 3
  provisioningStrategy: "buffer.x-k8s.io/active-capacity"
  limits:                                              # cluster-wide cap
    cpu: "32"
    memory: "128Gi"
```

**Composes with NAP / NAC.** The buffer pods carry `nodeSelector` for the target ComputeClass, so NAC honors the priority list and provisions buffer nodes the same way it would real workload nodes. Cluster-level NAP is recommended (and required on older GKE versions).

**When to use:**
- Burst-sensitive serving with strict pod-pending SLOs.
- Pre-warming GPU/TPU capacity ahead of a known traffic window.
- Workloads where NAC pool-creation latency is unacceptable on the fast path.

**When not to use:**
- Steady-state workloads — you'd be paying for idle capacity that consolidation would otherwise reclaim.
- Pod-billed clusters — Capacity Buffers require node-based billing.
- Custom scalable resource references — those need a manual RBAC grant for the cluster autoscaler.

> **Reaction lag.** Buffer recalculation against the source workload has up to ~5 min latency. For sub-minute traffic ramps, a fixed buffer matched to peak demand is more predictable than a percentage buffer chasing the workload.

> **Buffer vs. `min-nodes`.** A pool floor (`--min-nodes` or `--total-min-nodes`) is the dumbest version of "warm capacity" — it pins a fixed count of nodes regardless of workload. Capacity Buffers are richer: they target a specific ComputeClass, pair with a pod shape (so NAC knows what to provision), and can scale dynamically. Use buffers for shape-aware warm capacity; use pool floors only when you genuinely need a baseline node count for the pool's own workloads (e.g. a system pool).

## Updating an existing CCC's `autoscalingPolicy`

Modifying `autoscalingPolicy` does **not** retroactively change existing nodes — they keep the configuration they were created with. Only **new** nodes pick up the new tuning. Existing nodes drift to the new policy as they're rescheduled (for upgrades, preemption, or other consolidation events).

For details on the broader CCC update model see [gke-compute-classes-optimize.md → Updating a ComputeClass](./gke-compute-classes-optimize.md).

## Where to go next

- Enable cluster autoscaler / NAP / NAC, choose manual vs. NAC vs. hybrid: [gke-node-autoscaling-enable.md](./gke-node-autoscaling-enable.md)
- Pending pods, scale-up errors, scale-down not happening: [gke-node-autoscaling-debug.md](./gke-node-autoscaling-debug.md)
- Priority list design, fallback patterns, FlexCUDs, accelerator obtainability: [gke-compute-classes-optimize.md](./gke-compute-classes-optimize.md)
- Karpenter → CCC concept mapping (drift, weight, consolidation): [gke-compute-classes-karpenter-migration.md](./gke-compute-classes-karpenter-migration.md)
