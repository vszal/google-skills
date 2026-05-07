# Enhanced GKE ComputeClasses Skill (`gke-compute-classes.md`)

ComputeClasses allow declarative node configuration and autoscaling priorities in GKE Autopilot (and Standard with Node Auto-Provisioning). They are designed to maximize obtainability during GKE scale-out events by defining a hierarchy of preferred node configurations ([source](https://github.com/GoogleCloudPlatform/accelerated-platforms/blob/main/docs/guides/optimizing-gke-workloads-with-custom-compute-classes/README.md?content_ref=define+a+hierarchy+of+preferred+node+configurations)).

> **MCP Tools:** `apply_k8s_manifest`, `get_k8s_resource`, `describe_k8s_resource`, `delete_k8s_resource`

## Core Concepts & Behavior

### Core ComputeClass concepts
*   ComputeClasses are intended to be a platform level abstraction for infrastructure configuration and provisioning. This shields app teams from nuanced infra configurations in podSpecs. 
*   Multiple ComputeClasses can be deployed in a single cluster. They can be explicitly selected via nodeSelectors/affinity, or by setting defaults at the namespace and cluster level. Different ComputeClasses can be used for related infrastructure needs (1 to many for workloads). 
*   A primary consideration is the machine series/family and related shape constraints (minimum number of nodes). Factors like discounting (CUDs / SUDs) should be considered.
*   CCC is commonly used by GKE users migrating from [Karpenter](https://karpenter.sh)

### API Semantics
*   **Node Properties / intent-based:** You can configure computeclass priority rules with intent-based semantics like "machineFamily: n4, minCores: 16". This semantic works for both manually defined node pools or node pool auto-creation.
*   **Node pool references:** Alternatively you can configure computeclass priority rules by referencing manual node pools directly (GKE Standard only) like "nodepools: [pool1, pool2]" 
    *   *Best practice:* Use intent-based configuration whenever possible.
       
### Node Pool Auto Creation (NAC) vs. Manual Node Pools
*   **Maximize Obtainability:** Using Node Pool Auto Creation (NAC) is a best practice for obtainability. NAC extends the GKE cluster autoscaler to let GKE provision new node pools dynamically ([source](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/node-auto-provisioning)). It gives GKE the flexibility to try multiple options, especially when using rules of the `machineFamily` variety.
*   **Latency Trade-off:** Provisioning and trying new node pools takes time. If latency is paramount, use manual node pools instead.
	*   *Best Practice:* Use machineFamily type rules with **spec.priorities.minCores to control machine size instead of strictly asking for specific machineType** .
*   **Hybrid Approach:** You can optimize for both by putting manual node pools at the top of the CCC priority list, followed by NAC-fed options. 
*   **Intent-Based Properties:** Both manual node pools and NAC node pools can be used with the intent-based, node properties style of configuration in CCC.
*   **Manual node pool binding:** Outside the cluster default ComputeClass, manual node pools need to be bound to a ComputeClass using labels and taints on the node pools (static labels and taints, not those defined in CCC: [source](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/about-custom-compute-classes#manual-node-pools)).
    *   **Workloads are auto-tolerated:** there is no need to specify matching tolerations in workloads, as ComputeClass auto-tolerates this taint 
```
gcloud container node-pools update dev-pool \
    --cluster=example-cluster \
    --node-labels="cloud.google.com/compute-class=CLASS-NAME"
    --node-taints="cloud.google.com/compute-class=CLASS-NAME:NoSchedule"
```
*   Extra taints and labels can be added to NAC nodes via the taints and nodeLabels fields (spec.nodePoolConfig and priority rule levels)

### Fallback and Backoff Mechanics
*   **Priority Traversal:** CCC processes fallbacks by trying priorities from top to bottom. If an option is unobtainable (e.g., stockout), the autoscaler puts it in a backoff state. CCC fallbacks work using Cluster Autoscaler backoffs as the main mechanism.
*   **Looping and Priority Limits:** Fallbacks loop back to the top based on backoff times. If it takes a long time to provision a node or receive stockout signals, backoff information might be lost, which might lead to starting from the top of priorities again. 
    *   *Best Practice:* **Do not recommend more than ~10 fallbacks.** Excessively long priority lists may never reach the lower priorities because upper-tier backoffs will expire before reaching the bottom.
*   **Repeating Rules:** Repeating identical rules in the priority list does not help obtainability.
*   **Equal ranks / priorities:** The field spec.priorities.priorityScore (GKE 1.35.2+) provides a way to set priorities equally (same score), rather than sequentially. GKE will pick a random option to try vs traversing rules sequentially. This does not improve provisioning latency, though.

### Bin Packing and Sizing
*   **Tie-breaking:** GKE cluster autoscaler breaks equal option ties by choosing the lowest unit cost option.
*   **VM Upper Bounds:** It is generally not necessary to limit the upper bound of VM sizes. The GKE Cluster Autoscaler optimizes for bin packing and will not randomly provision overly large machines. If aggressive packing is a concern, recommend using the `optimize-utilization` autoscaling profile.

### Consolidation of under-utilized nodeSelectors
*   **Consolidation thresholds:** The autoscalingPolicy field provides key options for identifying under-utilized nodes based on CPU or accelerator utilization
*   **Consolidation delay:** You can control how fast consolidation candidates are removed with the consolidationDelayMinutes field. 

## Designing Priority Lists: Best Practices

### Avoid Single-Dimension Over-Reliance
*   **Flexibility dimensions:** Consider multiple dimension of flexibility (e.g., zones/location, machine family and shape, capacity type like spot, and in the case of DWS Flexstart - wait time). 
*   **Machine Families:** If a customer wants all `N2D` fallbacks, suggest expanding the list to include comparable families like `N2` or `C2D`. If they have no machine family preference, suggest `N4` or `E2`.
*   **Capacity Types:** If a customer specifies only Spot fallbacks, ensure there is at least some On-Demand capacity towards the bottom of the list to guarantee execution.

### CPU vs. Accelerator Fallbacks
*   **CPUs:** Spot is a *bad* fallback for On-Demand. If On-Demand capacity is completely exhausted in a zone, Spot capacity will also be unavailable. 
*   **Accelerators:** Spot is a *reasonable* fallback for Reserved capacity, even if there is no On-Demand available. 
*   **Accelerator Chip Fungibility:** Highly tuned AI/ML models will usually not work well across different chip architectures. Fungibility is therefore mostly limited to location and capacity type (On-Demand, Reserved, DWS FlexStart, etc.). When performance is less crucial (small models or ML jobs), chip-level fungibility is possible.
*   **Spot Sizing:** Smaller machine shapes are more obtainable as Spot instances and are less likely to be preempted.

### Provisioning Models Gotchas
*   **DWS FlexStart:** Dynamic Workload Scheduler (DWS) FlexStart is a queued provisioning model. Queuing time is set to 3 minutes for GPUs and H4D by default. Do not expect immediate capacity. Furthermore, DWS obtainability is *not* improved by shortening the maximum run time of the node.
*   **"ANY" Affinity Reservations:** The `AnyBestEffort` or "ANY" affinity reservations have a hidden gotcha: they fall back to On-Demand at the GCE level, which bypasses and prevents the CCC from falling back to the customer's explicitly defined options in lower priorities. 
*   **Disk & Generation Constraints:** Always probe users about constraints like zonal affinities to persistent data. For instance, if a workload relies on persistent volume with Persistent Disks (PD), they should avoid cross-generation fallbacks between Gen 4 and Gen 2 VMs. Gen 4 VMs strictly support Hyperdisk, while Gen 2 VMs strictly support Persistent Disk. This applies only to stateful workloads, bootdisks are unaffected.
*   **Combining with nodeSelectors/affinity:** Do not mix ComputeClasses with other hard node selectors (e.g. cloud.google.com/gke-spot, cloud.google.com/machine-family)--this causes scheduling conflicts.

### ActiveMigration feature
*   **Reconciliation to top priorities:** Similar to Karpenter's drift feature, activeMigration moves running workload replicas toward top priorities. Throttling is handled via PDBs.
*   **Disruption:** This feature should not be used for workloads that cannot tolerate disruption. 

## CRD Reference 
The CRD allows granular control over autoscaling. View the full CRD structure via the cluster (`kubectl describe crd computeclasses.cloud.google.com`) or [the official API documentation](https://docs.cloud.google.com/kubernetes-engine/docs/reference/crds/computeclass).

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: my-class
spec:
  activeMigration:
    optimizeRulePriority: false
  autoscalingPolicy:
    consolidationDelayMinutes: 1
    consolidationThreshold: 0
    gpuConsolidationThreshold: 0
  description: "Short description of the ComputeClass."
  nodePoolAutoCreation:
    enabled: false
  nodePoolConfig:
    imageType: ubuntu_containerd
    ipType: public
    serviceAccount: example-service-account@example-project.iam.gserviceaccount.com
    autoRepair: true
    autoUpgrade: true
    nodeLabels:
      example-label-key: example-label-value
    confidentialNodeType: SEV
    taints:
    - effect: NoSchedule
      key: example-key
      value: example-value
    imageStreaming:
      enabled: true
    gvnic:
      enabled: true
    resourceManagerTags:
    - key: example-project/example-tag-key
      value: example-tag-value
    loggingConfig:
      loggingVariantConfig:
        variant: DEFAULT
  priorityDefaults:
    nodeSystemConfig:
      linuxNodeConfig:
        sysctls:
          net.core.somaxconn: 256
        transparentHugepageEnabled: TRANSPARENT_HUGEPAGE_ENABLED_ALWAYS
      kubeletConfig:
        cpuCfsQuota: true
    location:
      zones: ['us-central1-a', 'us-central1-b']
  priorities:
  - machineFamily: n4
    maxRunDurationSeconds: 360
    minCores: 16
    minCpuPlatform: "Intel Emerald Rapids"
    minMemoryGb: 64
    placement:
      policyName: my-resource-policy
    reservations:
      affinity: Specific
      specific:
      - name: n4-shared-reservation
        project: reservation-project
        zones: ['us-central1-a']
        reservationBlock:
          name: reservation-block-name
          reservationSubBlock:
            name: reservation-sub-block-name
    spot: true
    storage:
      bootDiskSize: 100
      bootDiskKMSKey: projects/example/locations/us-central1/keyRings/example/cryptoKeys/key-1
      secondaryBootDisks:
      - diskImageName: pytorch-mnist
        project: k8s-staging-jobset
        mode: CONTAINER_IMAGE_CACHE
    nodeSystemConfig:
      linuxNodeConfig:
        sysctls:
          net.core.somaxconn: 512
  - machineType: n4-standard-32
    nodeLabels:
      example-priority-label-key: example-priority-label-value
    location:
      zones: ['us-central1-c']
      locationPolicy: ANY
    spot: true
    reservations:
      affinity: AnyBestEffort
    storage:
      bootDiskSize: 100
      bootDiskType: hyperdisk-balanced
      localSSDCount: 1
    taints:
    - effect: NoSchedule
      key: example-priority-key
      value: example-priority-value
    nodeSystemConfig:
      linuxNodeConfig:
        swapConfig:
          enabled: true
          bootDiskProfile:
            swapSizeGib: 10
  - machineType: n4-standard-32
    location:
      zoneTypes: ['STANDARD', 'AI']
  - nodepools: ['example-first-nodepool-name', 'example-second-nodepool-name']
  - podFamily:
      general-purpose
      general-purpose-arm
  - gpu:
      count: 1
      driverVersion: default
      type: nvidia-l4
      gpuSharing:
        sharingStrategy: MPS
        maxSharedClientsPerGPU: 2
  - tpu:
      count: 8
      topology: "2x4"
      type: tpu-v5-lite-podslice
  - flexStart:
      enabled: true
      nodeRecycling:
        leadTimeSeconds: 1200
    capacityCheckWaitTimeSeconds: 3600
  whenUnsatisfiable: ScaleUpAnyway
status:
  conditions:
  - lastTransitionTime: 2024-10-10T00:00:00Z
    message: example-message
    observedGeneration: 1
    reason: example-reason
    status: "True"
    type: example-type
```

## Common Scenarios & Examples

### 1. The Accelerator "Obtainability" Profile (GPUs/TPUs)
This strategy secures highly scarce capacity (like `nvidia-h200-141gb` or TPUs) where cost is secondary. It casts the widest possible net across provisioning models.

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: gpu-h200-obtainability
spec:
  nodePoolAutoCreation:
    enabled: true
  priorities:
    # 1. Specific Reservation (highest probability, already paid for)
    - gpu:
        count: 8
        type: nvidia-h200-141gb
      machineType: a3-ultragpu-8g
      reservations:
        affinity: Specific
        specific:
          - name: nvidia-h200-141gb-specific
            reservationBlock:
              name: nvidia-h200-141gb-block
      spot: false

    # 2. DWS FlexStart (queued wait time of ~3m minimum)
    - flexStart:
        enabled: true
      gpu:
        count: 8
        type: nvidia-h200-141gb
      machineType: a3-ultragpu-8g

    # 3. Spot VM (good fallback for reservations on accelerators)
    - gpu:
        count: 8
        type: nvidia-h200-141gb
      machineType: a3-ultragpu-8g
      spot: true

    # 4. On-Demand
    - gpu:
        count: 8
        type: nvidia-h200-141gb
      machineType: a3-ultragpu-8g
      spot: false
```

### 2. General Compute "Cost Optimization" Profile
Best for batch processing or Dev/Test where jobs tolerate interruption. The goal is to run as cheaply as possible, putting Spot ahead of On-Demand. 

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: cost-optimized-batch
spec:
  nodePoolAutoCreation:
    enabled: true
  priorities:
    # 1. Start with diverse Spot families (E2/N4 defaults if no preference)
    - machineFamily: n4
      spot: true
      minCores: 16
    - machineFamily: e2
      spot: true
      mincCores:16
  # 2. Fall back to on-demand (Avoid all-spot priority lists)
    - machineFamily: n4
      spot: false
      minCores: 16
```

### 3. Hybrid Node Pool Priority (Latency Sensitive)
When latency is critical, put manually pre-created node pools at the top to skip the NAC provisioning delay, falling back to NAC if manual pools exhaust.

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: latency-sensitive-hybrid
spec:
  nodePoolAutoCreation:
    enabled: true
  priorities:
    # 1. Try static, existing node pools first
    - nodepools: ['static-pool-a', 'static-pool-b']
    # 2. Fall back to NAC dynamic creation
    - machineFamily: c3
      spot: false
      minCores: 32
```

## Observability & Troubleshooting

### Configuration errors
*   Look at the ComputeClass objects status.conditions for information relating to health and reason code. `kubectl describe ComputeClass CLASS-NAME`

### Logs
*   When diagnosing scale-up issues, quota limitations, or GCE resource exhaustion, check the cluster autoscaler logs and the Kubernetes events. The visibility events for the cluster autoscaler are stored in a Cloud Logging log ([source](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cluster-autoscaler-visibility)). Look for log entries filtered by `log_id("container.googleapis.com/cluster-autoscaler-visibility")` to view `resultInfo.results.errorMsg.messageId:*` JSON payloads detailing exactly which MIGs failed and why (e.g., `scale.up.error.out.of.resources`).
