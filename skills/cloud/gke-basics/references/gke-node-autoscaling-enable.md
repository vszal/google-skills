# GKE Node Autoscaling: Enable

Turning on node-level scaling: cluster autoscaler (CA) on a pool, Node Auto-Provisioning (NAP) cluster-wide, and Node Pool Auto-Creation (NAC) per ComputeClass. For tuning the autoscaling profile, consolidation thresholds, and `autoscalingPolicy` see [gke-node-autoscaling-optimize.md](./gke-node-autoscaling-optimize.md). For triage when scaling doesn't happen see [gke-node-autoscaling-debug.md](./gke-node-autoscaling-debug.md). Authoritative concepts: [Cluster autoscaler](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler), [Node auto-provisioning](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/node-auto-provisioning).

> **MCP tools:** `get_cluster`, `update_cluster`, `update_node_pool`

> **Best practice — wrap node autoscaling in a ComputeClass.** For any cluster that uses node autoscaling (manual pools, NAC, or hybrid), express the configuration as a CCC. CCC gives you intent-based machine selection, ordered fallbacks (`priorities[]`), per-class consolidation tuning (`autoscalingPolicy`), and selective NAC enablement (`nodePoolAutoCreation.enabled`) — none of which the cluster-wide autoscaler / NAP knobs express on their own. Reach for the cluster-level flags below to turn capabilities **on** or set global caps; everything else belongs in a CCC. See [gke-compute-classes-create.md](./gke-compute-classes-create.md).

## Mechanism map

| Mechanism | Scope | What it does | Configured via |
|-----------|-------|--------------|----------------|
| **Cluster autoscaler (CA)** | Per node pool | Adds/removes **nodes** within an existing pool's `[min, max]` | `--enable-autoscaling --min-nodes --max-nodes` on `gcloud container node-pools create/update` |
| **Autoscaling profile** | Cluster-wide | Bias toward availability vs. utilization (controls how aggressively CA scales down) | `--autoscaling-profile balanced\|optimize-utilization` on `gcloud container clusters update` (see optimize doc) |
| **Node Auto-Provisioning (NAP)** | Cluster-wide | Lets CA create **new node pools** to fit pending pods, within cluster-wide CPU/memory/GPU caps | `--enable-autoprovisioning --min-cpu --max-cpu --min-memory --max-memory ...` on `gcloud container clusters create/update` |
| **Node Pool Auto-Creation (NAC)** | Per ComputeClass | Same capability as NAP, but **scoped to a CCC** so different workloads can have different rules | `nodePoolAutoCreation.enabled: true` in a ComputeClass |
| **CCC `autoscalingPolicy`** | Per ComputeClass | Per-class consolidation tuning — overrides the cluster-wide profile defaults for nodes that belong to the class | `spec.autoscalingPolicy` in a ComputeClass (see optimize doc) |

> **Autopilot:** CA, NAP, and node management are always on and managed by GKE. The flags below apply to **Standard** clusters. Autopilot users still get the most leverage from ComputeClasses for fallbacks and per-class tuning.

> **"NAP" is overloaded across clouds.** GKE NAP (above) is the cluster-wide auto-provisioner. **AKS NAP** (Azure) is Karpenter-on-Azure — a per-NodePool CRD with a different API surface and configuration model. Map AKS NAP NodePools to a GKE **CCC with `nodePoolAutoCreation.enabled: true`**, not to GKE NAP. See [Karpenter migration](./gke-compute-classes-karpenter-migration.md) for the field-by-field translation.

## Cluster autoscaler on a node pool

Resizes a pool between `--min-nodes` and `--max-nodes` based on pending pods (scale-up) and node utilization (scale-down). Operates per pool — each pool has its own `[min, max]`.

**Scale-up trigger:** pending pods that can't fit anywhere; CA picks a pool whose template would satisfy the pod and grows it.

**Scale-down trigger:** node stays under the utilization threshold for ~10 min and its pods can be rescheduled. Blocked by bare pods, local storage, `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`, PDB violations, and pod affinity that pins to that node. (See debug doc.)

**Caveats:**
- 15,000-node cluster cap.
- Standard CA cannot scale a manual pool to **zero** — must keep ≥1 node. Only NAC-managed pools can be deleted entirely when empty. (Autopilot sidesteps this question entirely — pod-billed pricing means $0 idle.)
- `--total-min-nodes` / `--total-max-nodes` set a *cluster-total* cap across zones (1.24+) — alternative to per-zone `--min-nodes` / `--max-nodes`.
- **`--total-max-nodes` caps the pool it's set on, not the cluster.** There is **no cluster-wide node-count cap** — cluster size is bounded indirectly by NAP `--max-cpu` / `--max-memory` / `--max-accelerator` divided by the smallest fitting shape, plus the sum of per-pool `--max-nodes` for manual pools. NAC-created pools each have their own autoscaler-managed max within the cluster-wide NAP caps.

**Enable on a new pool:**

