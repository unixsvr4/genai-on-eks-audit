#!/usr/bin/env bash
# Module: Optimize Inference - Benchmarking (RESEARCH.md §4 "Benchmarking")
# Runs a fixed-load baseline scenario and a staged-load saturation scenario against
# the live vLLM deployment, printing p50/p90/p99 latency + throughput.
#
# What to expect from the live workshop run (your numbers will vary by GPU/region/model
# load, but the SHAPE should match): baseline ~60ms TTFT p50 at 1 req/s; saturation
# staying flat through ~10 req/s then TTFT roughly doubling once you cross ~17-20 req/s
# on a single g6e.2xlarge — that's the real capacity ceiling for this setup, not a
# guess. See docs/GOTCHAS.md.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

mkdir -p "${MANIFEST_DIR}/700-benchmarking" "${DEPLOY_DIR}"
BENCH_TAG="v2.4.8"  # pinned separately — see docs/GOTCHAS.md "General workshop-repo hygiene"

log "Fetching benchmarking Helm chart (tag ${BENCH_TAG})..."
curl -sfL -o /tmp/benchmark-charts.tar.gz \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${BENCH_TAG}/manifests/400-benchmarking/benchmark-charts.tar.gz"
tar xzf /tmp/benchmark-charts.tar.gz -C "$DEPLOY_DIR"

log "Sanity-checking the model from inside the cluster..."
kubectl exec deployment/mistral -- curl -s http://vllm-serve-svc.default.svc.cluster.local:8000/v1/models | jq

for scenario in baseline saturation; do
  log "Fetching ${scenario}-values.yaml..."
  curl -sf -o "${MANIFEST_DIR}/700-benchmarking/${scenario}-values.yaml" \
    "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${BENCH_TAG}/manifests/400-benchmarking/${scenario}-values.yaml"
  envsubst < "${MANIFEST_DIR}/700-benchmarking/${scenario}-values.yaml" > "/tmp/${scenario}-values.yaml"

  log "Running ${scenario} benchmark (helm release: ${scenario})..."
  EXTRA_ARGS=()
  [ "$scenario" = "saturation" ] && EXTRA_ARGS+=(--set benchmark.serviceAccount.create=false)
  helm upgrade --install "$scenario" "${DEPLOY_DIR}/benchmark-charts" -n default \
    -f "/tmp/${scenario}-values.yaml" "${EXTRA_ARGS[@]}"

  TIMEOUT=300; [ "$scenario" = "saturation" ] && TIMEOUT=600
  kubectl wait --for=condition=complete "job" -l "benchmark.scenario=${scenario}" -n default --timeout="${TIMEOUT}s"

  log "${scenario} results:"
  kubectl logs -n default -l "benchmark.scenario=${scenario}" | grep -E "Uploaded|Stage" || true
done

warn "Full metrics parsing (p50/p90/p99 tables) uses the python snippet in RESEARCH.md §4 \"Benchmarking\" — \
pull the S3 result paths from the job logs above and pipe them through 'aws s3 cp <path> - | python3 -c ...' \
as documented there."

log "Benchmarking complete. Tearing down benchmark releases AND the vLLM deployment"
log "(mirrors the live workshop run exactly — the next modules deploy their own standalone"
log "vLLM pods and don't need this one running, so no reason to pay for two GPU pods at once)."
helm uninstall baseline -n default 2>/dev/null || true
helm uninstall saturation -n default 2>/dev/null || true
kubectl delete deployment mistral 2>/dev/null || true
kubectl delete service vllm-serve-svc 2>/dev/null || true

log "Next: ./07-lmcache-cpu.sh"
