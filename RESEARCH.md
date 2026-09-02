# RESEARCH.md — GenAI on Amazon EKS (NVIDIA GPU) Workshop

Source: AWS Workshop Studio, live event, joined via access-code 2026-08-11.
Event description (partial, from dashboard): "As organizations move beyond experimentation to production deployment of GenAI applications, Kubernetes has emerged as a preferred platform for managing inference workloads at scale..."

Workshop title: *Generative AI on EKS using NVIDIA GPU*
Topics: Containers, Generative AI · AWS services: Amazon EKS

This file is appended module-by-module as the workshop progresses. Each entry: what the module covers, key commands/YAML, and any gotchas hit live.

---

## 1. Getting Started

Two paths: **Self-paced** (own AWS account, Terraform) vs **At an AWS Event** (pre-provisioned, access via Event Dashboard → IdeUrl). Attended via the AWS-hosted event path.

### Self-paced path (for reference — not what I ran)
Repo: `github.com/aws-samples/sample-genai-on-eks` → `terraform/` dir.
```bash
git clone https://github.com/aws-samples/sample-genai-on-eks.git
cd sample-genai-on-eks/terraform
terraform init
terraform apply --auto-approve                       # or -var="region=us-west-2"
aws eks update-kubeconfig --name genai-workshop --region us-east-2
# Restrict ALB ingress to own IP
kubectl patch ingressclassparams alb --type=merge \
  -p "{\"spec\":{\"inboundCIDRs\":[\"$(curl -s https://checkip.amazonaws.com | tr -d '\n')/32\"]}}"
```
Requires sufficient GPU instance quota (request via EC2 quota console) — deployment ~20-25 min, non-trivial GPU cost.

Also requires an **On-Demand Capacity Reservation (ODCR)** for the GPU instance type so EKS Auto Mode can provision guaranteed GPU capacity fast:
```bash
export AWS_REGION="us-east-2" INSTANCE_TYPE="g6e.2xlarge" CR_AZ="us-east-2a"
aws ec2 create-capacity-reservation \
  --region $AWS_REGION --instance-type $INSTANCE_TYPE \
  --instance-platform Linux/UNIX --availability-zone "$CR_AZ" \
  --instance-count 1 --instance-match-criteria open --end-date-type unlimited
```
(`--end-date-type limited --end-date "<UTC ts>"` to auto-expire and avoid runaway cost.)

### At-an-Event path (what I actually used)
- Event Dashboard → Event Outputs → `IdeUrl` → opens code-server IDE (browser VS Code) with integrated terminal on an EC2-hosted workspace.
- Paste-in-terminal gotcha: Firefox `Shift+V`/`Cmd+Shift+V`; Chrome needs to grant clipboard-read permission when prompted.
- AWS Console access via a separate "Open AWS console" button (federated, no need to know creds).

**Key architecture point already surfacing:** the whole workshop is built on **EKS Auto Mode**, not a hand-rolled Karpenter/NodePool setup — that's the thing to remember for interviews (Auto Mode = AWS-managed Karpenter + managed core add-ons + managed AMI selection).

---

## 2. Setting Up the Cluster

Cluster name: `genai-workshop`. Pre-provisioned stack = VPC (multi-AZ public/private subnets) + EKS Auto Mode cluster + self-managed observability stack (Kube Prometheus Stack + Grafana Operator) + Amazon Managed Prometheus.

### Connect
```bash
aws eks update-kubeconfig --name genai-workshop
kubectl get pods --all-namespaces
```
Confirmed live — `kubectl get pods --all-namespaces` at connect time showed:
- `kube-system`: `metrics-server` (x2), and an **S3 CSI driver** (`s3-csi-controller` + `s3-csi-node` DaemonSet) — not mentioned in the workshop text itself, but this is almost certainly how the pre-provisioned **model storage** gets mounted into pods later (Mountpoint for S3 CSI driver lets S3 buckets present as a PV/volume, avoiding EBS for large model weights). Worth confirming when the "Serve a Model" module references a PVC/StorageClass.
- `monitoring`: Grafana Operator, Grafana, kube-state-metrics, Prometheus Operator, 2x `prometheus-node-exporter` (one per node — DaemonSet, matches the "runs on every nodepool" note above), Prometheus server (`2/2` — main container + config-reloader sidecar, standard for kube-prometheus-stack).
- Pods at 35h age → cluster was pre-provisioned well before the event start, consistent with "At an AWS Event" pre-baked infra.
- No `karpenter`/GPU nodes visible yet at this point — expected, since Auto Mode provisions the `general-purpose`/`system` nodes lazily and GPU nodes only get created on-demand later (per the "Testing GPU Functionality" step).

### Restrict ingress to own IP (at-event variant)
Get IP from **local browser** at https://checkip.amazonaws.com — NOT from the IDE terminal (that returns the EC2 workspace's IP, not yours).
```bash
export MY_IP=<YOUR_PUBLIC_IP>
kubectl patch ingressclassparams alb --type=merge -p "{\"spec\":{\"inboundCIDRs\":[\"${MY_IP}/32\"]}}"
```
Cluster-wide, one-time, applies to every ALB the workshop creates. Re-run if your IP changes.

Confirmed live: `ingressclassparams.eks.amazonaws.com/alb patched` — succeeded on first try, no errors.

### EKS Auto Mode built-in NodePools
```bash
kubectl get nodes -l karpenter.sh/nodepool=general-purpose
kubectl get nodes -l karpenter.sh/nodepool=system
```
Confirmed live — exactly one node per pool at this point in the workshop (Auto Mode had already lazily provisioned both by the 35h mark):
- `general-purpose`: `i-0582fa6f5d7ddebc3`, `v1.34.8-eks-a3a0722`
- `system`: `i-07021e996a2568ef6`, same k8s version
- **General-Purpose NodePool**: Bottlerocket OS, EKS-optimized AMI auto-selected, right-sized instances, amd64-only, on-demand only. Handles CPU workloads.
- **System NodePool**: for core cluster components.
- Auto Mode uses **Karpenter under the hood** but you never touch it directly; it rotates/replaces nodes every 21 days max for security patching.

### What EKS Auto Mode manages automatically
CoreDNS, kube-proxy, VPC CNI, EKS Pod Identity Agent, EBS CSI Driver, **NVIDIA Device Plugin** (bundled into the Bottlerocket GPU AMI variant, not a separate DaemonSet install).

### Self-managed add-ons (workshop-specific, layered on top)
Kube Prometheus Stack + Grafana Operator, running in `monitoring` namespace, pinned to the **system** nodepool via node selectors/tolerations in their Helm charts:
```bash
kubectl get pods -n monitoring -o wide
kubectl get pods -n monitoring -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' | \
  while read pod node; do
    echo "Pod: $pod -> Node: $node ($(kubectl get node $node -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}' 2>/dev/null || echo 'unknown'))"
  done
```
Note: `node-exporter` is a DaemonSet, so it legitimately appears on every nodepool — not a placement bug.

Confirmed live — placement matched exactly as documented: all 6 non-node-exporter monitoring pods on the `system` node (`i-07021e996a2568ef6`), the second `prometheus-node-exporter` replica on the `general-purpose` node (`i-0582fa6f5d7ddebc3`), one DaemonSet pod per node as expected.

### Model download job
Runs on **general-purpose** nodepool (no GPU need, no system tolerations):
```bash
kubectl get job model-download -o wide
```
Confirmed live: `model-download` job `Complete`, `1/1`, ran in 11m, containers `validate-pod-identity` + `download` (images `aws-cli:latest` + `python:3.11-slim` — so it validates EKS Pod Identity creds before pulling, then downloads via a Python step, presumably to the S3 bucket mounted via the S3 CSI driver noted above).

Known benign flake: an `Error`-status pod can appear alongside the `Completed` one — race condition in workshop provisioning, not a real failure.

**Reproduction gotcha:** the node-placement query for the model-download pod (`kubectl get pod -l job-name=model-download ...`) returned **no output** at 35h job age — the job's pod had already been garbage-collected by that point (jobs don't keep pods around indefinitely once complete). If recreating this workshop, capture that pod's node placement immediately after the job completes, not hours later.

---

## 2b. GPU Infrastructure

Goal: EKS Auto Mode GPU NodePool provisioning + SOCI-accelerated image pulls + prove GPU works end-to-end.

