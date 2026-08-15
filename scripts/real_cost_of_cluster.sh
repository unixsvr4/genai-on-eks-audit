#!/usr/bin/env bash
# Estimates the REAL dollar cost accrued SO FAR by whatever this repo has
# actually deployed right now — based on live AWS resource creation
# timestamps, not the hypothetical 4-hour run docs/COST.md walks through.
# Read-only. Makes no changes, costs nothing to run.
#
# Rates are the same approximate on-demand us-east-2 figures used in
# docs/COST.md (verify against https://calculator.aws for anything that
# matters) — the xlarge general-purpose rates were cross-checked against the
# real EC2 Fleet "lowest-price" priorities captured live in DIAGNOSTICS3.md,
# so those specific numbers are more than a guess. Everything here is still
# an estimate, not a bill — see "Want the real number?" at the bottom.
#
# Uses `aws ... --output json | jq` throughout rather than `--query`
# (JMESPath) — jq's plain string syntax avoids JMESPath's backtick-literal
# footgun (a bare word in backticks is a parse error, not a string, and an
# earlier version of this script silently misread that error as "no
# resources found" because of a stray 2>/dev/null). jq is already a required
# dependency of this repo per scripts/00-prereqs.sh.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

NOW_EPOCH=$(date -u +%s)
TOTAL="0.00"
EARLIEST_EPOCH=""

epoch_of() {
  # Normalizes an AWS API timestamp (e.g. 2026-08-13T14:52:31.000000+00:00)
  # to epoch seconds, working on both GNU date (Linux) and BSD date (macOS).
  local norm
  norm=$(printf '%s' "$1" | sed -E 's/\.[0-9]+//; s/\+00:00$/Z/; s/\+0000$/Z/')
  if command -v gdate >/dev/null 2>&1; then
    gdate -u -d "$norm" +%s
  elif date -u -d "$norm" +%s >/dev/null 2>&1; then
    date -u -d "$norm" +%s
  else
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$norm" +%s
  fi
}

hours_since() {
  awk -v now="$NOW_EPOCH" -v then="$1" 'BEGIN{h=(now-then)/3600; printf "%.3f", (h<0?0:h)}'
}

track_earliest() {
  if [ -z "$EARLIEST_EPOCH" ] || [ "$1" -lt "$EARLIEST_EPOCH" ]; then
    EARLIEST_EPOCH="$1"
  fi
}

add_line() {
  # add_line "<label>" <hours> <rate_per_hour>
  local label="$1" hours="$2" rate="$3" cost
  cost=$(awk -v h="$hours" -v r="$rate" 'BEGIN{printf "%.2f", h*r}')
  TOTAL=$(awk -v t="$TOTAL" -v c="$cost" 'BEGIN{printf "%.2f", t+c}')
  printf "  %-55s %7sh x \$%-7s = \$%s\n" "$label" "$hours" "$rate" "$cost"
}

rate_per_hour() {
  # Approximate on-demand us-east-2 hourly rate. xlarge values cross-checked
  # against real EC2 Fleet pricing priorities in DIAGNOSTICS3.md; "large"
  # sizes are approximated at half the xlarge rate (roughly linear with
  # vCPU count for a given family, not exact). Unknown types fall back to a
  # conservative flat estimate rather than erroring.
  case "$1" in
    g6e.2xlarge)      echo "2.20" ;;
    c7i-flex.large)   echo "0.0848" ;;
    c7i-flex.xlarge)  echo "0.16958" ;;
    c5.large)         echo "0.085" ;;
    c5.xlarge)        echo "0.17" ;;
    c5a.large)        echo "0.077" ;;
    c5a.xlarge)       echo "0.154" ;;
    c6a.large)        echo "0.0765" ;;
    c6a.xlarge)       echo "0.153" ;;
    c6i.large)        echo "0.085" ;;
    c6i.xlarge)       echo "0.17" ;;
    c7i.large)        echo "0.08925" ;;
    c7i.xlarge)       echo "0.1785" ;;
    c7a.large)        echo "0.10264" ;;
    c7a.xlarge)       echo "0.20528" ;;
    m5.large)         echo "0.096" ;;
    m5.xlarge)        echo "0.192" ;;
    m5a.large)        echo "0.086" ;;
    m5a.xlarge)       echo "0.172" ;;
    m6a.large)        echo "0.0864" ;;
    m6a.xlarge)       echo "0.1728" ;;
    m6i.large)        echo "0.096" ;;
    m6i.xlarge)       echo "0.192" ;;
    m7i-flex.large)   echo "0.09576" ;;
    m7i-flex.xlarge)  echo "0.19152" ;;
    t3.micro)         echo "0.0104" ;;
    t3.small)         echo "0.0208" ;;
    *) echo "0.20" ;;  # unrecognized type - conservative generic estimate, flagged below
  esac
}

