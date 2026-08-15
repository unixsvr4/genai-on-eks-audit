#!/usr/bin/env bash
# Module: Optimize Inference - Agentic App (RESEARCH.md §4 "Agentic App")
# Builds and deploys a Strands (AWS's open-source agent SDK) weather agent that
# calls the vLLM endpoint's OpenAI-compatible tool-calling API. Exercises the
# `enable_auto_tool_choice`/`tool_call_parser=mistral` flags set back in 03-serve-model.sh.
#
# IMPORTANT: this depends on the vLLM deployment from 03-serve-model.sh still being
# up (mistral pod + vllm-serve-svc). Run this BEFORE 06-benchmarking.sh — the
# benchmarking script deletes that deployment at the end.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

kubectl get pods -l model=mistral | grep -q Running || \
  die "No running 'mistral' pod found. Run 03-serve-model.sh first (and run this BEFORE 06-benchmarking.sh, which tears it down)."

mkdir -p "${MANIFEST_DIR}/600-strands-agent"

log "Fetching Strands weather agent source..."
curl -sf -o "${MANIFEST_DIR}/600-strands-agent/strands.zip" \
  "https://ws-assets-prod-iad-r-pdx-f3b3f9f1a7d6a3d0.s3.us-west-2.amazonaws.com/029d6c4e-4775-41c9-85ff-9f5360f32a15/strands.zip"
unzip -o "${MANIFEST_DIR}/600-strands-agent/strands.zip" -d "${MANIFEST_DIR}/600-strands-agent"

log "Building + pushing to ECR..."
aws ecr describe-repositories --repository-names strands-weather-agent >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name strands-weather-agent >/dev/null
ECR_REPO=$(aws ecr describe-repositories --repository-names strands-weather-agent --query 'repositories[0].repositoryUri' --output text)
export ECR_REPO
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$(echo "$ECR_REPO" | cut -d'/' -f1)"
docker build -t strands-weather-agent "${MANIFEST_DIR}/600-strands-agent"
docker tag strands-weather-agent:latest "${ECR_REPO}:latest"
docker push "${ECR_REPO}:latest"

log "Deploying agent, pointed at vllm-serve-svc..."
cat <<'EOF' > "${MANIFEST_DIR}/600-strands-agent/vllm-deployment-agents.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: strands-weather-agent
spec:
  replicas: 1
  selector:
    matchLabels: { app: strands-weather-agent }
  template:
    metadata:
      labels: { app: strands-weather-agent }
    spec:
      containers:
      - name: strands-weather-agent
        image: $ECR_REPO:latest
        ports: [{ containerPort: 8000 }]
        env:
        - name: MODEL_ENDPOINT
          value: "http://vllm-serve-svc:8000/v1"
        - name: MODEL_ID
          value: "s3://${S3_BUCKET_NAME}/Ministral-3-8B-Instruct-2512/"
---
apiVersion: v1
kind: Service
metadata:
  name: strands-weather-agent
spec:
  selector: { app: strands-weather-agent }
  ports: [{ port: 80, targetPort: 8000 }]
  type: ClusterIP
EOF
envsubst < "${MANIFEST_DIR}/600-strands-agent/vllm-deployment-agents.yaml" | kubectl apply -f -
kubectl wait pods --for=jsonpath='{.status.phase}'=Running -l app=strands-weather-agent --timeout=300s

log "Testing tool-calling end to end..."
kubectl port-forward svc/strands-weather-agent 8080:80 &
PF_PID=$!
sleep 3
curl -s -X POST http://localhost:8080/agent -H "Content-Type: application/json" \
  -d '{"query": "What time is it in Dallas?"}' | jq -r '.response.message.content[0].text'
curl -s -X POST http://localhost:8080/agent -H "Content-Type: application/json" \
  -d '{"query": "What weather is it in Denver?"}' | jq -r '.response.message.content[0].text'
kill "$PF_PID" 2>/dev/null || true

log "Agentic app verified. Next: ./06-benchmarking.sh (this WILL tear down the vLLM deployment at the end)"
