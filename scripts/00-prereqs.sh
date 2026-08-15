#!/usr/bin/env bash
# Checks local tooling + AWS account state before you spend any money.
# Run this FIRST. It makes no changes.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

log "Checking required CLI tools..."
missing=()
for tool in aws kubectl helm terraform docker jq envsubst curl; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  die "Missing required tools: ${missing[*]}. Install these before continuing."
fi
log "All required tools present: aws kubectl helm terraform docker jq envsubst curl"

log "Checking AWS identity..."
# Masked rather than printed raw (account ID + ARN would otherwise land in
# the .out.txt transcript scripts/lib/env.sh writes for every run — see
# README's "Every script's full terminal output" note. Only the account ID
# is a secret worth hiding here; UserId/session name aren't credentials.
IDENTITY_JSON=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || die "AWS CLI not authenticated. Run 'aws configure' or set up SSO first."
ACCOUNT_ID=$(echo "$IDENTITY_JSON" | jq -r '.Account')
ARN=$(echo "$IDENTITY_JSON" | jq -r '.Arn')
MASKED_ACCOUNT="********${ACCOUNT_ID: -4}"
MASKED_ARN="${ARN/$ACCOUNT_ID/$MASKED_ACCOUNT}"
log "Authenticated as: ${MASKED_ARN} (account ${MASKED_ACCOUNT})"

# --- Free Tier / new-account launch restriction -----------------------------
# Real gotcha hit on the first live run of this repo (see docs/GOTCHAS.md
# "Reproducing this repo in a fresh AWS account" and DIAGNOSTICS0.md-DIAGNOSTICS4.md
# for the full multi-hour trace): a brand-new or rarely-used AWS account can have
# an ACCOUNT-WIDE restriction that blocks launching ANY non-Free-Tier-eligible
# instance type. This has nothing to do with any service quota — quota checks
# below can look perfectly fine while this restriction still blocks every launch.
# It broke 01-deploy-infra.sh in a way that's invisible at the Kubernetes/Terraform
# layer: Karpenter's `general-purpose` NodePool (needed for the S3 CSI driver
# controller and the kube-prometheus-stack Helm hooks) churns forever without
# ever producing a node, and the real error only shows up in a raw CloudTrail
# CreateFleet event body as `errorCode: InvalidParameterCombination`,
# `errorMessage: "The specified instance type is not eligible for Free Tier..."`.
#
# Detect it early with an EC2 dry-run using a representative non-free-tier type
# (c5.large — one of the types Karpenter's general-purpose pool actually tries).
# `--dry-run` validates the request (including this restriction) without
# launching anything or costing a cent; a clean account gets `DryRunOperation`
# ("would have succeeded"), a restricted one gets the Free Tier error immediately.
log "Checking for an account-wide Free Tier launch restriction..."
AMI_ID=$(aws ssm get-parameter --region "$AWS_REGION" \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "")
if [ -n "$AMI_ID" ]; then
  DRYRUN_OUT=$(aws ec2 run-instances --region "$AWS_REGION" --dry-run \
    --instance-type c5.large --image-id "$AMI_ID" --count 1 2>&1 || true)
  if echo "$DRYRUN_OUT" | grep -qi "not eligible for Free Tier"; then
    warn "Your AWS account currently blocks launching non-Free-Tier-eligible instances (a c5.large dry-run failed with 'not eligible for Free Tier'). This WILL break 01-deploy-infra.sh — Karpenter's general-purpose NodePool needs exactly this kind of instance to run the S3 CSI driver controller and kube-prometheus-stack's install hooks."
    warn "This is a temporary AWS account validation hold, NOT a bug in this repo — see docs/GOTCHAS.md and DIAGNOSTICS0.md-DIAGNOSTICS4.md for the full live trace. AWS typically sends an automatic 'your request has been validated' email once it clears (minutes to ~a day observed). There is nothing to fix on your end but waiting — re-run this script periodically until this check passes."
  elif echo "$DRYRUN_OUT" | grep -qi "DryRunOperation"; then
    log "No Free Tier launch restriction detected (dry-run succeeded)."
  else
    log "Free Tier restriction dry-run check was inconclusive (often just means no default VPC exists yet, which is fine) — skipping."
  fi
else
  log "Could not resolve a test AMI via SSM — skipping Free Tier restriction check."
fi

log "Checking GPU instance quota for ${INSTANCE_TYPE} in ${AWS_REGION}..."
# g6e instances fall under the "Running On-Demand G and VT instances" vCPU-based quota (L-DB2E81BA).
# A fresh/rarely-used account often defaults to 0 — request an increase BEFORE running 01-deploy-infra.sh.
# Quota approval can take minutes to hours; don't let it eat into your cost-tracked window.
QUOTA=$(aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-DB2E81BA \
  --region "$AWS_REGION" --query 'Quota.Value' --output text 2>/dev/null || echo "unknown")
log "Current 'Running On-Demand G and VT instances' vCPU quota in ${AWS_REGION}: ${QUOTA}"
if [ "$QUOTA" = "unknown" ]; then
  warn "Could not read quota automatically. Check manually: EC2 console -> Service Quotas -> G and VT instances."
elif awk -v q="$QUOTA" 'BEGIN{exit !(q < 8)}'; then
  # g6e.2xlarge = 8 vCPUs
  warn "Quota (${QUOTA} vCPUs) looks too low for one g6e.2xlarge (8 vCPUs). Request an increase now — GPU-family quotas commonly open an AWS Support case for manual review rather than auto-approving instantly (observed: hours, not minutes), so do this before you plan to run 02-gpu-infrastructure.sh:"
  warn "  aws service-quotas request-service-quota-increase --region ${AWS_REGION} --service-code ec2 --quota-code L-DB2E81BA --desired-value 8"
  warn "Check status with:"
  warn "  aws service-quotas list-requested-service-quota-change-history --region ${AWS_REGION} --service-code ec2 --query \"RequestedQuotas[?QuotaCode=='L-DB2E81BA']\""
fi

log "Checking for an existing active GPU capacity reservation (avoid creating a duplicate)..."
EXISTING_ODCR=$(aws ec2 describe-capacity-reservations --region "$AWS_REGION" \
  --filters "Name=state,Values=active" "Name=instance-type,Values=${INSTANCE_TYPE}" \
  --query "CapacityReservations[0].CapacityReservationId" --output text 2>/dev/null || echo "None")
if [ "$EXISTING_ODCR" != "None" ] && [ -n "$EXISTING_ODCR" ]; then
  warn "Found an existing active ODCR for ${INSTANCE_TYPE}: ${EXISTING_ODCR}. 01-deploy-infra.sh will reuse it rather than creating a second one — verify this is one you expect."
fi

log "Prereqs check complete. Read docs/COST.md before running 01-deploy-infra.sh — this is not a free-tier-eligible repo."
