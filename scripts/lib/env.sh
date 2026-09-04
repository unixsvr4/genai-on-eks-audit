#!/usr/bin/env bash
# Shared environment for every script in this repo. Source it, don't run it:
#   source "$(dirname "$0")/lib/env.sh"
#
# Every value here can be overridden by exporting it before running a script,
# e.g.: AWS_REGION=us-west-2 ./scripts/01-deploy-infra.sh

set -euo pipefail

# Resolved here (ahead of the S3_BUCKET_NAME etc. exports below) because the
# output-masking pipeline set up next needs both before any script output
# flows. One call, parsed with jq (this repo's convention over --query/JMESPath).
IDENTITY_JSON="$(aws sts get-caller-identity --output json)"
AWS_ACCOUNT_ID="$(echo "$IDENTITY_JSON" | jq -r '.Account')"
export AWS_ACCOUNT_ID
MASKED_ACCOUNT_ID="********${AWS_ACCOUNT_ID: -4}"
# The IAM user/role name (last path segment of the ARN, e.g. "sysadmin" from
# .../user/sysadmin) shows up in ARNs throughout terraform apply/destroy logs
# just like the account ID. Same masking shape as the account ID above (fixed
# prefix masked, suffix kept) so it stays a recognizable-but-not-full name,
# e.g. "sysadmin" -> "***admin".
CALLER_ARN="$(echo "$IDENTITY_JSON" | jq -r '.Arn')"
CALLER_NAME="${CALLER_ARN##*/}"
if [ "${#CALLER_NAME}" -gt 3 ]; then
  MASKED_CALLER_NAME="***${CALLER_NAME:3}"
else
  MASKED_CALLER_NAME="***"
fi

# Tee every script's full terminal output (stdout + stderr) to a same-named
# <script>.out.txt in outputs/, so a run can be reviewed/shared (e.g. with
# workshop students) without re-running anything live. $0 here is the
# invoking script's own path — sourcing this file doesn't change $0, only
# BASH_SOURCE[0] (which would point at this file instead). Two perl stages
# piped in sequence: the first masks every occurrence of the raw AWS account
# ID and IAM user/role name — both show up in nearly every ARN terraform/aws
# prints (e.g. a destroy run's IAM/EKS resource IDs) — in BOTH the terminal
# and the file copy, since it runs before tee splits the stream; the second
# strips this repo's own log()/warn()/die() ANSI colors for the file copy
# only (terminal keeps color). Third-party tools (terraform/kubectl/helm/aws)
# auto-disable their own color once stdout isn't a TTY, which is expected
# pipe behavior, not something to work around.
# The mask program is SINGLE-quoted, so bash never substitutes into it and
# perl never parses an identifier as code. Values travel through the
# environment instead, which fixes three things at once:
#
#   1. Interpolation. `\Q` suppresses regex METAcharacters, not
#      interpolation, so an inlined `s/\Qa.b@gmail.com\E/.../g` has perl
#      expand `@gmail` as an empty array and silently match `a.b.com`, which
#      never appears. The email clause here had therefore never masked
#      anything; it only looked correct because the scripts print the
#      pre-masked shell variable themselves. Raw identifiers appearing in
#      third-party output (terraform/kubectl/cloud CLI) went through
#      unmasked, into the terminal and the outputs/ transcript both.
#      Confirmed with `perl -wpe`: "Possible unintended interpolation of
#      @gmail in string".
#   2. Process-table exposure. Inlining put the raw account id and email in
#      perl's argv, where any user on the box could read them out of `ps`.
#      %ENV is not shown by a plain `ps -e`.
#   3. Empty and metacharacter-bearing values. `length` guards the
#      empty-pattern case that would otherwise insert the replacement
#      between every character, and \Q on a runtime value correctly
#      literalizes `+ / .` in names.
#
# BEGIN{$|=1} is the autoflush: perl block-buffers at 8KB whenever STDOUT is
# not a TTY, and neither stage here has one -- the first writes into a pipe
# to tee, the second into the transcript file. Without it a script that logs
# a few lines then blocks on a slow cloud call prints NOTHING for the
# duration and leaves the transcript at 0 bytes, indistinguishable from a
# hang. Found in azure/ (RESEARCH.md entry 13a) where 00-prereqs.sh ran
# 3m12s that way.
MASK_PROG='BEGIN{$|=1}
  for my $i (1..9) {
    my $s = $ENV{"MASK_SRC_$i"};
    next unless defined $s && length $s;
    my $d = $ENV{"MASK_DST_$i"};
    $d = "" unless defined $d;
    s/\Q$s\E/$d/g;
  }'
