#!/usr/bin/env bash
# Module: Optimize Inference - Observability (RESEARCH.md §4)
# Installs DCGM Exporter for real GPU telemetry, exposes Grafana via ALB, and wires
# up a hand-written ServiceMonitor for vLLM's own /metrics endpoint.
#
# Gotcha (docs/GOTCHAS.md): every ServiceMonitor/PodMonitor below MUST carry
# `release: kube-prometheus-stack` or the Prometheus Operator silently ignores it -
# no error, just no data. Confirmed 3x independently in the live session.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

log "Installing DCGM Exporter via Helm (GPU telemetry)..."
mkdir -p "${MANIFEST_DIR}/200-inference"
cat << EOF > "${MANIFEST_DIR}/200-inference/values.yaml"
serviceMonitor:
  enabled: true
  additionalLabels:
    release: kube-prometheus-stack  # REQUIRED — see docs/GOTCHAS.md
  interval: 30s
  honorLabels: true
service:
  enable: true
  type: ClusterIP
  port: 9400
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9400"
nodeSelector:
  karpenter.sh/nodepool: gpu
tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9400"
podLabels:
  app.kubernetes.io/name: "dcgm-exporter"
resources:
  limits: { cpu: 500m, memory: 512Mi }
  requests: { cpu: 100m, memory: 256Mi }
EOF

helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts >/dev/null
helm repo update >/dev/null
helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \
  -n monitoring -f "${MANIFEST_DIR}/200-inference/values.yaml"
kubectl wait pods --for=jsonpath='{.status.phase}'=Running -l "app.kubernetes.io/name=dcgm-exporter" -n monitoring --timeout=300s

log "Exposing Grafana via ALB..."
mkdir -p "${MANIFEST_DIR}/300-observability"
cat <<EOF > "${MANIFEST_DIR}/300-observability/grafana-ingress.yaml"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /api/health
    alb.ingress.kubernetes.io/load-balancer-name: grafana-ingress
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kube-prometheus-stack-grafana
            port:
              number: 3000
EOF
kubectl apply -f "${MANIFEST_DIR}/300-observability/grafana-ingress.yaml"

# `kubectl get --timeout=120s` is not a real flag -- it errors with "unknown
# flag", 2>/dev/null swallowed that, and this printed "pending" on EVERY run
# regardless of the ALB. lb_hostname actually polls. Measured: 39s to appear.
log "Waiting for the ALB to be provisioned and its hostname published..."
GRAFANA_URL=$(lb_hostname grafana-ingress -n monitoring) \
  || { warn "ALB hostname did not appear within ${LB_TIMEOUT:-300}s. Check: kubectl describe ingress grafana-ingress -n monitoring"; GRAFANA_URL="pending"; }
GRAFANA_PASSWORD=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
log "Grafana: http://${GRAFANA_URL}  (user: admin / password: ${GRAFANA_PASSWORD})"
warn "Change this password if this deployment outlives the demo window — it's a chart default, not randomly generated."

log "Creating vLLM ServiceMonitor (hand-written — vLLM's own manifest doesn't include one)..."
cat << EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mistral-monitor
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames: [default]
  selector:
    matchLabels:
      model: mistral
  endpoints:
    - port: http
      interval: 30s
      path: /metrics
EOF

log "Observability wired up. Grafana dashboards (vllm-dashboard, dcgm-grafana-dashboard) should now show live data. Next: ./05-agentic-app.sh"
