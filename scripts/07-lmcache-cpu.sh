#!/usr/bin/env bash
# Module: Optimize Inference - CPU Offloading (RESEARCH.md §4 "CPU Offloading")
# Deploys a standalone vLLM+LMCache pod using CPU RAM as an L1 KV-cache tier, then
# proves prefix-cache reuse with a cold/warm request pair at 90% prompt overlap.
# Live workshop result: cold TTFT 0.387s -> warm TTFT 0.119s (3.2x faster).
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

LMCACHE_TAG="v2.4.7"  # pinned separately — see docs/GOTCHAS.md
mkdir -p "${MANIFEST_DIR}/400-advanced-ai/900-cache"

log "Fetching LMCache CPU-RAM manifests (tag ${LMCACHE_TAG})..."
curl -sf -o "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-cpu-ram-configmap.yaml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${LMCACHE_TAG}/manifests/500-lmcache/cpu-ram-offloading/lmcache-cpu-ram-configmap.yaml"
curl -sf -o "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-cpu-ram-pod.yaml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${LMCACHE_TAG}/manifests/500-lmcache/cpu-ram-offloading/lmcache-cpu-ram-pod.yaml"

envsubst < "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-cpu-ram-pod.yaml" > /tmp/lmcache-cpu-ram-pod.yaml
mv /tmp/lmcache-cpu-ram-pod.yaml "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-cpu-ram-pod.yaml"

kubectl apply -f "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-cpu-ram-configmap.yaml"
kubectl apply -f "${MANIFEST_DIR}/400-advanced-ai/900-cache/lmcache-cpu-ram-pod.yaml"

log "Waiting for pod (note: 'pip install lmcache==0.3.8' failing in the logs is a known"
log "cosmetic error — a working version is already baked into the image; see docs/GOTCHAS.md)..."
kubectl wait node --for=condition=Ready -l karpenter.sh/nodepool=gpu --timeout=300s
kubectl wait --for=condition=ready pod/lmcache-cpu-ram --timeout=600s

log "Running cold/warm prefix-cache test..."
kubectl exec lmcache-cpu-ram -- python /app/query-twice.py

log "Tearing down (LMCache CPU-RAM lab has no AWS-billed resources beyond the GPU pod itself)..."
kubectl delete pod lmcache-cpu-ram
kubectl delete configmap cpu-ram-cm

log "Next: ./08-lmcache-valkey.sh (this one DOES create a billed AWS resource — read its header first)"
