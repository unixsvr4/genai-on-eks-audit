#!/usr/bin/env bash
# Module: Optimize Inference - External KV Cache (RESEARCH.md §4 "External KV Cache")
#
# *** THIS IS THE ONE MODULE WITH ITS OWN ONGOING AWS BILL ***
# Provisions Amazon ElastiCache Serverless for Valkey as an L2, cross-pod KV-cache
# tier. Unlike every other lab in this repo, `kubectl delete` alone does NOT tear
# this down — it bills from the moment it's created until the cleanup at the bottom
# of THIS script runs. Per docs/COST.md: run this module last, right before your
# final teardown, and don't leave a long gap between running this script and running
# 99-destroy-all.sh (or just let this script's own built-in cleanup run to completion).
#
# Live workshop result proving cross-pod cache survival: `redis-cli dbsize` returned
# the SAME count before and after `kubectl delete pod lmcache-valkey` — the cache
# lives in Valkey, not pod memory. A brand-new pod with an empty local L1 still got
# a full cache hit from L2 (6.5x TTFT improvement on the second test run).
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

LMCACHE_TAG="v2.4.7"
mkdir -p "${MANIFEST_DIR}/500-lmcache" "${MANIFEST_DIR}/400-advanced-ai/900-cache"

log "Fetching + running Valkey setup script..."
curl -sf -o "${MANIFEST_DIR}/500-lmcache/setup-valkey.sh" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${LMCACHE_TAG}/manifests/500-lmcache/remote-cache-sharing-with-valkey/setup-valkey.sh"
chmod +x "${MANIFEST_DIR}/500-lmcache/setup-valkey.sh"

# Known transient flake (docs/GOTCHAS.md): CreateServerlessCache sometimes throws
# InvalidCredentialsException on the first attempt. The script is idempotent about
# the security group, so a single retry is safe and usually sufficient.
if ! source "${MANIFEST_DIR}/500-lmcache/setup-valkey.sh"; then
  warn "First attempt failed (often a transient AWS API flake) — retrying once..."
  source "${MANIFEST_DIR}/500-lmcache/setup-valkey.sh"
fi
[ -n "${VALKEY_ENDPOINT:-}" ] || die "VALKEY_ENDPOINT not set after setup-valkey.sh — check the script's own output above."
log "Valkey endpoint: ${VALKEY_ENDPOINT}"

log "Deploying LMCache pod wired to Valkey..."
curl -sf -o "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-valkey-configmap.yaml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${LMCACHE_TAG}/manifests/500-lmcache/remote-cache-sharing-with-valkey/lmcache-valkey-configmap.yaml"
curl -sf -o "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-valkey-pod.yaml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${LMCACHE_TAG}/manifests/500-lmcache/remote-cache-sharing-with-valkey/lmcache-valkey-pod.yaml"
envsubst < "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-valkey-pod.yaml" > /tmp/lmcache-valkey-pod.yaml
mv /tmp/lmcache-valkey-pod.yaml "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-valkey-pod.yaml"

kubectl apply -f "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-valkey-configmap.yaml"
kubectl apply -f "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-valkey-pod.yaml"
kubectl wait --for=condition=ready pod/lmcache-valkey --timeout=600s

log "Cold/warm test (same pod)..."
kubectl exec lmcache-valkey -- python /app/query-twice.py

log "Proving the cache survives pod deletion (this is the whole point of this lab)..."
BEFORE=$(kubectl run vcheck --rm -i --restart=Never --image=redis:7-alpine -- \
  redis-cli --tls -h "$VALKEY_ENDPOINT" -p 6379 dbsize)
log "dbsize before pod deletion: ${BEFORE}"
kubectl delete pod lmcache-valkey
AFTER=$(kubectl run vcheck --rm -i --restart=Never --image=redis:7-alpine -- \
  redis-cli --tls -h "$VALKEY_ENDPOINT" -p 6379 dbsize)
log "dbsize after pod deletion: ${AFTER} (should match — proves L2 persistence)"

log "Redeploying a fresh pod to prove a brand-new replica reuses the surviving L2 cache..."
kubectl apply -f "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-valkey-pod.yaml"
kubectl wait --for=condition=ready pod/lmcache-valkey --timeout=600s
kubectl exec lmcache-valkey -- python /app/query-twice.py
kubectl logs lmcache-valkey | grep -E "hit tokens|Retrieved" | head -4 || true

log "Tearing down Valkey NOW (this is the expensive resource — don't leave it running)..."
kubectl delete pod lmcache-valkey 2>/dev/null || true
kubectl delete configmap valkey-cm 2>/dev/null || true
curl -sf -o "${MANIFEST_DIR}/500-lmcache/cleanup-valkey.sh" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${LMCACHE_TAG}/manifests/500-lmcache/remote-cache-sharing-with-valkey/cleanup-valkey.sh"
chmod +x "${MANIFEST_DIR}/500-lmcache/cleanup-valkey.sh"
"${MANIFEST_DIR}/500-lmcache/cleanup-valkey.sh"

log "Valkey lab complete and torn down. Next: ./09-customize-model-lora.sh"
