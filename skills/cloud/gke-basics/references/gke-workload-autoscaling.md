# GKE Workload Autoscaling

Pod-level autoscaling on GKE: HPA, VPA, and rightsizing. For node-level autoscaling (cluster autoscaler, NAP, NAC, ComputeClass autoscalingPolicy) see [gke-node-autoscaling.md](./gke-node-autoscaling.md). The golden path enables VPA by default — see [gke-golden-path.md](./gke-golden-path.md).

> **MCP Tools:** `get_k8s_resource`, `describe_k8s_resource`, `apply_k8s_manifest`, `patch_k8s_resource`

## Mechanisms at a glance

| Mechanism | Adjusts | When to use |
|-----------|---------|-------------|
| **Manual scale** | Replica count (one-shot) | Quick fix or experiments |
| **HPA** | Replica count (continuous, metrics-driven) | Stateless services with horizontal scaling |
| **VPA** | CPU / memory **requests** (and limits) | Rightsizing, single-replica or memory-bound workloads |

> HPA and VPA can coexist on the same workload, but **not on the same metric**. Common pattern: HPA on CPU, VPA on memory (set `controlledResources: ["memory"]`).

## 1. Manual scaling

> **kubectl-only** — no MCP equivalent for `kubectl scale`.

```bash
kubectl scale deployment <DEPLOYMENT> --replicas=<N> -n <NAMESPACE>
```

## 2. Horizontal Pod Autoscaler (HPA)

Scales replicas based on CPU, memory, or custom/external metrics.

**Quick setup** (kubectl-only — no MCP equivalent for `kubectl autoscale`):

```bash
kubectl autoscale deployment <DEPLOYMENT> --cpu-percent=50 --min=1 --max=10
```

**Manifest** (preferred — apply via MCP `apply_k8s_manifest`). Template: [`assets/hpa-example.yaml`](../assets/hpa-example.yaml).

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: <DEPLOYMENT>-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: <DEPLOYMENT>
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
```

**Tuning:**

- HPA needs accurate `resources.requests` on the target pods — utilization is computed against requests.
- Default stabilization window is 5 minutes for scale-down. Tune `behavior.scaleDown.stabilizationWindowSeconds` for faster response.
- For external metrics (queue depth, RPS), use `type: External` or `type: Pods` with a custom metrics adapter.
- Pair every HPA target with a `PodDisruptionBudget` so scale-down events don't violate availability — see [gke-reliability.md](./gke-reliability.md).

## 3. Vertical Pod Autoscaler (VPA)

Adjusts CPU and memory **requests** (and optionally limits) based on observed usage. Enabled by default on Autopilot / golden path clusters.

**Update modes:**

| Mode | Behavior |
|------|----------|
| `Off` | Recommendations only. **Start here** for new workloads. |
| `Initial` | Sets resources at pod creation only — won't restart running pods. |
| `Auto` | Restarts pods to apply new requests. Requires ≥2 replicas (eviction safety). |
| `InPlaceOrRecreate` | Updates resources without restart when possible (GKE 1.34+). Falls back to `Auto`. |

**Recommendation-mode VPA** (template: [`assets/vpa-example.yaml`](../assets/vpa-example.yaml)):

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: <DEPLOYMENT>-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: <DEPLOYMENT>
  updatePolicy:
    updateMode: "Off"
```

**Read recommendations** (prefer MCP `describe_k8s_resource`):

```bash
# kubectl fallback
kubectl get vpa <DEPLOYMENT>-vpa -o jsonpath='{.status.recommendation}'
```

## Rightsizing workflow

1. Deploy VPA in `Off` mode for **24+ hours** (longer for bursty workloads — capture peaks).
2. Read `status.recommendation.containerRecommendations[].target`.
3. Compare against current `resources.requests`.
4. Apply with a buffer: `new_request = target * 1.2`.
5. Patch the Deployment (use MCP `patch_k8s_resource` for in-place edits).

| Condition | Recommendation | Risk |
|-----------|----------------|------|
| CPU request > 5× P95 actual | Reduce to `P95 × 1.2` | Medium |
| Memory request > 3× P95 actual | Reduce to `P95 × 1.2` | Medium |
| CPU request > 2× P95 actual | Rightsize with 20% buffer | Low |
| No `resources.limits` set | Add limits to prevent noisy-neighbor | Low |

## Best practices

1. **Always set `resources.requests`.** HPA, VPA, scheduler, and the cluster autoscaler all key off requests.
2. **No metric overlap between HPA and VPA.** Use `VerticalPodAutoscaler.spec.resourcePolicy.containerPolicies[].controlledResources` to scope VPA.
3. **PodDisruptionBudget on every production workload.** Scaling events (HPA down, VPA evictions, node consolidation, upgrades) all honor PDBs.
4. **VPA `Auto` requires graceful shutdown.** Pods are evicted to apply new resources — handle SIGTERM.
5. **Don't over-tune HPA stabilization.** 5 min is conservative; aggressive scale-down can amplify load oscillations.
6. **Use ComputeClasses, not raw nodeSelectors.** For workload-specific node shape / Spot / accelerator targeting, declare it in a CCC — see [gke-compute-classes-create.md](./gke-compute-classes-create.md). Mixing `cloud.google.com/compute-class` with hard selectors like `cloud.google.com/gke-spot` or `cloud.google.com/machine-family` causes scheduling conflicts.

## Where to go next

- Node pool autoscaling, NAP, NAC, autoscaling profile, consolidation: [gke-node-autoscaling.md](./gke-node-autoscaling.md)
- ComputeClass authoring (preferred wrapper for node-level autoscaling): [gke-compute-classes-create.md](./gke-compute-classes-create.md)
- Cost-driven rightsizing: [gke-cost.md](./gke-cost.md)
