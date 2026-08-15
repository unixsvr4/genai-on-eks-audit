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

log "terraform apply (region=${AWS_REGION})... this takes ~20-25 minutes."
terraform -chdir="$TF_DIR" apply --auto-approve -var="region=${AWS_REGION}"

log "Updating kubeconfig for cluster ${CLUSTER_NAME}..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

log "Verifying cluster connection..."
kubectl get pods --all-namespaces

# Gotcha (docs/GOTCHAS.md "EKS Auto Mode & cluster setup"): checkip.amazonaws.com
# MUST be queried from wherever YOU are actually running this script, not from
# inside a remote build box / CI runner unless that's genuinely your access point -
# otherwise you'll restrict ALB access to the wrong IP and lock yourself out.
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
log "Restricting ALB ingress to ${MY_IP}/32..."
kubectl patch ingressclassparams alb --type=merge \
  -p "{\"spec\":{\"inboundCIDRs\":[\"${MY_IP}/32\"]}}"

log "Infra deployed. Next: ./02-gpu-infrastructure.sh"
