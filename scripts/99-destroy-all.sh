#!/usr/bin/env bash
# Full teardown, in reverse dependency order. Mirrors the real end-of-workshop
# cleanup script captured live in RESEARCH.md §7, PLUS two things the workshop's
# own at-event cleanup couldn't do because it didn't own its infrastructure:
#   1. Actually cancel the GPU ODCR (the live event's ODCR lived in a separate
#      AWS-operator account and attendees got UnauthorizedOperation — see
#      docs/GOTCHAS.md. You own this one, so it will actually cancel.)
#   2. Actually run `terraform destroy` (the live event had no local clone/binary
#      for this — you do, via 00-clone-terraform.sh.)
#
# Every kubectl/helm delete is guarded with `|| true` so this is safe to re-run
# and safe to run even if you skipped some modules.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

log "=== Kubernetes resources, by module ==="

# Serve a Model / Agentic App
kubectl delete deployment mistral 2>/dev/null || true
kubectl delete deployment strands-weather-agent 2>/dev/null || true
kubectl delete service strands-weather-agent 2>/dev/null || true

# Optimize Inference (KV-cache labs — should already be gone if 07/08 completed,
# these are defensive no-ops)
kubectl delete pod lmcache-cpu-ram 2>/dev/null || true
kubectl delete configmap cpu-ram-cm 2>/dev/null || true
kubectl delete pod lmcache-valkey 2>/dev/null || true
kubectl delete configmap valkey-cm 2>/dev/null || true

# Inference Frameworks (Ray Serve + Open WebUI)
kubectl delete -f "${MANIFEST_DIR}/400-ray/ray-vllm-s3-service.yml" 2>/dev/null || true
kubectl delete -f "${MANIFEST_DIR}/400-ray/openwebui.yml" 2>/dev/null || true
kubectl delete deployment open-webui 2>/dev/null || true
kubectl delete service open-webui 2>/dev/null || true
kubectl delete ingress open-webui-ingress 2>/dev/null || true
kubectl delete configmap vllm-serve-script 2>/dev/null || true
kubectl delete podmonitor ray-head-monitor -n monitoring 2>/dev/null || true
kubectl delete podmonitor ray-workers-monitor -n monitoring 2>/dev/null || true

# Customize Model / fine-tuning
kubectl delete deployment anyvc 2>/dev/null || true
kubectl delete configmap anyvc-training-scripts 2>/dev/null || true
kubectl delete job anyvc-lora-finetune 2>/dev/null || true

# RAG
kubectl delete deployment rag-service 2>/dev/null || true
kubectl delete service rag-service 2>/dev/null || true
kubectl delete configmap rag-processor-script 2>/dev/null || true
kubectl delete configmap rag-serve-script 2>/dev/null || true
kubectl delete deployment rag-gradio-interface 2>/dev/null || true
kubectl delete service rag-gradio-interface 2>/dev/null || true
kubectl delete ingress rag-gradio-alb 2>/dev/null || true
kubectl delete configmap rag-gradio-app 2>/dev/null || true
kubectl delete job rag-document-processor 2>/dev/null || true
kubectl delete serviceaccount s3-access-sa 2>/dev/null || true

# Shared resources
kubectl delete service vllm-serve-svc 2>/dev/null || true
kubectl delete pvc s3-bucket-pvc 2>/dev/null || true
kubectl delete pv s3-bucket-pv 2>/dev/null || true

# Observability
kubectl delete -f "${MANIFEST_DIR}/300-observability/grafana-ingress.yaml" 2>/dev/null || true
kubectl delete servicemonitor mistral-monitor -n monitoring 2>/dev/null || true
helm uninstall dcgm-exporter -n monitoring 2>/dev/null || true

log "=== KubeRay operator ==="
helm uninstall kuberay-operator 2>/dev/null || true
kubectl wait --for=delete pods -l app.kubernetes.io/name=kuberay-operator --timeout=300s 2>/dev/null || true

