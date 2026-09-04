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

# --- Prerequisites the live workshop created by hand and never scripted ---------
# This module used to warn twice and carry on to a query that could not possibly
# work, producing:
#     WARNING: Sample dataset not found ...
#     WARNING: rag-document-processor Job not found ...
#     An error occurred (NotFoundException) ... The specified index could not be found
# The NotFoundException is a CONSEQUENCE of the two warnings, three steps later.
# Nothing here existed in a fresh account: no s3-access-sa, no
# rag-document-processor-role, no RagS3ReadPolicy, no pod identity association, no
# S3 Vectors bucket and no index -- and the processor script creates none of them.
# The old comment pointed at RESEARCH.md for "the full rag-document-processor Job
# spec", but RESEARCH.md itself records that the Job scrolled off the live log and
# was never captured. It is authored here instead, from the dependency versions the
# capture did preserve (torch 2.13.0+cpu, sentence-transformers 5.6.0,
# all-MiniLM-L6-v2, 384-dim).
log "Provisioning the RAG data bucket..."
aws s3 mb "s3://${S3_RAG_DATA_BUCKET}" --region "$AWS_REGION" 2>/dev/null || true

log "Uploading sample product catalog for embedding..."
# Upstream ships this as manifests/300-rag/eletronics.jsonl -- note the missing 'c',
# and note there is no samples/ subdirectory. The old path
# (300-rag/samples/electronics.jsonl) matched neither, so the upload silently
# warned and the bucket stayed empty. Accept both spellings so a fixed upstream
# keeps working.
RAG_SRC=""
for cand in "${DEPLOY_DIR}/sample-genai-on-eks/manifests/300-rag/samples/electronics.jsonl" \
            "${DEPLOY_DIR}/sample-genai-on-eks/manifests/300-rag/electronics.jsonl" \
            "${DEPLOY_DIR}/sample-genai-on-eks/manifests/300-rag/eletronics.jsonl"; do
  [ -f "$cand" ] && { RAG_SRC="$cand"; break; }
done
[ -n "$RAG_SRC" ] || die "No product-catalog dataset found under manifests/300-rag/ in the Terraform clone. Re-run ./00-clone-terraform.sh, or check whether upstream @ ${TERRAFORM_TAG} renamed it."
log "  using $(basename "$RAG_SRC")"
# The processor lists with Prefix='samples/', so the key must live under samples/
# regardless of what the source file is called.
aws s3 cp "$RAG_SRC" "s3://${S3_RAG_DATA_BUCKET}/samples/electronics.jsonl" \
  || die "Could not upload the product catalog to s3://${S3_RAG_DATA_BUCKET}/samples/."

log "Creating the S3 Vectors bucket + index (384-dim, cosine — matches all-MiniLM-L6-v2)..."
aws s3vectors create-vector-bucket --vector-bucket-name "$S3_VECTOR_BUCKET_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true
aws s3vectors create-index --vector-bucket-name "$S3_VECTOR_BUCKET_NAME" \
  --index-name "$S3_VECTOR_INDEX_NAME" --data-type float32 --dimension 384 \
  --distance-metric cosine --region "$AWS_REGION" 2>/dev/null || true
aws s3vectors get-index --vector-bucket-name "$S3_VECTOR_BUCKET_NAME" \
  --index-name "$S3_VECTOR_INDEX_NAME" --region "$AWS_REGION" >/dev/null 2>&1 \
  || die "S3 Vectors index ${S3_VECTOR_INDEX_NAME} does not exist and could not be created. Check that s3vectors is available in ${AWS_REGION} and that your credentials allow it."
VEC_ARN=$(aws s3vectors get-vector-bucket --vector-bucket-name "$S3_VECTOR_BUCKET_NAME" \
  --region "$AWS_REGION" --query 'vectorBucket.vectorBucketArn' --output text 2>/dev/null || echo "")

