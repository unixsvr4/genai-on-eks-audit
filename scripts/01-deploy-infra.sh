#!/usr/bin/env bash
# Module: Getting Started + Setting Up the Cluster (RESEARCH.md §1-2)
# Provisions VPC + EKS Auto Mode cluster + GPU NodePool/NodeClass + observability
# stack + S3 model bucket via AWS's own Terraform, then restricts ALB ingress to
# your own IP. Costs start accruing the moment `terraform apply` succeeds — see
# docs/COST.md. Deployment takes ~20-25 minutes per the workshop's own estimate.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

TF_DIR="${DEPLOY_DIR}/sample-genai-on-eks/terraform"
[ -d "$TF_DIR" ] || die "Terraform not found at ${TF_DIR} — run ./00-clone-terraform.sh first."

log "terraform init..."
terraform -chdir="$TF_DIR" init

# Gotcha (DIAGNOSTICS0/4/6.md, hit three times): when a previous `terraform
# apply` dies partway -- e.g. the 20-minute s3_csi_driver addon timeout -- Helm
# has already written a release record for kube-prometheus-stack but Terraform
# never got to save it to state. The next apply then does a fresh `helm install`
# and Helm refuses with "cannot re-use a name that is still in use", which reads
# like a Terraform bug but is just orphaned Helm state.
#
# Clear it, but ONLY when it is genuinely orphaned: the release is failed/
# pending AND Terraform has no record of it. A release Terraform *does* track is
# left alone -- uninstalling that would be destructive, not a repair.
if command -v helm >/dev/null 2>&1 && kubectl get ns monitoring >/dev/null 2>&1; then
  KPS_STATUS=$(helm list -n monitoring -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(next((r["status"] for r in json.load(sys.stdin) if r["name"]=="kube-prometheus-stack"), ""))' 2>/dev/null || echo "")
  case "$KPS_STATUS" in
    failed|pending-install|pending-upgrade)
      if terraform -chdir="$TF_DIR" state list 2>/dev/null | grep -q '^helm_release\.kube_prometheus_stack$'; then
        warn "kube-prometheus-stack is '${KPS_STATUS}' but IS in Terraform state -- leaving it for Terraform to reconcile."
      else
        warn "Found an orphaned '${KPS_STATUS}' kube-prometheus-stack Helm release that Terraform does not track (leftover from an interrupted apply). Uninstalling so this apply can install cleanly."
        helm uninstall kube-prometheus-stack -n monitoring || true
      fi
      ;;
  esac
fi

log "terraform apply (region=${AWS_REGION})... this takes ~20-25 minutes."
terraform -chdir="$TF_DIR" apply --auto-approve -var="region=${AWS_REGION}"

log "Updating kubeconfig for cluster ${CLUSTER_NAME}..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

log "Verifying cluster connection..."
kubectl get pods --all-namespaces

log "Nodes this created (the gpu NodePool won't show here -- it only launches a node once 02-gpu-infrastructure.sh schedules a pod onto it):"
kubectl get nodes -o wide

# Gotcha (docs/GOTCHAS.md "EKS Auto Mode & cluster setup"): checkip.amazonaws.com
# MUST be queried from wherever YOU are actually running this script, not from
# inside a remote build box / CI runner unless that's genuinely your access point -
# otherwise you'll restrict ALB access to the wrong IP and lock yourself out.
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
log "Restricting ALB ingress to ${MY_IP}/32..."
kubectl patch ingressclassparams alb --type=merge \
  -p "{\"spec\":{\"inboundCIDRs\":[\"${MY_IP}/32\"]}}"

log "Infra deployed. Next: ./02-gpu-infrastructure.sh"
