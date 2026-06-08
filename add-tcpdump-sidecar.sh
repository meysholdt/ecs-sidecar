#!/usr/bin/env bash
#
# add-tcpdump-sidecar.sh
#
# Out-of-band ("Option 2") attachment of a tcpdump capture sidecar to the
# ECS Fargate "proxy" task, WITHOUT changing the CDK source.
#
# What it does:
#   1. Reads the task definition currently running on the proxy service.
#   2. Appends a non-essential "tcpdump" sidecar (nicolaka/netshoot) that
#      captures the proxy's own task ENI (the SSH client<->proxy and
#      proxy<->env legs share one awsvpc namespace on Fargate).
#   3. Adds a writable "pcap" volume for rotated capture files.
#   4. Registers a NEW task definition revision and points the service at it.
#
# It records the ORIGINAL task-def ARN to a state file so the companion
# remove script can revert cleanly.
#
# Fargate constraints honoured:
#   - no privileged / NET_ADMIN (own-ENI capture does not need them)
#   - sidecar is Essential=false so it can never take down the proxy
#   - pcaps written to a dedicated volume (proxy root FS is read-only)
#
# Requirements: awscli v2, jq. AWS creds with:
#   ecs:DescribeServices, ecs:DescribeTaskDefinition,
#   ecs:RegisterTaskDefinition, ecs:UpdateService, iam:PassRole
#
# NOTE: applying a new task definition recycles the proxy task and will
#       briefly drop live SSH tunnels.

set -euo pipefail

# ---- Configuration (override via env) ---------------------------------------
: "${AWS_PROFILE:=EngineerAdmin_TestAccounts_3h-877922613839}"
: "${AWS_REGION:=eu-west-1}"
: "${CLUSTER:=testrunner-doptig-cloud-v1-ona-cluster}"
: "${SERVICE:=testrunner-doptig-cloud-v1-onaproxyserviceServiceA3507A74-iMuIlrZ2MoFO}"
: "${SIDECAR_IMAGE:=nicolaka/netshoot:latest}"
# Capture filter (BPF). Default: all TCP. Narrow to the SSH port if known,
# e.g. CAPTURE_FILTER="tcp port 8443 or tcp port 22".
: "${CAPTURE_FILTER:=tcp}"
# rotation: -C <MB per file>, -W <number of files kept>
: "${PCAP_FILE_MB:=50}"
: "${PCAP_FILE_COUNT:=10}"
# Optional: if set, sidecar uploads rotated pcaps to this S3 prefix.
# Requires the proxy TASK ROLE to have s3:PutObject on that prefix.
: "${PCAP_S3_PREFIX:=}"

STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${STATE_DIR}/.tcpdump-sidecar.state"

AWS=(aws --profile "$AWS_PROFILE" --region "$AWS_REGION")

echo ">> Cluster:  $CLUSTER"
echo ">> Service:  $SERVICE"
echo ">> Region:   $AWS_REGION"
echo ">> Profile:  $AWS_PROFILE"

# ---- 1. Resolve the currently running task definition -----------------------
CURRENT_TD_ARN="$("${AWS[@]}" ecs describe-services \
  --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].taskDefinition' --output text)"

if [[ -z "$CURRENT_TD_ARN" || "$CURRENT_TD_ARN" == "None" ]]; then
  echo "ERROR: could not resolve current task definition for the service." >&2
  exit 1
fi
echo ">> Current task definition: $CURRENT_TD_ARN"

# Guard against double-apply.
if [[ -f "$STATE_FILE" ]]; then
  echo "ERROR: state file already exists ($STATE_FILE)." >&2
  echo "       A sidecar revision may already be applied. Run the remove script first." >&2
  exit 1
fi

# ---- 2. Fetch the full task definition --------------------------------------
TD_JSON="$("${AWS[@]}" ecs describe-task-definition \
  --task-definition "$CURRENT_TD_ARN" \
  --query 'taskDefinition' --output json)"

# Bail out if a tcpdump container is somehow already present.
if echo "$TD_JSON" | jq -e '.containerDefinitions[] | select(.name=="tcpdump")' >/dev/null; then
  echo "ERROR: a 'tcpdump' container already exists in the task definition." >&2
  exit 1
fi

LOG_GROUP="$(echo "$TD_JSON" | jq -r '
  [.containerDefinitions[]
   | select(.logConfiguration.logDriver=="awslogs")
   | .logConfiguration.options["awslogs-group"]] | first // empty')"
echo ">> Reusing log group: ${LOG_GROUP:-<none found - sidecar logs to stdout only>}"

# ---- 3. Build the sidecar command ------------------------------------------
# Pick the data ENI dynamically (skip loopback + eth0; Fargate data iface is
# usually eth1 but we never hardcode it). Then run a rotating capture.
read -r -d '' CAPTURE_SCRIPT <<EOF || true
set -e
echo "[tcpdump-sidecar] starting"
IFACE=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -vE '^(lo|eth0)\$' | head -n1)
[ -z "\$IFACE" ] && IFACE=eth1
echo "[tcpdump-sidecar] capturing on interface: \$IFACE (filter: ${CAPTURE_FILTER})"
mkdir -p /pcap
EOF