log "=== S3 Vectors ==="
aws s3vectors delete-index --vector-bucket-name "$S3_VECTOR_BUCKET_NAME" --index-name "$S3_VECTOR_INDEX_NAME" 2>/dev/null || true
aws s3vectors delete-vector-bucket --vector-bucket-name "$S3_VECTOR_BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null || true

log "=== EKS Pod Identity + IAM (RAG ingestion job) ==="
ASSOCIATION_ID=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --query 'associations[?serviceAccount==`s3-access-sa` && namespace==`default`].associationId' \
  --output text 2>/dev/null || echo "")
[ -n "$ASSOCIATION_ID" ] && [ "$ASSOCIATION_ID" != "None" ] && \
  aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$ASSOCIATION_ID" 2>/dev/null || true

POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`RagS3ReadPolicy`].Arn' --output text 2>/dev/null || echo "")
if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
  aws iam detach-role-policy --role-name rag-document-processor-role --policy-arn "$POLICY_ARN" 2>/dev/null || true
  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
fi
aws iam delete-role --role-name rag-document-processor-role 2>/dev/null || true

log "=== Data buckets ==="
aws s3 rb "s3://${S3_RAG_DATA_BUCKET}" --force 2>/dev/null || true

log "=== ECR ==="
aws ecr delete-repository --repository-name strands-weather-agent --force 2>/dev/null || true

log "=== Valkey (defensive re-run — should already be gone from 08-lmcache-valkey.sh) ==="
if [ -f "${MANIFEST_DIR}/500-lmcache/cleanup-valkey.sh" ]; then
  bash "${MANIFEST_DIR}/500-lmcache/cleanup-valkey.sh" 2>/dev/null || true
fi

log "=== GPU capacity reservation ==="
log "(Unlike the live workshop event, you own this ODCR — this should actually succeed.)"
ODCR_ID=$(aws ec2 describe-capacity-reservations --region "$AWS_REGION" \
  --filters "Name=state,Values=active" "Name=instance-type,Values=${INSTANCE_TYPE}" \
  --query "CapacityReservations[0].CapacityReservationId" --output text 2>/dev/null || echo "None")
if [ "$ODCR_ID" != "None" ] && [ -n "$ODCR_ID" ]; then
  aws ec2 cancel-capacity-reservation --region "$AWS_REGION" --capacity-reservation-id "$ODCR_ID" \
    && log "Cancelled ODCR ${ODCR_ID}." \
    || warn "Failed to cancel ODCR ${ODCR_ID} — check manually in the EC2 console. It has --end-date-type limited set, so it will self-expire regardless (see docs/COST.md)."
else
  log "No active ODCR found."
fi

