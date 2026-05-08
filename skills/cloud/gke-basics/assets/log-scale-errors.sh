#!/usr/bin/env bash

# Verify dependencies are installed
for cmd in gcloud jq; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: Required command '$cmd' is not installed." >&2
    exit 1
  fi
done

LOG_FILE="errors.log"
touch "$LOG_FILE"

# Define polling interval in seconds
POLL_INTERVAL_SECS=10

# Initialize the tracking timestamp to 1 minute ago so you catch immediate past events
LAST_TIMESTAMP=$(date -u -d '1 minute ago' +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-1M +'%Y-%m-%dT%H:%M:%SZ')

echo "========================================================================="
echo " Starting GKE Cluster Autoscaler Log Error Monitor..."
echo " Logging output to: $LOG_FILE"
echo " Tracking logs starting from: $LAST_TIMESTAMP"
echo " Press [CTRL+C] to stop."
echo "========================================================================="

while true; do
  # Expanded query to capture resultInfo.results with errorMsg, alongside previous targets
  QUERY="log_id(\"container.googleapis.com/cluster-autoscaler-visibility\") AND \
         timestamp > \"$LAST_TIMESTAMP\" AND \
         (jsonPayload.result.error.code:* OR \
          jsonPayload.resultInfo.results.errorMsg.messageId:* OR \
          jsonPayload.noScaleUp:* OR \
          \"errorMsg:\" OR \
          \"scale.up.error\")"

  # Fetch the logs in JSON format chronologically
  LOGS_JSON=$(gcloud logging read "$QUERY" --order="asc" --format="json" 2>/dev/null)

  # Check if we got back valid entries
  if [[ ! -z "$LOGS_JSON" ]] && [[ "$LOGS_JSON" != "[]" ]]; then
    
    # Process each log entry in the returned JSON array
    echo "$LOGS_JSON" | jq -c '.[]?' | while read -r line; do
      [[ -z "$line" ]] && continue

      # Parse common fields
      timestamp=$(echo "$line" | jq -r '.timestamp // "N/A"')
      severity=$(echo "$line" | jq -r '.severity // "INFO"')
      cluster=$(echo "$line" | jq -r '.resource.labels.cluster_name // "Unknown-Cluster"')

      # Update the tracking timestamp to the latest log processed to prevent duplicates
      LAST_TIMESTAMP="$timestamp"

      # --- 1. Handle "resultInfo.results" Array Errors (e.g. Quota Exceeded) ---
      has_result_info_err=$(echo "$line" | jq -r 'if .jsonPayload.resultInfo.results != null then "true" else "false" end')
      if [[ "$has_result_info_err" == "true" ]]; then
        # Loop through the results array to find any errors
        echo "$line" | jq -c '.jsonPayload.resultInfo.results[]?' | while read -r res; do
          has_msg=$(echo "$res" | jq -r 'if .errorMsg != null then "true" else "false" end')
          if [[ "$has_msg" == "true" ]]; then
            msg_id=$(echo "$res" | jq -r '.errorMsg.messageId // "UNKNOWN_ERROR"')
            
            # Reconstruct parameters (usually instance groups or zones) as a readable string list
            params=$(echo "$res" | jq -r '[.errorMsg.parameters[]?] | join(", ")')
            
            formatted_info_err="[$timestamp] [$severity] [$cluster] SCALE_UP_ERROR: Code: $msg_id | Impacted: $params"
            
            # Output to terminal (red) and append to errors.log
            echo -e "\e[31m$formatted_info_err\e[0m"
            echo "$formatted_info_err" >> "$LOG_FILE"
          fi
        done
      fi

      # --- 2. Handle Traditional Hard Scale-Up Errors (Stockouts, direct API rejections) ---
      has_error=$(echo "$line" | jq -r 'if .jsonPayload.result.error != null then "true" else "false" end')
      if [[ "$has_error" == "true" ]]; then
        err_code=$(echo "$line" | jq -r '.jsonPayload.result.error.code')
        err_msg=$(echo "$line" | jq -r '.jsonPayload.result.error.message')
        
        formatted_err="[$timestamp] [$severity] [$cluster] SCALE_UP_ERROR: Code: $err_code | Msg: $err_msg"
        
        echo -e "\e[31m$formatted_err\e[0m"
        echo "$formatted_err" >> "$LOG_FILE"
      fi

      # --- 3. Handle "No Scale-Up" Decisions ---
      has_noscale=$(echo "$line" | jq -r 'if .jsonPayload.noScaleUp != null then "true" else "false" end')
      if [[ "$has_noscale" == "true" ]]; then
        echo "$line" | jq -c '.jsonPayload.noScaleUp.unhandledPodGroups[]?' | while read -r pod_group; do
          pod_name_prefix=$(echo "$pod_group" | jq -r '.podGroup.samplePod.name // "unknown-pod"')
          ns=$(echo "$pod_group" | jq -r '.podGroup.samplePod.namespace // "default"')
          
          # Pull rejection messages per Managed Instance Group (MIG)
          echo "$pod_group" | jq -c '.rejectedMigs[]?' | while read -r mig_data; do
            mig_name=$(echo "$mig_data" | jq -r '.mig.name // "unknown-mig"')
            reason_code=$(echo "$mig_data" | jq -r '.reason.code // "No-Code"')
            reason_msg=$(echo "$mig_data" | jq -r '.reason.message // "No message"')
            
            formatted_no_scale="[$timestamp] [WARNING] [$cluster] NOSCALEUP: Pod: $ns/$pod_name_prefix | MIG: $mig_name | Reason: [$reason_code] $reason_msg"
            
            echo -e "\e[33m$formatted_no_scale\e[0m"
            echo "$formatted_no_scale" >> "$LOG_FILE"
          done
        done
      fi
    done
  fi

  # Sleep until next check
  sleep "$POLL_INTERVAL_SECS"
done
