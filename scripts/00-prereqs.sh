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

# --- Free Tier plan launch restriction ---------------------------------------
# THE single most expensive gotcha in this repo. See DIAGNOSTICS0.md-DIAGNOSTICS8.md.
#
# An AWS account on the *new* Free Tier plan (accountPlanType == FREE, the default
# for accounts created since the 2025 Free Tier redesign) may only launch instance
# types that are Free-Tier-eligible -- currently a set of six. Every other type is
# refused. This is a property of the account PLAN, not a transient hold, so it does
# NOT clear by waiting, and it is completely independent of service quotas: you can
# hold a granted 16-vCPU GPU quota and still be unable to launch a single g6e.
#
# It is invisible at the Kubernetes/Terraform layer. Karpenter's NodeClaims churn
# forever with `FreeTierIneligible`, and the underlying error only appears in a raw
# CloudTrail CreateFleet event body -- CreateFleet returns HTTP 200 and buries the
# rejection in `errorSet.item`:
#     errorCode:    InvalidParameterCombination
#     errorMessage: "The specified instance type is not eligible for Free Tier."
#
# DO NOT "detect" this with a dry-run. Three dry-run signals were measured against a
# genuinely blocked g6e.2xlarge (DIAGNOSTICS8.md) and ALL THREE reported success:
#   1. `aws ec2 run-instances --dry-run`  -> DryRunOperation   (what this script used
#      to do; it never evaluates Free Tier eligibility at all)
#   2. `aws ec2 create-fleet  --dry-run`  -> DryRunOperation   (returned success even
#      with a launch-template id that did not exist -- it validates almost nothing)
#   3. Karpenter's own internal CreateFleet dry-run -> Client.DryRunOperation
# Only a REAL CreateFleet surfaces it, and a real CreateFleet launches an instance.
#
# So this gate is authoritative instead of empirical: ask what plan the account is on,
# ask which types that plan permits, and compare. Zero cost, no cluster, no launch
# template, and it runs correctly before anything has been deployed.
PLAN_BLOCKS_GPU=0
# Shared with 02-gpu-infrastructure.sh via free_tier_check() in lib/env.sh, so the
# advisory check here and the hard gate there can never disagree.
log "Checking the account's Free Tier plan (this gates which instance types can launch at all)..."
set +e
free_tier_check "$INSTANCE_TYPE"
FT_RC=$?
set -e
case "$FT_RC" in
  0)
    if [ "$FT_PLAN_TYPE" = "FREE" ]; then
      log "Account is on the FREE plan, but ${INSTANCE_TYPE} is Free-Tier-eligible — the GPU node can launch."
    else
      log "Account plan is ${FT_PLAN_TYPE} — no Free Tier instance-type restriction."
    fi
    ;;
  1)
    warn "This account is on the FREE plan. It can ONLY launch these instance types in ${AWS_REGION}:"
    warn "  $(echo "$FT_ELIGIBLE_TYPES" | tr '\n' ' ')"
    warn "${INSTANCE_TYPE} is NOT among them, so 02-gpu-infrastructure.sh CANNOT launch a GPU node on this account, no matter what the GPU quota says."
    warn "This does NOT clear by waiting — it is the account's plan, not a temporary validation hold. Upgrade first:"
    warn "  aws freetier upgrade-account-plan --account-plan-type PAID"
    warn "  (or: AWS Billing console -> Free Tier -> 'Upgrade to a paid plan')"
    warn "Until then, DO NOT run 02-gpu-infrastructure.sh: it creates a ${ODCR_HOURS}h On-Demand Capacity Reservation that bills the full ${INSTANCE_TYPE} rate from the moment it is created, for capacity no node will ever be able to occupy. (That script now refuses on its own too.)"
    PLAN_BLOCKS_GPU=1
    # 01-deploy-infra.sh survives a FREE plan only because Karpenter's system and
    # general-purpose pools accept a wide instance-type range and can fall back to an
    # eligible one (c7i-flex.large, on the reference account). The gpu NodePool is
    # pinned to exactly one type, so it has no fallback — that asymmetry is why
    # DIAGNOSTICS0-7 read the failure as "intermittent, seems to be clearing".
    if ! echo "$FT_ELIGIBLE_TYPES" | grep -qE '^(c7i-flex|m7i-flex)\.large$'; then
      warn "No flex-class type is Free-Tier-eligible in ${AWS_REGION} either — 01-deploy-infra.sh's system/general-purpose NodePools may not find a launchable type here at all."
    fi
    ;;
  *)
    warn "Could not read the account plan (needs aws-cli >= 2.22 and freetier:GetAccountPlanState). Skipping the Free Tier gate — if 01/02 later churn NodeClaims with 'FreeTierIneligible', this is why. Check manually:"
    warn "  aws freetier get-account-plan-state"
    ;;
esac

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

if [ "$PLAN_BLOCKS_GPU" -eq 1 ]; then
  warn "----------------------------------------------------------------------"
  warn "SUMMARY: 01-deploy-infra.sh can run, but 02-gpu-infrastructure.sh cannot"
  warn "succeed on this account's FREE plan — ${INSTANCE_TYPE} is not launchable."
  warn "Upgrade to a paid plan before running 02, or you will pay for an unusable"
  warn "capacity reservation. See DIAGNOSTICS8.md."
  warn "----------------------------------------------------------------------"
fi

log "Prereqs check complete. Read docs/COST.md before running 01-deploy-infra.sh — this is not a free-tier-eligible repo."
