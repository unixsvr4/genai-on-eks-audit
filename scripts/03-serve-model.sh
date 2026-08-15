#!/usr/bin/env bash
# Module: Serve a Model (RESEARCH.md §3)
# Deploys Ministral-3-8B-Instruct-2512 on vLLM, streamed directly from S3 via the
# Run:ai Model Streamer (no PersistentVolume — this is the model-loading pattern
# that does NOT depend on live IAM credentials for the life of the pod's mount,
# unlike the S3-CSI-PV pattern used later in 09-customize-model-lora.sh; see
# docs/GOTCHAS.md "RAG, fine-tuning, and the failures worth documenting honestly").
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

log "Verifying model weights exist in ${S3_BUCKET_NAME}..."
if ! aws s3 ls "s3://${S3_BUCKET_NAME}/Ministral-3-8B-Instruct-2512/consolidated.safetensors" >/dev/null 2>&1; then
  die "Model weights not found in s3://${S3_BUCKET_NAME}/Ministral-3-8B-Instruct-2512/. \
The vendored Terraform's model-download step may not have completed yet, or self-paced \
Terraform doesn't stage the model the same way the at-event account did — check \
'kubectl get job model-download' and the Terraform module's own docs before continuing."
fi

mkdir -p "${MANIFEST_DIR}/200-inference"
log "Fetching vLLM deployment manifest (tag ${TERRAFORM_TAG})..."
curl -sf -o "${MANIFEST_DIR}/200-inference/vllm-s3-deployment.yml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${TERRAFORM_TAG}/manifests/100-vllm/vllm-deployment.yml"

envsubst < "${MANIFEST_DIR}/200-inference/vllm-s3-deployment.yml" > /tmp/vllm-s3-deployment.yml
mv /tmp/vllm-s3-deployment.yml "${MANIFEST_DIR}/200-inference/vllm-s3-deployment.yml"
grep -A 2 "model=s3://" "${MANIFEST_DIR}/200-inference/vllm-s3-deployment.yml" || true

log "Applying deployment..."
kubectl apply -f "${MANIFEST_DIR}/200-inference/vllm-s3-deployment.yml"

log "Waiting for GPU node + pod (cold model load: expect ~30-60s node provision + ~30s model stream from S3)..."
kubectl wait node --for=condition=Ready -l karpenter.sh/nodepool=gpu --timeout=300s
kubectl wait pods --for=jsonpath='{.status.phase}'=Running -l model=mistral --timeout=300s

log "Streaming logs for 15s so you can see the Run:ai Streamer + KV-cache init lines..."
timeout 15 kubectl logs -l model=mistral -f || true

log "Testing via port-forward..."
kubectl port-forward svc/vllm-serve-svc 8000:8000 &
PF_PID=$!
sleep 3
curl -s http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"s3://${S3_BUCKET_NAME}/Ministral-3-8B-Instruct-2512/\",\"prompt\": \"San Francisco is a city that has\",\"max_tokens\": 7,\"temperature\": 0}" | jq
kill "$PF_PID" 2>/dev/null || true

log "Model serving verified. Next: ./04-observability.sh"
