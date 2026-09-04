#!/usr/bin/env bash
# Checks local tooling + AWS account state before you spend any money.
# Run this FIRST. It creates nothing and costs nothing, and it is the only script
# in this repo that can tell you the workshop is unrunnable BEFORE anything is
# billable. The single change it can make is local and reversible: if a Docker
# daemon is running but your docker CLI points at a socket that does not exist,
# it repoints the CLI (docker context only -- no AWS call, no cluster call).
#
# Exit codes: 0 = clear to proceed, 1 = a check refused (most importantly, the
# account is on the FREE plan, which cannot launch the GPU instance type at all).
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

log "Checking required CLI tools..."
missing=()
# docker is deliberately NOT in this list. 05-agentic-app.sh builds its image
# in-cluster now, so a local Docker daemon is optional -- see the check below.
for tool in aws kubectl helm terraform jq envsubst curl; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  die "Missing required tools: ${missing[*]}. Install these before continuing."
fi
log "All required tools present: aws kubectl helm terraform jq envsubst curl"

# Docker is OPTIONAL. 05-agentic-app.sh builds in-cluster by default, on an amd64
# node, which is what removed this module's three laptop-shaped failures
# (daemon down / wrong context / wrong architecture -- DIAGNOSTICS9.md). You only
# need a local daemon if you opt back into the upstream path with
# USE_LOCAL_DOCKER=1, so this reports and never blocks.
if ! command -v docker >/dev/null 2>&1; then
  log "Docker CLI not installed -- fine. 05 builds in-cluster; you would only need it for USE_LOCAL_DOCKER=1."
else
  set +e
  docker_daemon_check
  DOCKER_RC=$?
  set -e
  case "$DOCKER_RC" in
    0)
      log "Docker daemon is reachable (only needed for USE_LOCAL_DOCKER=1; 05 builds in-cluster by default)."
      ;;
    1)
      # A daemon IS running; the docker CLI is just pointed at a socket that does
      # not exist. Repair it here rather than printing two commands to retype --
      # this is the one local change this script makes (docker CLI config only:
      # no AWS call, no cluster call, no cost, undo with 'docker context use default').
      warn "'docker info' failed, but a Docker daemon IS running at ${DOCKER_ALT_SOCK}."
      warn "Your docker context was pointing somewhere else. Repointing it..."
      if docker_daemon_autofix; then
        log "Docker now works via context '${DOCKER_CTX_NAME}' -> unix://${DOCKER_ALT_SOCK}"
        log "  (this persists across shells; undo with: docker context use default)"
      else
        warn "Could not repoint the docker context automatically. Only matters for USE_LOCAL_DOCKER=1:"
        while IFS= read -r line; do warn "$line"; done <<< "$(docker_daemon_advice)"
      fi
      ;;
    *)
      log "Docker CLI present but no daemon reachable -- fine, 05 builds in-cluster. (USE_LOCAL_DOCKER=1 would need one.)"
      ;;
  esac
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

# Only reachable when the FREE-plan stop above was explicitly overridden.
if [ "$PLAN_BLOCKS_GPU" -eq 1 ]; then
  warn "----------------------------------------------------------------------"
  warn "SUMMARY: this account is on the FREE plan and ${INSTANCE_TYPE} is NOT"
  warn "launchable on it. You overrode the stop with ALLOW_FREE_TIER_BLOCKED=1."
  warn "Every check printed after that point is advisory only — the quota and the"
  warn "capacity reservation are irrelevant while the plan itself refuses the"
  warn "launch. 02-gpu-infrastructure.sh will still refuse on its own. Upgrade to"
  warn "a paid plan first. See DIAGNOSTICS8.md."
  warn "----------------------------------------------------------------------"
fi

log "Prereqs check complete. Read docs/COST.md before running 01-deploy-infra.sh — this is not a free-tier-eligible repo."