```bash
gcloud container node-pools create my-pool \
  --cluster=my-cluster --location=us-central1 \
  --enable-autoscaling --min-nodes=1 --max-nodes=10 \
  --machine-type=n4-standard-8
```

**Enable on an existing pool:**

```bash
gcloud container clusters update my-cluster --location=us-central1 \
  --enable-autoscaling --node-pool=my-pool \
  --min-nodes=1 --max-nodes=10
```

**Use total-node bounds (preferred for regional clusters):**

```bash
gcloud container node-pools create my-pool \
  --cluster=my-cluster --location=us-central1 \
  --enable-autoscaling \
  --total-min-nodes=3 --total-max-nodes=30 \
  --location-policy=BALANCED \
  --machine-type=n4-standard-8
```

`--location-policy=BALANCED` (vs. `ANY`) keeps node counts even across zones — important for HA workloads. `ANY` minimizes provisioning latency and tolerates uneven distribution. See [optimize doc](./gke-node-autoscaling-optimize.md) for when to pick which.

## Node Auto-Provisioning (NAP) — cluster-wide

NAP extends CA: when no existing pool can host a pending pod, NAP creates a **new node pool** sized for that pod, within cluster-wide resource caps. NAP-created pools are ephemeral — CA can delete them when empty.

> **Prefer NAC via ComputeClass over cluster-wide NAP** for everyday workload-shape decisions. Cluster-wide NAP is the right tool for setting **global caps** on a cluster (max CPU, max memory, max GPU) — those caps don't live in any CCC.

**Enable NAP cluster-wide** (Standard only; Autopilot manages it implicitly):

```bash
# At cluster create
gcloud container clusters create my-cluster \
  --location=us-central1 \
  --enable-autoprovisioning \
  --min-cpu=4 --max-cpu=200 \
  --min-memory=16 --max-memory=800

# On an existing cluster
gcloud container clusters update my-cluster --location=us-central1 \
  --enable-autoprovisioning \
  --min-cpu=4 --max-cpu=200 \
  --min-memory=16 --max-memory=800
```

**Add GPU caps:**

```bash
gcloud container clusters update my-cluster --location=us-central1 \
  --enable-autoprovisioning \
  --max-accelerator=type=nvidia-l4,count=8 \
  --max-accelerator=type=nvidia-h100-80gb,count=16
```

**Advanced config** (`--autoprovisioning-config-file=<file>`) covers identity defaults, upgrade settings (`--autoprovisioning-max-surge-upgrade`, `--autoprovisioning-max-unavailable-upgrade`), service account (`--autoprovisioning-service-account`), CMEK keys, image type, and `--autoprovisioning-locations`.

**Limitations of NAP-created pools:**
- Per-pool `min-nodes > 0` is not allowed (conflicts with the empty-pool deletion model).
- Unsupported: GKE Sandbox, Windows nodes, local PersistentVolumes, modified scheduling filters, SMT/PMU controls.
- Beyond ~200 total node pools per cluster, autoscaling latency increases.

## NAC via ComputeClass — preferred for per-workload control

`nodePoolAutoCreation.enabled: true` on a ComputeClass gives you the same auto-creation capability **scoped to that class**, with two big advantages over cluster-wide NAP:

1. **Selective enablement.** One CCC can use NAC; another can pin to manual pools only. Cluster-wide NAP applies to every pending pod that doesn't fit existing pools.
2. **Intent-based shape selection.** The CCC priority list (`machineFamily`, `minCores`, `gpu`, fallbacks) drives what NAC provisions — far richer than NAP's bare resource caps.

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: batch-pool
spec:
  nodePoolAutoCreation:
    enabled: true                    # NAC for this class only
  priorities:
  - machineFamily: n4
    spot: true
    minCores: 16
  - machineFamily: n4                # OD floor
    spot: false
    minCores: 16
