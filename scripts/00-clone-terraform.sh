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

log "Cloned. Terraform module lives at: ${TARGET}/terraform"
