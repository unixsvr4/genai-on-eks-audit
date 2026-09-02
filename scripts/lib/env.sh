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
SCRIPT_OUT_FILE="${SCRIPT_OUT_DIR}/$(basename "$0" .sh).out.txt"
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
