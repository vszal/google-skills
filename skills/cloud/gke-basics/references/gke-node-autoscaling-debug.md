# GKE Node Autoscaling: Debug

Triage when node autoscaling doesn't behave as expected: pending pods, scale-up failures, scale-down stalls, NAP not creating a pool. For enabling autoscaling see [gke-node-autoscaling-enable.md](./gke-node-autoscaling-enable.md); for tuning the profile and consolidation see [gke-node-autoscaling-optimize.md](./gke-node-autoscaling-optimize.md). For CCC-specific issues (status conditions, priority traversal, sysctl/kubelet allowlist failures) see [gke-compute-classes-debug.md](./gke-compute-classes-debug.md).

## First stop: cluster autoscaler visibility logs

When pods stay `Pending` and no node arrives, or scale-down isn't happening, the cluster autoscaler publishes per-decision logs that explain exactly what it tried and why it failed. ([Docs](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cluster-autoscaler-visibility))

**Cloud Logging filter:**

```
log_id("container.googleapis.com/cluster-autoscaler-visibility")
```

**Log shapes you'll inspect:**
- `decision.scaleUp.increasedMigs[]` — successful per-MIG scale-up
- `decision.nodePoolCreated.nodePools[]` — NAP created a new node pool
- `decision.scaleDown.nodesToBeRemoved[]` — successful node removal
- `resultInfo.results[].errorMsg.messageId` — per-MIG scale-up failures
- `noDecisionStatus.noScaleUp.unhandledPodGroups[].rejectedMigs[].reason.messageId` — per-pod-group rejections (which MIGs were considered and why each was rejected)
- `noDecisionStatus.noScaleDown.nodes[].reason.messageId` — per-node scale-down blockers

For a continuous live tail of all of these scoped to a single cluster, use [`assets/log-autoscaler-events.sh <cluster-name>`](../assets/log-autoscaler-events.sh) — polls every 10s, color-prints to terminal. Pass `--errors-only` (`-e`) to suppress successful scale events; pass `--log-file PATH` (`-o PATH`) to also append plain text to a file. Requires `gcloud` and `jq`.

**Pull recent logs ad-hoc:**

```bash
gcloud logging read 'log_id("container.googleapis.com/cluster-autoscaler-visibility")' \
  --freshness=1h --limit=50 --format=json
```

## Common scale-up `messageId` codes

| `messageId` | Meaning | Action |
|-------------|---------|--------|
| `scale.up.error.out.of.resources` | GCE stockout for the requested shape/zone | Add a zone or family fallback (CCC priority list) |
| `scale.up.error.quota.exceeded` | Project quota cap | Raise quota in target region/project (`gcloud compute project-info describe`) |
| `scale.up.error.waiting.for.instances.to.be.created` | Slow provisioning | Often DWS queue; check `flexStart` configuration on the CCC |
| `scale.up.error.ip.space.exhausted` | Subnet IP exhaustion | Expand subnet or secondary range (pod IP range usually) |
| `scale.up.no.scale.up` | No priority / pool matched the pending pod | Check `whenUnsatisfiable`, pod requests, and selectors |

## Pods stuck `Pending` — checklist

Walk the list in order:

1. **`kubectl describe pod <name>`** — read events. Most issues surface here directly (e.g. "0/N nodes available: insufficient cpu", "node(s) had taints…").
2. **Resource requests fit somewhere?** A pod requesting 64 cores can't land on a pool with `--max-nodes` of `n4-standard-16` shapes — autoscaler can't satisfy it.
3. **Selectors / tolerations match the available pools?** Common conflict: pod has `cloud.google.com/gke-spot=true` selector but bound CCC's top priority is On-Demand only. Move constraints into the CCC instead of pinning at the pod level.
4. **Cluster autoscaler enabled on the pool?** `gcloud container node-pools describe <pool> --cluster=<c> --location=<l> --format='value(autoscaling)'` — should show `enabled: true`.
5. **Hit `--max-nodes` already?** `kubectl get nodes --selector='cloud.google.com/gke-nodepool=<pool>' | wc -l` vs. the pool's `maxNodes`.
6. **`PodDisruptionBudget` blocking eviction-driven moves?** Check `kubectl get pdb -A` — overly-tight PDBs can wedge consolidation and re-scheduling.
7. **CCC `whenUnsatisfiable: DoNotScaleUp`** (the default)? By design, won't trigger NAC or fall back to E2 — pod stays Pending if no priority is satisfiable. See [gke-compute-classes-create.md](./gke-compute-classes-create.md).
8. **Visibility logs** for the actual reason (above).

