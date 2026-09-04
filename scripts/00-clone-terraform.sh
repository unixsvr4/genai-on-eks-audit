#!/usr/bin/env bash
# Clones AWS's own Terraform for this workshop at a pinned tag. See terraform/README.md
# for why we vendor-by-reference instead of copying the code into this repo.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

mkdir -p "$DEPLOY_DIR"
TARGET="${DEPLOY_DIR}/sample-genai-on-eks"

if [ -d "$TARGET" ]; then
  CURRENT_TAG=$(git -C "$TARGET" describe --tags --exact-match 2>/dev/null || echo "unknown")
  if [ "$CURRENT_TAG" = "$TERRAFORM_TAG" ]; then
    log "Already cloned at ${TERRAFORM_TAG}: ${TARGET}"
    exit 0
  fi
  warn "Existing clone at ${TARGET} is tag '${CURRENT_TAG}', not '${TERRAFORM_TAG}'. Removing and re-cloning."
  rm -rf "$TARGET"
fi

log "Cloning aws-samples/sample-genai-on-eks @ ${TERRAFORM_TAG} into ${TARGET}..."
git clone --depth 1 --branch "$TERRAFORM_TAG" \
  https://github.com/aws-samples/sample-genai-on-eks.git "$TARGET"

# --- Destroy-ordering fix ----------------------------------------------------
# Upstream has no dependency edge from the Kubernetes layer to module.vpc, so
# `terraform destroy` races the NAT gateway / subnets / IGW against the
# monitoring namespace and dies with "context deadline exceeded". A
# *_override.tf cannot fix this -- Terraform rejects it ("The depends_on
# argument may not be overridden") -- so the vendored files are edited in place,
# here, on every clone. The patcher asserts each upstream depends_on before
# touching it and is idempotent. See scripts/lib/fix_destroy_order.py.
log "Applying the destroy-ordering fix to the clone..."
python3 "${REPO_ROOT}/scripts/lib/fix_destroy_order.py" "${TARGET}/terraform" \
  || die "Could not apply the destroy-ordering fix -- upstream @ ${TERRAFORM_TAG} no longer matches what scripts/lib/fix_destroy_order.py expects (see above). Reconcile it before deploying, or `terraform destroy` will hit the ordering bug in DIAGNOSTICS8.md."

# --- Pod Identity admission race ---------------------------------------------
# EKS Pod Identity injects credentials at pod ADMISSION. The model-download Job
# is created immediately after its association, and CreatePodIdentityAssociation
# returns before the association is visible to the admission webhook -- measured
# at a 141ms overlap on a real run -- so the pod is admitted with no credentials
# and cannot recover. Upstream's own retry (backoffLimit: 10) cannot fire because
# the validator is a sibling of a container that keeps running for a ~16GB
# download. Moving the validator to initContainers makes that retry work. This is
# NOT a depends_on problem: upstream already has the edge and still loses the
# race. See scripts/lib/fix_pod_identity_race.py and DIAGNOSTICS9.md.
log "Applying the Pod Identity race fix to the clone..."
python3 "${REPO_ROOT}/scripts/lib/fix_pod_identity_race.py" "${TARGET}/terraform" \
  || die "Could not apply the Pod Identity race fix -- upstream @ ${TERRAFORM_TAG} no longer matches what scripts/lib/fix_pod_identity_race.py expects (see above). Reconcile it before deploying, or the model-download Job can burn a ~16GB download and fail at the upload (DIAGNOSTICS9.md)."

# --- Karpenter consolidation vs. the model download ---------------------------
# The model-download Job writes a ~16GB model to the container's ephemeral
# filesystem (the pod template mounts nothing), so an eviction destroys all
# progress and the replacement pod restarts from zero. Karpenter consolidated the
# node out from under it after six minutes to save $0.20/hr, and would keep doing
# so until activeDeadlineSeconds (measured from JOB creation, so every restart is
# charged against the same hour) killed the Job. Nothing looks wrong while this
# happens: the Job reads Running 0/1 throughout. The pod-scoped
# karpenter.sh/do-not-disrupt annotation stops the voluntary disruption without
# disabling consolidation cluster-wide. See scripts/lib/fix_download_disruption.py.
log "Applying the download-disruption fix to the clone..."
python3 "${REPO_ROOT}/scripts/lib/fix_download_disruption.py" "${TARGET}/terraform" \
  || die "Could not apply the download-disruption fix -- upstream @ ${TERRAFORM_TAG} no longer matches what scripts/lib/fix_download_disruption.py expects (see above). Reconcile it before deploying, or Karpenter can evict the model download until the Job times out (DIAGNOSTICS9.md)."

log "Cloned. Terraform module lives at: ${TARGET}/terraform"
