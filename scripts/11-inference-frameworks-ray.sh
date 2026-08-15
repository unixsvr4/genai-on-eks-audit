#!/usr/bin/env bash
# Module: Inference Frameworks (RESEARCH.md §6)
# Deploys the SAME model behind Ray Serve/KubeRay instead of a plain vLLM Deployment,
# then redeploys Open WebUI UNCHANGED against it — proving the OpenAI-API contract
# is fully framework-agnostic. Also wires up Ray-specific Prometheus PodMonitors,
# which finally give data to the Ray Grafana dashboards that have existed (empty)
# since the observability module.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

RAY_CM_TAG="v2.3.1"
RAY_SVC_TAG="v2.3.2"   # yet another tag, even within this one module — see docs/GOTCHAS.md
mkdir -p "${MANIFEST_DIR}/400-ray"

log "Cleaning up any prior plain-vLLM/LoRA/Open-WebUI deployments first (idempotent no-ops if already gone)..."
kubectl delete deployment mistral 2>/dev/null || true
kubectl delete deployment anyvc 2>/dev/null || true
kubectl delete service vllm-serve-svc 2>/dev/null || true
kubectl delete ingress open-webui-ingress 2>/dev/null || true
kubectl delete deployment open-webui 2>/dev/null || true
kubectl delete service open-webui 2>/dev/null || true

log "Fetching Ray-Serve vLLM wrapper ConfigMap (tag ${RAY_CM_TAG})..."
curl -sf -o "${MANIFEST_DIR}/400-ray/vllm-s3-configmap.yml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${RAY_CM_TAG}/manifests/200-ray/vllm-s3-configmap.yaml"
kubectl apply -f "${MANIFEST_DIR}/400-ray/vllm-s3-configmap.yml"

log "Installing KubeRay operator..."
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ >/dev/null
helm repo update >/dev/null
helm upgrade --install kuberay-operator kuberay/kuberay-operator --version 1.1.0
kubectl wait pods --for=jsonpath='{.status.phase}'=Running -l app.kubernetes.io/name=kuberay-operator --timeout=300s

log "Checking for the S3-backed model PV (should already exist from Terraform apply)..."
if ! kubectl get pv mistral-model-pv >/dev/null 2>&1; then
  warn "mistral-model-pv not found — your Terraform apply may not have provisioned it. \
See RESEARCH.md 'Inference Frameworks' for the expected PV spec (CSI driver s3.csi.aws.com, \
bucketName=${S3_BUCKET_NAME}, prefix=Ministral-3-8B-Instruct-2512/, accessMode ROX) and create it manually if needed."
fi

log "Deploying RayService (tag ${RAY_SVC_TAG}, uses an AWS Deep Learning Container image)..."
curl -sf -o "${MANIFEST_DIR}/400-ray/ray-vllm-s3-service.yml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${RAY_SVC_TAG}/manifests/200-ray/vllm-s3-service.yaml"
kubectl apply -f "${MANIFEST_DIR}/400-ray/ray-vllm-s3-service.yml"
kubectl wait --for=jsonpath='{.status.serviceStatus}'=Running rayservice/vllm --timeout=600s

log "Service topology:"
kubectl get svc | grep -E "vllm|NAME"

log "Redeploying Open WebUI UNCHANGED against the Ray-backed model (this is the actual point of this module)..."
curl -sf -o "${MANIFEST_DIR}/400-ray/openwebui.yml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${RAY_CM_TAG}/manifests/200-ray/openwebui.yml"
kubectl apply -f "${MANIFEST_DIR}/400-ray/openwebui.yml"
kubectl wait --for=condition=ready pod -l app=open-webui --timeout=300s

OPENWEBUI_URL=$(kubectl get ingress open-webui-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
log "Open WebUI (Ray-backed): http://${OPENWEBUI_URL}"

log "Wiring up Ray-specific Prometheus PodMonitors..."
cat << EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  labels: { release: kube-prometheus-stack }
  name: ray-head-monitor
  namespace: monitoring
spec:
  selector:
    matchLabels: { ray.io/node-type: head }
  podMetricsEndpoints:
    - port: metrics
    - port: as-metrics
    - port: dash-metrics
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: ray-workers-monitor
  namespace: monitoring
  labels: { release: kube-prometheus-stack }
spec:
  selector:
    matchLabels: { ray.io/node-type: worker }
  podMetricsEndpoints:
    - port: metrics
EOF

log "Ray Grafana dashboards should now have live data:"
kubectl get grafanadashboards -n monitoring | grep ray || true

log "All 8 workshop modules reproduced. Ready to showboat — screenshot Grafana/Gradio/Open WebUI now."
log "When done: ./99-destroy-all.sh"