Also check standard Kubernetes events:

```bash
kubectl get events --sort-by=.lastTimestamp -n <namespace>
```

## NAP didn't create a pool

Check, in order:

1. **NAP enabled cluster-wide?**
   ```bash
   gcloud container clusters describe <CLUSTER> --location=<LOC> \
     --format='value(autoscaling.enableNodeAutoprovisioning)'
   ```
   On GKE 1.33.3-gke.1136000+, CCC-scoped NAC works without cluster-level NAP — but on older versions, cluster NAP is required.
2. **CCC has `nodePoolAutoCreation.enabled: true`?** Verify with `kubectl get computeclass <name> -o yaml`.
3. **Cluster-wide resource caps not exhausted?** NAP refuses to create pools that would exceed `--min-cpu`/`--max-cpu`/`--min-memory`/`--max-memory`/`--max-accelerator`. Inspect:
   ```bash
   gcloud container clusters describe <CLUSTER> --location=<LOC> \
     --format='value(autoscaling.resourceLimits)'
   ```
4. **Service account permissions.** NAP-created pools use the SA on `nodePoolConfig.serviceAccount` (or the cluster default Compute SA). Needs `roles/container.nodeServiceAccount` plus any custom IAM for what the workload accesses.
5. **Visibility logs** for the actual error — typically quota, IP exhaustion, or unsupported SKU in the target zone.
6. **Pool count near 200?** Beyond ~200 total pools per cluster, autoscaling latency increases and pool creation may stall. Consolidate near-duplicate CCCs or trim long priority lists.

## Scale-down isn't happening

Symptoms: idle nodes persist, cluster cost stays flat after traffic drops.

For a one-shot scan of the four most common workload-side blockers (`safe-to-evict: false` annotations, bare pods, local-storage pods, tight PDBs), run [`assets/find-scale-down-blockers.sh`](../assets/find-scale-down-blockers.sh) — categorizes offenders so you can prioritize the fix. Pair with `log-autoscaler-events.sh` for the autoscaler's own per-node `noScaleDown.reason` codes.

**Common causes:**

- **`safe-to-evict: "false"` annotation** on a pod sitting on the node. Find offenders:
  ```bash
  kubectl get pods -A -o json | jq -r \
    '.items[] | select(.metadata.annotations["cluster-autoscaler.kubernetes.io/safe-to-evict"]=="false") | "\(.metadata.namespace)/\(.metadata.name)"'
  ```
- **Bare pods** (no controller). Same query without the annotation filter; check `ownerReferences`.
- **Pods with local storage** (emptyDir-on-local-SSD or hostPath PVCs).
- **PDB blocks eviction.** `kubectl get pdb -A` and check `currentHealthy`/`disruptionsAllowed`.
- **`consolidationThreshold`** too high to ever match — if nodes hover at 60% utilization but threshold is 50%, they'll never become candidates. See [optimize doc](./gke-node-autoscaling-optimize.md).
- **`consolidationDelayMinutes`** very long — if delay is 30 min and nodes only stay underutilized for 20 min between bursts, scale-down never fires. Check the pattern in [Cloud Monitoring](./gke-observability.md) before lowering.
- **Maintenance window?** ⚠ This is a *common false belief* — maintenance windows do **not** gate consolidation. They only scope upgrades and node auto-repair. If you actually need time-windowed consolidation suppression, gate at the workload layer with a scheduled PDB tightening.
- **`min-nodes` / `total-min-nodes` > 0** on the pool — autoscaler won't drop below the floor.

For visibility into specific scale-down decisions, the same visibility log filter shows `noScaleDown.nodes[].reason` per node.

### System pods blocking consolidation of expensive nodes

Symptom: a high-cost node (e.g. GPU/TPU host or large compute SKU) refuses to drain because a non-DaemonSet `kube-system` pod (metrics-server, coredns, konnectivity-agent, custom operators in `kube-system`-like namespaces) is sitting on it. Visibility logs show `noScaleDown.nodes[].reason.messageId = "no.scale.down.node.pod.kube.system.unmovable"` or similar.

