#!/usr/bin/env bash
# Module: GPU Infrastructure (RESEARCH.md §2b)
# Creates the On-Demand Capacity Reservation for g6e.2xlarge and wires it into the
# GPU NodeClass, then proves the GPU stack works end-to-end with an nvidia-smi pod.
#
# COST NOTE: from the moment the ODCR is created, you are billed the g6e.2xlarge
# on-demand rate for its full duration whether or not a GPU node is actually running
# in it (see docs/COST.md "How the ODCR actually bills"). --end-date-type limited
# below makes it self-expire after $ODCR_HOURS as a safety net even if you forget
# to run 99-destroy-all.sh.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

log "Checking GPU NodePool/NodeClass exist..."
kubectl get nodepool/gpu
kubectl get nodeclass/gpu

# HARD GATE — must run BEFORE the ODCR is created.
#
# This script commits money at the create-capacity-reservation call below, but the
# first evidence that a GPU node cannot launch does not arrive until the kubectl
# wait ~50 lines later. On an account whose Free Tier plan forbids ${INSTANCE_TYPE},
# that gap costs a full ${ODCR_HOURS}h reservation at the on-demand rate for capacity
# no instance is permitted to occupy -- billed from creation, used never. That is
# exactly what happened on 2026-09-03 (DIAGNOSTICS8.md), which is why this is a
# `die` and not a warning: the whole point is to stop before the spend.
#
# Note this is NOT the quota check. Eligibility is evaluated before quota, so a
# granted GPU quota says nothing about whether the launch will be permitted.
log "Checking the account's Free Tier plan permits ${INSTANCE_TYPE} (before creating any billable reservation)..."
set +e
free_tier_check "$INSTANCE_TYPE"
FT_RC=$?
set -e
case "$FT_RC" in
  0)
    if [ "$FT_PLAN_TYPE" = "FREE" ]; then
      log "Account is on the FREE plan, but ${INSTANCE_TYPE} is Free-Tier-eligible — proceeding."
    else
      log "Account plan is ${FT_PLAN_TYPE} — no Free Tier instance-type restriction."
    fi
    ;;
  1)
    warn "Account plan is FREE. It may launch ONLY these instance types in ${AWS_REGION}:"
    warn "  $(echo "$FT_ELIGIBLE_TYPES" | tr '\n' ' ')"
    warn "${INSTANCE_TYPE} is not among them, so Karpenter's gpu NodePool will churn NodeClaims"
    warn "forever with FreeTierIneligible and no GPU node will EVER launch. Your GPU service"
    warn "quota is irrelevant here — eligibility is checked before quota."
    warn ""
    warn "Refusing to continue: the next step creates a ${ODCR_HOURS}h capacity reservation that"
    warn "bills the full ${INSTANCE_TYPE} on-demand rate from the moment it exists, for capacity"
    warn "no instance could occupy. See DIAGNOSTICS8.md."
    warn ""
    warn "Fix (a plan change — this does NOT clear by waiting):"
    warn "  aws freetier upgrade-account-plan --account-plan-type PAID"
    warn "  (or: AWS Billing console -> Free Tier -> 'Upgrade to a paid plan')"
    warn ""
    warn "To override anyway — you will be billed for the reservation regardless:"
    warn "  ALLOW_FREE_TIER_BLOCKED=1 ./02-gpu-infrastructure.sh"
    [ "${ALLOW_FREE_TIER_BLOCKED:-0}" = "1" ] \
      || die "${INSTANCE_TYPE} cannot launch on this account's FREE plan. Nothing was created, nothing was billed."
    warn "ALLOW_FREE_TIER_BLOCKED=1 set — continuing into a launch that is expected to fail."
    ;;
  *)
    warn "Could not determine the account's Free Tier plan (needs aws-cli >= 2.22 and freetier:GetAccountPlanState). Continuing, but if the GPU node never appears, check this first:"
    warn "  aws freetier get-account-plan-state"
    warn "  aws ec2 describe-instance-types --region ${AWS_REGION} --filters \"Name=free-tier-eligible,Values=true\" --query 'InstanceTypes[].InstanceType' --output text"
    ;;
