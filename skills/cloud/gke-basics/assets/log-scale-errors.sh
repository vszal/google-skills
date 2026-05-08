#!/usr/bin/env bash
#
# Live tail of GKE cluster autoscaler visibility logs for a single cluster,
# filtered to scale-up failures and per-pod noScaleUp rejections. Polls every
# $POLL_INTERVAL_SECS, colorizes terminal output, and appends a plain-text
# copy to errors.log. Requires: gcloud, jq.

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  echo "Usage: $0 <cluster-name>" >&2
  echo "  Tails cluster-autoscaler-visibility logs for the named GKE cluster" >&2
  echo "  in the current gcloud project. Cluster name matches resource.labels.cluster_name." >&2
  exit 1
fi
CLUSTER="$1"

for cmd in gcloud jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: Required command '$cmd' is not installed." >&2
    exit 1
  fi
done

LOG_FILE="errors.log"
POLL_INTERVAL_SECS=10
touch "$LOG_FILE"

# Initial cursor: 1 minute ago. Portable across GNU date (Linux) and BSD date (macOS).
LAST_TIMESTAMP=$(date -u -d '1 minute ago' +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -v-1M +'%Y-%m-%dT%H:%M:%SZ')

echo "========================================================================="
echo " GKE cluster autoscaler scale-error monitor"
echo "   cluster: $CLUSTER"
echo "   output:  $LOG_FILE"
echo "   start:   $LAST_TIMESTAMP"
echo "   press Ctrl-C to stop"
echo "========================================================================="

while true; do
  # Two structured shapes carry scale-up failures:
  #   resultInfo.results[].errorMsg          per-MIG failures (quota, stockout, IP, …)
  #   noScaleUp.unhandledPodGroups[]         pods that no MIG could host
  # Field-existence checks (`:*`) keep the filter tight — substring fallbacks
  # would match unrelated log lines and inflate the response.
  QUERY="log_id(\"container.googleapis.com/cluster-autoscaler-visibility\")
         AND resource.labels.cluster_name = \"$CLUSTER\"
         AND timestamp > \"$LAST_TIMESTAMP\"
         AND ( jsonPayload.resultInfo.results.errorMsg.messageId:*
               OR jsonPayload.noScaleUp:* )"

  LOGS_JSON=$(gcloud logging read "$QUERY" --order=asc --format=json 2>/dev/null)
  if [[ -z "$LOGS_JSON" || "$LOGS_JSON" == "[]" ]]; then
    sleep "$POLL_INTERVAL_SECS"
    continue
  fi

  # Advance the cursor BEFORE the per-line loop. The pipeline below runs the
  # loop body in a subshell, so any LAST_TIMESTAMP update inside it would not
  # survive to the next iteration — replaying the same window every tick.
  NEW_TIMESTAMP=$(echo "$LOGS_JSON" | jq -r '[.[].timestamp] | max // empty')
  [[ -n "$NEW_TIMESTAMP" ]] && LAST_TIMESTAMP="$NEW_TIMESTAMP"

  echo "$LOGS_JSON" | jq -c '.[]' | while read -r entry; do
    ts=$(echo "$entry" | jq -r '.timestamp')

    # 1. Per-MIG scale-up errors
    echo "$entry" | jq -c '.jsonPayload.resultInfo.results[]? | select(.errorMsg)' \
      | while read -r res; do
          mid=$(echo    "$res" | jq -r '.errorMsg.messageId // "UNKNOWN"')
          params=$(echo "$res" | jq -r '[.errorMsg.parameters[]?] | join(", ")')
          line="[$ts] SCALE_UP_ERROR: $mid | $params"
          printf '\033[31m%s\033[0m\n' "$line"
          echo "$line" >>"$LOG_FILE"
        done

    # 2. noScaleUp per-pod rejections (each rejected MIG has its own reason)
    echo "$entry" | jq -c '.jsonPayload.noScaleUp.unhandledPodGroups[]?' \
      | while read -r grp; do
          ns=$(echo  "$grp" | jq -r '.podGroup.samplePod.namespace // "default"')
          pod=$(echo "$grp" | jq -r '.podGroup.samplePod.name      // "unknown"')
          echo "$grp" | jq -c '.rejectedMigs[]?' | while read -r mig; do
            mig_name=$(echo "$mig" | jq -r '.mig.name                  // "unknown"')
            reason=$(echo   "$mig" | jq -r '.reason.messageId          // "no-reason"')
            params=$(echo   "$mig" | jq -r '[.reason.parameters[]?] | join(", ")')
            line="[$ts] NOSCALEUP: $ns/$pod | MIG: $mig_name | $reason | $params"
            printf '\033[33m%s\033[0m\n' "$line"
            echo "$line" >>"$LOG_FILE"
          done
        done
  done

  sleep "$POLL_INTERVAL_SECS"
done