**Why it happens:** kube-system pods often have no PDB, no controller that tolerates eviction across nodes, or `safe-to-evict: "false"` set defensively. They land on whichever node the scheduler picks first — frequently a large/expensive one — and then pin that node forever.

**Fix — segregate system pods into their own ComputeClass via a namespace default.** Label `kube-system` (and any other infra namespaces) with `cloud.google.com/default-compute-class-non-daemonset=<name>` so non-DaemonSet system pods land on a dedicated, cheap class. The `-non-daemonset` variant leaves DaemonSets alone (they'd otherwise need to run everywhere anyway). This creates automatic workload separation: expensive nodes only host actual workloads, and consolidation can drain them freely.

Full CCC: [`assets/system-pool-compute-class.yaml`](../assets/system-pool-compute-class.yaml). Apply and label:

```bash
kubectl apply -f assets/system-pool-compute-class.yaml
kubectl label namespace kube-system \
  cloud.google.com/default-compute-class-non-daemonset=system-pool
```

**Caveats:**
- The `-non-daemonset` label leaves DaemonSets alone — correct, since CA already ignores DaemonSet-only nodes for scale-down. The pattern targets singleton/Deployment-style system pods.
- Don't apply to pods with hard locality requirements (e.g. node-local agents). Verify with `kubectl get pods -n kube-system -o wide` after rollout that nothing got displaced from where it must run.
- A namespace default is overridden by an explicit pod-level `nodeSelector` — third-party operators that hard-code selectors may need a separate fix (admission webhook or operator config).
- Existing system pods won't reschedule on their own. Either wait for natural restarts, or `kubectl rollout restart deployment -n kube-system <name>` for the offenders.

See [gke-compute-classes-create.md](./gke-compute-classes-create.md#selecting-a-ccc) for namespace-default and cluster-default mechanics.

## Standard CA can't scale to zero

Symptoms: empty manual pool stays at 1 node.

**Cause:** Standard cluster autoscaler does not delete the last node of a manual pool. Only **NAC-managed** pools can be removed entirely when empty (the autoscaler created them, so it can also delete them).

**Fix options:**
- Switch to a CCC with `nodePoolAutoCreation.enabled: true` so the pool is NAC-managed and ephemeral. NAC will scale the pool to zero (and remove it entirely) when no pods are pending.
- **Switch to Autopilot** if pod-billed pricing is acceptable. Autopilot bills per-pod resources, so a cluster with no running workloads costs $0 — no node management at all, and the scale-to-zero question disappears. Especially fitting for dev/test clusters that idle on weekends. See [core-concepts.md](./core-concepts.md) for Autopilot vs Standard tradeoffs.
- Accept the floor — set `--min-nodes=1` and live with one idle node when demand is zero.

## Spot preemption — graceful shutdown signal

EKS and AKS migrants commonly ask whether GKE needs an [AWS Node Termination Handler](https://github.com/aws/aws-node-termination-handler)-style DaemonSet to drain Spot nodes on the preemption notice. **It does not** — kubelet handles this directly. Symptoms that send people here: pods on Spot nodes appearing to die abruptly, `terminationGracePeriodSeconds` not honored on Spot, or migration parity worries.

**Default behavior.** When GCE preempts a Spot VM, the metadata server sets `preempted=TRUE` and an ACPI shutdown signal follows. On GKE, kubelet starts a node-wide graceful shutdown when it sees the signal — a **30-second** window by default — sending SIGTERM to each pod (longest `terminationGracePeriodSeconds` first) and waiting for them to exit before the node terminates. No DaemonSet required.

**Recommended: opt into the 120-second extended grace period** (GKE 1.35.0-gke.1171000+, Standard only, currently Preview). The graceful-shutdown duration is set in the [kubelet system config](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/node-system-config); allowed values are `0`, `30`, or `120` seconds. **For any Spot pool, prefer 120s** — it gives kubelet the maximum window to drain pods and run `preStop` hooks before the node disappears, at no cost when no preemption is happening.

```yaml
# system-config.yaml
kubeletConfig:
  shutdownGracePeriodSeconds: 120
  shutdownGracePeriodCriticalPodsSeconds: 15   # reserved for system pods
```

Apply per node pool on create or update:

```bash
gcloud container node-pools create my-spot-pool \
  --cluster=my-cluster --location=us-central1 \
  --spot \
  --system-config-from-file=system-config.yaml

# Or on an existing pool
gcloud container node-pools update my-spot-pool \
  --cluster=my-cluster --location=us-central1 \
  --system-config-from-file=system-config.yaml
```

**Pod-side knobs.**
- `terminationGracePeriodSeconds` on the pod is **capped** by the kubelet's `shutdownGracePeriodSeconds`. A pod with TGPS=300 on a node with kubelet=120 gets 120.
- Use `preStop` hooks for cleanup work (drain connections, flush buffers) — they run inside the grace window.

**EKS migrant notes.**
- AWS Spot Interruption Notice is 2 min; GKE default is 30s; opt-in extended is 120s. Workloads designed around the AWS 2-min window need to either tolerate a shorter notice or run on a pool with the extended grace enabled.
- AWS Node Termination Handler has no GKE counterpart and isn't needed.

**Caveats.**
- Standard mode only. Autopilot manages Spot termination internally — the kubelet system config surface isn't exposed there.
- The `kubeletConfig.shutdownGracePeriodSeconds` field is not necessarily in the [ComputeClass `nodePoolConfig.kubeletConfig` allowlist](https://docs.cloud.google.com/kubernetes-engine/docs/reference/crds/computeclass) at time of writing. Verify against the live CRD reference before relying on it from a CCC; if it isn't listed, configure on a manual pool bound to the CCC via `nodepools: [...]` and let NAC fall through.
- The Compute Engine [`preemptionNoticeDuration`](https://docs.cloud.google.com/compute/docs/instances/spot) flag (`--preemption-notice-duration=120s` on raw VMs) governs the metadata-signal-to-ACPI window — **a separate concept** from the kubelet's pod-drain grace. On GKE, the kubelet `shutdownGracePeriodSeconds` is the operative knob; you don't need (and can't easily set) the CE-level preemption notice on GKE-managed nodes.

See:
- [GKE Spot VMs concepts](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/spot-vms)
- [Customize node system configuration](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/node-system-config)
- [Compute Engine Spot preemption notice (Preview)](https://docs.cloud.google.com/compute/docs/instances/spot)

## Backoff loops at the top of a CCC priority list

Symptom: lower priorities never get tried; pods stay Pending despite obtainable shapes lower in the list.

**Causes:**
- **Too many priorities (>~10).** Upper-tier backoffs expire before traversal reaches the bottom; the list loops back to the top. Trim.
- **Slow provisioning or delayed stockout signals.** Backoff state is lost and traversal restarts. Reduce zones/shapes per priority or consolidate similar entries.
- **Repeated identical rules.** They don't help and waste backoff slots.

Full triage flow with status-condition mapping is in [gke-compute-classes-debug.md](./gke-compute-classes-debug.md#backoff-loops-at-the-top-of-the-priority-list).

## "ANY" reservation bypassing CCC fallbacks

Symptom: workload lands on On-Demand even though lower CCC priorities should have been tried first.

**Cause:** `reservations.affinity: AnyBestEffort` falls back to On-Demand at the **GCE layer**, before CCC sees the failure. CCC never advances to the next priority.

**Fix:** use `affinity: Specific` with named reservations, or accept the bypass intentionally. See [gke-compute-classes-debug.md](./gke-compute-classes-debug.md).

## Cluster autoscaler is slow / unresponsive

Symptoms: scale-up decisions take minutes longer than expected; pods queue even when capacity is available somewhere; visibility logs show long gaps between decision cycles.

**Workload-side causes** (most common — these dominate the autoscaler's per-cycle work):

- **Heavy required pod (anti-)affinity.** `requiredDuringSchedulingIgnoredDuringExecution` rules — especially anti-affinity across many pods — explode the scheduler's per-pod evaluation cost. Every candidate node gets checked against every existing pod's affinity. Convert to `preferredDuringScheduling…` where possible, or use `topologySpreadConstraints` (cheaper than full affinity for spread).
- **Strict `topologySpreadConstraints` with `whenUnsatisfiable: DoNotSchedule`.** Forces the scheduler to enumerate all topology domains for every placement. Use `ScheduleAnyway` unless you genuinely need the hard guarantee.
- **Workload separation via taints/tolerations alone.** Without a matching `nodeSelector`, the scheduler considers every node and rejects most by taint — wasted work at scale. Always pair taints with a positive selector (label or `nodeSelector: cloud.google.com/compute-class: <name>` via CCC).
- **Watch-heavy controllers / Secret automount.** Each mounted Secret creates a watch on every node. Many DaemonSets compound this. The autoscaler shares the same API server load — apiserver pressure delays decisions. Disable service-account automount on pods that don't need API access, and audit third-party operators for LIST-heavy patterns.
- **Many DaemonSets.** Each one shrinks allocatable per node and adds per-node objects the autoscaler must reason about.

**Cluster-side causes:**

- **Pool count near 200.** See "Pool count creep" below.
- **Cluster size approaching the autoscaler ceiling.** Cluster autoscaler **is not supported beyond 5,000 nodes** — for larger clusters you must scale node pools manually via the GKE API. The hard cluster cap is **15,000 nodes** (quota increase required); 65,000 nodes is supported on GKE 1.31+ for AI workloads (also via quota).
- **Pod-throughput limits.** Up to ~500 nodes: ~20 pods created/deleted per second. Beyond 500 nodes: ~100 pods per second. Tight PDBs and long termination grace periods can saturate this and stall autoscaling rounds.

**Triage order:**

1. `kubectl get pods -A -o json | jq '[.items[] | select(.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution)] | length'` — count required anti-affinity offenders.
2. `kubectl get nodes -o json | jq '[.items[].metadata.labels | length] | add'` — total label cardinality across nodes (high values can degrade scheduler performance).
3. `gcloud container node-pools list --cluster=<c> --location=<l> | wc -l` — pool count vs. the 200 ceiling.
4. Visibility logs (above) — look at decision cycle frequency. Long gaps between `decision` events suggest the autoscaler is busy rather than idle.

## Pool count creep

Symptom: cluster has 100+ node pools, autoscaling is sluggish, NAP errors increasing.

**Cause:** Beyond ~200 pools per cluster the autoscaler's per-cycle work grows enough to slow scaling decisions. Common drivers:
- Many CCCs with NAC, each creating distinct shapes per zone.
- Long priority lists multiplied across CCCs.
- Old manual pools that are no longer used.

**Fix:**
- `gcloud container node-pools list --cluster=<c> --location=<l>` and prune unused pools.
- Consolidate near-duplicate CCCs (same shape, different name).
- Trim priority lists to <10 entries — long lists rarely improve outcomes (see [optimize doc](./gke-compute-classes-optimize.md)).

## Useful commands

```bash
# Cluster autoscaling settings (profile, NAP, resource limits)
gcloud container clusters describe <CLUSTER> --location=<LOC> \
  --format='yaml(autoscaling)'

# Node pool autoscaling status (min/max/current/location-policy)
gcloud container node-pools describe <POOL> --cluster=<CLUSTER> --location=<LOC> \
  --format='yaml(autoscaling,locations)'

# Live tail all autoscaler decisions for a cluster (color terminal output)
./assets/log-autoscaler-events.sh <cluster-name>

# Errors-only, with file output
./assets/log-autoscaler-events.sh --errors-only --log-file errors.log <cluster-name>

# One-shot scan for the 4 common workload-side scale-down blockers
./assets/find-scale-down-blockers.sh
./assets/find-scale-down-blockers.sh -n my-namespace

# Last hour of visibility logs as JSON
gcloud logging read 'log_id("container.googleapis.com/cluster-autoscaler-visibility")' \
  --freshness=1h --limit=50 --format=json

# Which CCC each node belongs to
kubectl get nodes -L cloud.google.com/compute-class

# Pending pods with why
kubectl get pods -A --field-selector=status.phase=Pending
kubectl describe pod <name> -n <ns>
```

## Where to go next

- Enable CA / NAP / NAC, golden-path defaults: [gke-node-autoscaling-enable.md](./gke-node-autoscaling-enable.md)
- Tune autoscaling profile, consolidation thresholds, location policy: [gke-node-autoscaling-optimize.md](./gke-node-autoscaling-optimize.md)
- CCC-specific: status.conditions, sysctl/kubelet allowlist, version gating, disk-gen mismatch: [gke-compute-classes-debug.md](./gke-compute-classes-debug.md)
- Pod-level autoscaling debug (HPA not scaling, VPA recommendations): [gke-workload-autoscaling.md](./gke-workload-autoscaling.md)
