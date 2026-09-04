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

# Check the daemon BEFORE the ECR login. `docker login` succeeds without a daemon
# (it just writes a credential), so without this the run prints "Login Succeeded"
# and then dies on the build -- which reads as an ECR/auth problem and is not one.
set +e
docker_daemon_check
DOCKER_RC=$?
set -e
if [ "$DOCKER_RC" -ne 0 ]; then
  warn "This script has to build an image, and 'docker info' failed."
  while IFS= read -r line; do warn "$line"; done <<< "$(docker_daemon_advice)"
  die "Docker is not usable. Nothing has been created."
fi

log "Building + pushing to ECR..."
aws ecr describe-repositories --repository-names strands-weather-agent >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name strands-weather-agent >/dev/null
ECR_REPO=$(aws ecr describe-repositories --repository-names strands-weather-agent --query 'repositories[0].repositoryUri' --output text)
export ECR_REPO
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$(echo "$ECR_REPO" | cut -d'/' -f1)"
# --platform is REQUIRED, not cosmetic. `docker build` with no platform builds for
# the BUILD HOST, and on Apple Silicon that is arm64 -- which lands on an amd64 EKS
# node and dies with a message that says nothing about architecture:
#     exec /usr/local/bin/python: exec format error
# The cluster is mixed (EKS Auto Mode ran c6g.large/arm64 for system and
# c6a.large/amd64 for general-purpose), so "whatever the host is" is wrong even by
# accident. Pin the image to amd64 here and pin the POD to amd64 below, so the two
# cannot disagree.
log "Building for linux/amd64 (build host is $(uname -m); EKS Auto Mode's general-purpose nodes are amd64)..."
docker build --platform linux/amd64 -t strands-weather-agent "${MANIFEST_DIR}/600-strands-agent"
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
      # Must match the --platform the image was built for. Without this the pod can
      # be scheduled onto the arm64 system node and fail with "exec format error"
      # even though the image is correct for the nodes it was meant to run on.
      nodeSelector:
        kubernetes.io/arch: amd64
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
# `phase == Running` above only means the container started; the agent's own HTTP
# server binds later, and it in turn calls vLLM. A fixed `sleep 3` here produced
# the same misleading "connection refused inside namespace" failure that
# 03-serve-model.sh hit (DIAGNOSTICS9.md) -- so wait for the port to actually
# answer instead.
set +e
pf_start svc/strands-weather-agent 8080:80 / app=strands-weather-agent
PF_RC=$?
set -e
case "$PF_RC" in
  0) ;;
  2) die "The strands agent pod is failing and will not recover: ${PF_ABORT_REASON}
If that says 'exec format error' in the logs, the image architecture does not match the node -- this script builds --platform linux/amd64 and pins the pod to amd64 for exactly that reason.
Check: kubectl logs -l app=strands-weather-agent" ;;
  *) die "The strands agent never answered on :8080 within ${PF_TIMEOUT:-300}s. Check: kubectl logs -l app=strands-weather-agent" ;;
esac
curl -s -X POST http://localhost:8080/agent -H "Content-Type: application/json" \
  -d '{"query": "What time is it in Dallas?"}' | jq -r '.response.message.content[0].text'
curl -s -X POST http://localhost:8080/agent -H "Content-Type: application/json" \
  -d '{"query": "What weather is it in Denver?"}' | jq -r '.response.message.content[0].text'
kill "$PF_PID" 2>/dev/null || true

log "Agentic app verified. Next: ./06-benchmarking.sh (this WILL tear down the vLLM deployment at the end)"