export MASK_SRC_1="$AWS_ACCOUNT_ID" MASK_DST_1="$MASKED_ACCOUNT_ID"
export MASK_SRC_2="$CALLER_NAME"    MASK_DST_2="$MASKED_CALLER_NAME"
SCRIPT_OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/outputs"
mkdir -p "$SCRIPT_OUT_DIR"
# Transcripts are per-RUN, not per-script. The old fixed `<script>.out.txt` meant
# every re-run silently overwrote the previous one — which destroyed exactly the
# evidence you most want to keep, since the case where you re-run a script is the
# case where the first attempt went wrong. (Lost this way: the successful
# 99-destroy-all run whose ordering we wanted to inspect, clobbered ~10 minutes
# later by a second no-op run of the same script.)
#
# `<script>-<YYYYmmdd-HHMMSS>.out.txt` keeps every run; `<script>-latest.out.txt`
# is a relative symlink to the newest, so `cat outputs/01-deploy-infra-latest.out.txt`
# still just works. The whole directory is gitignored — these are local-only and
# carry account IDs/ARNs/IPs.
SCRIPT_STEM="$(basename "$0" .sh)"
SCRIPT_OUT_FILE="${SCRIPT_OUT_DIR}/${SCRIPT_STEM}-$(date +%Y%m%d-%H%M%S).out.txt"
# Two runs starting in the same second would otherwise share a file.
_n=2
while [ -e "$SCRIPT_OUT_FILE" ]; do
  SCRIPT_OUT_FILE="${SCRIPT_OUT_DIR}/${SCRIPT_STEM}-$(date +%Y%m%d-%H%M%S)_${_n}.out.txt"
  _n=$((_n + 1))
done
ln -sfn "$(basename "$SCRIPT_OUT_FILE")" "${SCRIPT_OUT_DIR}/${SCRIPT_STEM}-latest.out.txt"
exec > >(perl -pe "$MASK_PROG" \
         | tee >(perl -pe 'BEGIN{$|=1} s/\e\[[0-9;]*m//g' > "$SCRIPT_OUT_FILE")) 2>&1

export AWS_REGION="${AWS_REGION:-us-east-2}"                 # same region the workshop used
export CLUSTER_NAME="${CLUSTER_NAME:-genai-workshop}"
export INSTANCE_TYPE="${INSTANCE_TYPE:-g6e.2xlarge}"          # same instance type the workshop used (1x NVIDIA L40S, 46GB VRAM)
# No AMI ID is pinned on purpose: EKS Auto Mode auto-selects its own Bottlerocket
# GPU-optimized AMI variant for this instance family (see docs/ARCHITECTURE.md,
# "EKS Standard vs Auto Mode") — that IS "the same AMI the workshop uses," since
# the workshop itself never pins one either. Pinning an AMI ID would fight Auto Mode's
# own node-rotation/patching behavior, not replicate the workshop's setup.

export TERRAFORM_TAG="${TERRAFORM_TAG:-v2.5.2}"                # see terraform/README.md
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.deploy}"
export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export MANIFEST_DIR="${REPO_ROOT}/manifests"

# Auto-expiry window for the GPU ODCR — the primary cost safety net. See docs/COST.md.
export ODCR_HOURS="${ODCR_HOURS:-4}"

# Populated by earlier scripts / derived at runtime — don't set these yourself.
# (AWS_ACCOUNT_ID itself is already resolved above, ahead of the output-masking setup.)
export S3_BUCKET_NAME="genai-models-${AWS_ACCOUNT_ID}"
export S3_VECTOR_BUCKET_NAME="rag-vectors-${AWS_ACCOUNT_ID}-${AWS_REGION}"
export S3_VECTOR_INDEX_NAME="knowledge-base"
export S3_RAG_DATA_BUCKET="rag-workshop-data-${AWS_ACCOUNT_ID}-${AWS_REGION}"

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARNING:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] FATAL:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# --- Free Tier plan eligibility (shared by 00-prereqs.sh and 02-gpu-infrastructure.sh) ---
# An account on the new Free Tier plan (accountPlanType=FREE) may launch ONLY the
# free-tier-eligible instance types. This is a plan property: it does not expire, it
# is evaluated BEFORE service quotas, and no dry-run can detect it -- run-instances
# --dry-run, create-fleet --dry-run and Karpenter's own internal dry-run were all
# measured returning success against a provably-blocked g6e.2xlarge. See
# DIAGNOSTICS8.md. So ask the account what plan it is on and what that plan permits.
#
# Sets FT_PLAN_TYPE and FT_ELIGIBLE_TYPES, then returns:
#   0  the given instance type is launchable (or the plan does not restrict it)
#   1  the plan is FREE and the type is NOT launchable
#   2  indeterminate (old CLI, missing freetier:GetAccountPlanState, unknown plan)
free_tier_check() {
  local want="$1"
  FT_PLAN_TYPE="$(aws freetier get-account-plan-state --query 'accountPlanType' --output text 2>/dev/null || echo "")"
  FT_ELIGIBLE_TYPES=""
  case "$FT_PLAN_TYPE" in
    FREE)
      FT_ELIGIBLE_TYPES="$(aws ec2 describe-instance-types --region "$AWS_REGION" \
        --filters "Name=free-tier-eligible,Values=true" \
        --query 'InstanceTypes[].InstanceType' --output text 2>/dev/null | tr '\t' '\n' | sort)"
      # An empty list means the describe call failed, not that nothing is eligible --
      # don't turn an API hiccup into a hard block.
      [ -z "$FT_ELIGIBLE_TYPES" ] && return 2
      echo "$FT_ELIGIBLE_TYPES" | grep -qx "$want" && return 0
      return 1
      ;;
    PAID)    return 0 ;;
    ""|None) return 2 ;;
    *)       return 2 ;;
  esac
}

