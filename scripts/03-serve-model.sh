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

# `phase == Running` only means the container process started. vLLM then has to
# pull 9.7GB of weights from S3, load them onto the GPU and initialise the KV
# cache before it binds :8000 -- and this deployment declares no readinessProbe,
# so nothing in Kubernetes reflects that gap. Measured live 2026-09-04: pod
# Running at 08:34:29, "Application startup complete" at 08:35:38, i.e. 69s later.
# The old code slept 3s and curled, which failed inside the pod's own netns:
#     failed to connect to localhost:8000 ... connect: connection refused
#     error: lost connection to pod
# That reads like a port-forward/networking fault and is really just "too early".
# So poll vLLM's own /health until it answers, and only then send the completion.
log "Waiting for vLLM to finish loading the model and bind :8000 (this is the slow part)..."
VLLM_READY=0
for attempt in $(seq 1 60); do
  if kubectl exec deploy/mistral -- \
       curl -sf -o /dev/null --max-time 3 http://localhost:8000/health 2>/dev/null; then
    VLLM_READY=1
    log "vLLM is serving (ready after roughly $(( attempt * 5 ))s of polling)."
    break
  fi
  # A crash-looping or evicted pod will never become ready -- fail fast instead of
  # burning the full 5 minutes.
  POD_PHASE=$(kubectl get pods -l model=mistral -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  case "$POD_PHASE" in
    Running|Pending|"") ;;
    *) die "The mistral pod left Running (phase=${POD_PHASE}) while waiting for vLLM to start. Check: kubectl logs -l model=mistral" ;;
  esac
  sleep 5
done
[ "$VLLM_READY" -eq 1 ] || die "vLLM did not answer /health within 300s. The model load may still be in progress on a slow S3 pull -- check: kubectl logs -l model=mistral --tail=50"

log "Testing via port-forward..."
kubectl port-forward svc/vllm-serve-svc 8000:8000 &
PF_PID=$!
# The forward itself needs a moment to bind locally, but /health above already
# proved the far end is up, so this is only about the local listener.
for _ in 1 2 3 4 5; do
  curl -sf -o /dev/null --max-time 2 http://localhost:8000/health 2>/dev/null && break
  sleep 2
done
curl -s http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"s3://${S3_BUCKET_NAME}/Ministral-3-8B-Instruct-2512/\",\"prompt\": \"San Francisco is a city that has\",\"max_tokens\": 7,\"temperature\": 0}" | jq
kill "$PF_PID" 2>/dev/null || true

log "Model serving verified. Next: ./04-observability.sh"
