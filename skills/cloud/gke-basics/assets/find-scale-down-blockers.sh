#!/usr/bin/env bash
#
# Surface pods that block GKE cluster autoscaler scale-down. Categorizes by
# reason so you can prioritize the fix:
#   1. safe-to-evict: "false"  — explicit pin (often defensive, audit each)
#   2. bare pods               — no controller, autoscaler won't evict them
#   3. local-storage pods      — emptyDir / hostPath that would lose data on eviction
#   4. PDB tightness           — currently disruptionsAllowed = 0
#
# Reads the current kube context. Run after `gcloud container clusters
# get-credentials` for the target cluster.
#
# See gke-node-autoscaling-debug.md → "Scale-down isn't happening".
#
# Requires: kubectl, jq.

set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 [-n NAMESPACE]

  Categorizes scale-down blockers across the current kube context.

Options:
  -n NAMESPACE   Restrict the scan to one namespace. Default: all namespaces.
  -h, --help     Show this help.
EOF
}

NS_FLAG=(-A)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n)        [[ -z "${2:-}" ]] && { echo "Error: -n requires a namespace." >&2; exit 1; }
               NS_FLAG=(-n "$2"); shift 2 ;;
    *)         echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

for cmd in kubectl jq; do
  command -v "$cmd" >/dev/null || { echo "Error: '$cmd' not installed." >&2; exit 1; }
done

PODS_JSON=$(kubectl get pods "${NS_FLAG[@]}" -o json)
PDBS_JSON=$(kubectl get pdb  "${NS_FLAG[@]}" -o json)

section() { printf '\n=== %s ===\n' "$1"; }

# 1. safe-to-evict: "false" annotations
section 'safe-to-evict: "false" (explicit scale-down pin)'
echo "$PODS_JSON" | jq -r '
  .items[]
  | select(.metadata.annotations["cluster-autoscaler.kubernetes.io/safe-to-evict"] == "false")
  | "\(.metadata.namespace)/\(.metadata.name)\ton node: \(.spec.nodeName // "<unscheduled>")"
' | column -t -s $'\t' || echo '(none)'

# 2. Bare pods — no controller ownerReference
section 'Bare pods (no controller — autoscaler will not evict)'
echo "$PODS_JSON" | jq -r '
  .items[]
  | select((.metadata.ownerReferences // []) | length == 0)
  | "\(.metadata.namespace)/\(.metadata.name)\ton node: \(.spec.nodeName // "<unscheduled>")"
' | column -t -s $'\t' || echo '(none)'

# 3. Pods with local storage that would lose data on eviction.
#    emptyDir volumes (any medium) and hostPath PVCs both block consolidation.
section 'Local-storage pods (emptyDir / hostPath — eviction loses data)'
echo "$PODS_JSON" | jq -r '
  .items[]
  | select(
      (.spec.volumes // []) | any(
        (.emptyDir != null) or (.hostPath != null)
      )
    )
  | "\(.metadata.namespace)/\(.metadata.name)\ton node: \(.spec.nodeName // "<unscheduled>")"
' | column -t -s $'\t' || echo '(none)'

# 4. PDBs currently allowing zero disruptions — block voluntary eviction.
section 'PodDisruptionBudgets currently blocking eviction (disruptionsAllowed = 0)'
echo "$PDBS_JSON" | jq -r '
  .items[]
  | select((.status.disruptionsAllowed // 0) == 0)
  | "\(.metadata.namespace)/\(.metadata.name)\tcurrentHealthy=\(.status.currentHealthy // 0)\tdesiredHealthy=\(.status.desiredHealthy // 0)\texpectedPods=\(.status.expectedPods // 0)"
' | column -t -s $'\t' || echo '(none)'

cat <<'EOF'

---
Next steps:
  - safe-to-evict pins: confirm each one is genuinely irreplaceable; remove
    the annotation otherwise. Every annotated pod is a permanent scale-down
    blocker on its host node.
  - Bare pods: wrap in a Deployment/Job/StatefulSet so the autoscaler can
    reschedule them.
  - Local-storage pods: move to a network volume (PVC) where the data can
    survive node deletion, or accept that those nodes won't consolidate.
  - PDBs: tight is fine for SLO protection; if disruptionsAllowed stays at 0
    indefinitely, the PDB is mis-sized for the replica count.

For per-node scale-down reasons from the autoscaler itself, run:
  ./assets/log-autoscaler-events.sh <cluster-name>
and look for NOSCALEDOWN lines.
EOF
