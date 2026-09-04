#!/usr/bin/env bash
# Module: RAG on Amazon EKS (RESEARCH.md §5b)
# Ingests a small product-catalog dataset into Amazon S3 Vectors, deploys a RAG
# orchestration service in front of vLLM, and a Gradio UI comparing standard vs.
# RAG-enhanced responses side by side.
#
# Gotcha (docs/GOTCHAS.md): this service's MODEL_ENDPOINT points at vllm-serve-svc —
# the SAME service name reused across modules. In the live workshop run, the prior
# module's LoRA-serving deployment never came up, so RAG deployed cleanly but had
# no working backend. This script checks for that and falls back to redeploying the
# plain vLLM model from 03-serve-model.sh if vllm-serve-svc has no ready endpoints,
# so this demo is actually end-to-end functional rather than silently reproducing
# that failure.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

RAG_TAG_CONFIGMAP="v2.5.0"   # pinned separately from the Deployment — see docs/GOTCHAS.md
RAG_TAG_DEPLOY="v2.5.2"
mkdir -p "${MANIFEST_DIR}/500-rag"

log "Checking vllm-serve-svc has a working backend before wiring RAG to it..."
READY_ENDPOINTS=$(kubectl get endpoints vllm-serve-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
if [ -z "$READY_ENDPOINTS" ]; then
  warn "vllm-serve-svc has no ready endpoints. Redeploying the plain vLLM model from 03-serve-model.sh so this module actually has something to talk to..."
  bash 03-serve-model.sh
fi

log "Provisioning S3 bucket + IAM for the ingestion job (EKS Pod Identity, least-privilege)..."
aws s3 mb "s3://${S3_RAG_DATA_BUCKET}" --region "$AWS_REGION" 2>/dev/null || true
# NOTE: this repo doesn't script the RagS3ReadPolicy/rag-document-processor-role
# creation in detail — that IAM setup lives in the vendored Terraform/sample data
# under sample-genai-on-eks; see RESEARCH.md "RAG on Amazon EKS" for the exact
# `aws iam` / `aws eks create-pod-identity-association` commands this reproduces
# if your Terraform apply didn't already provision them.

log "Uploading sample product catalog for embedding..."
aws s3 cp "${DEPLOY_DIR}/sample-genai-on-eks/manifests/300-rag/samples/electronics.jsonl" \
  "s3://${S3_RAG_DATA_BUCKET}/samples/electronics.jsonl" 2>/dev/null \
  || warn "Sample dataset not found in the vendored repo at the expected path — check manifests/300-rag/samples/ in your Terraform clone and upload manually if needed."

log "Running the embedding ingestion Job (creates the S3 Vectors index if it doesn't exist)..."
# See RESEARCH.md "RAG on Amazon EKS" for the full rag-document-processor Job spec
# (torch==2.13.0+cpu, sentence-transformers==5.6.0, all-MiniLM-L6-v2, 384-dim).
kubectl get job rag-document-processor >/dev/null 2>&1 && kubectl wait --for=condition=complete job/rag-document-processor --timeout=600s \
  || warn "rag-document-processor Job not found — apply it from your Terraform clone's manifests/300-rag/ before continuing, per RESEARCH.md."

log "Verifying vectors landed in S3 Vectors..."
python3 -c "import json; print(json.dumps({'float32': [0.1]*384}))" > /tmp/test_query_384.json
aws s3vectors query-vectors \
  --vector-bucket-name "$S3_VECTOR_BUCKET_NAME" \
  --index-name "$S3_VECTOR_INDEX_NAME" \
  --query-vector file:///tmp/test_query_384.json \
  --top-k 3 --return-metadata --return-distance | jq '.vectors[].metadata.product'

log "Deploying RAG service..."
curl -sf -o "${MANIFEST_DIR}/500-rag/rag-serve.yml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${RAG_TAG_CONFIGMAP}/manifests/300-rag/rag-serve.yml"
kubectl apply -f "${MANIFEST_DIR}/500-rag/rag-serve.yml"

curl -sf -o "${MANIFEST_DIR}/500-rag/rag-service.yml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${RAG_TAG_DEPLOY}/manifests/300-rag/rag-service.yml"
export MODEL_ID="ministral-base"
export MODEL_ENDPOINT="http://vllm-serve-svc:8000/v1/chat/completions"
envsubst < "${MANIFEST_DIR}/500-rag/rag-service.yml" > "${MANIFEST_DIR}/500-rag/rag-service-processed.yml"
kubectl apply -f "${MANIFEST_DIR}/500-rag/rag-service-processed.yml"
kubectl rollout status deployment/rag-service --timeout=300s

log "Deploying Gradio comparison UI..."
curl -sf -o "${MANIFEST_DIR}/500-rag/rag-gradio-app.yml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${RAG_TAG_CONFIGMAP}/manifests/300-rag/rag-gradio-app.yml"
kubectl apply -f "${MANIFEST_DIR}/500-rag/rag-gradio-app.yml"
curl -sf -o "${MANIFEST_DIR}/500-rag/rag-gradio-deploy.yml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${RAG_TAG_CONFIGMAP}/manifests/300-rag/rag-gradio-deploy.yml"
kubectl apply -f "${MANIFEST_DIR}/500-rag/rag-gradio-deploy.yml"
kubectl wait pods --for=jsonpath='{.status.phase}'=Running -l app=rag-gradio-interface --timeout=300s

log "Waiting for the Gradio ALB hostname..."
GRADIO_URL=$(lb_hostname rag-gradio-alb) \
  || { warn "ALB hostname did not appear within ${LB_TIMEOUT:-300}s. Check: kubectl describe ingress rag-gradio-alb"; GRADIO_URL="pending"; }
log "RAG Gradio UI: http://${GRADIO_URL}/?__theme=dark"
log "Next: ./11-inference-frameworks-ray.sh"
