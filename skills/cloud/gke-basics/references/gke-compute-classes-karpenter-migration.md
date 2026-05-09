# GKE ComputeClasses: Migrating from Karpenter

For teams moving from Karpenter (commonly EKS+Karpenter → GKE+ComputeClasses). The fundamentals — CRD shape, NAC vs. manual pools, the field tables — are in [gke-compute-classes-create.md](./gke-compute-classes-create.md). Priority list design and fallback patterns are in [gke-compute-classes-optimize.md](./gke-compute-classes-optimize.md). This doc focuses on the translation: what maps cleanly, what changes, what GKE doesn't have an equivalent for.

## Concept mapping

| Karpenter concept | GKE ComputeClass equivalent |
|---|---|
| `NodePool` (one per capacity tier) | One CCC with multiple `priorities[]` entries — collapse multiple NodePools into a single ordered list |
| `spec.weight` (NodePool preference) | **Order in `priorities[]`** — top wins. Strictly ordered, fast-fail traversal. Not weighted-random. |
| `priorityScore` is **not** Karpenter weight | It's for tie-breaking among equally-acceptable rules at the same score, not for preference. Cap of 3 rules per score, all-or-nothing scoring (if any rule has a score, all rules must). Requires GKE 1.35.2-gke.1842000+. |
| `requirements: capacity-type In [spot, on-demand]` | `spot: true` / `spot: false` per priority — declare preference order explicitly |
| `requirements: instance-family In [m6i, c6i]` | One `machineFamily` per priority (no list operator) — repeat the priority per family, or use intent fields like `minCores` / `minMemoryGb` to give the autoscaler substitution room |
| `kubernetes.io/arch: amd64` | Implicit in GKE; only specify Arm explicitly (`c4a` / `n4a` `machineFamily`, or `podFamily: general-purpose-arm` on Autopilot) |
| `disruption.consolidationPolicy` + `consolidateAfter` | `autoscalingPolicy.consolidationDelayMinutes` + `consolidationThreshold` (granularity is **minutes**, not seconds — minimum is `1`) |
| `disruption.budgets` (concurrent disruption cap) | **`PodDisruptionBudget` on the workload** — not a CCC field |
| `disruption.budgets` with `schedule` (time-windowed disruption block) | **No first-class equivalent.** CronJob toggling `maxUnavailable` on a PDB is the closest; cluster maintenance windows scope upgrades, not consolidation. |
| Karpenter drift (reconcile nodes when better option exists) | `activeMigration.optimizeRulePriority: true` (set a PDB to bound disruption) |
| `spec.limits.cpu` / `.memory` (per-NodePool cost cap) | **`ResourceQuota` at the namespace level** — not a CCC field. Pair with `--enable-cost-allocation` for billing alignment. See [gke-multitenancy.md](./gke-multitenancy.md). |
| `template.metadata.labels` | `nodePoolConfig.nodeLabels` |
| `template.spec.taints` | `nodePoolConfig.taints` (NAC-created nodes only — manual pools take labels/taints from `gcloud container node-pools update`) |
| Pod implicitly matches NodePool by requirements | Pod **must** opt in: `nodeSelector: cloud.google.com/compute-class: <name>` (or namespace/cluster default) |

## Rough family translation

| AWS | GCP equivalent |
|---|---|
| `m5` / `m6i` (Intel general-purpose) | `n2` (Gen 2) / `n4` (Gen 4) |
| `c5` / `c6i` (Intel compute-optimized) | `c2` (Gen 2) / `c4` (Gen 4) |
| `m5a` / `m6a` (AMD general-purpose) | `n2d` (Gen 2) / `n4d` (Gen 4) |
| `c6a` (AMD compute-optimized) | `c4d` (Gen 4) |
| `c7g` / `m7g` (Graviton/ARM) | `c4a` / `n4a` (Axion/ARM) |
| `r5` / `r6i` (memory-optimized) | `n2-highmem-*` / `n4-highmem-*`, or `m1` / `m2` / `m3` / `m4` for very memory-heavy |

Verify the target family is available in your chosen GCP region before locking it down — not all families are in all regions. `kubectl describe crd computeclasses.cloud.google.com` and `gcloud compute machine-types list --zones=<zone>` are the authoritative checks.

## Behavioral differences worth flagging up front