```

**GKE 1.33.3-gke.1136000+:** ComputeClass-scoped NAC works **without** cluster-level NAP enabled. On older versions, you must turn on cluster-wide NAP first for `nodePoolAutoCreation.enabled` to take effect.

> **NAC shape sizing scales with the cluster.** When NAC creates a pool from an intent-based priority (e.g. `machineFamily: n4`, `minCores: 16`), it picks the shape based on **overall cluster size** — biasing larger as the cluster grows so bin packing stays efficient at scale. Small clusters get small NAC pools; large clusters get larger ones. If you need a strict shape, pin via `machineType`. If you want NAC to scale up the shape with the cluster, use `machineFamily` + `minCores` (the usual choice).

> **Decision rule:** Default to CCC-scoped NAC. Enable cluster-wide NAP **also** when you need a global cap on cluster CPU/memory/accelerator consumption — caps live on the cluster object, not in any CCC. The two compose: CCCs use NAC inside the cluster-wide NAP caps.

For the full CCC authoring surface (CRD fields, manual-pool binding, selecting a class) see [gke-compute-classes-create.md](./gke-compute-classes-create.md).

## Cutover: cluster-wide NAP → CCC-scoped NAC

Common migration on existing clusters: cluster-wide NAP has been managing pool creation for a while; you want to introduce per-workload CCCs (different shape/fallback rules per class) without disruption. Order of operations:

1. **Apply CCCs.** `kubectl apply -f <ccc>.yaml` for each class with `nodePoolAutoCreation.enabled: true` and the priority list you want. On GKE 1.33.3-gke.1136000+ this works without cluster NAP enabled, but leaving NAP on during cutover is fine and gives you a safety net.
2. **Opt workloads in.** Either per-pod (`nodeSelector: cloud.google.com/compute-class: <name>`), per-namespace (`kubectl label namespaces <ns> cloud.google.com/default-compute-class=<name>`), or cluster-wide via the `default` CCC. New pods land on CCC-managed nodes; existing nodes don't migrate automatically.
3. **Drain old NAP-managed pools.** For each pool you want gone, `kubectl drain <node>` (one node at a time, respecting PDBs) or `gcloud container node-pools delete <pool>` once empty. Or rely on natural turnover (rolling restarts, preemptions) to drift workloads onto the new CCC nodes — slower but no manual disruption.
4. **Verify.** `kubectl get nodes -L cloud.google.com/compute-class` should show every node tagged with the expected class.
5. **Decide on cluster NAP.** Keep it enabled if you need cluster-wide caps on CPU/memory/accelerators (those don't live in any CCC). Disable it (`gcloud container clusters update <c> --no-enable-autoprovisioning`) if you don't — cleaner mental model and the CCC-scoped NAC fully replaces it for shape decisions.

> **Existing nodes don't drift to new CCCs.** Step 3 is the part most easily skipped. After steps 1–2 you'll have a cluster where new pods land on CCC nodes but old NAP nodes hang around indefinitely (their pods are running and eviction isn't triggered). The cutover isn't complete until those nodes are drained or naturally turn over.

## Choosing manual pools, NAC, or hybrid

| Approach | Strengths | Weaknesses | When to pick |
|----------|-----------|------------|--------------|
| **Manual pools only** | Stable names (eligible for `nodepools: [...]` pinning); fast scheduling (no pool-creation latency) | Limited to pre-provisioned shapes; obtainability brittle on stockout | Latency-sensitive serving with stable shape; pools you need to inspect/manage by name |
| **NAC only (CCC)** | Best obtainability — GKE tries multiple shapes; no idle pools when demand is zero | Pool-creation latency on each new shape; ephemeral pool names (no `nodepools: [...]` refs) | Bursty workloads; broad fallback chains; cost-sensitive batch |
| **Hybrid (preferred)** | Manual pool at the top of the priority list for the fast path; NAC fallbacks below for obtainability | Slightly more to manage | Most production workloads — see Pattern 3 in [gke-compute-classes-optimize.md](./gke-compute-classes-optimize.md). If pending-pod latency on traffic spikes is also a concern, layer a [Capacity Buffer](./gke-node-autoscaling-optimize.md#capacity-buffers--pre-warm-capacity-for-faster-scale-up) on top of the hybrid CCC. |

See the [create doc's NAC vs. manual section](./gke-compute-classes-create.md#nac-vs-manual-node-pools-provisioning-source) for the full comparison and the bind-with-label/taint pattern for manual pools.

## Golden-path quick recipe

```bash
# Standard cluster with NAP, optimize-utilization profile, and golden-path defaults.
# Layer ComputeClasses on top to express per-workload shape and fallback intent.
gcloud container clusters create my-cluster --location=us-central1 \
  --enable-autoprovisioning \
  --min-cpu=4 --max-cpu=200 \
  --min-memory=16 --max-memory=800 \
  --autoscaling-profile=optimize-utilization \
  --release-channel=regular
```

```bash
# Migrate a manually-managed pool to autoscaling
gcloud container clusters update my-cluster --location=us-central1 \
  --enable-autoscaling --node-pool=existing-pool \
  --total-min-nodes=2 --total-max-nodes=20
```

```bash
# Add a CCC to an existing autoscaled cluster (preferred long-term shape)
kubectl apply --dry-run=server -f my-class.yaml   # validate first
kubectl apply -f my-class.yaml
```

Workloads opt in via `nodeSelector: cloud.google.com/compute-class: <name>` (or namespace/cluster default). See [gke-compute-classes-create.md](./gke-compute-classes-create.md#selecting-a-ccc).

## Where to go next

- Tuning the autoscaling profile, consolidation, location policy: [gke-node-autoscaling-optimize.md](./gke-node-autoscaling-optimize.md)
- Pending pods, scale-up errors, NAP not creating a pool: [gke-node-autoscaling-debug.md](./gke-node-autoscaling-debug.md)
- ComputeClass authoring (priority lists, manual-pool binding): [gke-compute-classes-create.md](./gke-compute-classes-create.md)
- Pod-level autoscaling (HPA, VPA): [gke-workload-autoscaling.md](./gke-workload-autoscaling.md)
