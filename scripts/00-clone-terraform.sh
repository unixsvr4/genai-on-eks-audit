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

log "Cloned. Terraform module lives at: ${TARGET}/terraform"
