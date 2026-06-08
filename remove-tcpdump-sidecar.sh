#!/usr/bin/env bash
#
# remove-tcpdump-sidecar.sh
#
# Reverts the change made by add-tcpdump-sidecar.sh:
#   1. Points the proxy service back at the ORIGINAL task definition revision
#      (the CDK-managed one captured in the state file).
#   2. Deregisters the temporary sidecar task definition revision.
#   3. Deletes the local state file.
#
# This recycles the proxy task again (briefly drops live SSH tunnels).
#
# Requirements: awscli v2, jq. AWS creds with:
#   ecs:UpdateService, ecs:DeregisterTaskDefinition, ecs:DescribeServices

set -euo pipefail

STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${STATE_DIR}/.tcpdump-sidecar.state"

# ---- Load state -------------------------------------------------------------
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  echo ">> Loaded state from $STATE_FILE"
else
  echo "No state file found at $STATE_FILE."
  echo "Falling back to environment variables (you must provide ORIGINAL_TD_ARN,"
  echo "SIDECAR_TD_ARN, CLUSTER, SERVICE, AWS_REGION, AWS_PROFILE)."
fi

# ---- Configuration (state file wins; env as fallback) -----------------------
: "${AWS_PROFILE:?AWS_PROFILE not set and no state file}"
: "${AWS_REGION:?AWS_REGION not set and no state file}"
: "${CLUSTER:?CLUSTER not set and no state file}"
: "${SERVICE:?SERVICE not set and no state file}"
: "${ORIGINAL_TD_ARN:?ORIGINAL_TD_ARN not set and no state file}"
: "${SIDECAR_TD_ARN:=}"  # optional; if empty we only revert the service

AWS=(aws --profile "$AWS_PROFILE" --region "$AWS_REGION")

echo ">> Cluster:        $CLUSTER"
echo ">> Service:        $SERVICE"
echo ">> Restoring to:   $ORIGINAL_TD_ARN"
echo ">> Sidecar revs:   ${SIDECAR_TD_ARN:-<none recorded>}"

# ---- 1. Revert the service to the original task definition ------------------
echo ">> Updating service back to the original task definition (recycles task)..."
"${AWS[@]}" ecs update-service \
  --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$ORIGINAL_TD_ARN" \
  --query 'service.{service:serviceName,taskDef:taskDefinition,desired:desiredCount}' \
  --output json

# ---- 2. Wait for the service to stabilize on the original revision ----------
echo ">> Waiting for service to stabilize on the original revision..."
if "${AWS[@]}" ecs wait services-stable \
     --cluster "$CLUSTER" --services "$SERVICE"; then
  echo ">> Service stable."
else
  echo "WARNING: services-stable wait timed out; check rollout manually before deregistering." >&2
fi

# ---- 3. Deregister the temporary sidecar revision ---------------------------
if [[ -n "$SIDECAR_TD_ARN" ]]; then
  echo ">> Deregistering temporary sidecar task definition: $SIDECAR_TD_ARN"
  "${AWS[@]}" ecs deregister-task-definition \
    --task-definition "$SIDECAR_TD_ARN" \
    --query 'taskDefinition.{arn:taskDefinitionArn,status:status}' \
    --output json || \
    echo "WARNING: failed to deregister $SIDECAR_TD_ARN (deregister manually if needed)." >&2
else
  echo ">> No sidecar revision ARN recorded; skipping deregister."
fi

# ---- 4. Clean up state ------------------------------------------------------
if [[ -f "$STATE_FILE" ]]; then
  rm -f "$STATE_FILE"
  echo ">> Removed state file: $STATE_FILE"
fi

cat <<EOF

Done. The proxy service is back on its original CDK-managed task definition
and the temporary sidecar revision has been deregistered.

Verify:
  aws --profile $AWS_PROFILE --region $AWS_REGION ecs describe-services \\
    --cluster $CLUSTER --services $SERVICE \\
    --query 'services[0].{taskDef:taskDefinition,deployments:deployments[].status}'
EOF