echo ""
log "Estimating real cost accrued so far for cluster '${CLUSTER_NAME}' in ${AWS_REGION}..."
echo ""

# --- EKS control plane -------------------------------------------------------
log "=== EKS control plane ==="
CLUSTER_CREATED=$( (aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --output json 2>/dev/null || echo '{}') \
  | jq -r '.cluster.createdAt // empty')
if [ -n "$CLUSTER_CREATED" ]; then
  EPOCH=$(epoch_of "$CLUSTER_CREATED")
  track_earliest "$EPOCH"
  add_line "EKS control plane" "$(hours_since "$EPOCH")" "0.10"
else
  log "  No cluster named '${CLUSTER_NAME}' found — nothing to estimate here."
fi
echo ""

# --- GPU ODCR (this IS the billing unit for the GPU node, not the instance -
# see docs/COST.md: an active ODCR bills its own rate whether or not a
# matching instance is running in it) --------------------------------------
log "=== GPU capacity reservation (${INSTANCE_TYPE}) ==="
ODCR_JSON=$( (aws ec2 describe-capacity-reservations --region "$AWS_REGION" \
  --filters "Name=state,Values=active" "Name=instance-type,Values=${INSTANCE_TYPE}" \
  --output json 2>/dev/null || echo '{}') )
ODCR_ID=$(echo "$ODCR_JSON" | jq -r '.CapacityReservations[0].CapacityReservationId // empty')
ODCR_START=$(echo "$ODCR_JSON" | jq -r '.CapacityReservations[0].StartDate // empty')
if [ -n "$ODCR_ID" ]; then
  EPOCH=$(epoch_of "$ODCR_START")
  track_earliest "$EPOCH"
  RATE=$(rate_per_hour "$INSTANCE_TYPE")
  add_line "ODCR ${ODCR_ID}" "$(hours_since "$EPOCH")" "$RATE"
else
  log "  No active ODCR for ${INSTANCE_TYPE} — GPU line item is \$0 (module 02 not run yet, or already torn down)."
fi
echo ""

# --- All other running EC2 instances (system + general-purpose pools; skips
# the GPU instance type since the ODCR above already covers its billing) ----
log "=== Other EC2 instances (system / general-purpose pools) ==="
# Queries by explicit instance ID (from `kubectl get nodes` -- an EKS Auto
# Mode node's name IS its EC2 instance ID) rather than a blanket
# describe-instances scan. This was discovered the hard way: EKS Auto Mode's
# own worker instances carry "Operator": {"Managed": true, "Principal":
# "eks.amazonaws.com", "HiddenByDefault": true} in the EC2 API response, and
# an UNFILTERED describe-instances call excludes operator-managed resources
# entirely -- confirmed live (same account/region/moment: an ID-specific
# lookup found the instance fine, the blanket call returned zero
# Reservations). Querying by the exact IDs this cluster actually has as
# nodes sidesteps that opt-in-filter guessing game entirely, and is also
# more *correct*: it can't accidentally pick up unrelated instances
# elsewhere in the account.
NODE_IDS=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -n "$NODE_IDS" ]; then
  # shellcheck disable=SC2086 # word-splitting NODE_IDS is intentional here
  INSTANCES_JSON=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids $NODE_IDS --output json 2>/dev/null || echo '{}')
  INSTANCES=$(echo "$INSTANCES_JSON" | jq -r --arg gpu_type "$INSTANCE_TYPE" '
    .Reservations[]?.Instances[]?
    | select(.State.Name == "running" and .InstanceType != $gpu_type)
    | [.InstanceId, .InstanceType, .LaunchTime] | @tsv
  ')
else
  INSTANCES=""
fi
if [ -n "$INSTANCES" ]; then
  while IFS=$'\t' read -r id type launch; do
    [ -z "$id" ] && continue
    EPOCH=$(epoch_of "$launch")
    track_earliest "$EPOCH"
    RATE=$(rate_per_hour "$type")
    add_line "${id} (${type})" "$(hours_since "$EPOCH")" "$RATE"
  done <<< "$INSTANCES"
else
  log "  No other running instances found (or kubectl couldn't reach the cluster — run 'aws eks update-kubeconfig' first)."
fi
echo ""

# --- NAT Gateway(s) — flat rate only, data-processing ($0.045/GB) excluded -
log "=== NAT Gateway(s) (flat rate only — excludes \$0.045/GB data processing) ==="
NATS_JSON=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
  --filter "Name=state,Values=available" --output json 2>/dev/null || echo '{}')