log "Provisioning IAM + EKS Pod Identity for the ingestion Job (least-privilege)..."
# Scoped to exactly the two buckets this job touches. s3vectors resources fall back
# to "*" only if the bucket ARN could not be read back, so a wrong guess at the ARN
# shape cannot silently produce a policy that denies everything.
VEC_RESOURCES="\"${VEC_ARN}\", \"${VEC_ARN}/index/*\""
[ -z "$VEC_ARN" ] && VEC_RESOURCES='"*"'
cat > /tmp/rag-s3-read-policy.json <<POLICY
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": ["arn:aws:s3:::${S3_RAG_DATA_BUCKET}", "arn:aws:s3:::${S3_RAG_DATA_BUCKET}/*"] },
  { "Effect": "Allow",
    "Action": ["s3vectors:PutVectors", "s3vectors:QueryVectors", "s3vectors:GetVectors",
               "s3vectors:ListVectors", "s3vectors:GetIndex", "s3vectors:ListIndexes",
               "s3vectors:GetVectorBucket"],
    "Resource": [${VEC_RESOURCES}] }
] }
POLICY
POLICY_ARN=$(aws iam list-policies --scope Local \
  --query 'Policies[?PolicyName==`RagS3ReadPolicy`].Arn' --output text 2>/dev/null || echo "")
if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" = "None" ]; then
  POLICY_ARN=$(aws iam create-policy --policy-name RagS3ReadPolicy \
    --policy-document file:///tmp/rag-s3-read-policy.json \
    --query 'Policy.Arn' --output text) || die "Could not create RagS3ReadPolicy."
fi
# EKS Pod Identity assumes via pods.eks.amazonaws.com and needs TagSession.
cat > /tmp/rag-trust-policy.json <<'TRUST'
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"] } ] }
TRUST
aws iam get-role --role-name rag-document-processor-role >/dev/null 2>&1 \
  || aws iam create-role --role-name rag-document-processor-role \
       --assume-role-policy-document file:///tmp/rag-trust-policy.json >/dev/null \
  || die "Could not create rag-document-processor-role."
aws iam attach-role-policy --role-name rag-document-processor-role --policy-arn "$POLICY_ARN"
rm -f /tmp/rag-s3-read-policy.json /tmp/rag-trust-policy.json

kubectl create serviceaccount s3-access-sa --dry-run=client -o yaml | kubectl apply -f -
if [ -z "$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
     --query 'associations[?serviceAccount==`s3-access-sa` && namespace==`default`].associationId' --output text 2>/dev/null)" ]; then
  aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace default --service-account s3-access-sa \
    --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/rag-document-processor-role" >/dev/null \
    || die "Could not create the pod identity association for s3-access-sa."
fi
# Pod Identity is injected at pod ADMISSION and the association is not instantly
# visible to that webhook -- the same race that cost a 16GB download in
# DIAGNOSTICS9.md bug 1. The Job below is created seconds later, so wait it out.
log "Waiting for the pod identity association to become visible to the admission webhook..."
sleep 15

log "Running the embedding ingestion Job (torch 2.13.0+cpu, sentence-transformers 5.6.0, all-MiniLM-L6-v2)..."
kubectl apply -f "${DEPLOY_DIR}/sample-genai-on-eks/manifests/300-rag/rag-processor.yml"
kubectl delete job rag-document-processor --ignore-not-found >/dev/null
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: rag-document-processor
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      annotations:
        karpenter.sh/do-not-disrupt: "true"
    spec:
      restartPolicy: Never
      serviceAccountName: s3-access-sa
      nodeSelector:
        kubernetes.io/arch: amd64
      containers:
        - name: processor
          image: python:3.12-slim
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              pip install --no-cache-dir --quiet \
                torch==2.13.0 --index-url https://download.pytorch.org/whl/cpu || \
                pip install --no-cache-dir --quiet torch --index-url https://download.pytorch.org/whl/cpu
              pip install --no-cache-dir --quiet sentence-transformers==5.6.0 boto3
              python /scripts/rag-processor.py
          env:
            - { name: AWS_REGION,             value: "${AWS_REGION}" }
            - { name: S3_BUCKET_NAME,         value: "${S3_RAG_DATA_BUCKET}" }
            - { name: S3_VECTOR_BUCKET_NAME,  value: "${S3_VECTOR_BUCKET_NAME}" }
            - { name: S3_VECTOR_INDEX_NAME,   value: "${S3_VECTOR_INDEX_NAME}" }
          volumeMounts:
            - { name: scripts, mountPath: /scripts }
          resources:
            requests: { cpu: "1", memory: 3Gi }
            limits:   { cpu: "2", memory: 6Gi }
      volumes:
        - name: scripts
          configMap: { name: rag-processor-script }
EOF

INGEST_DEADLINE=$(( $(date +%s) + ${RAG_INGEST_TIMEOUT:-1200} ))
INGEST_STATE="running"
while [ "$(date +%s)" -lt "$INGEST_DEADLINE" ]; do
  [ "$(kubectl get job rag-document-processor -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ] && { INGEST_STATE="ok"; break; }
  [ -n "$(kubectl get job rag-document-processor -o jsonpath='{.status.failed}' 2>/dev/null)" ] && { INGEST_STATE="failed"; break; }
  sleep 10
done
log "Ingestion log:"
kubectl logs job/rag-document-processor --tail=25 2>/dev/null || true
case "$INGEST_STATE" in
  ok)     log "Embeddings ingested into S3 Vectors." ;;
  failed) die "The embedding ingestion Job failed (log above). Nothing downstream can work without it." ;;
  *)      die "Ingestion did not finish within ${RAG_INGEST_TIMEOUT:-1200}s. Check: kubectl logs job/rag-document-processor" ;;
esac

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