### GPU NodePool/NodeClass (pre-created)
```bash
kubectl get nodepool/gpu
kubectl get nodeclass/gpu
```
Confirmed live:
```
NAME   NODECLASS   NODES   READY   AGE
gpu    gpu         0       True    35h
NAME   ROLE                                                      READY   AGE
gpu    genai-workshop-eks-node-role-20260810053826894700000003   True    35h
```
`NODES: 0` at this point — unlike general-purpose/system, Auto Mode had **not** pre-provisioned any GPU node; it truly waits for a pod that needs one (cost control — GPU instances aren't cheap to leave idle).

Config highlights:
- Instance type: `g6e.2xlarge`
- AMI: Bottlerocket w/ embedded NVIDIA support
- **SOCI (Seekable OCI) snapshotter**: auto-enabled for G/P/Trn family instances w/ local NVMe as of 2025-11-19 — no config needed. Parallel-pull/unpack on NVMe dramatically speeds up cold-start on multi-GB ML container images (5-20GB typical).
- Taint: `nvidia.com/gpu:NoSchedule` — GPU nodes only take pods that explicitly tolerate it
- Label: `karpenter.sh/nodepool: gpu`
- amd64-only

### Wire up the ODCR to the GPU NodeClass
```bash
AWS_REGION=$(kubectl config get-contexts | grep '*' | awk '{print $2}' | cut -d':' -f4)
ODCR_ID=$(aws ec2 describe-capacity-reservations --region $AWS_REGION \
  --filters "Name=state,Values=active" \
  --query "CapacityReservations[0].CapacityReservationId" --output text)

mkdir -p manifests/100-introduction
cat <<EOF > manifests/100-introduction/patch-gpu-nodeclass.yaml
apiVersion: eks.amazonaws.com/v1
kind: NodeClass
metadata:
  name: gpu
spec:
  capacityReservationSelectorTerms:
    - id: $ODCR_ID
EOF

kubectl patch nodeclass gpu --patch-file manifests/100-introduction/patch-gpu-nodeclass.yaml --type=merge
kubectl get nodeclass gpu -o yaml | grep -A 3 capacityReservationSelectorTerms
```
Confirmed live: `AWS_REGION=us-east-2`, `ODCR_ID=cr-EXAMPLE000000095` (single active reservation found, matches the 1x `g6e.2xlarge` created in the self-paced/ODCR step). Patch applied cleanly:
```
nodeclass.eks.amazonaws.com/gpu patched
  capacityReservationSelectorTerms:
  - id: cr-EXAMPLE000000095
  ephemeralStorage:
    iops: 3000
```
(`ephemeralStorage.iops: 3000` showing right after confirms the NodeClass's SOCI-tuned local-NVMe storage config lives in the same spec block.)

### Prove GPU provisioning + device plugin work
Deploy a pod that requires `nvidia.com/gpu: 1`, tolerates the GPU taint, and node-selects `karpenter.sh/nodepool: gpu`, running `nvidia-smi` as its command:
```bash
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-smi
spec:
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
  nodeSelector:
    karpenter.sh/nodepool: gpu
  containers:
  - name: nvidia-smi
    image: public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
  restartPolicy: OnFailure
EOF

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/nvidia-smi --timeout=300s
kubectl logs nvidia-smi
```
Expected flow: pod `Pending` (no GPU node yet) → Auto Mode provisions a new GPU node (~30s–1min, no manual Karpenter NodePool wrangling) → device plugin auto-configures GPU on the node → pod runs → `nvidia-smi` logs show GPU model, CUDA driver version, memory, power/temp.

Confirmed live — `pod/nvidia-smi created` → `kubectl wait` returned `pod/nvidia-smi condition met` (within the 300s timeout, no retry needed) → `kubectl logs nvidia-smi`:
```
NVIDIA-SMI 580.159.03   Driver Version: 580.159.03   CUDA Version: 13.0
GPU 0: NVIDIA L40S, 46068MiB total, 0MiB used, 82W/350W, 39C, 0% util
No running processes found
```
So `g6e.2xlarge` = **1x NVIDIA L40S (46GB VRAM)** — that's the concrete GPU spec to remember when sizing model-serving workloads in later modules (e.g. what fits in 46GB at fp16/bf16/int8). Driver 580.159.03 + CUDA 13.0 both came pre-baked via the Bottlerocket GPU AMI variant — zero manual driver install, confirming the "embedded NVIDIA device plugin" claim end-to-end.

**Talking point for interviews:** this whole GPU-node-from-zero flow (taint/toleration/nodeSelector → Auto Mode Karpenter-driven provisioning → embedded NVIDIA device plugin, no manual driver/plugin install) is the crux of what makes EKS Auto Mode different from classic self-managed Karpenter + NVIDIA device plugin DaemonSet setups.

---

## 3. Serve a Model

### Why vLLM
Inference engine chosen for the workshop's Mistral-based LLM deployment on EKS. Claimed benefits (vendor-stated, from vLLM's own perf update):
- **Throughput**: up to 24x higher than raw PyTorch, via continuous batching + optimized CUDA kernels
- **Memory**: **PagedAttention** cuts GPU memory usage up to 60% by dynamically allocating KV cache (paged like OS virtual memory) instead of pre-reserving a worst-case contiguous block — this is what lets you run larger batches / longer context on a fixed GPU (relevant here: 46GB L40S)
- **Production shape**: OpenAI-compatible API server (drop-in for existing OpenAI client code), tensor-parallel distributed inference, built-in streaming + request scheduling

Not mandatory — TensorRT-LLM is a named alternative — but vLLM is what this workshop actually deploys. Concepts (continuous batching, PagedAttention, OpenAI-compatible serving) transfer to other engines.

**Interview-relevant framing:** vLLM's PagedAttention is the single most-cited reason it beats naive HF `transformers`-serving in production — worth being able to explain *why* (fragmented/wasted GPU memory from static KV-cache allocation) not just *that* it's faster.

### Deploy Mistral via vLLM

Deployment manifest source: `github.com/aws-samples/sample-genai-on-eks` tag `v2.5.2`, `manifests/100-vllm/vllm-deployment.yml` (downloaded raw, then `envsubst` fills in the S3 bucket placeholder).

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export S3_BUCKET_NAME="genai-models-${AWS_ACCOUNT_ID}"

mkdir -p manifests/200-inference
curl -o manifests/200-inference/vllm-s3-deployment.yml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.5.2/manifests/100-vllm/vllm-deployment.yml
envsubst < manifests/200-inference/vllm-s3-deployment.yml > /tmp/vllm-temp.yml \
  && mv /tmp/vllm-temp.yml manifests/200-inference/vllm-s3-deployment.yml
kubectl apply -f manifests/200-inference/vllm-s3-deployment.yml
```

Confirmed live:
- `AWS_ACCOUNT_ID=222233334444` → `S3_BUCKET_NAME=genai-models-222233334444`
- Model already pre-staged in that bucket (per the model-download job from module 2): `Ministral-3-8B-Instruct-2512/` — **note the name is "Ministral" (Mistral's small on-device/edge line), not "Mistral"** — includes `consolidated.safetensors` (**9.7GB**), tokenizer files (`tekken.json` — Mistral's own tokenizer format), `params.json`, `processor_config.json` (the `processor_config.json` is the tell that this is a **multimodal** checkpoint, confirmed below).
- `kubectl apply` → `service/vllm-serve-svc created`, `deployment.apps/mistral created`
- Manifest args of note: `--model=s3://genai-models-222233334444/Ministral-3-8B-Instruct-2512/`, `--load-format=runai_streamer`, `--model-loader-extra-config={"concurrency":16}` — **vLLM streams weights directly from S3 via the Run:ai Model Streamer, no download-to-disk step**; concurrency=16 parallel streams.

### GPU node provisioning + pod startup (live)
```bash
kubectl wait node --for=condition=Ready -l karpenter.sh/nodepool=gpu
kubectl wait pods --for=jsonpath='{.status.phase}'=Running -l model=mistral --timeout=300s
kubectl logs -l model=mistral -f
```
- New GPU node auto-provisioned: `i-01f0dfced3cf175a8` — **a different instance than the earlier `nvidia-smi` test node**, implying Auto Mode had already scaled that first GPU node back down (consolidation) once its pod finished, then spun up a fresh one for this deployment. Good evidence of real scale-to-zero behavior, not a fluke.
- Pod `mistral-864b87f8db-zv5h6` reached `Running` well inside the 300s timeout.

### vLLM startup log — key facts
- vLLM version **0.15.1**
- `enable_auto_tool_choice=True`, `tool_call_parser='mistral'`, `trust_remote_code=True`, `config_format='mistral'` — Mistral-native config/tool-calling support, not generic HF.
- **Resolved architecture: `PixtralForConditionalGeneration`** — this confirms Ministral-3-8B here is a **multimodal (vision+text) model** (Pixtral is Mistral's VLM architecture), not pure text. Encoder cache initialized with an 8192-token budget, profiled with 2 image items.
- `max_model_len=2048`, `enforce_eager=True` (disables CUDA graph capture — trades some throughput for faster/simpler startup, common in demo/workshop settings), `dtype=torch.bfloat16`, **`quantization=fp8`** running on `CutlassFP8ScaledMMLinearKernel` — so weights/activations run FP8 on the L40S despite bf16 dtype flag, i.e. quantized inference is on by default here.
- Attention backend auto-selected: `FLASH_ATTN` (candidates were `FLASH_ATTN`, `FLASHINFER`, `TRITON_ATTN`, `FLEX_ATTENTION`).
- **Run:ai Streamer load**: streamed **9.7 GiB in 7.22s = 1.3 GiB/s** straight from S3 to CPU, then to GPU — model load (weights + init) took **9.77 GiB GPU memory / 26.9s total**. This is the concrete number for "why stream from S3 instead of downloading first" — sub-30s cold start for an 8B-class model.
- **KV cache**: 27.96 GiB available (of the 46GB L40S, after ~9.77GiB for weights) → 215,584 tokens of KV cache capacity → **max concurrency 105.27x** at 2048 tokens/request. This is the PagedAttention payoff mentioned in the "Why vLLM" section made concrete: ~105 concurrent 2048-token requests on a single L40S.
- Full engine init (profile + KV cache create + warmup) took **2.92s**.
- Exposed routes confirm production-shape API surface: `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/responses`, **`/v1/messages`** (Anthropic Messages-API-compatible, not just OpenAI!), `/v1/rerank`, `/classify`, `/score`, `/metrics`, `/health`, plus vLLM-specific `/scale_elastic_ep`, `/pause`/`/resume`.

**Reproduction gotcha:** the model bucket/prefix must already be populated by the `model-download` job (module 2) before this step — this manifest doesn't download the model itself, it only mounts/streams from an S3 path assumed to already hold the weights.

### Test the Model

**Direct API test via port-forward:**
```bash
kubectl port-forward svc/vllm-serve-svc 8000:8000 &

curl -s http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"s3://${S3_BUCKET_NAME}/Ministral-3-8B-Instruct-2512/\",\"prompt\": \"San Francisco is a city that has\",\"max_tokens\": 7,\"temperature\": 0}" | jq
```
Confirmed live — OpenAI-compatible `/v1/completions` response: completion `" a lot of history and culture."`, `finish_reason: length` (hit the 7-token cap, not a natural stop), `usage: {prompt_tokens: 8, completion_tokens: 7, total_tokens: 15}`. Note the `model` field in both request and response is the **S3 URI itself** — vLLM uses the model path as its served-model-name here, there's no separate `--served-model-name` alias configured.

**Open WebUI (chat UI) deployment:**
Manifest source: same sample repo, but pinned to an **older tag `v2.3.1`** (vs `v2.5.2` for the vLLM manifest) at `manifests/200-ray/openwebui.yml` — worth knowing if reproducing, since the two manifests come from different repo versions.

```bash
curl -o manifests/200-inference/openwebui.yml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.3.1/manifests/200-ray/openwebui.yml
kubectl apply -f manifests/200-inference/openwebui.yml
kubectl wait --for=condition=ready pod -l app=open-webui --timeout=300s

export OPENWEBUI_URL=$(kubectl get ingress open-webui-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
aws elbv2 wait load-balancer-available --load-balancer-arns \
  $(aws elbv2 describe-load-balancers --query 'LoadBalancers[?DNSName==`'"$OPENWEBUI_URL"'`].LoadBalancerArn' --output text)
```

Manifest contents (3 objects):
- **Deployment**: `ghcr.io/open-webui/open-webui:v0.5.20`, pinned to `node.kubernetes.io/instance-type: "m5.xlarge"` (a CPU node — no GPU needed for the chat frontend, only the inference backend needs it). `WEBUI_AUTH=False` (no login wall — fine for a throwaway workshop, not something to carry into a real deployment), points at the vLLM service via `OPENAI_API_BASE_URLS=http://vllm-serve-svc:8000/v1` (in-cluster DNS, same pattern as the earlier port-forward test but service-to-service instead of local).
- **Service**: ClusterIP, port 80 → 8080.
- **Ingress**: ALB, `internet-facing`, **`alb.ingress.kubernetes.io/inbound-cidrs: 0.0.0.0/0`** in the manifest itself.

**Security detail worth remembering:** the Ingress annotation asks for `0.0.0.0/0`, which looks like it contradicts the earlier "restrict ALB ingress to your own IP" step (module 2) — but that earlier step patched the **`IngressClassParams`** (`inboundCIDRs`), which is a cluster-wide governance control the AWS Load Balancer Controller enforces on top of / instead of the per-Ingress annotation. So the actual security group ends up scoped to `${MY_IP}/32` regardless of what any individual Ingress manifest requests. This is a good interview point: `IngressClassParams.inboundCIDRs` > per-Ingress `inbound-cidrs` annotation for governance purposes.

Confirmed live: `deployment.apps/open-webui created`, `service/open-webui created`, `ingress.networking.k8s.io/open-webui-ingress created`, pod `open-webui-796c89dcf-btrcn` reached Ready within timeout, ALB provisioned and became available at `http://open-webui-ingress-246464927.us-east-2.elb.amazonaws.com`.

---

## 4. Optimize Inference

### Deploy Observability Stack (DCGM Exporter)

**Review pre-existing monitoring stack:**
```bash
kubectl get pods -n monitoring
kubectl get pods -l "app.kubernetes.io/name=prometheus" -n monitoring
kubectl get pods -l "app.kubernetes.io/name=prometheus-node-exporter" -n monitoring
kubectl get pods -l "app.kubernetes.io/name=kube-state-metrics" -n monitoring
kubectl get pods -l "app.kubernetes.io/name=grafana" -n monitoring
kubectl get pods -l "app.kubernetes.io/name=grafana-operator" -n monitoring
```
Confirmed live: node-exporter DaemonSet grew from 2 pods (35h old) → **4 pods** (2 new, ages 5m8s and 19m) — one per node added since baseline (the GPU node from "Serve a Model" + the `m5.xlarge` Open WebUI node), confirming DaemonSet auto-coverage as Auto Mode scales out.

**Grafana CR (managed by Grafana Operator):**
```bash
kubectl get Grafana external-grafana -n monitoring -o yaml
```
Confirmed live — `external-grafana` is an `external` Grafana CR (points the operator at the **existing** `kube-prometheus-stack-grafana` service rather than provisioning its own Grafana instance), Grafana version **12.4.2**, and it already has **6 dashboards pre-registered** via `GrafanaDashboard` CRs, *before* DCGM exporter existed:
- `rayServeDashboard`, `rayServeDeploymentDashboard`, `rayDefaultDashboard` — **Ray dashboards, despite this workshop's model being served via a plain Kubernetes `Deployment`, not KubeRay** — strong signal these dashboard manifests are reused/shared from a broader version of the sample repo that also has a Ray-based serving path (the Open WebUI manifest itself came from a `200-ray/` directory, corroborating this).
- `vllm-dashboard`, `vllm-ray-grafana-dashboard` — vLLM-specific panels.
- `dcgm-grafana-dashboard` — the one that lights up once DCGM Exporter starts publishing.

So the dashboards existed pre-wired but blank/no-data until this step installs the actual metrics source.

**Install DCGM Exporter via Helm:**
```bash
mkdir -p manifests/200-inference
cat << EOF > manifests/200-inference/values.yaml
serviceMonitor:
  enabled: true
  additionalLabels:
    release: kube-prometheus-stack  # Important for prometheus operator discovery
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
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 256Mi
EOF

helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update
helm install dcgm-exporter gpu-helm-charts/dcgm-exporter -n monitoring -f manifests/200-inference/values.yaml
```
Key config points:
- `additionalLabels.release: kube-prometheus-stack` on the ServiceMonitor is **required**, not decorative — the Prometheus Operator only picks up ServiceMonitors matching the label selector on the `Prometheus` CR (typically `release: <helm-release-name>`); without this label the ServiceMonitor is silently ignored and DCGM metrics never reach Prometheus.
- Same `nodeSelector: gpu` + `nvidia.com/gpu` toleration pattern as the vLLM/nvidia-smi pods — DCGM exporter only runs where there's a GPU to monitor, one pod per GPU node.

Confirmed live: Helm install succeeded (`STATUS: deployed`, `REVISION: 1`), `kubectl wait` → `pod/dcgm-exporter-qv4pc condition met` (only 1 pod, matching the single GPU node currently up).

**Query metrics directly:**
```bash
NAME=$(kubectl get pods -l "app.kubernetes.io/name=dcgm-exporter" -n monitoring -o "jsonpath={ .items[0].metadata.name}")
kubectl port-forward -n monitoring $NAME 9400:9400 &
curl -sL http://127.0.0.1:9400/metrics
```
Confirmed live — real GPU telemetry, all labeled with `pod="mistral-864b87f8db-zv5h6"`, `container="vllm"`, `hostname="i-01f0dfced3cf175a8"` (**DCGM auto-correlates GPU metrics to the k8s pod/container consuming that GPU** — this per-pod attribution is the actual value-add over raw `nvidia-smi`, especially once multiple models/pods share a node):
- `DCGM_FI_DEV_FB_USED = 40798 MiB`, `DCGM_FI_DEV_FB_FREE = 4659 MiB` (of 46068MiB total) — matches the earlier vLLM log math almost exactly: ~9.77GiB weights + ~27.96GiB KV cache pool ≈ 38.7GiB reserved, DCGM shows ~40GB used at idle since vLLM **pre-allocates** the full KV cache pool at startup rather than growing it lazily.
- `DCGM_FI_DEV_GPU_UTIL = 0`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE = 0`, `DCGM_FI_DEV_DEC_UTIL/ENC_UTIL = 0` — GPU compute idle at scrape time (no inference in flight), consistent with only having sent one test request earlier.
- `DCGM_FI_DEV_POWER_USAGE = 108.386W` (idle draw, vs 350W cap seen in `nvidia-smi` earlier) — idle-vs-loaded power delta is a useful capacity-planning number.
- `DCGM_FI_DEV_GPU_TEMP = 44C`, `DCGM_FI_DEV_SM_CLOCK = 2520MHz`, `DCGM_FI_DEV_MEM_CLOCK = 9001MHz`.
- Error-correction counters all `0` (`CORRECTABLE_REMAPPED_ROWS`, `UNCORRECTABLE_REMAPPED_ROWS`, `ROW_REMAP_FAILURE`, `PCIE_REPLAY_COUNTER`) — healthy hardware, no ECC events.

**Interview-relevant takeaway:** DCGM's `FB_USED` reading is the ground-truth way to explain *why* GPU memory looks "full" even when `GPU_UTIL` is 0% — vLLM's upfront KV-cache reservation (the PagedAttention memory-pool strategy from the "Why vLLM" section) shows up here as a large static allocation, not a leak or a bug.

### NVIDIA DCGM Dashboard (Grafana access)

Expose Grafana externally via a third ALB (same pattern as Open WebUI — one ALB per app rather than a shared ingress/path-based routing):
```bash
mkdir -p manifests/300-observability
cat <<EOF > manifests/300-observability/grafana-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /api/health
    ...
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
kubectl apply -f manifests/300-observability/grafana-ingress.yaml

export GRAFANA_URL=$(kubectl get ingress/grafana-ingress -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
aws elbv2 wait load-balancer-available --load-balancer-arns \
  $(aws elbv2 describe-load-balancers --query 'LoadBalancers[?DNSName==`'"$GRAFANA_URL"'`].LoadBalancerArn' --output text)

export GRAFANA_PASSWORD=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
```
Confirmed live: `ingress.networking.k8s.io/grafana-ingress created`, ALB became available at `http://grafana-ingress-101004048.us-east-2.elb.amazonaws.com`. Admin credentials pulled straight from the `kube-prometheus-stack-grafana` Secret: user `admin`, password decoded to the literal string **`notforproductionuse`** — a deliberately obvious placeholder baked into the workshop's Helm values (the kube-prometheus-stack chart lets you set `grafana.adminPassword`; this wasn't randomly generated). Real deployments should override this via a proper secret rather than chart defaults.

Note this Ingress has **no `inbound-cidrs` annotation at all** (unlike Open WebUI's explicit `0.0.0.0/0`) — same governance point applies though: the cluster-wide `IngressClassParams.inboundCIDRs` patched to `${MY_IP}/32` back in "Setting Up the Cluster" still caps actual access regardless of what any individual Ingress does or doesn't specify.

Once logged in: the 6 pre-registered dashboards (module intro) become live, especially `dcgm-grafana-dashboard` — now populated since DCGM Exporter is running and its ServiceMonitor is correctly labeled for discovery.

### vLLM Metrics (ServiceMonitor)

Unlike DCGM (installed via a Helm chart that creates its own ServiceMonitor from `values.yaml`), the vLLM Deployment needs its **ServiceMonitor created by hand** — the sample repo's `vllm-deployment.yml` from module 3 didn't include one:
```bash
cat << EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mistral-monitor
  namespace: monitoring
  labels:
    release: kube-prometheus-stack  # Important for Prometheus operator discovery
spec:
  namespaceSelector:
    matchNames:
      - default
  selector:
    matchLabels:
      model: mistral
  endpoints:
    - port: http
      interval: 30s
      path: /metrics
EOF
```
Same `release: kube-prometheus-stack` label requirement as the DCGM ServiceMonitor — confirms this is a hard rule for this Prometheus Operator install, not chart-specific. `selector.matchLabels.model: mistral` cross-namespace-selects the `vllm-serve-svc` Service in `default` (via `namespaceSelector`, since the ServiceMonitor itself lives in `monitoring`) — relies on the vLLM Service having a `model: mistral` label and a **named port `http`** (not just a numeric port) for the `endpoints[].port: http` reference to resolve.

Confirmed live: `servicemonitor.monitoring.coreos.com/mistral-monitor created`.

**Verify the Grafana dashboard picks it up:**
```bash
kubectl get grafanadashboard vllm-dashboard -n monitoring
```
Confirmed live: `NO MATCHING INSTANCES` column empty (i.e. false — the dashboard *does* have a matching Grafana instance), `LAST RESYNC: 3m23s`, `AGE: 36h` — the `GrafanaDashboard` CR itself predates this step by a day and a half (pre-provisioned like the others), it just had nothing to render until the vLLM ServiceMonitor above gave Prometheus something to scrape for the `vllm-dashboard` panels.

---

### Agentic App (Strands Weather Agent)

Ties everything together: an **agent** (tool-calling LLM app) built with **Strands Agents** (AWS's open-source agent SDK), served in-cluster, pointed at the same vLLM endpoint from module 3 — this is what exercises the `tool_call_parser='mistral'` / `enable_auto_tool_choice=True` vLLM flags noted back in "Serve a Model" (they were configured then, but nothing had used tool-calling until now).

**Re-verify the serving stack is still up before building on it:**
```bash
kubectl get pods -l model=mistral
kubectl get svc vllm-serve-svc
```
Confirmed live: `mistral-864b87f8db-zv5h6` still `Running` (31m old — no restarts across the whole Optimize Inference module), `vllm-serve-svc` ClusterIP `172.20.191.87:8000`.

**Pull down the agent source and containerize it:**
```bash
mkdir -p manifests/600-strands-agent
curl -o manifests/600-strands-agent/strands.zip \
  https://ws-assets-prod-iad-r-pdx-f3b3f9f1a7d6a3d0.s3.us-west-2.amazonaws.com/029d6c4e-4775-41c9-85ff-9f5360f32a15/strands.zip
unzip manifests/600-strands-agent/strands.zip -d manifests/600-strands-agent
# -> Dockerfile, requirements.txt, strands-agent.py
```
Note: this asset is a **workshop-specific S3 bundle** (`ws-assets-prod-...` — Workshop Studio's own asset CDN), not from the `sample-genai-on-eks` GitHub repo like the other manifests — so this file won't survive outside the live event and would need to be sourced differently for a from-scratch reproduction (e.g. write the Strands agent code directly, or check if it's mirrored in the repo).

**Build, push to ECR, deploy:**
```bash
aws ecr create-repository --repository-name strands-weather-agent
export ECR_REPO=$(aws ecr describe-repositories --repository-names strands-weather-agent --query 'repositories[0].repositoryUri' --output text)

aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $(echo $ECR_REPO | cut -d'/' -f1)
docker build -t strands-weather-agent manifests/600-strands-agent
docker tag strands-weather-agent:latest $ECR_REPO:latest
docker push $ECR_REPO:latest
```
Confirmed live: ECR repo `222233334444.dkr.ecr.us-east-2.amazonaws.com/strands-weather-agent` created (AES256 encryption, scan-on-push disabled), image built from `python:3.12-slim` in ~29s (pip install of deps was the bulk at 23.3s), pushed successfully (8 layers).

**Deployment manifest** — this is the interesting wiring: the agent talks to vLLM the exact same way the earlier `curl` test did (OpenAI-compatible endpoint), just from inside the cluster instead of via port-forward:
```yaml
env:
- name: MODEL_ENDPOINT
  value: "http://vllm-serve-svc:8000/v1"
- name: MODEL_ID
  value: "s3://${S3_BUCKET_NAME}/Ministral-3-8B-Instruct-2512/"
```
(Same `served-model-name = S3 URI` quirk noted in "Serve a Model" — the agent has to know to pass the S3 URI as the model name, since that's what vLLM registered it as.)
```bash
envsubst < manifests/600-strands-agent/vllm-deployment-agents.yaml | kubectl apply -f -
kubectl wait pods --for=jsonpath='{.status.phase}'=Running -l app=strands-weather-agent --timeout=300s
```
Confirmed live: `deployment.apps/strands-weather-agent created`, `service/strands-weather-agent created`, pod `strands-weather-agent-5f5c544d6-nmh5r` reached Running.

**Test tool-calling end to end:**
```bash
kubectl port-forward svc/strands-weather-agent 8080:80 &
curl -s -X POST http://localhost:8080/agent -H "Content-Type: application/json" \
  -d '{"query": "What time is it in Dallas?"}' | jq -r '.response.message.content[0].text'
curl -s -X POST http://localhost:8080/agent -H "Content-Type: application/json" \
  -d '{"query": "What weather is it in Denver?"}' | jq -r '.response.message.content[0].text'
```
Confirmed live — both worked, proving real tool dispatch (not hallucinated answers):
- `"The current time in Dallas is **1:08 PM CDT**."`
- `"The current weather in **Denver, Colorado** is **mainly clear** with a temperature of **35.0°C (95°F)**."`

**Interview-relevant takeaway:** this is the full agentic-inference stack in one place — Strands agent (orchestration + tool definitions) → OpenAI-compatible HTTP call → vLLM with `tool_call_parser='mistral'` translating the model's raw tool-call output into structured OpenAI-format tool calls → agent executes the actual tool (time/weather lookup) → feeds result back to the model for a final natural-language answer. The vLLM-level config from module 3 (`enable_auto_tool_choice`, `tool_call_parser`) is *why* this works with a self-hosted model instead of requiring OpenAI/Anthropic's hosted APIs.

### Benchmarking (Baseline vs Saturation)

Uses a benchmarking Helm chart (`benchmark-charts`) from the same sample repo, this time pinned to **yet another tag: `v2.4.8`** — the fourth distinct tag referenced across this workshop so far (`v2.5.2` vLLM, `v2.3.1` Open WebUI, `v2.4.8` benchmarking). **Reproduction note:** pin manifests to their exact original tags if rebuilding from scratch — this repo's `main`/latest may have moved on and broken compatibility between these pieces.

```bash
curl -L -o /tmp/benchmark-charts.tar.gz \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.4.8/manifests/400-benchmarking/benchmark-charts.tar.gz
tar xzf /tmp/benchmark-charts.tar.gz -C ~/
```

**Sanity-check the model from inside the cluster** (different technique than the earlier port-forward test — exec into the vLLM pod itself and curl the in-cluster DNS name):
```bash
kubectl exec deployment/mistral -- curl -s http://vllm-serve-svc.default.svc.cluster.local:8000/v1/models
```
Confirmed live: `/v1/models` returns the S3-URI-as-model-id again, `max_model_len: 2048`, `allow_sampling/allow_logprobs: true`.

**Benchmarking Grafana dashboard** — different pattern than the pre-baked dashboards from module 4's intro (those were presumably inline JSON in the `GrafanaDashboard` CR); this one is dashboard-JSON-in-a-ConfigMap + a CR that references it:
```bash
curl -o manifests/700-benchmarking/vllm-benchmarking-dashboard.json \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.4.8/manifests/400-benchmarking/vllm-benchmarking-dashboard.json
curl -o manifests/700-benchmarking/vllm-benchmarking-dashboard-cr.yaml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.4.8/manifests/400-benchmarking/vllm-benchmarking-dashboard-cr.yaml

kubectl create configmap vllm-benchmarking-dashboard-config \
  --from-file=vllm-benchmarking-dashboard.json=manifests/700-benchmarking/vllm-benchmarking-dashboard.json \
  -n monitoring
kubectl apply -f manifests/700-benchmarking/vllm-benchmarking-dashboard-cr.yaml
```
Confirmed live: `configmap/vllm-benchmarking-dashboard-config created`, `grafanadashboard.grafana.integreatly.org/vllm-benchmarking-dashboard created`.

#### Baseline scenario

`baseline-values.yaml` (from the repo, `envsubst`'d for `$S3_BUCKET_NAME`) config highlights:
- `tokenizerPath: "mistralai/Mistral-Nemo-Instruct-2407"` — **note this is a different model family than the actual served model** (`Ministral-3-8B-Instruct-2512`). Almost certainly just reused because it's a Mistral-family tokenizer compatible enough for the benchmark client to count tokens correctly, not a bug — but worth double-checking if reproducing with a different model, since a mismatched tokenizer would silently mis-measure prompt/output token counts.
- `affinity.targetLabels: {model: mistral}` — schedules the benchmark load-generator pod(s) with affinity toward the same node/label as the model pod (likely to reduce network-hop latency skewing the measurement).
- Fixed-size, zero-variance workload (`input: mean=512, stdDev=0`, `output: mean=128, stdDev=0`) — deliberately deterministic so the run measures pure serving latency, not workload variance. `numWorkers=4`, constant `rate=1` req/s for 60s — described as "zero contention" baseline.
- Results land in `s3://${S3_BUCKET_NAME}/benchmarks`.

```bash
envsubst < manifests/700-benchmarking/baseline-values.yaml > /tmp/baseline-values.yaml
helm install baseline ~/benchmark-charts -n default -f /tmp/baseline-values.yaml
kubectl wait --for=condition=complete job -l benchmark.scenario=baseline -n default --timeout=300s
```
Confirmed live — **baseline results (60 requests, 0 failures, ~513 in / ~129 out tokens, matching config):**

| Metric | p50 | p90 | p99 |
|---|---|---|---|
| TTFT (ms) | 61.5 | 71.5 | 72.5 |
| TPOT (ms) | 10.75 | 10.84 | 10.93 |

Output TPS: **126.8 tok/s**, achieved rate: **0.99 req/s** (matches the requested `rate=1`). TPOT ≈10.75ms/token ⇒ ≈93 tokens/sec *per individual request stream* — the 126.8 aggregate is close to that since concurrency was low (rate=1, 4 workers, mostly one generation in flight at a time).

#### Saturation scenario

`saturation-values.yaml` differs from baseline in exactly the ways that matter for a "find the ceiling" test:
- Variable workload (`input: mean=512, stdDev=128, range 128-2048`; `output: mean=256, stdDev=64, range 32-512`) — realistic mixed traffic instead of fixed-size.
- `metrics.enabled: true`, scraping vLLM's own `/metrics` every 5s during the run, labeled `deployment=mistral, scenario=saturation` — so the benchmark's load timeline can be correlated against vLLM's internal engine metrics in Grafana afterward (not just client-observed latency).
- `numWorkers=8`, **3 staged rates: 5 → 10 → 20 req/s, 60s each** — description: "Determine maximum sustainable throughput."

```bash
envsubst < manifests/700-benchmarking/saturation-values.yaml > /tmp/saturation-values.yaml
helm install saturation ~/benchmark-charts -n default -f /tmp/saturation-values.yaml \
  --set benchmark.serviceAccount.create=false
kubectl wait --for=condition=complete job -l benchmark.scenario=saturation -n default --timeout=600s
```
`--set benchmark.serviceAccount.create=false` was needed on this second `helm install` — the baseline release already created a ServiceAccount the chart expects, so saturation reuses it instead of trying to create a conflicting duplicate. **Reproduction gotcha** if running scenarios independently/out of order.

Confirmed live — **per-stage results, and this is the actual "find the knee" data**:

| Stage | Target rate | Achieved | Successes | TTFT p50 | Output TPS |
|---|---|---|---|---|---|
| 0 | 5 req/s | 4.41 req/s | 300 | **69ms** | 1110.7 |
| 1 | 10 req/s | 8.83 req/s | 600 | **71ms** | 2263.5 |
| 2 | 20 req/s | 16.90 req/s | 1200 | **160ms** | 4271.3 |

**Interview-relevant takeaway:** stage 2 is where the single-L40S deployment starts to saturate — TTFT more than doubles (71ms → 160ms) and achieved throughput (16.9 req/s) falls further short of the requested rate (20) than either earlier stage did, both classic signs of queueing delay once concurrent in-flight requests eat into the ~28GiB KV-cache budget (215,584-token capacity / ~105x concurrency ceiling noted back in "Serve a Model"). This is real, first-hand evidence of *why* horizontal scaling (more GPU replicas) or a bigger GPU becomes necessary past a certain request rate — good concrete numbers to cite instead of hand-waving about "GPU inference doesn't scale linearly."

#### Teardown after benchmarking

Run live at the end of this section (unlike the separate "Cleanup" module text, which was NOT run) — removes the benchmark Helm releases and the vLLM deployment itself:
```bash
helm uninstall baseline -n default 2>/dev/null || true
helm uninstall saturation -n default 2>/dev/null || true
kubectl delete deployment mistral 2>/dev/null || true
kubectl delete service vllm-serve-svc 2>/dev/null || true
```
Confirmed live: both Helm releases uninstalled, `deployment.apps "mistral" deleted`, `service "vllm-serve-svc" deleted`, pod `mistral-864b87f8db-zv5h6` shown `Terminating` at 55m age.

**State checkpoint:** as of this point, the `mistral`/`vllm-serve-svc` deployment from "Serve a Model" **no longer exists** — any subsequent module ("Customize Model", "Inference Frameworks") presumably redeploys its own model-serving setup rather than reusing this one. Note that live when capturing those sections.

### CPU Offloading (LMCache L1 CPU RAM Cache)

Redeploys a standalone vLLM pod (not the earlier Deployment) wired to **LMCache** — extends KV-cache capacity beyond GPU HBM into CPU RAM, so repeated/overlapping prompts don't need full GPU recomputation. Manifests pinned to **yet another tag: `v2.4.7`** (fifth distinct repo tag seen this workshop — reinforces the earlier pin-exact-tags reproduction note).

```bash
mkdir -p manifests/400-advanced-ai/900-cache
curl -o manifests/400-advanced-ai/900-cache/lmcache-cpu-ram-configmap.yaml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.4.7/manifests/500-lmcache/cpu-ram-offloading/lmcache-cpu-ram-configmap.yaml
curl -o manifests/400-advanced-ai/900-cache/lmcache-cpu-ram-pod.yaml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.4.7/manifests/500-lmcache/cpu-ram-offloading/lmcache-cpu-ram-pod.yaml
envsubst < manifests/400-advanced-ai/900-cache/lmcache-cpu-ram-pod.yaml > /tmp/lmcache-cpu-ram-pod.yaml \
  && mv /tmp/lmcache-cpu-ram-pod.yaml manifests/400-advanced-ai/900-cache/lmcache-cpu-ram-pod.yaml
kubectl apply -f manifests/400-advanced-ai/900-cache/lmcache-cpu-ram-configmap.yaml
kubectl apply -f manifests/400-advanced-ai/900-cache/lmcache-cpu-ram-pod.yaml
```
Confirmed live: `configmap/cpu-ram-cm created` (bundles a `query-twice.py` test script + static docs), `pod/lmcache-cpu-ram created`. Model args this time include **`--served-model-name=ministral-3-8b-instruct-2512`** — unlike the module-3 deployment (which had no alias, so clients had to address it by the raw S3 URI), this pod gives the model a friendly name. Also note `max_model_len=8192` here vs `2048` in module 3 — bumped up specifically to allow the long overlapping test prompts (4092/4039 tokens) used below.

**Known benign error, safe to ignore:** container startup logs an error trying to `pip install lmcache==0.3.8` (not a published version — PyPI's version list jumps `0.3.7 → 0.3.9`), but vLLM/LMCache start up fine afterward using an already-installed version (**LMCache 0.3.13**, confirmed later in the logs) — this looks like a leftover/no-op version-pin step in the container image, not a real failure. Same pattern as the benign `Error` pod seen in the model-download job back in module 2: don't panic at every red line in workshop logs.

**How LMCache wires into vLLM:** visible in the non-default engine args as `kv_transfer_config: KVTransferConfig(kv_connector='LMCacheConnectorV1', kv_role='kv_both', ...)` — vLLM has a native **KV-connector API (v1)** specifically for pluggable external KV-cache backends; LMCache registers through that, not as a sidecar/proxy hack. Config summary confirmed live:
- `local_cpu=True`, **`max_local_cpu_size=12.0` (GB)** — this run's "L1" tier is pure CPU RAM, capped at 12GB. No disk tier, no remote/P2P tier configured (`local_disk=None`, `enable_p2p=False`, `remote_url=None`) — single-node only.
- `chunk_size=256` tokens, `cache_policy='LRU'` — cache is chunked and evicted LRU when the 12GB fills.
- Hash algorithm: `builtin`, with an explicit **production warning**: `PYTHONHASHSEED` must be set for consistent hashing across processes in real deployments (Python's hash randomization would otherwise break cache-key consistency across worker restarts) — a genuine gotcha to remember, not a workshop-only quirk.
- KV shape logged: `(34 layers, 2 [K/V], 256 chunk, 8 kv_heads/GPU, 128 head_size)` — confirms Ministral-3-8B's actual architecture numbers (34 transformer layers, grouped-query attention with 8 KV heads, 128 head_dim) if ever needed for KV-cache-size math.
- Builds on top of vLLM's own `enable_prefix_caching=True` (already on by default) — LMCache's contribution is extending that prefix cache's *capacity* beyond GPU HBM into CPU RAM, not inventing prefix caching itself.

**The actual test — cold vs warm TTFT with 90% prompt overlap:**
```bash
kubectl wait node --for=condition=Ready -l karpenter.sh/nodepool=gpu
kubectl wait --for=condition=ready pod/lmcache-cpu-ram --timeout=600s
kubectl exec lmcache-cpu-ram -- python /app/query-twice.py
```
Confirmed live — real numbers, this is a strong one to remember:
- **Cold** request (4,092-token prompt, LMCache empty, GPU computes every token): **TTFT 0.387s**.
- **Warm** request (4,039-token prompt, ~90% content overlap with the cold one): LMCache L1 serves the matching prefix from CPU RAM, GPU only computes the new ~10% tail: **TTFT 0.119s**.
- **Result: 3.2x TTFT improvement** (0.267s saved) purely from CPU-RAM prefix-cache reuse, zero GPU/model changes.

**Interview-relevant takeaway:** this is the concrete case for LMCache in a production RAG/chat system — any workload with repeated/shared prefixes (long system prompts, multi-turn conversation history, shared document context in RAG) pays the full prefill cost once, then gets a multi-x TTFT speedup on every subsequent request sharing that prefix, without needing more/bigger GPUs. It's a memory-hierarchy argument (GPU HBM → CPU RAM → disk/remote, each tier bigger/slower/cheaper) rather than a compute optimization — good framing if asked to explain LMCache vs. e.g. just enabling vLLM's own prefix caching (which is GPU-HBM-only and evicted much sooner under memory pressure).

**Teardown (run live):**
```bash
kubectl delete pod lmcache-cpu-ram
kubectl delete configmap cpu-ram-cm
```
Confirmed live: both deleted cleanly.

### External KV Cache (L2 Remote Cache via ElastiCache Serverless Valkey)

Extends the LMCache setup from "CPU Offloading" with an **L2 remote tier**: Amazon **ElastiCache Serverless for Valkey** (Redis-compatible, AWS-managed), shared across pods over TLS (`rediss://`) — so the cache survives pod restarts/rescheduling instead of dying with the pod like the L1-only CPU-RAM test did.

**Provision the Valkey cluster:**
```bash
mkdir -p manifests/500-lmcache
curl -o manifests/500-lmcache/setup-valkey.sh \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.4.7/manifests/500-lmcache/remote-cache-sharing-with-valkey/setup-valkey.sh
chmod +x manifests/500-lmcache/setup-valkey.sh
source manifests/500-lmcache/setup-valkey.sh   # must `source`, not run — exports $VALKEY_ENDPOINT into the shell
echo "Valkey endpoint: $VALKEY_ENDPOINT"
```
**First attempt failed with a transient AWS API error**: `InvalidCredentialsException` on `CreateServerlessCache` (not an actual credentials problem — a known-flaky ElastiCache Serverless API behavior). Re-running the exact same script succeeded: it detected and reused the already-created security group (`sg-08949059ed973494e`) rather than erroring on a duplicate, and the cluster then transitioned `creating` → available in ~8 polling cycles. **Reproduction gotcha:** this script is safe to blindly retry on failure — it's idempotent about the security group, and the cluster creation itself just needs to be kicked off successfully once.

Confirmed live: `VALKEY_ENDPOINT=lmcache-valkey-eks-jkwm0s.serverless.use2.cache.amazonaws.com`.

**Deploy the LMCache pod wired to Valkey:**
```bash
curl -o manifests/400-advanced-ai/900-cache/lmcache-valkey-configmap.yaml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.4.7/manifests/500-lmcache/remote-cache-sharing-with-valkey/lmcache-valkey-configmap.yaml
curl -o manifests/400-advanced-ai/900-cache/lmcache-valkey-pod.yaml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.4.7/manifests/500-lmcache/remote-cache-sharing-with-valkey/lmcache-valkey-pod.yaml
envsubst < manifests/400-advanced-ai/900-cache/lmcache-valkey-pod.yaml > /tmp/lmcache-valkey-pod.yaml \
  && mv /tmp/lmcache-valkey-pod.yaml manifests/400-advanced-ai/900-cache/lmcache-valkey-pod.yaml
kubectl apply -f manifests/400-advanced-ai/900-cache/lmcache-valkey-configmap.yaml
kubectl apply -f manifests/400-advanced-ai/900-cache/lmcache-valkey-pod.yaml
```
`envsubst` fills in both `${S3_BUCKET_NAME}` (model path, same as before) and **`${VALKEY_ENDPOINT}`** → pod env var `value: "rediss://lmcache-valkey-eks-jkwm0s.serverless.use2.cache.amazonaws.com:6379"`. Confirmed live: `configmap/valkey-cm created`, `pod/lmcache-valkey created`, and logs confirm the connector wiring:
```
LMCache INFO: Discovered adapter: ValkeyConnectorAdapter
LMCache INFO: Connected to remote storage at rediss://lmcache-valkey-eks-jkwm0s.serverless.use2.cache.amazonaws.com:6379
```

**First test run (same pod, L1 warm cache-writer):**
```bash
kubectl exec lmcache-valkey -- python /app/query-twice.py
```
Confirmed live: Cold TTFT **0.398s** (KV tensors written to L1 CPU-RAM *and* L2 Valkey **in parallel**), Warm TTFT **0.179s** → **2.2x** improvement. Slightly less dramatic than the pure-L1 test's 3.2x (0.119s) — plausibly the parallel L1+L2 write path adds a touch of overhead even on the fast warm-hit path.

**The actual point of this module — prove the cache survives pod death:**
```bash
kubectl logs lmcache-valkey | grep "Stored" | tail -3
# Stored 4096 tokens, 0.5312 GB; Stored 512 tokens, 0.0664 GB — written to Valkey

kubectl run vcheck --rm -i --restart=Never --image=redis:7-alpine -- \
  redis-cli --tls -h $VALKEY_ENDPOINT -p 6379 dbsize
# 36

kubectl delete pod lmcache-valkey

kubectl run vcheck --rm -i --restart=Never --image=redis:7-alpine -- \
  redis-cli --tls -h $VALKEY_ENDPOINT -p 6379 dbsize
# 36 — unchanged. L2 cache persisted across pod deletion.
```
Confirmed live exactly as scripted: `dbsize` stayed at **36 keys** before and after `kubectl delete pod lmcache-valkey` — hard proof the KV cache lives in the external service, not pod memory.

**Redeploy a brand-new pod and confirm it reuses the surviving cache:**
```bash
kubectl apply -f manifests/400-advanced-ai/900-cache/lmcache-valkey-pod.yaml
kubectl wait --for=condition=ready pod/lmcache-valkey --timeout=600s
kubectl exec lmcache-valkey -- python /app/query-twice.py
```
Confirmed live: this new pod's own L1 is empty (never processed anything), but it's connected to the same populated L2. Cold TTFT **2.318s** (notably higher than the first pod's 0.398s cold run — likely fresh-pod overhead: first CUDA kernel execution, first TLS handshake to Valkey, general cold-start cost beyond pure KV compute, not a like-for-like comparison), Warm TTFT **0.359s** → **6.5x** improvement.

Direct log evidence of the cross-pod cache hit:
```
LMCache INFO: Reqid: ..., Total tokens 4258, LMCache hit tokens: 4096, need to load: 4096
LMCache INFO: Retrieved 4096 out of 4096 required tokens (from 4096 total tokens). size: 0.5312 gb
```
A full 4096-token prefix served from cache on a pod that never computed it locally — the definitive proof this is genuine **cross-pod cache sharing**, not just an L1 coincidence.

**Teardown (run live) — includes the billed AWS resource, not just k8s objects:**
```bash
kubectl delete pod lmcache-valkey
kubectl delete configmap valkey-cm

curl -o manifests/500-lmcache/cleanup-valkey.sh \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.4.7/manifests/500-lmcache/remote-cache-sharing-with-valkey/cleanup-valkey.sh
chmod +x manifests/500-lmcache/cleanup-valkey.sh
./manifests/500-lmcache/cleanup-valkey.sh
```
Confirmed live: pod + configmap deleted, then the cleanup script deletes the Valkey cluster (`status=deleting` × 13 polls) and the security group, ending with `"Return": true` and `Cleanup complete.`

**Reproduction/cost gotcha:** unlike the L1-only CPU-RAM test (pure in-cluster resources, no extra AWS billing), this module provisions a real **ElastiCache Serverless** cache — `kubectl delete` alone does NOT tear it down; the dedicated `cleanup-valkey.sh` must be run afterward or the cache (and its data transfer/request charges) keeps running/billing.

**Interview-relevant takeaway:** this is the difference between *node-local* KV-cache reuse (L1, module: CPU Offloading) and *fleet-wide* KV-cache reuse (L2/Valkey) — the latter is what actually matters at production scale, where requests for the same shared context (e.g. a common RAG system prompt, or a user's session continuing on a different replica after a scale event) land on different pods/nodes. L1 alone would miss every time a request landed on a "cold" pod for that prefix; L2 makes the cache a cluster-wide resource instead of a per-replica one.

## 5. Customize Model

**Note on this run: the workshop's ~6-hour event window very likely expired partway through this module** — several symptoms below (a stuck pod, an odd IAM permission error, empty API responses) line up with the temporary AWS account/credentials being torn down mid-session rather than any real config mistake. Captured as-is, including the failure, since it's a legitimately useful "what environment expiry looks like" case study, but the LoRA-serving portion did not complete successfully in this session.

### LoRA fine-tuning job (worked)

Cleanup from the earlier "Serve a Model" deployment first (already gone since the benchmarking teardown, so this is a no-op safety net):
```bash
kubectl delete deployment mistral 2>/dev/null || true
kubectl delete svc vllm-serve-svc 2>/dev/null || true
```

**Dataset + training script**, pulled from **yet another tag: `v2.5.1`** (sixth distinct repo tag seen this workshop, reinforcing the pin-exact-tags reproduction note):
```bash
mkdir -p manifests/800-fine-tuning
curl -o manifests/800-fine-tuning/anyvc-startup-dataset.jsonl \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.5.1/manifests/600-finetuning/anyvc-startup-dataset.jsonl
curl -o manifests/800-fine-tuning/train_lora.py \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.5.1/manifests/600-finetuning/train_lora.py
```
Confirmed live: dataset is **200 examples**, each a `{user pitch} → {assistant VC verdict}` pair for a "AnyVC Startup Advisor" persona — e.g. a startup pitch gets a structured **Verdict / Market Potential / Strengths / Risks / Differentiation / Suggestions** response. This is a domain-specific-persona LoRA, not a knowledge-injection fine-tune.

**Manual patch applied to the downloaded script** (a documented workaround, not something discovered live):
```bash
sed -i 's/dataset = dataset.map(format_chat)/dataset = dataset.map(format_chat)\ndataset = dataset.remove_columns(["messages"])/' manifests/800-fine-tuning/train_lora.py
```
Removes the raw `messages` column after chat-template formatting so `SFTTrainer` doesn't try to re-tokenize it — i.e. the workshop's own upstream script has a known bug that the walkthrough patches around via `sed` rather than fixing at the source. **Intra-step tag mismatch, separate from the cross-module ones**: the job manifest below is pulled from `v2.5.2`, one tag ahead of the dataset/script's `v2.5.1`, in the same setup sequence.
```bash
curl -o manifests/800-fine-tuning/lora-training-job.yaml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.5.2/manifests/600-finetuning/lora-training-job.yaml
kubectl create configmap anyvc-training-scripts \
  --from-file=train_lora.py=manifests/800-fine-tuning/train_lora.py \
  --from-file=anyvc-startup-dataset.jsonl=manifests/800-fine-tuning/anyvc-startup-dataset.jsonl
envsubst < manifests/800-fine-tuning/lora-training-job.yaml | kubectl apply -f -
```
Confirmed live: `configmap/anyvc-training-scripts created`, `job.batch/anyvc-lora-finetune created`, pod reached Ready.

**Training run, confirmed live via `kubectl logs -f job/anyvc-lora-finetune`:**
- Job installs its Python deps **fresh at container start** (not baked into the image): `transformers==5.11.0`, `datasets==5.0.0`, `peft==0.19.1`, `trl==1.5.1`, `accelerate==1.13.0`, `mistral-common==1.11.3` — adds real startup latency but pins exact reproducible versions per training run.
- **Non-fatal version-range warning**: `Supported flash-attn versions are >= 2.1.1, <= 2.7.4.post1. Found flash-attn 2.8.3` — the base image ships a newer flash-attn than this training stack officially supports. Didn't block training here, but a real "watch for base-image vs. training-lib drift" gotcha for reproduction.
- Config: **LoRA rank/alpha 16/32**, 5 epochs planned, effective batch size 4, 200 examples.
- Model loaded **FP8 → BF16**: note the base model is served in FP8 by vLLM (per "Serve a Model"), but training upcasts to BF16 — sidesteps quantization-aware-training complexity by just training in higher precision. **8.9B params, 17.8GB GPU memory** — comfortably fits the 46GB L40S alongside training overhead.
- LoRA adapters: **17.6M trainable params = 0.20% of the 8.9B total** — the concrete number for "LoRA touches under 1% of weights."
- Repeated `MistralCommonBackend.apply_chat_template(..., tokenize=False) is unsafe` warnings during dataset formatting — this is exactly the code path the `sed` patch above works around (drop the `messages` column after this formatting step so the trainer doesn't touch it again).
- **Loss/accuracy curve** (interrupted at epoch 3.4/5 by `Ctrl-C` on the log stream — the job itself likely kept running server-side; `kubectl logs -f` stopping is just the client detaching): loss **2.52 → ~0.07**, `mean_token_accuracy` **0.48 → ~0.98** by epoch ~2. **Interview-relevant caveat**: >97% token accuracy this early on only 200 examples over multiple epochs is the signature of near-memorization on a small dataset — expected and fine for a workshop demo of LoRA mechanics, but explicitly not evidence of a generalizable production fine-tune; a real deployment would need a much larger/held-out-eval'd dataset to trust that accuracy number.

### LoRA serving (did not complete — environment expiry symptoms)

**First odd sign** — checking the trained adapter in S3 failed on a permission that shouldn't even be relevant to listing one already-known bucket's contents:
```bash
aws s3 ls s3://${S3_BUCKET_NAME}/anyvc-startup-lora/
# aws: [ERROR]: An error occurred (AccessDenied) when calling the ListBuckets operation:
# ...i-0b10686310e0793d6 is not authorized to perform: s3:ListAllMyBuckets
```
`ListAllMyBuckets` (list every bucket in the account) has nothing to do with listing objects inside one specific bucket you already have the name of — a CLI implementation quirk on its own, but combined with what follows it reads as the first symptom of the workshop's temporary IAM role/session starting to degrade.

**Deploy vLLM + LoRA adapter serving**, from `v2.5.1` again:
```bash
curl -o manifests/800-fine-tuning/vllm-with-lora.yaml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.5.1/manifests/600-finetuning/vllm-with-lora.yaml
envsubst < manifests/800-fine-tuning/vllm-with-lora.yaml | kubectl apply -f -
```
Confirmed live: `persistentvolume/s3-bucket-pv created`, `persistentvolumeclaim/s3-bucket-pvc created`, `service/vllm-serve-svc created`, `deployment.apps/anyvc created`. **This is the first time the S3 CSI driver spotted way back in "Setting Up the Cluster" (`s3-csi-controller`/`s3-csi-node`, unexplained at the time) gets used** — a PV/PVC backed directly by the S3 bucket, presumably mounting the LoRA adapter output into the serving pod alongside the base model. The two different `model` names tried in testing below (`ministral-base` vs `anyvc-startup-expert`) match vLLM's standard **multi-LoRA serving** pattern: one running server exposing both the base model and a named LoRA adapter as separate "models" over the same OpenAI-compatible API.

**Pod never became Ready:**
```bash
kubectl get pods -l model=anyvc -w
# anyvc-98bf6bc77-88zjx   0/1   ContainerCreating   0   14s
# ... (re-checked later) ...
# anyvc-98bf6bc77-88zjx   0/1   ContainerCreating   0   37m
```
Stuck in `ContainerCreating` for **37+ minutes** — consistent with the S3-backed PV mount silently failing to authenticate once the workshop's temporary IAM session started expiring (the same underlying credentials the earlier `s3 ls` call had just failed on).

**Every subsequent request failed as a direct consequence, not as separate bugs:**
```bash
kubectl port-forward svc/vllm-serve-svc 8000:8000
# error: unable to forward port because pod is not running. Current status=Pending
```
Port-forward correctly refused since the pod was never Running. All following `curl` calls to `localhost:8000` therefore hit nothing and got an **empty response body**, which the Python JSON parser reported as `Expecting value: line 1 column 1 (char 0)` — tried three different `model` values (`ministral-base`, `anyvc-startup-expert`, a placeholder) as a reasonable troubleshooting step, but the root cause was upstream (no server listening at all), not a model-name mismatch. **Reproduction note:** if rebuilding this module from scratch, watch cluster/IAM session validity for long-running workshops — the S3-CSI-backed PV mount is the piece that depends on live AWS credentials, unlike the Run:ai-streamer-from-S3 approach used everywhere else in this workshop (module 3 onward), which only needs credentials at model-load time, not for the life of the pod's mount.

---

## 5b. RAG on Amazon EKS

**Log excerpt starts mid-stream** (user noted missing scrollback) — picks up during a `apt-get install build-essential`-style toolchain install (gcc/g++/python3-dev, needed to compile native Python deps) inside what's clearly a **separate CPU-only pipeline pod**, distinct from the GPU vLLM pods used everywhere else in this workshop.

### Embedding ingestion pipeline

Confirmed live — pip installs in this pod: `boto3==1.43.43`, **`torch==2.13.0+cpu`** (explicitly the CPU build, from `download.pytorch.org/whl/cpu` — this pod does embedding generation, not GPU inference), `sentence-transformers==5.6.0` (pulling in `transformers==5.15.0`, `scikit-learn`, `scipy`).

Environment/config confirmed live:
```
Using S3 bucket: rag-workshop-data-222233334444-us-east-2
Using S3 Vector Bucket: rag-vectors-222233334444-us-east-2
Using S3 Vector Index: knowledge-base
```
**This workshop uses Amazon S3 Vectors** (AWS's native, fully-managed vector store built directly into S3) as the RAG vector database — not a self-hosted vector DB (no Milvus/Weaviate/pgvector deployment anywhere in this workshop). Confirmed as a first-class AWS service, not a custom wrapper, by the dedicated CLI subcommand used later: `aws s3vectors query-vectors`.

Embedding model: SentenceTransformer, loaded from HF Hub unauthenticated (same rate-limit warning pattern seen in LoRA training) — **384-dimensional embeddings** (inferred from the test-vector dimension used later, consistent with `all-MiniLM-L6-v2`).

**Pipeline run, confirmed live:**
```
Found document: samples/electronics.jsonl
Found 1 documents in S3
Downloaded file size: 22458 bytes
Processed 25 records from file: /tmp/electronics.jsonl
Final batch: Uploaded 25 vectors to S3 Vectors
Total embeddings generated and stored: 25
Verification query returned 1 results
S3 Vectors storage verification successful!
```
Dataset: a small retail electronics product catalog (25 products — HomeAudio 7.1, PhotoMaster DSLR, GameBox X, etc.), each with `category`, `price_range`, `rating`, and a `combined_text` field (product + category + description concatenated) — this `combined_text` is almost certainly what actually gets embedded, since it gives the embedding model structured context beyond the raw description.

### Verify vectors directly via CLI

```bash
python3 -c "
import json
test_vector = [0.1] * 384
print(json.dumps({'float32': test_vector}))
" > manifests/500-rag/test_query_384.json

aws s3vectors query-vectors \
    --vector-bucket-name $S3_VECTOR_BUCKET_NAME \
    --index-name $S3_VECTOR_INDEX_NAME \
    --query-vector file://manifests/500-rag/test_query_384.json \
    --top-k 3 --return-metadata --return-distance
```
Confirmed live: returned 3 nearest neighbors by **cosine distance** (~0.978–0.981 — high distance/low similarity, expected since the query was an arbitrary constant vector `[0.1]*384`, not a real semantic embedding, so this is purely a plumbing check, not a relevance test), each result carrying full metadata (`text`, `combined_text`, `category`, `price_range`, `rating`, `product`, `source`) alongside the vector — confirms S3 Vectors stores rich payload metadata co-located with embeddings, not just raw float arrays.

**Side note, still visible in this excerpt:** the broken `anyvc` LoRA-serving pod from "Customize Model" was checked again here and was **still `ContainerCreating` at 49 minutes** — confirms that issue never self-resolved; it was a real, persistent failure (consistent with the environment-expiry theory), not a transient blip.

### Deploy the RAG service

```bash
mkdir -p manifests/500-rag
curl -o manifests/500-rag/rag-serve.yml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.5.0/manifests/300-rag/rag-serve.yml
kubectl apply -f manifests/500-rag/rag-serve.yml
```
**Seventh distinct repo tag** seen this workshop (`v2.5.0`) — this `rag-serve.yml` is just a ConfigMap holding the actual Python RAG-service source, applied on its own before the Deployment.

```bash
curl -o manifests/500-rag/rag-service.yml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.5.2/manifests/300-rag/rag-service.yml
export MODEL_ID="ministral-base"
export MODEL_ENDPOINT=http://vllm-serve-svc:8000/v1/chat/completions
envsubst < manifests/500-rag/rag-service.yml > manifests/500-rag/rag-service-processed.yml
kubectl apply -f manifests/500-rag/rag-service-processed.yml
```
**Another intra-module tag mismatch** (`v2.5.0` ConfigMap vs `v2.5.2` Deployment), same pattern as "Customize Model"'s dataset-vs-job-manifest split. **Critical dependency, easy to miss**: `MODEL_ENDPOINT` points at `vllm-serve-svc:8000` — the **exact same Service name** the broken `anyvc` LoRA deployment from "Customize Model" was trying to provide. Since that deployment never came up, the RAG service has **no live model backend** to actually call, even though the RAG orchestration pod itself deploys and reports Running fine (it doesn't need the model at pod-startup, only at query time).

Confirmed live: `configmap/rag-serve-script created`, `deployment.apps/rag-service created`, `service/rag-service created`, `kubectl rollout status` → `successfully rolled out`, pod `rag-service-77c7d7dd8-w76fw` Running.

**Query test — inconclusive, hit the wrong target:**
```bash
kubectl port-forward svc/rag-service 8080:80
# Unable to listen on port 8080: ... bind: address already in use
curl -X POST http://localhost:8080/query -H "Content-Type: application/json" \
  -d '{"query": "...", "use_rag": false}' | jq
# {"detail": "Not Found"}
```
The port-forward **failed to bind** (port 8080 already held by some other stale local process from earlier in this long session), so the subsequent curl on `localhost:8080` did **not** actually reach `rag-service` — it hit whatever else was already listening there, which had no `/query` route (the `{"detail": "Not Found"}` body is FastAPI's default 404 shape). **This test result is not meaningful either way** — it doesn't prove the RAG service is broken, just that this particular curl never reached it. **Reproduction gotcha:** long sessions accumulate stray background `port-forward` processes; check `jobs`/`lsof -i :8080` before reusing a port, or just pick a fresh local port each time.

### Gradio comparison UI

```bash
curl -o manifests/500-rag/rag-gradio-app.yml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.5.0/manifests/300-rag/rag-gradio-app.yml
kubectl apply -f manifests/500-rag/rag-gradio-app.yml
curl -o manifests/500-rag/rag-gradio-deploy.yml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.5.0/manifests/300-rag/rag-gradio-deploy.yml
kubectl apply -f manifests/500-rag/rag-gradio-deploy.yml
```
A genuinely nice demo tool: side-by-side **Standard LLM response vs. RAG-Enhanced response**, plus a **"Retrieved Context"** panel showing exactly what got pulled from S3 Vectors for that query — good for explaining RAG's value concretely rather than just asserting it. Backed by `gradio==5.49.1`, installed live at container start (same runtime-pip-install pattern as the LoRA training job and Open WebUI), running on a CPU node (`m5.xlarge`, same as Open WebUI) — reaches the model only indirectly through `rag-service` → `vllm-serve-svc`, so it inherits the same missing-backend problem noted above.

ALB Ingress again: `inbound-cidrs: 0.0.0.0/0` in the manifest, still actually governed by the cluster-wide `IngressClassParams.inboundCIDRs` restriction from "Setting Up the Cluster" (same governance point noted for Open WebUI and Grafana).

Confirmed live: `deployment.apps/rag-gradio-interface created`, `service/rag-gradio-interface created`, `ingress.networking.k8s.io/rag-gradio-alb created`, pod Running, ALB available at `http://rag-gradio-alb-949923673.us-east-2.elb.amazonaws.com/?__theme=dark`.

**Open question carried into whatever comes next:** whether an actual query through this Gradio UI succeeds depends entirely on whether `vllm-serve-svc` has a live backend at that point — which, per "Customize Model," was stuck broken as of the last check. Worth confirming/capturing when you actually run a query through the UI.

### Cleanup (RAG module, run live)

```bash
kubectl delete -f manifests/500-rag/rag-serve.yml
kubectl delete -f manifests/500-rag/rag-service-processed.yml
kubectl delete job rag-document-processor
kubectl delete deployment rag-gradio-interface
kubectl delete service rag-gradio-interface
kubectl delete ingress rag-gradio-alb
kubectl delete configmap rag-gradio-app
```
Confirmed live: `rag-serve-script` ConfigMap, `rag-service` deployment+service, the `rag-document-processor` Job (this is the first confirmation of that Job's actual name — it's what ran the embedding-ingestion pipeline from earlier in this module, in the part of the log that scrolled off), and all four Gradio resources — all deleted cleanly.

**IAM teardown — reveals how the ingestion job got S3 access:**
```bash
aws iam detach-role-policy --role-name rag-document-processor-role \
  --policy-arn $(aws iam list-policies --query 'Policies[?PolicyName==`RagS3ReadPolicy`].Arn' --output text)
aws iam delete-role --role-name rag-document-processor-role
aws iam delete-policy --policy-arn $(aws iam list-policies --query 'Policies[?PolicyName==`RagS3ReadPolicy`].Arn' --output text)

aws eks delete-pod-identity-association --cluster-name genai-workshop \
  --association-id $(aws eks list-pod-identity-associations --cluster-name genai-workshop \
  --query 'associations[?serviceAccount==`s3-access-sa` && namespace==`default`].associationId' --output text)
kubectl delete serviceaccount s3-access-sa -n default
```
**This is the first appearance of EKS Pod Identity in the workshop** — a newer, simpler alternative to IRSA/OIDC-federation for granting a pod's ServiceAccount real AWS IAM permissions. Confirmed live via the printed association before deletion: k8s ServiceAccount `s3-access-sa` (namespace `default`) ↔ IAM role `rag-document-processor-role`, association id `a-iap47dmiq7wqnw0gf`, `createdAt 20:43:47` / `modifiedAt 20:55:22` (a ~12-minute gap, suggesting the association was touched/re-applied once during the module). Follows least-privilege practice: a dedicated `RagS3ReadPolicy` + dedicated role for this one workload, not a reuse of the IDE's own broad role — good practice to point to if asked how you'd scope AWS access for a specific in-cluster job.

**Data cleanup:**
```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export S3_BUCKET_NAME="rag-workshop-data-${ACCOUNT_ID}-${AWS_REGION}"
aws s3 rb s3://${S3_BUCKET_NAME} --force
```
Confirmed live: `delete: s3://rag-workshop-data-222233334444-us-east-2/samples/electronics.jsonl` then `remove_bucket: ...` — `--force` empties the bucket before removing it (same pattern reasoning as ECR's `--force` flag back in "Agentic App": a non-empty bucket/repo would otherwise refuse deletion).

**Also finally cleans up the still-broken deployment from "Customize Model":**
```bash
kubectl delete deployment anyvc 2>/dev/null || true
kubectl delete svc vllm-serve-svc 2>/dev/null || true
```
Confirmed live: both deleted. This is the `anyvc`/`vllm-serve-svc` pair that was stuck `ContainerCreating` for 49+ minutes back in "Customize Model" and never recovered — cleaned up here rather than left dangling, and also frees the `vllm-serve-svc` name for reuse by whatever module comes next.

---

## 6. Inference Frameworks

**This module resolves an open question flagged back in "Optimize Inference"**: pre-provisioned Ray Grafana dashboards (`rayServeDashboard`, `rayServeDeploymentDashboard`, `rayDefaultDashboard`) showed up in the Grafana CR even though every model deployment so far used a plain Kubernetes `Deployment`, not KubeRay. This module is exactly the Ray/KubeRay path those dashboards were always meant for — comparing **plain vLLM Deployment** (modules 3–5) against **Ray Serve on KubeRay** as an alternative inference-serving framework.

**Cleanup preamble** (same idempotent safety-net pattern as every module so far):
```bash
kubectl delete deployment mistral 2>/dev/null || true
kubectl delete deployment anyvc 2>/dev/null || true
kubectl delete service vllm-serve-svc 2>/dev/null || true
kubectl delete ingress open-webui-ingress 2>/dev/null || true
kubectl delete deployment open-webui 2>/dev/null || true
kubectl delete service open-webui 2>/dev/null || true
```

### The Ray Serve wrapper around vLLM

```bash
mkdir -p manifests/400-ray
curl -o manifests/400-ray/vllm-s3-configmap.yml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.3.1/manifests/200-ray/vllm-s3-configmap.yaml
kubectl apply -f manifests/400-ray/vllm-s3-configmap.yml
```
**Tag `v2.3.1`** — notably *older* than the tags used for the plain-vLLM path (`v2.4.7`–`v2.5.2`), confirming the Ray/KubeRay path is a separately-maintained branch of this sample repo, not just another manifest in the same version line. Confirmed live: `configmap/vllm-serve-script created`.

This ConfigMap is a **hand-written FastAPI + Ray Serve wrapper around vLLM's raw engine internals** (`AsyncEngineArgs`, `AsyncLLMEngine`, `OpenAIServingChat`/`OpenAIServingCompletion`/`OpenAIServingModels`), reimplementing the exact same `/v1/models`, `/v1/completions`, `/v1/chat/completions` routes that vLLM's own built-in `vllm serve` CLI already provides for free. **The point isn't the API surface (it's identical) — it's that Ray Serve's `@serve.deployment(ray_actor_options={"num_gpus": 1})` decorator ties GPU allocation to a Ray *actor*/replica**, giving Ray Serve's own autoscaling, multi-model routing, and rolling-update machinery a hook into vLLM, instead of relying on plain Kubernetes Deployment rollout semantics. `enable_auto_tools`/`tool_parser` are wired from env vars (`ENABLE_AUTO_TOOL_CHOICE`, `TOOL_CALL_PARSER`) — same tool-calling capability as the plain-vLLM path, just configured differently.

### Install KubeRay operator

```bash
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm install kuberay-operator kuberay/kuberay-operator --version 1.1.0
kubectl wait pods --for=jsonpath='{.status.phase}'=Running -l app.kubernetes.io/name=kuberay-operator --timeout=300s
```
Confirmed live: operator deployed and Running. This is the controller that reconciles `RayCluster`/`RayService` custom resources — analogous to how the AWS Load Balancer Controller reconciles `Ingress` objects.

### A third way to get model weights into a pod: S3-backed PV via CSI

```bash
kubectl get pv mistral-model-pv -o wide
kubectl get pvc mistral-model-pvc -o wide
kubectl describe pv mistral-model-pv
```
Confirmed live — this PV/PVC pair is **39h old**, meaning it was silently pre-provisioned near the very start of the workshop and sat unused until this module:
```
mistral-model-pv   20Gi   ROX   Retain   Bound   default/mistral-model-pvc   ...   39h
```
`kubectl describe` shows the actual mechanism: CSI driver `s3.csi.aws.com`, `VolumeAttributes: bucketName=genai-models-222233334444, prefix=Ministral-3-8B-Instruct-2512/, region=us-east-2` — **the same S3 CSI driver spotted unexplained in "Setting Up the Cluster" and used (and stuck) in "Customize Model"'s LoRA serving**. Access mode **ROX (ReadOnlyMany)** — multiple Ray worker pods can mount the same S3 prefix read-only concurrently, as a real filesystem mount rather than an app-level stream.

**This workshop now demonstrates three distinct patterns for getting model weights into a serving pod**, worth being able to contrast in an interview:
1. **App-level streaming from S3** (Run:ai Model Streamer) — used by every plain-vLLM deployment since "Serve a Model." No PV at all; vLLM's own `--load-format=runai_streamer` pulls weights directly.
2. **S3-backed PV/PVC via the Mountpoint-for-S3 CSI driver** — this module and the (broken) LoRA-serving deployment. Presents S3 as a mounted filesystem; works well for frameworks like Ray/KubeRay that expect a normal file path (`self.model_path`) rather than knowing how to speak S3 natively.
3. *(seen implicitly)* baking weights into a container image — not used anywhere in this workshop, but the standard alternative outside it.

Confirms the S3 CSI driver seen running since module 2 (`s3-csi-controller` + `s3-csi-node` DaemonSet) is now checked directly:
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver
```
3 node pods at different ages (`72m`, `39h`, `3h18m`) — direct evidence of Auto Mode's continuous node churn/consolidation over this long session (nodes have been created and replaced repeatedly, not a static fleet).

### Deploy the RayService

```bash
curl -o manifests/400-ray/ray-vllm-s3-service.yml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.3.2/manifests/200-ray/vllm-s3-service.yaml
kubectl apply -f manifests/400-ray/ray-vllm-s3-service.yml
kubectl wait --for=jsonpath='{.status.serviceStatus}'=Running rayservice/vllm --timeout=600s
```
**Yet another tag (`v2.3.2`)** — third distinct tag just within this one module (`v2.3.1` ConfigMap, `v2.3.2` RayService). Described as using an **AWS Deep Learning Container (DLC) image** for the Ray worker — AWS's own pre-built, pre-validated CUDA/PyTorch/Ray image, rather than a custom Dockerfile like every other GPU workload in this workshop. Confirmed live: `rayservice.ray.io/vllm created`, then `condition met` on `serviceStatus=Running` within the 600s timeout.

**`RayService` is a KubeRay-specific CRD** that bundles a `RayCluster` + a Ray Serve application deployment + built-in zero-downtime rolling updates — a capability plain Kubernetes Deployments don't give you for free (you'd need to hand-roll blue/green via labels/services yourself, as effectively happened by convention across this workshop's repeated "delete old deployment, apply new one" pattern).

**Service topology this creates, confirmed live via `kubectl get svc`:**
```
vllm             ClusterIP   8080/TCP,6379/TCP,8265/TCP,10001/TCP,8000/TCP,52365/TCP
vllm-head-svc     ClusterIP   6379/TCP,8265/TCP,10001/TCP,8000/TCP,52365/TCP,8080/TCP
vllm-serve-svc    ClusterIP   8000/TCP
```
Port map: `6379` Ray GCS (cluster metadata), `8265` Ray dashboard, `10001` Ray client, `52365` dashboard agent, `8080` Ray Serve HTTP, and the familiar `8000` on the dedicated `vllm-serve-svc` — **same service name as every prior module's plain vLLM deployment**, meaning downstream consumers (Open WebUI, RAG service, anything speaking OpenAI-API) never need to know or care which serving framework is actually behind it.

### Proof the API contract is framework-agnostic: redeploy Open WebUI unchanged

```bash
curl -o manifests/400-ray/openwebui.yml \
  https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/v2.3.1/manifests/200-ray/openwebui.yml
kubectl apply -f manifests/400-ray/openwebui.yml
kubectl wait --for=condition=ready pod -l app=open-webui --timeout=300s
```
This is the **exact same manifest** used against plain vLLM back in "Serve a Model" (`OPENAI_API_BASE_URLS: http://vllm-serve-svc:8000/v1`, unchanged) — deployed here against the Ray-Serve-backed model instead, with zero modification. Confirmed live: pod Ready, ALB provisioned at a fresh URL: `http://open-webui-ingress-998908307.us-east-2.elb.amazonaws.com`. **This is the actual demonstration this module is making**: an OpenAI-API-compatible client cannot tell (and doesn't need to know) whether it's talking to plain vLLM or Ray-Serve-wrapped vLLM — the serving-framework choice is fully decoupled from the client integration.

### Ray-specific observability

```bash
cat << EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  labels:
    release: kube-prometheus-stack
  name: ray-head-monitor
  namespace: monitoring
spec:
  selector:
    matchLabels:
      ray.io/node-type: head
  podMetricsEndpoints:
    - port: metrics
    - port: as-metrics   # autoscaler metrics
    - port: dash-metrics  # dashboard metrics
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: ray-workers-monitor
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      ray.io/node-type: worker
  podMetricsEndpoints:
    - port: metrics
EOF
```
Same `release: kube-prometheus-stack` label rule confirmed a third time (after DCGM's and vLLM's ServiceMonitors) — now on `PodMonitor` objects instead of `ServiceMonitor`, so this is a Prometheus-Operator-wide rule, not specific to one CRD kind. Selects pods by KubeRay's own labels (`ray.io/node-type: head`/`worker`) rather than app-specific labels. The **head node exposes 3 separate metrics ports** (`metrics`, `as-metrics` for the autoscaler, `dash-metrics` for the dashboard) vs. plain vLLM's single `/metrics` endpoint — a materially richer built-in observability surface than the plain-Deployment path needed a hand-written ServiceMonitor for back in "Optimize Inference." Confirmed live: both `podmonitor.monitoring.coreos.com/ray-head-monitor` and `ray-workers-monitor` created (some terminal-rendering garbling visible in the pasted heredoc output, but both objects confirmed created).

**Closes the loop from "Optimize Inference":**
```bash
kubectl get grafanadashboards -n monitoring | grep ray
```
Confirmed live — all **39h old** (pre-provisioned from workshop start, exactly as suspected back when first noted): `ray-grafana-default-dashboard`, `ray-grafana-serve-dashboard`, `ray-grafana-serve-deployment-dashboard`, `vllm-ray-grafana-dashboard` — these now finally have live data sources wired up via the PodMonitors just created, resolving the "why are there Ray dashboards for a non-Ray deployment" mystery flagged three modules ago.

---

## 7. Cleanup

**Not run yet** — captured from workshop text only, for later reference when tearing down a self-paced reproduction. Labeled here as covering the "Agentic AI on EKS" module specifically (the Strands agent from "Optimize Inference"), so this is likely a per-module cleanup, not full workshop teardown — expect similar cleanup steps for the other modules (vLLM deployment, DCGM exporter, Open WebUI, Grafana ingress, monitoring ServiceMonitors, the EKS cluster/VPC itself) that weren't shown in this excerpt.

**Kubernetes resources (Strands agent):**
```bash
kubectl delete service strands-weather-agent -n default
kubectl delete deployment strands-weather-agent -n default
```

**ECR repository:**
```bash
aws ecr delete-repository --repository-name strands-weather-agent --force
```
`--force` deletes all images in the repo along with the repo itself — otherwise ECR refuses to delete a non-empty repository.

**Local files:**
```bash
rm -rf manifests/600-strands-agent
```

**Reproduction note:** for a full self-paced teardown (not just this module), also expect: `kubectl delete -f` on the vLLM deployment/service, Open WebUI deployment/service/ingress, Grafana ingress, DCGM Exporter (`helm uninstall dcgm-exporter -n monitoring`), the `mistral-monitor` ServiceMonitor, and finally the ODCR (`aws ec2 cancel-capacity-reservation`) + `terraform destroy` in `sample-genai-on-eks/terraform` to remove the EKS cluster/VPC/S3 bucket — none of that was shown in this excerpt, so confirm against the actual module content if/when reproducing outside the live event.

### The real, full end-of-workshop teardown (actually run)

Unlike the excerpt above, this is the **complete, actually-executed cleanup script** covering every module of the workshop, organized by the exact same module boundaries used throughout this file — good external confirmation the module grouping in this document matches the workshop's own structure.

**Kubernetes resources, by module, all wrapped in `2>/dev/null || true` (safe to run regardless of what's already gone):**
```bash
# 100-serve-model
kubectl delete deployment mistral 2>/dev/null || true
kubectl delete deployment strands-weather-agent 2>/dev/null || true
kubectl delete service strands-weather-agent 2>/dev/null || true

# 200-optimize-inference (KV cache labs)
kubectl delete pod lmcache-cpu-ram 2>/dev/null || true
kubectl delete configmap cpu-ram-cm 2>/dev/null || true
kubectl delete pod lmcache-valkey 2>/dev/null || true
kubectl delete configmap valkey-cm 2>/dev/null || true

# 300-inference-frameworks (Ray Serve + OpenWebUI)
kubectl delete -f manifests/400-ray/ray-vllm-s3-service.yml 2>/dev/null || true
kubectl delete -f manifests/400-ray/openwebui.yml 2>/dev/null || true
kubectl delete deployment open-webui 2>/dev/null || true
kubectl delete service open-webui 2>/dev/null || true
kubectl delete ingress open-webui-ingress 2>/dev/null || true
kubectl delete configmap vllm-serve-script 2>/dev/null || true
kubectl delete podmonitor ray-head-monitor -n monitoring 2>/dev/null || true
kubectl delete podmonitor ray-workers-monitor -n monitoring 2>/dev/null || true

# 400-customize-model/100-fine-tuning
kubectl delete deployment anyvc 2>/dev/null || true
kubectl delete configmap anyvc-training-scripts 2>/dev/null || true
kubectl delete job anyvc-lora-finetune 2>/dev/null || true

# 400-customize-model/200-adding-rag
kubectl delete deployment rag-service 2>/dev/null || true
kubectl delete service rag-service 2>/dev/null || true
kubectl delete configmap rag-processor-script 2>/dev/null || true
kubectl delete deployment rag-gradio-interface 2>/dev/null || true
kubectl delete service rag-gradio-interface 2>/dev/null || true
kubectl delete ingress rag-gradio-alb 2>/dev/null || true
kubectl delete configmap rag-gradio-app 2>/dev/null || true
kubectl delete job rag-document-processor 2>/dev/null || true
kubectl delete serviceaccount s3-access-sa 2>/dev/null || true

# Shared Service, PVC, PV (used by 100-serve-model and fine-tuning)
kubectl delete service vllm-serve-svc 2>/dev/null || true
kubectl delete pvc s3-bucket-pvc 2>/dev/null || true
kubectl delete pv s3-bucket-pv 2>/dev/null || true

# Observability
kubectl delete -f manifests/300-observability/grafana-ingress.yaml 2>/dev/null || true
```
Confirmed live (only resources that still existed printed a deletion line — the rest were already gone from earlier per-module cleanups, which is exactly why every command is guarded): `strands-weather-agent` deployment+service, `rayservice.ray.io "vllm"`, `open-webui` deployment+service+ingress, `vllm-serve-script` configmap, both `ray-*-monitor` PodMonitors, `anyvc-training-scripts` configmap, **`rag-processor-script` configmap** (a script configmap for the `rag-document-processor` Job that never appeared explicitly in the earlier RAG capture — it was in the scrolled-off portion of that log), **`s3-bucket-pvc`/`s3-bucket-pv`** (the S3-backed PV/PVC from the broken "Customize Model" LoRA-serving deployment — confirms that leftover survived, unremoved, all the way from "Customize Model" through "RAG" and "Inference Frameworks" until this final sweep), and `grafana-ingress`.

**Uninstall KubeRay operator:**
```bash
helm uninstall kuberay-operator 2>/dev/null || true
kubectl wait --for=delete pods -l app.kubernetes.io/name=kuberay-operator --timeout=300s 2>/dev/null || true
```
Confirmed live: released, pod confirmed deleted.

**S3 Vectors teardown** — note the two-step order, index before bucket (S3 Vectors has its own dedicated API surface, not a plain S3 bucket you can just `rb`):
```bash
aws s3vectors delete-index --vector-bucket-name $S3_VECTOR_BUCKET_NAME --index-name $S3_VECTOR_INDEX_NAME 2>/dev/null || true
aws s3vectors delete-vector-bucket --vector-bucket-name $S3_VECTOR_BUCKET_NAME --region $AWS_REGION 2>/dev/null || true
```

**EKS Pod Identity + IAM cleanup** — same resources as the RAG module's own cleanup, repeated here defensively (guarded, so it's a no-op if already done): pod identity association for `s3-access-sa`, `RagS3ReadPolicy` detach+delete, `rag-document-processor-role` delete, then `aws s3 rb s3://${S3_BUCKET_NAME} --force` for the RAG data bucket again.

**Valkey cleanup**, conditionally run only if the setup script's artifact exists:
```bash
if [ -f manifests/500-lmcache/cleanup-valkey.sh ]; then
  chmod +x manifests/500-lmcache/cleanup-valkey.sh
  ./manifests/500-lmcache/cleanup-valkey.sh 2>/dev/null || true
else
  echo "Valkey cleanup script not found — either the Valkey lab wasn't run or it was already cleaned up."
fi
```
Confirmed live: `(cache already deleted or not found)`, `Security group genai-workshop-valkey not found, skipping.` — expected, since the Valkey cluster and its security group were already torn down live at the end of "External KV Cache." Clean no-op, proving the earlier cleanup was actually complete.

**ODCR cancellation — failed, and the failure is genuinely informative:**
```bash
ODCR_ID=$(aws ec2 describe-capacity-reservations --region $AWS_REGION --filters "Name=state,Values=active" --query "CapacityReservations[0].CapacityReservationId" --output text)
aws ec2 cancel-capacity-reservation --region $AWS_REGION --capacity-reservation-id $ODCR_ID
# UnauthorizedOperation: ...assumed-role/workshop-team-stack-IDEIdeRoleD2980FC1-... is not authorized to perform:
# ec2:CancelCapacityReservation on resource: arn:aws:ec2:us-east-2:111122223333:capacity-reservation/cr-EXAMPLE000000095
```
**The ARN reveals the ODCR lives in AWS account `111122223333` — a completely different account from the workshop's own `222233334444`** (visible everywhere else this session: S3 buckets, ECR repo, IAM roles). This is a real architectural insight, not a misconfiguration: **AWS centrally manages the shared GPU capacity pool for this workshop in its own operator account**, separate from each attendee's ephemeral per-session account — makes sense for guaranteeing scarce `g6e.2xlarge` capacity across many concurrent workshop attendees without each disposable account owning (and being able to accidentally release) a slice of that shared reservation. The workshop IDE role is deliberately scoped without `ec2:CancelCapacityReservation` for exactly this reason. **This failure is expected, not a bug** — don't chase it if reproducing this cleanup script.

**Terraform destroy — also expected to fail here:**
```bash
cd sample-genai-on-eks/terraform && terraform destroy --auto-approve
# bash: cd: sample-genai-on-eks/terraform: No such file or directory
# bash: terraform: command not found
```
Both failures are expected in the **at-event** path: that directory only exists if you cloned the repo for a **self-paced** deployment (module 1), which this session never did, and the IDE doesn't ship `terraform` at all since it's not needed for the at-event flow. This script is evidently shared/reused between the self-paced and at-event cleanup instructions, with this step being a harmless no-op in the at-event context — **the actual EKS cluster/VPC teardown for at-event sessions is AWS's own responsibility** when the event's `workshop-team-stack` CloudFormation stack gets torn down after the event window closes, not something attendees do themselves. This closes the loop cleanly with module 1's Self-paced vs. At-an-Event distinction: at-event attendees only ever clean up the things *they* created inside the pre-provisioned account (k8s objects, S3 data, IAM entities they added, the ODCR they were allowed to create) — the base infrastructure (cluster, VPC, base S3 model bucket, ODCR-hosting account) is entirely AWS-managed and outside their cleanup scope.

---

## Identifier masking in `scripts/lib/env.sh` was silently broken (2026-09-02)

Found while porting the `BEGIN{$|=1}` autoflush fix across all three clouds.
`\Q` suppresses regex METAcharacters, not interpolation, so an identifier
inlined into the perl program is still parsed as perl source:

```
$ echo "a.b@gmail.com" | perl -pe 's/\Qa.b@gmail.com\E/MASKED/g'
a.b@gmail.com                      # unchanged -- never matched
$ echo "a.b@gmail.com" | perl -wpe 's/\Qa.b@gmail.com\E/MASKED/g'
Possible unintended interpolation of @gmail in string at -e line 1.
```

`@gmail` expands as an empty array, so the pattern silently becomes
`a.b.com`, which never appears. Any clause masking a value containing `@`
therefore matched nothing. It looked correct only because the scripts print
the pre-masked shell variable (`${MASKED_ACCOUNT}`) themselves -- so the
clause was never exercised on the output it exists to protect: raw
identifiers appearing in terraform/kubectl/cloud-CLI output, which went
through to the terminal and the `outputs/` transcript unmasked.

Second problem in the same line: inlining put the raw values in perl's argv,
readable by any user on the machine. Observed live during an `azure/` run:

```
$ ps -eo pid,etime,command
29749  02:03  perl -pe s/\Q@@NEVERMATCH@@\E//; s/\Q<full-subscription-guid>\E/...;
              s/\Q<full-tenant-guid>\E/...; s/\Q<real-email>\E/...
```

Fixed by moving values through `%ENV` and keeping the perl program
single-quoted, so bash never substitutes into it and perl never parses an
identifier as code. Measured with long-lived processes:

| | raw value in perl argv | `a.b@gmail.com` masked | `svc+ci/admin` masked |
|---|---|---|---|
| inline (old) | **yes** | no | n/a |
| `%ENV` (new) | no | yes | yes |

The `%ENV` form also fixes metacharacter-bearing identifiers (`+ / .` are
literalised correctly by `\Q` on a runtime value) and replaces the
`@@NEVERMATCH@@` sentinel with a plain `length` guard.

Verified against the real `env.sh` by sourcing it and echoing the live
subscription id, tenant id and UPN as a tool would: all three came out
masked, and the transcript held 399 bytes 1.2s into a run containing a
2s stall (0 bytes would mean the buffering bug was still present).

---

## 8. Summary

Workshop's own closing framing: EKS's value for GenAI workloads is scalability/resiliency/repeatable-deployments plus more control/flexibility/cost-effectiveness than fully-managed options — positioned as complementary to, not a replacement for, **Amazon Bedrock** (off-the-shelf FM access) and **Amazon SageMaker** (train/deploy custom models), for when you specifically need self-hosted control over the serving stack.

### Next-steps resources pointed to by the workshop (not yet fetched/verified — links live in the workshop page, capture URLs if you revisit it)
- **Workshop slide deck** — architecture diagrams and reference material.
- **Deploy in Your Account** — a deployment guide + the same Terraform blueprints referenced back in module 1's "Self-paced" path (`github.com/aws-samples/sample-genai-on-eks`, `terraform/` dir) — this is the direct path for the reproduction goal this repo is tracking toward.
- **GenAI on EKS best practices guide** — production security/perf-tuning recommendations, presumably formalizing the ad-hoc gotchas captured throughout this file (ServiceMonitor label rules, IngressClassParams governance, ODCR sizing, tag-pinning, etc.).
- **AI on EKS repository** — broader blueprint collection beyond this workshop's scope.
- **EKS Specialist office hours** — for architecture/production-readiness guidance.
- **Account team** — for AWS credits/capacity-reservation/commercial conversations (relevant if pursuing a real GPU-capacity commitment beyond a single ODCR).

### Workshop-wide takeaways worth keeping front-of-mind for reproduction or interview framing

- **Core stack**: EKS Auto Mode (managed Karpenter + managed core add-ons + Bottlerocket GPU AMI w/ embedded NVIDIA device plugin) → vLLM (PagedAttention, FP8, OpenAI-compatible API) → optional LMCache (L1 CPU-RAM / L2 ElastiCache-Valkey KV-cache tiering) → optional Ray Serve/KubeRay as an alternative serving-framework layer behind the *same* API contract.
- **Three model-loading patterns demonstrated**: app-level S3 streaming (Run:ai Model Streamer, used by default), S3-backed PV via the Mountpoint-S3 CSI driver (Ray path + the broken LoRA-serving attempt), container-baked weights (not used here).
- **Concrete numbers worth remembering**: L40S GPU = 46GB VRAM; 8B-class model cold-loads in ~27s streaming from S3; KV cache gives ~105x concurrency at 2048 tokens/request; saturation knee hit around 17-20 req/s on one GPU (TTFT 71ms→160ms); LMCache CPU-RAM prefix cache = 3.2x TTFT win, remote Valkey L2 = proven cross-pod cache survival; LoRA fine-tune = 17.6M trainable params (0.2% of 8.9B) reaching ~98% token accuracy on 200 examples.
- **Real failure modes captured, not just successes**: environment/IAM expiry mid-"Customize Model" (S3-backed PV silently failing to mount), a stray local port-forward producing a misleading 404, several intra- and cross-module sample-repo tag mismatches (`v2.3.1` through `v2.5.2`) worth pinning exactly if reproducing, and the ODCR living in a separate AWS-operator account entirely.

This closes out live capture of the workshop content itself. Remaining work for the reproduction goal this repo is tracking toward: actually running the self-paced Terraform path end-to-end in a personal AWS account, using this file as the debug trail/checklist.