NATS=$(echo "$NATS_JSON" | jq -r '.NatGateways[]? | [.NatGatewayId, .CreateTime] | @tsv')
if [ -n "$NATS" ]; then
  while IFS=$'\t' read -r id created; do
    [ -z "$id" ] && continue
    EPOCH=$(epoch_of "$created")
    track_earliest "$EPOCH"
    add_line "NAT Gateway ${id}" "$(hours_since "$EPOCH")" "0.045"
  done <<< "$NATS"
else
  log "  None found."
fi
echo ""

# --- ALBs — flat rate only, LCU-hours excluded ------------------------------
# NOTE: unverified whether ALBs created by EKS Auto Mode's built-in
# load-balancing operator (eks-auto-mode-loadbalancing, seen live in
# DIAGNOSTICS4.md's audit log) are ALSO excluded from an unfiltered
# describe-load-balancers call the same way operator-managed EC2 instances
# are (see the note above) -- no ALB existed yet to test this against. If a
# module that creates one (e.g. 04-observability.sh's Grafana ingress) shows
# $0 here while an ALB clearly exists in the console, that's why -- the fix
# would be the same pattern used above: look up the ARN via `kubectl get
# ingress` instead of a blanket scan.
log "=== Application Load Balancer(s) (flat rate only — excludes LCU-hours) ==="
ALBS_JSON=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --output json 2>/dev/null || echo '{}')
ALBS=$(echo "$ALBS_JSON" | jq -r '.LoadBalancers[]? | select(.Type == "application") | [.LoadBalancerName, .CreatedTime] | @tsv')
if [ -n "$ALBS" ]; then
  while IFS=$'\t' read -r name created; do
    [ -z "$name" ] && continue
    EPOCH=$(epoch_of "$created")
    track_earliest "$EPOCH"
    add_line "ALB ${name}" "$(hours_since "$EPOCH")" "0.0225"
  done <<< "$ALBS"
else
  log "  None found."
fi
echo ""

# --- ElastiCache Serverless (Valkey) — usage-based, can't estimate from CLI
log "=== ElastiCache Serverless (Valkey, if the 08-lmcache-valkey.sh module is up) ==="
VALKEY_JSON=$(aws elasticache describe-serverless-caches --region "$AWS_REGION" --output json 2>/dev/null || echo '{}')
VALKEY=$(echo "$VALKEY_JSON" | jq -r '.ServerlessCaches[]? | select(.ServerlessCacheName | contains("lmcache")) | [.ServerlessCacheName, .CreateTime] | @tsv')
if [ -n "$VALKEY" ]; then
  while IFS=$'\t' read -r name created; do
    [ -z "$name" ] && continue
    warn "  ${name} has been running since ${created} — this bills usage-based (GB-hour + ECPU-hours), NOT a flat rate, so it's not in the total below. Docs/COST.md estimates ~\$1-5 for a short lab; tear it down with the module's own cleanup-valkey.sh if you're done with it."
  done <<< "$VALKEY"
else
  log "  None found."
fi
echo ""

log "=== Estimated total accrued so far: \$${TOTAL} ==="
if [ -n "$EARLIEST_EPOCH" ]; then
  log "(across $(hours_since "$EARLIEST_EPOCH")h of wall-clock time since the earliest resource was created)"
fi
echo ""
warn "This is an ESTIMATE from resource timestamps x approximate on-demand rates — it excludes data transfer, NAT/ALB usage-based charges, S3/ECR storage (negligible), and any ElastiCache Valkey usage flagged above. It is NOT your AWS bill."
echo ""
log "Want the real (but delayed, usually 8-24h) number? AWS Cost Explorer, if enabled on this account:"
log "  aws ce get-cost-and-usage --time-period Start=\$(date -u +%Y-%m-%d),End=\$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d '+1 day' +%Y-%m-%d) --granularity DAILY --metrics UnblendedCost --region us-east-1"
log "(Cost Explorer's API is only available in us-east-1 regardless of which region your resources are in.)"