esac

EXISTING_ODCR=$(aws ec2 describe-capacity-reservations --region "$AWS_REGION" \
  --filters "Name=state,Values=active" "Name=instance-type,Values=${INSTANCE_TYPE}" \
  --query "CapacityReservations[0].CapacityReservationId" --output text 2>/dev/null || echo "None")

if [ "$EXISTING_ODCR" != "None" ] && [ -n "$EXISTING_ODCR" ]; then
  warn "Reusing existing active ODCR: ${EXISTING_ODCR}"
  ODCR_ID="$EXISTING_ODCR"
else
  END_DATE=$(date -u -v+"${ODCR_HOURS}"H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "+${ODCR_HOURS} hours" +"%Y-%m-%dT%H:%M:%SZ")

  # An ODCR is AZ-scoped, and GPU capacity runs out per-AZ. This used to ask for
  # ${AWS_REGION}a only and die on the first InsufficientInstanceCapacity, which
  # is a shortage in ONE zone reported as if the region were empty:
  #   An error occurred (InsufficientInstanceCapacity) when calling the
  #   CreateCapacityReservation operation: Insufficient capacity.
  # So try every AZ that can actually run the node. Candidates are the AZs of the
  # cluster's own subnets (reserving where no subnet exists would strand the
  # reservation) intersected with the AZs that offer ${INSTANCE_TYPE} at all.
  CLUSTER_SUBNETS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.subnetIds' --output text 2>/dev/null || echo "")
  CLUSTER_AZS=""
  if [ -n "$CLUSTER_SUBNETS" ]; then
    # shellcheck disable=SC2086
    CLUSTER_AZS=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids $CLUSTER_SUBNETS \
      --query 'Subnets[].AvailabilityZone' --output text 2>/dev/null | tr '\t' '\n' | sort -u)
  fi
  OFFERED_AZS=$(aws ec2 describe-instance-type-offerings --region "$AWS_REGION" \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=${INSTANCE_TYPE}" \
    --query 'InstanceTypeOfferings[].Location' --output text 2>/dev/null | tr '\t' '\n' | sort -u)

  if [ -n "$CLUSTER_AZS" ] && [ -n "$OFFERED_AZS" ]; then
    CANDIDATE_AZS=$(comm -12 <(echo "$CLUSTER_AZS") <(echo "$OFFERED_AZS"))
  else
    # Fall back to whichever list we managed to read, then to the old hardcoded AZ.
    CANDIDATE_AZS="${OFFERED_AZS:-${CLUSTER_AZS:-${AWS_REGION}a}}"
  fi
  [ -z "$CANDIDATE_AZS" ] && die "No AZ in ${AWS_REGION} both offers ${INSTANCE_TYPE} and has a cluster subnet. Check the cluster's VPC layout."

  log "Creating ODCR for 1x ${INSTANCE_TYPE}, auto-expiring at ${END_DATE} (${ODCR_HOURS}h from now)..."
  log "  AZs to try: $(echo "$CANDIDATE_AZS" | tr '\n' ' ')"
  ODCR_ID=""
  ODCR_AZ=""
  for az in $CANDIDATE_AZS; do
    set +e
    ODCR_ERR=$(aws ec2 create-capacity-reservation \
      --region "$AWS_REGION" \
      --instance-type "$INSTANCE_TYPE" \
      --instance-platform Linux/UNIX \
      --availability-zone "$az" \
      --instance-count 1 \
      --instance-match-criteria open \
      --end-date-type limited \
      --end-date "$END_DATE" \
      --query 'CapacityReservation.CapacityReservationId' --output text 2>&1)
    RC=$?
    set -e
    if [ "$RC" -eq 0 ]; then
      ODCR_ID="$ODCR_ERR"
      ODCR_AZ="$az"
      break
    fi
    case "$ODCR_ERR" in
      *InsufficientInstanceCapacity*|*InsufficientCapacity*)
        warn "  ${az}: no ${INSTANCE_TYPE} capacity right now — trying the next AZ."
        ;;
      *)
        # Anything that is not a capacity shortage (auth, quota, bad params) will
        # fail identically in every other AZ, so stop rather than retry 2 more times.
        die "create-capacity-reservation failed in ${az} for a reason other than capacity. Nothing was created, nothing was billed:
