# GKE ComputeClasses: Create

Authoring a ComputeClass (CCC): concepts, CRD basics, and starter examples. For tuning priority lists see [gke-compute-classes-optimize.md](./gke-compute-classes-optimize.md); for troubleshooting see [gke-compute-classes-debug.md](./gke-compute-classes-debug.md).

> **MCP tools:** `apply_k8s_manifest`, `get_k8s_resource`, `describe_k8s_resource`, `delete_k8s_resource`

## When to use ComputeClasses

- Declarative node configuration + autoscaling priorities for GKE Autopilot, or Standard with NodePoolAutoCreation (NAC) and/or manually created node pools.
- Platform-level abstraction: shields app teams from infra details in podSpecs. Multiple CCCs per cluster; selected via nodeSelector/affinity, or as namespace/cluster default.
- Common landing spot for users migrating from [Karpenter](https://karpenter.sh) — see [gke-compute-classes-karpenter-migration.md](./gke-compute-classes-karpenter-migration.md) for the concept-mapping reference (NodePool → CCC, weight → priority order, drift → activeMigration, etc.).

## Two ways to declare priorities

1. **Intent-based (preferred)** — e.g. `machineFamily: n4`, `minCores: 16`. Describes the *shape* of node you want; GKE picks a fitting node pool.
2. **Node pool reference (Standard only)** — `nodepools: [pool1, pool2]`. Pins to specific pre-existing pools by name.

> **Best practice:** Prefer intent-based. Use `minCores`/`minMemoryGb` rather than a strict `machineType` so GKE has room to substitute.

**Configuration method is independent of provisioning source.** Both methods work with manually-created node pools — you can describe a manual pool *intent-based* (e.g. `machineFamily: n4`, `minCores: 16`) and the autoscaler will match it against the pool's actual shape, just as it would for a NAC-created pool. The `nodepools: [...]` reference is only required when you need to **pin to a named pool by identity** (e.g. excluding other equally-matching pools, or referencing a pool whose shape would otherwise tie with another).

| Configuration method | Manual node pools | NAC (auto-created) |
|----------------------|-------------------|--------------------|
| Intent-based (`machineFamily`, `minCores`, …) | ✅ — autoscaler matches by shape | ✅ — autoscaler creates a fitting pool |
| Node pool reference (`nodepools: [...]`) | ✅ — pin by name | ❌ — NAC pools are ephemeral; their names are autoscaler-managed and can change |

> **Implication:** A CCC that relies exclusively on NAC **cannot** use `nodepools: [...]` anywhere in its priority list — there are no stable pool names to reference. Use intent-based syntax for all NAC priorities. Reserve `nodepools: [...]` for manual pools you control directly.

## NAC vs. manual node pools (provisioning source)

- **NAC** (Node Pool Auto-Creation) extends the cluster autoscaler to provision new pools on demand. Best for obtainability — GKE can try multiple shapes. Cost: provisioning latency. NAC-created pools are **ephemeral**: created, scaled, and removed by the autoscaler, with names you don't pick — so they can't be targeted with `nodepools: [...]`.
- **Manual pools** are faster to schedule onto but limited to what's pre-provisioned. Stable names — eligible for `nodepools: [...]` pinning.
- **Hybrid:** put manual pools at the top of the priority list (intent-based or by name), NAC fallbacks below (intent-based only) — gets latency *and* obtainability.

### Binding a manual node pool to a CCC

Outside the cluster default CCC, manual pools must be labeled and tainted to bind ([docs](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/about-custom-compute-classes#manual-node-pools)). Workloads do **not** need matching tolerations — CCC auto-tolerates.

```bash
gcloud container node-pools update dev-pool \
    --cluster=example-cluster \
    --node-labels="cloud.google.com/compute-class=CLASS-NAME" \
    --node-taints="cloud.google.com/compute-class=CLASS-NAME:NoSchedule"
```

These labels/taints are static on the pool — they're separate from `nodeLabels`/`taints` defined inside the CCC spec (which apply only to NAC-created nodes).

## CRD essentials

Full CRD: `kubectl describe crd computeclasses.cloud.google.com` or [official API reference](https://docs.cloud.google.com/kubernetes-engine/docs/reference/crds/computeclass).

Minimal shape:

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: my-class
spec:
  nodePoolAutoCreation:
    enabled: true        # turn on NAC for this class
  priorities:            # tried top-to-bottom
  - machineFamily: n4
    minCores: 16
    spot: false
  # whenUnsatisfiable defaults to DoNotScaleUp — leave unset unless the
  # workload genuinely accepts "any VM" as a fallback (rare; nginx-style
  # stateless tiers). See table below.
```

Common top-level fields:

| Field | Purpose |
|-------|---------|
| `nodePoolAutoCreation.enabled` | Allow GKE to create pools dynamically |
| `nodePoolConfig` | Defaults for NAC-created pools (image, IP type, SA, labels, taints, image streaming, gVNIC, logging) |
| `priorityDefaults` | Defaults applied to every priority entry (e.g. zones, sysctls) |
| `priorities[]` | Ordered list of provisioning attempts |
| `autoscalingPolicy` | Consolidation thresholds + delay |
| `activeMigration` | Drift workloads back to higher priorities (see optimize doc) |
| `whenUnsatisfiable` | What happens when no priority is satisfiable. **Default: `DoNotScaleUp`** — appropriate for most workloads, since they have specific shape/accelerator/zone requirements. Set `ScaleUpAnyway` only when the workload genuinely accepts any-VM fallback (e.g. stateless web tier with HPA replicas). **What `ScaleUpAnyway` actually picks**: on **Standard with NAC**, it provisions an **E2** node — hardcoded, not configurable, and a poor fit for memory-bound, latency-sensitive, or accelerator workloads. On **Autopilot**, GKE places the pod on any available node. If E2 isn't acceptable as a last resort, leave `whenUnsatisfiable` at the default and accept that pods stay `Pending` when no priority matches. |

Common per-priority fields:

| Field | Purpose |
|-------|---------|
| `machineFamily` / `machineType` | Family (intent) or exact type (strict). Prefer family. |
| `minCores`, `minMemoryGb`, `minCpuPlatform` | Lower bounds GKE must satisfy when picking a shape |
| `spot` | `true` for Spot, `false` for On-Demand |
| `location.zones`, `location.locationPolicy` | Zone list and `ANY` vs `BALANCED` placement |
| `reservations` | `Specific` (named) vs `AnyBestEffort` (see optimize doc — has a fallback gotcha) |
| `flexStart` | Enable DWS FlexStart queued provisioning |
| `gpu` / `tpu` | Accelerator request (count, type, topology, sharing) |
| `podFamily` | Autopilot pod-family targeting (e.g. `general-purpose`, `general-purpose-arm`) |
| `nodepools` | Manual pool refs (Standard only) |
| `placement` | Compact placement policy reference |
| `storage.bootDiskType` | `pd-standard`, `pd-ssd`, `pd-balanced` (Gen 2) or `hyperdisk-balanced`, `hyperdisk-extreme` (Gen 3/4). Must match disk generation of any attached PVs — see gotcha below. |
| `storage.bootDiskSize`, `storage.localSSDCount`, `storage.secondaryBootDisks` | Boot/scratch/cache disks |
| `taints`, `nodeLabels` | Applied to NAC-created nodes only (manual-pool labels are static — see above) |
| `nodeSystemConfig.linuxNodeConfig` | Per-priority kernel tuning: `sysctls`, `transparentHugepageEnabled` (`ALWAYS`/`NEVER`/`MADVISE`), `swapConfig`, `cgroupMode`. Useful for memory-bound or network-heavy workloads (Redis, Postgres, Kafka). Can also be set in `priorityDefaults` to apply to all priorities. |
| `nodeSystemConfig.kubeletConfig` | `cpuManagerPolicy`, `cpuCfsQuota`, `cpuCfsQuotaPeriod`, `podPidsLimit`, plus eviction tunables (`evictionSoft`, `evictionMaxPodGracePeriodSeconds`, …), image-GC tunables (`imageGcLowThresholdPercent`, …), `allowedUnsafeSysctls`, and version-gated fields like `singleProcessOOMKill` (1.34.1+). See callout below for the authoritative allowlist. |

> **⚠️ Sysctl allowlist — verify before recommending.** GKE accepts only a fixed allowlist of sysctl keys under `linuxNodeConfig.sysctls`, grouped as `fs.*`, `kernel.*`, `net.*`, and `vm.*`, each with bounded value ranges. The list evolves with GKE versions. **Before recommending or applying any sysctl, fetch the current allowlist live** from the [ComputeClass CRD reference](https://docs.cloud.google.com/kubernetes-engine/docs/reference/crds/computeclass) (authoritative — what the admission webhook actually accepts) or inspect the cluster's installed CRD with `kubectl describe crd computeclasses.cloud.google.com`. The older [node system configuration doc](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/node-system-config) lists a narrower set; **trust the CRD reference when they disagree** (e.g. `vm.swappiness` is in the CRD allowlist but absent from the node-system-config doc). Do not rely on memory or general-Linux tuning advice — many widely-cited keys are still **not** permitted (notably `kernel.threads-max` and most `net.bridge.*`). Setting an unsupported key surfaces in `status.conditions` (see [debug doc](./gke-compute-classes-debug.md)). Pair this check with the [GKE-version verification](./gke-compute-classes-debug.md#always-check-first-gke-version-vs-feature-requirements) when fields seem silently ignored.

> **⚠️ Kubelet config allowlist — verify before recommending.** Same rule for `nodeSystemConfig.kubeletConfig`: GKE accepts only a fixed set of fields, several of which are **version-gated** (e.g. `containerLogMaxSize`, `containerLogMaxFiles`, image-GC fields → 1.33.4+; `maxParallelImagePulls`, `singleProcessOOMKill` → 1.34.1+). **Before recommending or applying any kubelet config, fetch the current allowlist live** from the [ComputeClass `kubeletConfig` reference](https://docs.cloud.google.com/kubernetes-engine/docs/reference/crds/computeclass#kubeletConfig) (authoritative) or inspect the cluster's installed CRD. Common omissions: `topologyManagerPolicy`, raw `featureGates`, `systemReserved`/`kubeReserved` overrides, and most arbitrary kubelet flags are **not** exposed through this field. Unsupported keys surface in `status.conditions`; version-gated fields on too-old clusters are silently ignored — see [version check](./gke-compute-classes-debug.md#always-check-first-gke-version-vs-feature-requirements).

> **⚠️ CCC ≠ full node-pool API.** Not every field exposed by `gcloud container node-pools create` is reachable through CCC for **NAC-created** pools — CCC's surface area continues to expand but lags the gcloud node-pool API. Before assuming a node-pool capability is available via NAC, cross-check the [CCC CRD reference](https://docs.cloud.google.com/kubernetes-engine/docs/reference/crds/computeclass) against the [gcloud `node-pools create` reference](https://docs.cloud.google.com/sdk/gcloud/reference/container/node-pools/create). If a flag you need isn't expressible in the CRD, the fallback is a **manual node pool** created with the desired flag, bound to the CCC via the static label/taint pair (see "Binding a manual node pool to a CCC" above).

## Starter example: general-purpose default class

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: general-default
spec:
  nodePoolAutoCreation:
    enabled: true
  priorities:
  - machineFamily: n4
    minCores: 16
  - machineFamily: e2
    minCores: 16
```

Pod opts in via:

```yaml
spec:
  nodeSelector:
    cloud.google.com/compute-class: general-default
```

## Validate before applying

Run `kubectl apply --dry-run=server -f <file>.yaml` against the target cluster before applying. Server-side dry-run executes the same admission validation as a real apply (without persisting), so it catches:

- Sysctl / kubelet keys outside the cluster's allowlist
- Version-gated fields on a too-old control plane
- `priorityDefaults.location` colliding with `Specific` reservations
- Schema mismatches between the YAML and the installed CRD

Client-side dry-run (`--dry-run=client`) only checks YAML well-formedness, not the CRD or admission rules — use server-side. If validation passes but the CCC still surfaces issues at runtime, check `status.conditions` (see [debug doc](./gke-compute-classes-debug.md)).

## Worked examples

When you reproduce or adapt any of the patterns below in a response, **cite the asset path** (e.g. `assets/genai-inference-g4-compute-class.yaml`) so the user can pull the canonical version directly. Don't silently mirror the YAML — the asset library is part of the deliverable, not a private reference.

- **Stateful cache (Redis):** [`assets/redis-compute-class.yaml`](../assets/redis-compute-class.yaml) — kernel tuning (THP off, somaxconn), all-Gen-4 disk-gen lock-in, family-axis fallback (c4d → c4 → n4) on Hyperdisk.
- **Stateful primary DB (Postgres):** [`assets/postgres-primary-compute-class.yaml`](../assets/postgres-primary-compute-class.yaml) — single-zone pin for zonal PV affinity, `reservations.affinity: Specific` on the top priority, On-Demand floor, `vm.overcommit_memory: 2` for OOM-killer safety.
- **Stateful broker (Kafka):** [`assets/kafka-broker-compute-class.yaml`](../assets/kafka-broker-compute-class.yaml) — multi-zone, `localSSDCount: 2` for page cache, `vm.max_map_count` and `fs.file-max` raised for many-segment workloads, Hyperdisk durable boot.
- **Stateless, disruption-tolerant Spot tier (serving + batch):** [`assets/spot-cost-tiebreak-compute-class.yaml`](../assets/spot-cost-tiebreak-compute-class.yaml) — Spot-first **cost tie-break** for workloads that tolerate preemption (web serving, batch jobs, async processors): three equal-score Spot families (`e2`, `n2d`, `n4`) at the top let CCC pick the lowest-cost-available among them rather than baking a family ordering into YAML that would rot as Spot pricing shifts. `activeMigration` drifts replicas back from the OD floor when Spot returns — good for serving, drop the block for long-running batch to avoid mid-job restarts. On-Demand floor at score 10. Requires GKE 1.35.2-gke.1842000+.
- **GenAI inference (G4 / RTX PRO 6000 Blackwell):** [`assets/genai-inference-g4-compute-class.yaml`](../assets/genai-inference-g4-compute-class.yaml) — accelerator obtainability chain tuned for serving latency: reservation → Spot → DWS FlexStart → On-Demand. Note the Spot-before-DWS inversion vs. training-style chains (DWS's 3-min queue is unacceptable for online serving).
- **Shared GPU inference (L4 with MPS):** [`assets/shared-l4-inference-compute-class.yaml`](../assets/shared-l4-inference-compute-class.yaml) — multi-tenant low-utilization inference with `gpuSharing.sharingStrategy: MPS` and `maxSharedClientsPerGPU: 4`. Single- and dual-GPU shapes for bin-packing flexibility.
- **TPU v5e training:** [`assets/tpu-v5e-training-compute-class.yaml`](../assets/tpu-v5e-training-compute-class.yaml) — Reservation → On-Demand → Spot for training, with `tpu.type: tpu-v5-lite-podslice`, `count: 8`, `topology: 2x4`. Spot sits below On-Demand because preemption mid-step forces a checkpoint restart; for cost-tolerant batch retries, accept the trade-off. Single-zone since TPU reservations are zonal.
- **Equal-priority tie-breaking (`priorityScore`):** [`assets/equal-priority-tiebreak-compute-class.yaml`](../assets/equal-priority-tiebreak-compute-class.yaml) — stateless web tier with three Gen-4 families tied at score 100, two Gen-2 fallbacks tied at 50, and an e2 floor at 10. Demonstrates the **3-rules-per-score cap**, "all priorities need a score if any do" rule, and unit-cost tie-break. Requires GKE 1.35.2-gke.1842000+.
- **Manual-pool tie-breaking (`nodepools:` list):** [`assets/manual-pool-tiebreak-compute-class.yaml`](../assets/manual-pool-tiebreak-compute-class.yaml) — Standard-cluster hybrid pinning to three equal On-Demand zonal pools, then two equal Spot pools, then a NAC intent-based floor. Multiple pools listed in one priority are all eligible; autoscaler tie-breaks by unit cost.

## Selecting a CCC

- **Per workload:** `nodeSelector: { cloud.google.com/compute-class: <name> }` or matching `affinity`.
- **Namespace default:** label the namespace — `kubectl label namespaces <NS> cloud.google.com/default-compute-class=<name>`. Use `cloud.google.com/default-compute-class-non-daemonset=<name>` to exclude DaemonSets.
- **Cluster default:** two-part — (1) enable the feature on the cluster: `gcloud container clusters update <CLUSTER> --location <LOC> --enable-default-compute-class`, and (2) create a ComputeClass whose `metadata.name` is exactly `default`. There is no per-CCC "is-default" spec field; the literal name `default` is what GKE recognizes.

> **Gotcha:** Don't combine CCC selection with other hard node selectors like `cloud.google.com/gke-spot` or `cloud.google.com/machine-family` — that creates scheduling conflicts. Express those constraints inside the CCC instead.

> **Gotcha (stateful workloads):** Disk generation is a *create-time* constraint that's painful to fix later. Gen 4 VMs (`n4`, `c4`, `c4a`, `c4d`) require **Hyperdisk**; Gen 2 VMs (`n2`, `n2d`, `c2`, `c2d`, `m1`, `m2`) require **Persistent Disk**. If your workload has attached PVs, every priority in the list must use the same disk generation as those PVs — otherwise volume attach fails on the wrong-gen fallback. Boot disks aren't affected. Set `storage.bootDiskType` explicitly per priority (or in `priorityDefaults`) to make this intent visible. See [gke-compute-classes-debug.md](./gke-compute-classes-debug.md) for symptoms.

> **Gotcha (Specific reservation + location):** Don't set `priorityDefaults.location` when any priority uses `reservations.affinity: Specific`. The default propagates to the reservation priority and conflicts with the reservation's own zonal scope, surfacing as `compute-class <name> contains priorities using location config with specific reservations enabled`. Fix: omit `priorityDefaults.location` and instead (a) set `reservations.specific[].zones` on the reservation priority to scope it to the reservation's actual zone(s), and (b) set `location.zones` per-priority on the non-reservation entries. This rule applies to per-priority `location` on a Specific-reservation priority too — not just the default.

> **Reservation blocks:** When a Specific reservation has been partitioned into named blocks, set `reservations.specific[].reservationBlock.name` to consume from a particular block. Plain (non-partitioned) reservations omit this field. Sub-fields of `reservations.specific[]`: `name` (required), `zones`, `project` (cross-project reservations), and `reservationBlock`.

## Where to go next

- Designing the priority list, fallback strategy, GPU/TPU patterns: [gke-compute-classes-optimize.md](./gke-compute-classes-optimize.md)
- Status conditions, autoscaler logs, stockout signals: [gke-compute-classes-debug.md](./gke-compute-classes-debug.md)