# --- Unstick pods whose node disappeared ---------------------------------------
# A pod on a node that is terminated mid-deletion can sit in Terminating forever:
# the kubelet is gone, so it never acknowledges, and nothing else will. Measured
# 2026-09-04: a kube-prometheus-stack node-exporter pod sat at 103 minutes and
# blocked `kubernetes_namespace_v1.monitoring` from finalizing, which blew
# Terraform's 5-minute delete timeout and ended the destroy with the generic
# `Error: context deadline exceeded`.
#
# The dependency edge added by scripts/lib/fix_destroy_order.py prevents this by
# destroying the namespace before the NodePool. This sweep is the backstop for a
# cluster that is ALREADY wedged -- e.g. re-running after a failed destroy. It only
# touches pods that have a deletionTimestamp, i.e. ones Kubernetes has already been
# told to delete, so it cannot kill anything that was meant to keep running.
STUCK=$(kubectl get pods -A -o json 2>/dev/null | python3 -c '
import json,sys
try: pods=json.load(sys.stdin).get("items",[])
except Exception: sys.exit(0)
for p in pods:
    m=p["metadata"]
    if m.get("deletionTimestamp"):
        print(m["namespace"], m["name"])
' 2>/dev/null || echo "")
if [ -n "$STUCK" ]; then
  warn "Pods stuck in Terminating (their node is likely gone) — force-deleting so namespaces can finalize:"
  echo "$STUCK" | while read -r ns name; do
    [ -z "$name" ] && continue
    warn "  ${ns}/${name}"
    kubectl delete pod -n "$ns" "$name" --force --grace-period=0 2>/dev/null || true
  done
fi

log "=== Base infrastructure (terraform destroy) ==="
TF_DIR="${DEPLOY_DIR}/sample-genai-on-eks/terraform"
if [ -d "$TF_DIR" ]; then
  terraform -chdir="$TF_DIR" destroy --auto-approve -var="region=${AWS_REGION}"
else
  warn "No Terraform clone found at ${TF_DIR} — nothing to destroy at the infrastructure layer. \
If you deployed manually, tear down the VPC/EKS cluster/S3 model bucket yourself."
fi

# --- Post-destroy verification ------------------------------------------------
# This used to say "verify in the AWS console that nothing remains", which is
# advice rather than a check, on the one step where being wrong costs money by
# the hour. Teardown has been this repo's most expensive recurring problem
# (DIAGNOSTICS8.md, DIAGNOSTICS9.md), so verify it here.
#
# NOTE on instances: EKS Auto Mode's nodes carry
# Operator{Managed:true, HiddenByDefault:true} and are OMITTED from an unfiltered
# `describe-instances` -- a blanket scan reports zero while a g6e.2xlarge bills at
# $2.24/hr (docs/GOTCHAS.md). They cannot outlive their cluster, so the EKS check
# below is the one that actually covers them; the instance check is a backstop and
# is labelled as such rather than trusted.
log "=== Verifying teardown (checking the line items that keep billing) ==="
LEFTOVERS=0
check_gone() {  # <label> <command...>
  local label="$1"; shift
  local found
  found=$("$@" 2>/dev/null | tr '\t' ' ' | tr -s ' ' | sed '/^\s*$/d' | head -5)
  if [ -z "$found" ]; then
    log "  clean    ${label}"
  else
    LEFTOVERS=$((LEFTOVERS + 1))
    warn "  REMAINS  ${label}: $(echo "$found" | tr '\n' ' ')"
  fi
}

check_gone "EKS clusters" \
  aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output text
check_gone "NAT gateways" \
  aws ec2 describe-nat-gateways --region "$AWS_REGION" --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text
check_gone "Load balancers" \
  aws elbv2 describe-load-balancers --region "$AWS_REGION" --query 'LoadBalancers[].LoadBalancerName' --output text
check_gone "Active capacity reservations" \
  aws ec2 describe-capacity-reservations --region "$AWS_REGION" --filters Name=state,Values=active --query 'CapacityReservations[].CapacityReservationId' --output text
check_gone "Elastic IPs" \
  aws ec2 describe-addresses --region "$AWS_REGION" --query 'Addresses[].AllocationId' --output text
check_gone "ElastiCache serverless (Valkey)" \
  aws elasticache describe-serverless-caches --region "$AWS_REGION" --query 'ServerlessCaches[].ServerlessCacheName' --output text
check_gone "AMP workspaces" \
  aws amp list-workspaces --region "$AWS_REGION" --query 'workspaces[].workspaceId' --output text
check_gone "Non-default VPCs" \
  aws ec2 describe-vpcs --region "$AWS_REGION" --filters Name=isDefault,Values=false --query 'Vpcs[].VpcId' --output text
check_gone "Unattached EBS volumes" \
  aws ec2 describe-volumes --region "$AWS_REGION" --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
check_gone "Instances (backstop only -- Auto Mode nodes are hidden here)" \
  aws ec2 describe-instances --region "$AWS_REGION" --filters Name=instance-state-name,Values=running,pending --query 'Reservations[].Instances[].InstanceId' --output text

if [ "$LEFTOVERS" -eq 0 ]; then
  log "=== Teardown verified: nothing billable left in ${AWS_REGION}. ==="
else
  warn "======================================================================"
  warn "${LEFTOVERS} resource group(s) still present in ${AWS_REGION} — THESE ARE STILL BILLING."
  warn "Re-run this script; if something persists, delete it by hand (see docs/COST.md)."
  warn "======================================================================"
  exit 1
fi
