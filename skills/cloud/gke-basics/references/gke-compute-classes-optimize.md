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

## Flexible CUDs and ComputeClass

[Compute Flexible CUDs (FlexCUDs)](https://docs.cloud.google.com/compute/docs/instances/committed-use-discounts-overview#spend_based) are spend-based commitments that pair naturally with CCC priority lists: the discount is billing-account-wide and machine-series / region / project portable, so it follows whichever family the autoscaler ends up picking from your fallback list. A *resource-based* CUD locks back to a single shape and undermines the family-spread that gives a CCC its obtainability.

**Coverage:**
- ✅ vCPU, memory, local SSD on `C3`, `C3D`, `C4`, `C4A`, `C4D`, `E2`, `N1`, `N2`, `N2D`, `N4`, `N4D`, `N4A`, `H3`, `H4D`, `C2`, `C2D`, `Z3`.
- **28% (1-yr) / 46% (3-yr)** on the general-purpose / compute-optimized series above; **17% / 38%** on `H3` / `H4D`.
- ❌ Not covered: GPUs, TPUs, Hyperdisk, Persistent Disk.
- ⚠ **M-series (`M1`–`M4`): 0% discount on 1-year**, 63% on 3-year — only 3-year is worth buying for memory-optimized.
- ⚠ Spot is not documented as eligible — assume Spot priorities sit outside FlexCUD coverage.

**Where the discount lands in a CCC:** the **On-Demand floor** is the highest-leverage spot for FlexCUDs to apply. Reservation priorities are already pre-paid, DWS is short-lived, and Spot has its own pricing — none of those benefit from a FlexCUD. For accelerator priorities, FlexCUDs cover only the host vCPU / memory portion of the instance — not the GPU or TPU itself; accelerator economics still come through reservations.

**Family-spread tie-break tiers** (`priorityScore` with mixed eligible families) get the discount whichever family wins the tie-break — so don't constrain a spread to chase a resource-based CUD.

## Consolidation (scale-down)

`spec.autoscalingPolicy` controls how aggressively under-utilized nodes are removed.

```yaml
autoscalingPolicy:
  consolidationDelayMinutes: 1        # how fast candidates are removed; 1 is the floor
  consolidationThreshold: 0           # CPU utilization threshold (0 = always)
  gpuConsolidationThreshold: 0        # accelerator utilization threshold
```

Tune `consolidationDelayMinutes` upward for workloads that scale up/down frequently to avoid churn. **The minimum is 1 minute** — sub-minute consolidation (e.g. Karpenter's `consolidateAfter: 30s`) cannot be expressed; `1` is the floor.

> **Cluster maintenance windows don't gate consolidation.** GKE's `--add-maintenance-exclusion-*` flags scope only **upgrades and node auto-repair**, not autoscaler scale-down. Consolidation runs continuously on its own clock regardless of maintenance windows. To suppress disruption during a quiet window, gate at the workload layer with a scheduled PDB tightening (CronJob toggling `maxUnavailable` to `0` and back) — there is no first-class CCC or cluster knob for time-windowed consolidation suppression.

## ActiveMigration

Reconciles running replicas back toward the top priorities (similar to Karpenter's drift). Throttling honors PDBs — set a PDB on the workload to bound concurrent disruption during drift; without one, eviction is uncontrolled.

```yaml
spec:
  activeMigration:
    optimizeRulePriority: true
```

> **Don't enable** for workloads that can't tolerate disruption.

## Updating a ComputeClass

Modifying a CCC's spec (priorities, sysctls, families, sizes, etc.) **does not retroactively change existing nodes**. They keep the configuration they were created with. Only **new** nodes created after the update use the new spec.

What happens to running pods depends on `activeMigration`:

- **Without `activeMigration`** (default): pods stay on their current nodes until they're rescheduled for some other reason (rollout, node drain, consolidation, Spot preemption). Old-spec nodes can persist indefinitely.
- **With `activeMigration.optimizeRulePriority: true`**: the controller continuously drifts pods toward higher-priority rules. When a spec change introduces (or newly satisfies) a higher priority, drift replaces old-spec nodes with new-spec ones over time, throttled by any PDB on the workload. Note that activeMigration's trigger is "higher-priority capacity available," not "spec changed" directly — but the practical effect after a spec change is the same.

If a CCC change must take effect immediately on running workloads (and you can tolerate the disruption), drain the affected nodes manually (`kubectl drain` — PDBs are honored). For workloads that can't tolerate disruption (training, stateful primaries), schedule the change at a maintenance window.

## Pattern 1 — Accelerator obtainability (GPU/TPU)

Casts the widest net for scarce capacity. Cost is secondary.

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: gpu-h100-obtainability
spec:
  nodePoolAutoCreation:
    enabled: true
  priorities:
  # 1. Specific reservation (already paid for)
  - gpu: { count: 8, type: nvidia-h100-80gb }
    machineType: a3-megagpu-8g
    reservations:
      affinity: Specific
      specific:
      - name: h100-mega-reservation
        zones: ['us-central1-a']   # reservation is zonal — pin to avoid wasted backoff in other zones
    spot: false
  # 2. DWS FlexStart (queued, ~3 min) — can land scarce capacity OD can't
  - flexStart: { enabled: true }
    gpu: { count: 8, type: nvidia-h100-80gb }
    machineType: a3-megagpu-8g
  # 3. On-Demand — guaranteed forward progress when reservation and DWS are exhausted
  - gpu: { count: 8, type: nvidia-h100-80gb }
    machineType: a3-megagpu-8g
    spot: false
  # 4. Spot — last for training: mid-step preemption forces a checkpoint restart,
  #    usually more disruptive than waiting longer. Only useful for cost-tolerant
  #    batch with frequent checkpointing. Drop this priority entirely if checkpoint
  #    cost is high.
  - gpu: { count: 8, type: nvidia-h100-80gb }
    machineType: a3-megagpu-8g
    spot: true
```

> **Heads-up — not every accelerator SKU has a plain OD path.** The chain above assumes the SKU supports plain On-Demand provisioning (true for `a3-megagpu-8g`, A100, L4, T4). Several scarce SKUs **do not**: A3 Ultra (`a3-ultragpu-8g`, H200), A4 / A4X bare metal, and A3 High with fewer than 8 GPUs all require reservation, Spot, Flex-start, or a MIG resize request — there is no plain OD floor available. For those SKUs, drop priority #3 and accept that the workload stays `Pending` if Reservation + DWS + Spot are all exhausted. A3 Ultra reservations are also **block-organized** — set `reservations.specific[].reservationBlock.name` on the reservation priority to consume from a particular block (the AI Hypercomputer flow expects this). Verify per-SKU at the [GCE GPU machine types reference](https://docs.cloud.google.com/compute/docs/gpus) and [accelerator-optimized machines](https://docs.cloud.google.com/compute/docs/accelerator-optimized-machines) before choosing the chain.

> **Inference vs. training fallback order:** the two workload types want very different chains.
> - **Training** (Pattern 1 above): `Reservation → DWS → OD → Spot`. DWS's ~3-min queue is acceptable and can land scarce capacity OD can't. OD provides a guaranteed floor when DWS times out. Spot sits **last** because mid-step preemption forces a checkpoint restart — usually more disruptive than waiting longer for OD or DWS. Drop Spot entirely if checkpoint cost is high. See [`assets/tpu-v5e-training-compute-class.yaml`](../assets/tpu-v5e-training-compute-class.yaml) for the same Spot-last shape applied to TPUs.
> - **Online inference / serving:** `Reservation → Spot → DWS → OD`. Spot is instant and replica count masks preemption, so it sits high; DWS's queue is incompatible with serving latency; OD is the guaranteed floor. Worked example: [`assets/genai-inference-g4-compute-class.yaml`](../assets/genai-inference-g4-compute-class.yaml).

> **Reservations are zonal — pin the zone.** A Specific reservation only exists in the zone(s) it was created in. Without `reservations.specific[].zones` (set on priority 1 above), the autoscaler may try the reservation in zones where it doesn't exist, burning backoff slots before falling through to lower priorities. Set `zones` on the reservation entry itself — don't try to express this with `priorityDefaults.location`, which collides with `Specific` (see [create-doc gotcha](./gke-compute-classes-create.md)).

> **GPU sharing (multi-tenant inference):** For low-utilization workloads where multiple clients can share a GPU (dev/staging, batch eval, small-model APIs), a sharing strategy on the GPU priority packs more clients per node. Surface example: [`assets/shared-l4-inference-compute-class.yaml`](../assets/shared-l4-inference-compute-class.yaml) — MPS with 4 clients/GPU on L4. Strategy selection (MPS vs. time-slicing vs. MIG) is covered in a separate skill.

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
