# GKE ComputeClasses: Debug

Triage CCC config errors, scale-up failures, and scheduling conflicts. For authoring see [gke-compute-classes-create.md](./gke-compute-classes-create.md); for priority list design see [gke-compute-classes-optimize.md](./gke-compute-classes-optimize.md).

## Always check first: GKE version vs. feature requirements

Many CCC fields are gated on a minimum GKE control plane / node version. If a field appears to be **silently ignored**, accepted but never honored, or surfaces a "field not supported" error in `status.conditions`, the cluster is likely below the version that introduced it. Examples that have shipped at different times: `priorityScore` (1.35.2-gke.1842000+), `activeMigration`, `flexStart`, `podFamily`, `confidentialNodeType`, certain `nodeSystemConfig` keys, and Hyperdisk options.

Verify against the source of truth before assuming a config bug:

```bash
# Cluster's installed CRD definition (authoritative for what THIS cluster accepts)
kubectl describe crd computeclasses.cloud.google.com
kubectl get crd computeclasses.cloud.google.com -o yaml | less

# Control plane and node versions
gcloud container clusters describe <CLUSTER> --location <LOC> \
  --format="value(currentMasterVersion,currentNodeVersion)"
```

Also see the [official ComputeClass API reference](https://docs.cloud.google.com/kubernetes-engine/docs/reference/crds/computeclass) for the per-field "Available in GKE version" notes. If the field exists in the public docs but not in your cluster's CRD, you need a control-plane upgrade.

## First stop: `status.conditions`

The CCC object publishes health and reason codes to its status:

```bash
kubectl describe ComputeClass <CLASS-NAME>
# or
kubectl get computeclass <CLASS-NAME> -o yaml
```

Look at `status.conditions[].reason` and `.message` — these surface invalid spec, NAC permission issues, and unsupported field combinations directly.

Common config errors and their fixes:

| Error message | Cause | Fix |
|---------------|-------|-----|
| `compute-class <name> contains priorities using location config with specific reservations enabled` | A priority with `reservations.affinity: Specific` has a `location` block, either set per-priority or inherited from `priorityDefaults.location` | Omit `location` on the reservation priority. Put the reservation's zonal scope in `reservations.specific[].zones`, and set `location.zones` per-priority only on the non-reservation entries. |

## Scale-up failures (stockout, quota, exhaustion)

When pods stay `Pending` and no node arrives, the answer is in **cluster autoscaler visibility logs** ([docs](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cluster-autoscaler-visibility)).

Cloud Logging filter:

```
log_id("container.googleapis.com/cluster-autoscaler-visibility")
```

Inspect `resultInfo.results.errorMsg.messageId` — it tells you exactly which MIG failed and why. Common message IDs:

| `messageId` | Meaning | Action |
|-------------|---------|--------|
| `scale.up.error.out.of.resources` | GCE stockout for that shape/zone | Add zone or family fallback in CCC |
| `scale.up.error.quota.exceeded` | Project quota cap | Raise quota in target region/project |
| `scale.up.error.waiting.for.instances.to.be.created` | Slow provisioning | Possibly DWS queue; verify timing |
| `scale.up.error.ip.space.exhausted` | Subnet IP exhaustion | Expand subnet / secondary range |
| `scale.up.no.scale.up` | No priority matched | Check `whenUnsatisfiable` and pod requests |

For a continuous live tail of all autoscaler decisions — successful scale-ups, NAP node-pool creations, scale-downs, plus failures (`resultInfo.results.errorMsg`) and stalls (`noDecisionStatus.noScaleUp` / `noScaleDown`) — use [`assets/log-autoscaler-events.sh <cluster-name>`](../assets/log-autoscaler-events.sh). Polls every 10s, scopes the filter to one cluster, color-prints to terminal. Add `--errors-only` (or `-e`) to suppress successes, and `--log-file PATH` (or `-o PATH`) to also append plain text to a file. Requires `gcloud` and `jq`. Useful when you're watching a CCC roll out and want decisions surfaced as they happen.

Also check standard Kubernetes events:

```bash
kubectl get events --sort-by=.lastTimestamp -n <ns>
kubectl describe pod <pending-pod>
```

## Pods stuck `Pending` despite available CCC

Walk the checklist:

1. **Selector match** — pod has `nodeSelector: cloud.google.com/compute-class: <name>` (or namespace/cluster default applies)?
2. **Conflicting hard selectors** — pod also pins `cloud.google.com/gke-spot` or `cloud.google.com/machine-family`? That conflicts with CCC scheduling. Move those constraints into the CCC spec instead.
3. **Resource requests** — pod requests something no priority can satisfy (e.g. 64 cores when all priorities use `minCores: 16` on small families)?
4. **Taints on manual pools** — manual node pools bound to a CCC need the static label/taint pair (see create doc). Missing label → CCC won't schedule there.
5. **`whenUnsatisfiable: DoNotScaleUp`** — by design, won't trigger NAC. Switch to `ScaleUpAnyway` if you want fallback.

## Backoff loops at the top of the priority list

Symptom: lower priorities never get tried.

Causes:
- **Too many priorities (>~10).** Upper-tier backoffs expire before traversal reaches the bottom; the list loops back to the top. Trim the list.
- **Slow provisioning or delayed stockout signals.** Backoff state is lost, and traversal restarts. Reduce the number of zones/shapes per priority, or consolidate similar entries.
- **Repeated identical rules.** They don't help and waste backoff slots.

## "ANY" reservation bypassing CCC fallbacks

Symptom: workload lands on On-Demand even though lower priorities should have been tried.

Cause: `reservations.affinity: AnyBestEffort` falls back to On-Demand at the **GCE layer**, before CCC sees the failure. CCC never advances to the next priority.

Fix: use `affinity: Specific` with named reservations, or accept this behavior intentionally.

## Disk generation mismatch (stateful workloads)

Symptom: pod with attached PV can't bind on a fallback node, or volume attach fails.

Cause: Gen 4 VMs require **Hyperdisk**; Gen 2 require **Persistent Disk**. Mixing Gen 4 / Gen 2 in priorities for a workload with PD-backed PVs breaks attachment on the wrong generation.

Fix: keep priorities within one disk-generation family for stateful workloads, or migrate the volume to Hyperdisk.

## DWS FlexStart timing surprises

- Default queue: ~3 min for GPUs and H4D — not instant.
- Shortening `maxRunDurationSeconds` does **not** speed obtainability.
- `capacityCheckWaitTimeSeconds` controls how long DWS waits before failing over — verify it's long enough for your queue.

## NAC didn't create a pool

Check, in order:
1. `nodePoolAutoCreation.enabled: true` on the CCC.
2. Cluster has NAP / Autopilot enabled (NAC requires it).
3. Service account on `nodePoolConfig.serviceAccount` (or default Compute SA) has `roles/container.nodeServiceAccount` and any required custom roles.
4. Cluster autoscaler logs (filter above) for the actual error — usually quota or IP exhaustion.

## Useful commands

```bash
# Inspect a CCC
kubectl describe ComputeClass <name>

# See which CCC a node belongs to
kubectl get nodes -L cloud.google.com/compute-class

# Find pods that selected a given CCC
kubectl get pods -A -o json | jq -r \
  '.items[] | select(.spec.nodeSelector["cloud.google.com/compute-class"]=="<name>") | .metadata.namespace+"/"+.metadata.name'

# Pull cluster autoscaler visibility logs (last hour)
gcloud logging read 'log_id("container.googleapis.com/cluster-autoscaler-visibility")' \
  --freshness=1h --limit=50 --format=json
```