${ODCR_ERR}"
        ;;
    esac
  done

  if [ -n "$ODCR_ID" ]; then
    log "Created ODCR: ${ODCR_ID} in ${ODCR_AZ} (self-expires in ${ODCR_HOURS}h — see docs/COST.md before extending this)"
  else
    # Every AZ is out of capacity. That is a real regional shortage, but it is NOT
    # fatal: the gpu NodePool accepts capacity-type "on-demand" as well as
    # "reserved", so Karpenter can still launch the node the moment capacity frees
    # up anywhere in the region. Continuing also costs LESS, not more -- with no
    # reservation nothing bills until an instance actually exists, whereas an ODCR
    # bills from creation whether or not it is used (docs/COST.md).
    warn "----------------------------------------------------------------------"
    warn "No ${INSTANCE_TYPE} capacity in ANY candidate AZ: $(echo "$CANDIDATE_AZS" | tr '\n' ' ')"
    warn "Continuing WITHOUT a capacity reservation. This is a degraded mode, not"
    warn "a failure: the gpu NodePool allows capacity-type 'on-demand', so the node"
    warn "can still launch -- but nothing is holding capacity for it, so it may sit"
    warn "unschedulable until AWS has a ${INSTANCE_TYPE} free, and it can lose the"
    warn "race to another customer. Nothing has been billed."
    warn "Re-run this script later to pick up a reservation once capacity returns."
    warn "----------------------------------------------------------------------"
  fi
fi

mkdir -p "${MANIFEST_DIR}/100-introduction"
if [ -n "$ODCR_ID" ]; then
  log "Patching GPU NodeClass to use ODCR ${ODCR_ID}..."
  cat <<EOF > "${MANIFEST_DIR}/100-introduction/patch-gpu-nodeclass.yaml"
apiVersion: eks.amazonaws.com/v1
kind: NodeClass
metadata:
  name: gpu
spec:
  capacityReservationSelectorTerms:
    - id: ${ODCR_ID}
EOF
  kubectl patch nodeclass gpu --patch-file "${MANIFEST_DIR}/100-introduction/patch-gpu-nodeclass.yaml" --type=merge
  kubectl get nodeclass gpu -o yaml | grep -A 3 capacityReservationSelectorTerms
else
  # Clear any selector left by an earlier run, or Karpenter keeps waiting for a
  # reservation that no longer exists instead of falling back to on-demand.
  log "Clearing any capacityReservationSelectorTerms from the GPU NodeClass (running on-demand)..."
  kubectl patch nodeclass gpu --type=merge -p '{"spec":{"capacityReservationSelectorTerms":null}}'
fi

log "Deploying nvidia-smi test pod to prove GPU provisioning + device plugin work..."
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-smi
spec:
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
  nodeSelector:
    karpenter.sh/nodepool: gpu
  containers:
  - name: nvidia-smi
    image: public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
  restartPolicy: OnFailure
EOF

log "Waiting for GPU node to provision + pod to succeed (expect ~30s-1min, first cold GPU node from zero)..."
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/nvidia-smi --timeout=300s
kubectl logs nvidia-smi
kubectl delete pod nvidia-smi

log "GPU infrastructure verified. Next: ./03-serve-model.sh"