if [[ -n "$PCAP_S3_PREFIX" ]]; then
  # Capture in background, then continuously sync rotated files to S3.
  CAPTURE_SCRIPT+=$'\n'"tcpdump -i \"\$IFACE\" -nn -s 0 -C ${PCAP_FILE_MB} -W ${PCAP_FILE_COUNT} -w /pcap/proxy.pcap '${CAPTURE_FILTER}' &"
  CAPTURE_SCRIPT+=$'\n'"TCPDUMP_PID=\$!"
  CAPTURE_SCRIPT+=$'\n'"while kill -0 \$TCPDUMP_PID 2>/dev/null; do sleep 30; aws s3 cp --recursive --exclude '*' --include 'proxy.pcap*' /pcap '${PCAP_S3_PREFIX}/' || true; done"
else
  CAPTURE_SCRIPT+=$'\n'"exec tcpdump -i \"\$IFACE\" -nn -s 0 -C ${PCAP_FILE_MB} -W ${PCAP_FILE_COUNT} -w /pcap/proxy.pcap '${CAPTURE_FILTER}'"
fi

# Sidecar container definition (built with jq to embed the script safely).
SIDECAR=$(jq -n \
  --arg image "$SIDECAR_IMAGE" \
  --arg script "$CAPTURE_SCRIPT" \
  --arg loggroup "$LOG_GROUP" \
  --arg region "$AWS_REGION" \
  '{
    name: "tcpdump",
    image: $image,
    essential: false,
    entryPoint: ["/bin/sh","-c"],
    command: [$script],
    mountPoints: [ { sourceVolume: "pcap", containerPath: "/pcap", readOnly: false } ],
    memoryReservation: 128
  }
  + ( if $loggroup != "" then {
        logConfiguration: {
          logDriver: "awslogs",
          options: {
            "awslogs-group": $loggroup,
            "awslogs-region": $region,
            "awslogs-stream-prefix": "tcpdump-sidecar"
          }
        }
      } else {} end )')

# ---- 4. Compose the new task definition input -------------------------------
# Strip read-only/derived fields that RegisterTaskDefinition rejects, append
# the sidecar container, and add the writable pcap volume.
NEW_TD_INPUT=$(echo "$TD_JSON" | jq \
  --argjson sidecar "$SIDECAR" '
  {
    family,
    taskRoleArn,
    executionRoleArn,
    networkMode,
    cpu,
    memory,
    requiresCompatibilities,
    pidMode,
    ipcMode,
    runtimePlatform,
    proxyConfiguration,
    placementConstraints,
    volumes,
    containerDefinitions
  }
  # drop null-valued top-level keys (e.g. pidMode) so the API stays happy
  | with_entries(select(.value != null))
  | .containerDefinitions += [$sidecar]
  | .volumes = ((.volumes // []) + [ { name: "pcap", host: {} } ])
  ')

echo ">> Registering new task definition revision with tcpdump sidecar..."
NEW_TD_ARN="$("${AWS[@]}" ecs register-task-definition \
  --cli-input-json "$NEW_TD_INPUT" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
echo ">> Registered: $NEW_TD_ARN"

# ---- 5. Persist state, then point the service at the new revision -----------
{
  echo "ORIGINAL_TD_ARN=$CURRENT_TD_ARN"
  echo "SIDECAR_TD_ARN=$NEW_TD_ARN"
  echo "CLUSTER=$CLUSTER"
  echo "SERVICE=$SERVICE"
  echo "AWS_REGION=$AWS_REGION"
  echo "AWS_PROFILE=$AWS_PROFILE"
} > "$STATE_FILE"
echo ">> Wrote state file: $STATE_FILE"

echo ">> Updating service to the sidecar revision (this recycles the proxy task)..."
"${AWS[@]}" ecs update-service \
  --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$NEW_TD_ARN" \
  --query 'service.{service:serviceName,taskDef:taskDefinition,desired:desiredCount}' \
  --output json

cat <<EOF

Done. The proxy task is being replaced with a revision that includes the
'tcpdump' sidecar.

Watch rollout:
  aws --profile $AWS_PROFILE --region $AWS_REGION ecs describe-services \\
    --cluster $CLUSTER --services $SERVICE \\
    --query 'services[0].deployments'

Sidecar logs (if a log group was found):
  ${LOG_GROUP:+aws --profile $AWS_PROFILE --region $AWS_REGION logs tail "$LOG_GROUP" --since 5m --filter-pattern tcpdump-sidecar}

Retrieve pcaps:
  - If PCAP_S3_PREFIX was set, files sync there every ~30s.
  - Otherwise exec into the task and copy from /pcap:
      aws --profile $AWS_PROFILE --region $AWS_REGION ecs execute-command \\
        --cluster $CLUSTER --task <TASK_ID> --container tcpdump \\
        --interactive --command "/bin/sh"
    (ECS Exec must be enabled on the service for this.)

To remove the sidecar and restore the original task definition:
  ./remove-tcpdump-sidecar.sh
EOF
