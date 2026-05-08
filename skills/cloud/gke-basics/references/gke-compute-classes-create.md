# GKE ComputeClasses: Create

Authoring a ComputeClass (CCC): concepts, CRD basics, and starter examples. For tuning priority lists see [gke-compute-classes-optimize.md](./gke-compute-classes-optimize.md); for troubleshooting see [gke-compute-classes-debug.md](./gke-compute-classes-debug.md).

> **MCP tools:** `apply_k8s_manifest`, `get_k8s_resource`, `describe_k8s_resource`, `delete_k8s_resource`

## When to use ComputeClasses

- Declarative node configuration + autoscaling priorities for GKE Autopilot, or Standard with Node Auto-Provisioning (NAP).
- Platform-level abstraction: shields app teams from infra details in podSpecs. Multiple CCCs per cluster; selected via nodeSelector/affinity, or as namespace/cluster default.
- Common landing spot for users migrating from [Karpenter](https://karpenter.sh).

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
  whenUnsatisfiable: ScaleUpAnyway   # or DoNotScaleUp
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
| `whenUnsatisfiable` | `ScaleUpAnyway` or `DoNotScaleUp` if no priority matches |

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

> **⚠️ Sysctl allowlist — verify before recommending.** GKE accepts only a fixed allowlist of sysctl keys under `linuxNodeConfig.sysctls`, grouped as `fs.*`, `kernel.*`, `net.*`, and `vm.*`, each with bounded value ranges. The list evolves with GKE versions. **Before recommending or applying any sysctl, fetch the current allowlist live** from the [GKE node system configuration docs](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/node-system-config) (authoritative) or inspect the cluster's installed CRD with `kubectl describe crd computeclasses.cloud.google.com`. Do not rely on memory or general-Linux tuning advice — many widely-cited keys are **not** permitted (notably `vm.swappiness`, `kernel.threads-max`, most `net.bridge.*`). Setting an unsupported key surfaces in `status.conditions` (see [debug doc](./gke-compute-classes-debug.md)). Pair this check with the [GKE-version verification](./gke-compute-classes-debug.md#always-check-first-gke-version-vs-feature-requirements) when fields seem silently ignored.

> **⚠️ Kubelet config allowlist — verify before recommending.** Same rule for `nodeSystemConfig.kubeletConfig`: GKE accepts only a fixed set of fields, several of which are **version-gated** (e.g. `containerLogMaxSize`, `containerLogMaxFiles`, image-GC fields → 1.33.4+; `maxParallelImagePulls`, `singleProcessOOMKill` → 1.34.1+). **Before recommending or applying any kubelet config, fetch the current allowlist live** from the [ComputeClass `kubeletConfig` reference](https://docs.cloud.google.com/kubernetes-engine/docs/reference/crds/computeclass#kubeletConfig) (authoritative) or inspect the cluster's installed CRD. Common omissions: `topologyManagerPolicy`, raw `featureGates`, `systemReserved`/`kubeReserved` overrides, and most arbitrary kubelet flags are **not** exposed through this field. Unsupported keys surface in `status.conditions`; version-gated fields on too-old clusters are silently ignored — see [version check](./gke-compute-classes-debug.md#always-check-first-gke-version-vs-feature-requirements).

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
  whenUnsatisfiable: ScaleUpAnyway
```

Pod opts in via:

```yaml
spec:
  nodeSelector:
    cloud.google.com/compute-class: general-default
```

## Worked examples

- **Stateful cache (Redis):** [`assets/redis-compute-class.yaml`](../assets/redis-compute-class.yaml) — kernel tuning (THP off, somaxconn), all-Gen-4 disk-gen lock-in, family-axis fallback (c4d → c4 → n4) on Hyperdisk.
- **Stateful primary DB (Postgres):** [`assets/postgres-primary-compute-class.yaml`](../assets/postgres-primary-compute-class.yaml) — single-zone pin for zonal PV affinity, `reservations.affinity: Specific` on the top priority, On-Demand floor, `vm.overcommit_memory: 2` for OOM-killer safety.
- **Stateful broker (Kafka):** [`assets/kafka-broker-compute-class.yaml`](../assets/kafka-broker-compute-class.yaml) — multi-zone, `localSSDCount: 2` for page cache, `vm.max_map_count` and `fs.file-max` raised for many-segment workloads, Hyperdisk durable boot.
- **Stateless, Spot-cost-optimized (nginx and similar):** [`assets/nginx-spot-hunt-compute-class.yaml`](../assets/nginx-spot-hunt-compute-class.yaml) — Spot-first hunt across mixed-generation families ordered by us-central1 cost, with `activeMigration` to drift back to cheaper Spot and an On-Demand floor at the bottom.

## Selecting a CCC

- **Per workload:** `nodeSelector: { cloud.google.com/compute-class: <name> }` or matching `affinity`.
- **Namespace default:** label the namespace with `cloud.google.com/default-compute-class=<name>`.
- **Cluster default:** mark a single CCC as cluster-wide default in its spec.

> **Gotcha:** Don't combine CCC selection with other hard node selectors like `cloud.google.com/gke-spot` or `cloud.google.com/machine-family` — that creates scheduling conflicts. Express those constraints inside the CCC instead.

> **Gotcha (stateful workloads):** Disk generation is a *create-time* constraint that's painful to fix later. Gen 4 VMs (`n4`, `c4`, `c4a`, `c4d`) require **Hyperdisk**; Gen 2 VMs (`n2`, `n2d`, `c2`, `c2d`, `m1`, `m2`) require **Persistent Disk**. If your workload has attached PVs, every priority in the list must use the same disk generation as those PVs — otherwise volume attach fails on the wrong-gen fallback. Boot disks aren't affected. Set `storage.bootDiskType` explicitly per priority (or in `priorityDefaults`) to make this intent visible. See [gke-compute-classes-debug.md](./gke-compute-classes-debug.md) for symptoms.

## Where to go next

- Designing the priority list, fallback strategy, GPU/TPU patterns: [gke-compute-classes-optimize.md](./gke-compute-classes-optimize.md)
- Status conditions, autoscaler logs, stockout signals: [gke-compute-classes-debug.md](./gke-compute-classes-debug.md)