- **Strictly ordered fast-fail traversal.** CCC tries priorities top-to-bottom and falls through on stockout/quota/exhaustion. There is no probabilistic selection — once priority 1 is satisfiable, all pods land there until it isn't.
- **No `WhenEmpty`-only consolidation mode.** GKE consolidates both empty and under-utilized nodes; tune the threshold (`consolidationThreshold: 0` ≈ aggressive consolidation) rather than picking a policy variant. See [optimize.md → Consolidation](./gke-compute-classes-optimize.md).
- **Spot ↔ On-Demand share underlying capacity for CPU on GCP.** Karpenter Spot-only NodePools that fall through to "wait for Spot" make sense on AWS where Spot capacity is independent. On GCP, if On-Demand is exhausted in a zone, Spot usually is too — add an On-Demand floor *below* your Spot priorities, not above them. (Accelerators are different — Spot can fill in when On-Demand can't.)
- **Spec changes don't drift existing nodes.** Karpenter drifts on any NodePool spec change. CCC's `activeMigration` triggers on "higher-priority capacity available," not "spec changed." After a CCC update, old-spec nodes persist until something else evicts them. See [optimize.md → Updating a ComputeClass](./gke-compute-classes-optimize.md).
- **`AnyBestEffort` reservation affinity is a trap.** It looks like the broadest setting but falls back to On-Demand at the GCE layer, bypassing CCC priorities entirely. Use `Specific` with named reservations.
- **Reservations are zonal.** Pin via `reservations.specific[].zones` on the priority entry. Don't use `priorityDefaults.location` for this — it collides with `Specific` reservations.
- **Region/zone naming differs.** AWS `us-east-1a/b/c` doesn't have a single GCP equivalent — `us-east1` (South Carolina), `us-east4` (N. Virginia), and `us-east5` (Columbus) are separate regions. Pick by latency / data residency / available SKUs, not by name match.
- **No `topologySpreadConstraints` in the CCC.** That's a Kubernetes pod-spec feature on GKE just as it is on EKS — set it on the workload, not the CCC. CCC's `location.locationPolicy: BALANCED` controls how NAC distributes *new* nodes across zones, which is related but not the same.
- **`whenUnsatisfiable: ScaleUpAnyway` picks E2.** On Standard with NAC, `ScaleUpAnyway` provisions an E2 node — hardcoded, not configurable. Inappropriate for memory-bound, latency-sensitive, or accelerator workloads. Karpenter's "any obtainable VM" semantic doesn't quite match; if E2 isn't acceptable, leave `whenUnsatisfiable` at `DoNotScaleUp` and accept Pending as the failure mode.

## Migration patterns

The closest CCC analogs to common Karpenter NodePool shapes:

- **General-purpose Spot-first stateless tier** → [`assets/spot-cost-tiebreak-compute-class.yaml`](../assets/spot-cost-tiebreak-compute-class.yaml). Three equal-score Spot families plus an OD floor; let CCC pick lowest-cost-available.
- **Reserved-first with Spot fallback** → [`assets/genai-inference-g4-compute-class.yaml`](../assets/genai-inference-g4-compute-class.yaml) (GPU example) or compose a CPU equivalent: Specific reservation top, `spot: true` middle, `spot: false` floor.
- **Multiple equivalent OD families with cost tie-break** → [`assets/equal-priority-tiebreak-compute-class.yaml`](../assets/equal-priority-tiebreak-compute-class.yaml). Demonstrates `priorityScore` mechanics.
- **Latency-sensitive hybrid** (manual pre-warmed pools + NAC fallback) → see Pattern 3 in [optimize.md](./gke-compute-classes-optimize.md). Karpenter doesn't have a direct analog for "pre-existing pool I want pinned at the top of the list" — `nodepools: [<pool-name>]` is GKE-specific (Standard only).

## Where to go next

- CRD shape, NAC vs. manual pools, selecting a CCC: [gke-compute-classes-create.md](./gke-compute-classes-create.md)
- Priority list design, consolidation, activeMigration, FlexCUDs: [gke-compute-classes-optimize.md](./gke-compute-classes-optimize.md)
- Diagnosing scale-up failures, stockouts, scheduling conflicts: [gke-compute-classes-debug.md](./gke-compute-classes-debug.md)