# --- Readiness helpers --------------------------------------------------------
# Both of these exist because several scripts used a fixed `sleep 3` (or a flag
# that does not exist) in place of an actual readiness check, and then reported a
# timing problem as an infrastructure failure. See DIAGNOSTICS9.md.

# Wait for an Ingress to be given its load-balancer hostname.
#
# ALB provisioning is asynchronous: the AWS Load Balancer Controller has to see
# the Ingress, create the ALB, and write the hostname back into
# .status.loadBalancer.ingress[0].hostname. Measured live 2026-09-04: 39s. Reading
# it immediately after `kubectl apply` always yields an empty string.
#
# NOTE: `kubectl get --timeout=120s` does NOT do this. `--timeout` is not a valid
# flag for `kubectl get` at all ("error: unknown flag: --timeout"), so that idiom
# fails instantly and, with 2>/dev/null || echo "pending", silently prints
# "pending" forever -- which is exactly the bug this replaces.
#
# Usage: lb_hostname <ingress-name> [extra kubectl args, e.g. -n monitoring]
# Echoes the hostname and returns 0, or echoes nothing and returns 1 on timeout.
lb_hostname() {
  local name="$1"; shift
  local deadline=$(( $(date +%s) + ${LB_TIMEOUT:-300} ))
  local h=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # AWS ALBs publish .hostname; GKE/AKS publish .ip. Take whichever exists so
    # this helper stays valid when gcloud/ and azure/ grow their own scripts.
    h=$(kubectl get ingress "$name" "$@" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' \
      2>/dev/null || echo "")
    if [ -n "$h" ]; then echo "$h"; return 0; fi
    sleep 5
  done
  return 1
}

# Start a port-forward and block until the far end actually answers HTTP.
#
# `kubectl wait --for=jsonpath='{.status.phase}'=Running` only proves the
# container process started. A server that then loads a model (vLLM: 9.7GB from
# S3 onto the GPU, measured at 69s) is not listening yet, and the port-forward
# reports that as what looks like a CNI fault:
#     failed to connect to localhost:8000 inside namespace "..."
#     connect: connection refused / error: lost connection to pod
# kubectl port-forward EXITS in that case, so this restarts it rather than
# holding a dead PID.
#
# Any HTTP response counts as ready -- a 404 still proves something is listening,
# and not every service has a /health.
#
# Pass a pod selector as the 4th argument and this also gives up early on a pod
# that can NEVER become ready, instead of waiting out the full timeout. Observed
# live 2026-09-04: an arm64 image on an amd64 node crash-looped with "exec format
# error", and without this the caller sat polling a doomed pod for 5 minutes.
#
# Usage: pf_start <svc/name> <localport>:<remoteport> [path] [pod-selector]
# Sets PF_PID on success. Returns 1 on timeout, 2 if the backing pod is failing
# (reason in PF_ABORT_REASON). PF_PID is left empty on both failures.
pf_start() {
  local target="$1" ports="$2" path="${3:-/}" selector="${4:-}"
  local lport="${ports%%:*}"
  local deadline=$(( $(date +%s) + ${PF_TIMEOUT:-300} ))
  PF_PID=""
  PF_ABORT_REASON=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -n "$selector" ]; then
      PF_ABORT_REASON=$(kubectl get pods -l "$selector" -o json 2>/dev/null | python3 -c '
import json,sys
try: pods=json.load(sys.stdin).get("items",[])
except Exception: sys.exit(0)
for p in pods:
    for c in p.get("status",{}).get("containerStatuses",[]):
        st=c.get("state",{})
        w=st.get("waiting") or {}
        if w.get("reason") in ("CrashLoopBackOff","ImagePullBackOff","ErrImagePull","CreateContainerError"):
            print("%s: %s (%s restarts)" % (c["name"], w["reason"], c.get("restartCount",0)))
            sys.exit(0)
        t=st.get("terminated") or {}
        if t.get("exitCode") and c.get("restartCount",0) >= 3:
            print("%s: exited %s, %s restarts" % (c["name"], t["exitCode"], c["restartCount"]))
            sys.exit(0)
' 2>/dev/null || echo "")
      if [ -n "$PF_ABORT_REASON" ]; then return 2; fi
    fi
    kubectl port-forward "$target" "$ports" >/dev/null 2>&1 &
    PF_PID=$!
    local inner=$(( $(date +%s) + 15 ))
    while [ "$(date +%s)" -lt "$inner" ]; do
      kill -0 "$PF_PID" 2>/dev/null || break   # forward died: server not up yet
      if curl -s -o /dev/null --max-time 2 "http://localhost:${lport}${path}" 2>/dev/null; then
        return 0
      fi
      sleep 2
    done
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
    PF_PID=""
    sleep 2
  done
  return 1
}

# Verify the Docker daemon is actually reachable -- and if it is not, work out
# WHY, rather than asserting a cause.
#
# "docker info failed" has two very different causes and they need different
# advice: the daemon is not running, or the daemon is running fine and the docker
# context / DOCKER_HOST points at a socket that does not exist. Observed live
# 2026-09-04: OrbStack was running and serving Docker 29.4.0 on
# <home>/.orbstack/run/docker.sock, while the active context was `default` ->
# unix:///var/run/docker.sock, which did not exist. Telling that user to "start
# Docker" would have been useless -- it was already started.
#
# Sets DOCKER_ALT_SOCK to a working socket the current config is NOT using.
# Returns 0 = reachable, 1 = daemon found at another socket, 2 = none found.
docker_daemon_check() {
  DOCKER_ALT_SOCK=""
  docker info >/dev/null 2>&1 && return 0
  local s
  for s in "${HOME}/.orbstack/run/docker.sock" \
           "${HOME}/.colima/default/docker.sock" \
           "${HOME}/.docker/run/docker.sock" \
           "${HOME}/.rd/docker.sock"; do
    [ -S "$s" ] || continue
    if DOCKER_HOST="unix://${s}" docker info >/dev/null 2>&1; then
      DOCKER_ALT_SOCK="$s"
      return 1
    fi
  done
  return 2
}

# The human-readable half of the above, so 00 and 05 cannot describe the same
# state differently. Echoes multi-line advice for the non-zero cases.
docker_daemon_advice() {
  if [ -n "${DOCKER_ALT_SOCK:-}" ]; then
    echo "A Docker daemon IS running, but your docker context/DOCKER_HOST is not pointing at it."
    echo "  working socket: ${DOCKER_ALT_SOCK}"
    echo "  fix (persists across shells):"
    echo "    docker context create orbstack --docker host=unix://${DOCKER_ALT_SOCK}"
    echo "    docker context use orbstack"
    echo "  or, for this shell only:  export DOCKER_HOST=unix://${DOCKER_ALT_SOCK}"
  else
    echo "No Docker daemon found at the configured endpoint or at any known socket."
    echo "  start one -- e.g. 'open -a OrbStack' or 'open -a Docker' -- then re-check with 'docker info'."
  fi
}

# Point the docker CLI at a daemon that docker_daemon_check() found but the
# current context is not using. Only ever called after that returned 1, i.e. we
# have already PROVEN a daemon answers on DOCKER_ALT_SOCK.
#
# This is a local docker-CLI config change and nothing else: no AWS call, no
# cluster call, no cost. Fully reversible with `docker context use default`.
# It exists because printing two commands for the user to retype, every time,
# is not a fix -- and this situation recurs on any machine where OrbStack (or
# Colima, etc.) owns the daemon but never claimed /var/run/docker.sock.
#
# Sets DOCKER_CTX_NAME. Returns 0 if docker works afterwards, 1 otherwise.
docker_daemon_autofix() {
  [ -n "${DOCKER_ALT_SOCK:-}" ] || return 1
  case "$DOCKER_ALT_SOCK" in
    *".orbstack"*) DOCKER_CTX_NAME="orbstack" ;;
    *".colima"*)   DOCKER_CTX_NAME="colima" ;;
    *".rd"*)       DOCKER_CTX_NAME="rancher-desktop" ;;
    *)             DOCKER_CTX_NAME="desktop-linux" ;;
  esac
  if docker context inspect "$DOCKER_CTX_NAME" >/dev/null 2>&1; then
    docker context update "$DOCKER_CTX_NAME" \
      --docker "host=unix://${DOCKER_ALT_SOCK}" >/dev/null 2>&1 || return 1
  else
    docker context create "$DOCKER_CTX_NAME" \
      --docker "host=unix://${DOCKER_ALT_SOCK}" >/dev/null 2>&1 || return 1
  fi
  docker context use "$DOCKER_CTX_NAME" >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1
}
