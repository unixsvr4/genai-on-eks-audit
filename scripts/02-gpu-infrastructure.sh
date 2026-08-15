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

EXISTING_ODCR=$(aws ec2 describe-capacity-reservations --region "$AWS_REGION" \
  --filters "Name=state,Values=active" "Name=instance-type,Values=${INSTANCE_TYPE}" \
  --query "CapacityReservations[0].CapacityReservationId" --output text 2>/dev/null || echo "None")

if [ "$EXISTING_ODCR" != "None" ] && [ -n "$EXISTING_ODCR" ]; then
  warn "Reusing existing active ODCR: ${EXISTING_ODCR}"
  ODCR_ID="$EXISTING_ODCR"
else
  END_DATE=$(date -u -v+"${ODCR_HOURS}"H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "+${ODCR_HOURS} hours" +"%Y-%m-%dT%H:%M:%SZ")
  log "Creating ODCR for 1x ${INSTANCE_TYPE}, auto-expiring at ${END_DATE} (${ODCR_HOURS}h from now)..."
  ODCR_ID=$(aws ec2 create-capacity-reservation \
    --region "$AWS_REGION" \
    --instance-type "$INSTANCE_TYPE" \
    --instance-platform Linux/UNIX \
    --availability-zone "${AWS_REGION}a" \
    --instance-count 1 \
    --instance-match-criteria open \
    --end-date-type limited \
    --end-date "$END_DATE" \
    --query 'CapacityReservation.CapacityReservationId' --output text)
  log "Created ODCR: ${ODCR_ID} (self-expires in ${ODCR_HOURS}h — see docs/COST.md before extending this)"
fi

log "Patching GPU NodeClass to use ODCR ${ODCR_ID}..."
mkdir -p "${MANIFEST_DIR}/100-introduction"
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
