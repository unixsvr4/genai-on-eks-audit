#!/usr/bin/env bash
# Module: Customize Model (RESEARCH.md §5)
# Fine-tunes a LoRA adapter on a small "AnyVC Startup Advisor" dataset, then attempts
# to serve base model + adapter together via an S3-backed PersistentVolume.
#
# *** RESOLVED 2026-09-04 -- kept because the dependency is still real ***
# This step DID succeed in this account. The hypothesis below ("in YOUR OWN account
# ... this specific failure mode shouldn't recur") was tested and held: the pod came
# up, the Mountpoint-for-S3 CSI mount stayed healthy, and vLLM served the adapter:
#     pod -l model=anyvc            1/1 Running
#     pv s3-bucket-pv driver        s3.csi.aws.com
#     s3://<bucket>/anyvc-startup-lora/   83.3 MiB, 4 objects
#     POST /v1/chat/completions to model "anyvc-startup-expert" -> 264 tokens
# So this is no longer an open failure. The warning stays because the underlying
# dependency has not changed -- it was the credentials that were different, not the
# design -- and it is still the right thing to check first if the pod hangs.
#
# *** ORIGINAL KNOWN FAILURE MODE ***
# In the live workshop run, the fine-tuning job succeeded cleanly (loss 2.5 -> 0.07),
# but the LoRA-SERVING step failed: the S3-backed PV (Mountpoint-for-S3 CSI driver)
# depends on live IAM credentials for the ENTIRE lifetime of the pod's mount — unlike
# the Run:ai-streamer pattern used everywhere else in this repo, which only needs
# credentials at load time. In the workshop's temporary AWS account this broke when
# the session's IAM role expired mid-module; in YOUR OWN account with your own
# long-lived credentials this specific failure mode shouldn't recur, but the
# dependency itself is real — if this step hangs in ContainerCreating for more than
# a few minutes, check `kubectl describe pod -l model=anyvc` for CSI mount errors
# and verify your AWS credentials/session are still valid before assuming it's a
# cluster bug. See docs/GOTCHAS.md for the full failure signature.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

FT_TAG="v2.5.1"       # dataset + train script pinned here
JOB_TAG="v2.5.2"      # job manifest pinned one tag ahead — see docs/GOTCHAS.md
mkdir -p "${MANIFEST_DIR}/800-fine-tuning"

log "Fetching training dataset + script (tag ${FT_TAG})..."
curl -sf -o "${MANIFEST_DIR}/800-fine-tuning/anyvc-startup-dataset.jsonl" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${FT_TAG}/manifests/600-finetuning/anyvc-startup-dataset.jsonl"
curl -sf -o "${MANIFEST_DIR}/800-fine-tuning/train_lora.py" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${FT_TAG}/manifests/600-finetuning/train_lora.py"

# Documented upstream workaround, not discovered here: SFTTrainer re-tokenizes the
# raw 'messages' column unless it's dropped after chat-template formatting.
sed -i.bak 's/dataset = dataset.map(format_chat)/dataset = dataset.map(format_chat)\ndataset = dataset.remove_columns(["messages"])/' \
  "${MANIFEST_DIR}/800-fine-tuning/train_lora.py"

curl -sf -o "${MANIFEST_DIR}/800-fine-tuning/lora-training-job.yaml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${JOB_TAG}/manifests/600-finetuning/lora-training-job.yaml"

kubectl create configmap anyvc-training-scripts \
  --from-file=train_lora.py="${MANIFEST_DIR}/800-fine-tuning/train_lora.py" \
  --from-file=anyvc-startup-dataset.jsonl="${MANIFEST_DIR}/800-fine-tuning/anyvc-startup-dataset.jsonl" \
  --dry-run=client -o yaml | kubectl apply -f -
envsubst < "${MANIFEST_DIR}/800-fine-tuning/lora-training-job.yaml" | kubectl apply -f -

log "Training (LoRA rank/alpha 16/32, 5 epochs, 200 examples — expect ~10-20 min on one L40S)..."
kubectl wait --for=condition=ready pod -l app=anyvc-lora-finetune --timeout=600s
kubectl logs -f job/anyvc-lora-finetune | tail -50 || true
kubectl wait --for=condition=complete job/anyvc-lora-finetune --timeout=1800s

log "Fine-tuning complete. Now attempting LoRA serving (see this script's header for the known risk)..."
curl -sf -o "${MANIFEST_DIR}/800-fine-tuning/vllm-with-lora.yaml" \
  "https://raw.githubusercontent.com/aws-samples/sample-genai-on-eks/refs/tags/${FT_TAG}/manifests/600-finetuning/vllm-with-lora.yaml"
envsubst < "${MANIFEST_DIR}/800-fine-tuning/vllm-with-lora.yaml" | kubectl apply -f -

log "Waiting up to 5 min for the anyvc pod (if this times out, see the header comment above)..."
if ! kubectl wait --for=jsonpath='{.status.phase}'=Running pod -l model=anyvc --timeout=300s 2>/dev/null; then
  warn "LoRA-serving pod did not reach Running within 5 minutes."
  warn "kubectl describe pod -l model=anyvc   # look for CSI/mount errors"
  warn "aws sts get-caller-identity           # confirm your credentials are still valid"
  warn "Continuing to the next module rather than blocking — this matches the honest outcome"
  warn "documented in RESEARCH.md; the fine-tune itself already succeeded above."
else
  # This vLLM has to load the base model AND the LoRA adapter before it binds
  # :8000 -- strictly slower than the 69s measured in 03-serve-model.sh. A fixed
  # `sleep 3` here was especially bad: this script documents LoRA SERVING as a
  # known-risk step, so a purely-timing failure would be misread as the real
  # LoRA problem. Wait for /health, then ask.
  set +e
  pf_start svc/vllm-serve-svc 8000:8000 /health model=anyvc
  PF_RC=$?
  set -e
  if [ "$PF_RC" -ne 0 ]; then
    [ "$PF_RC" -eq 2 ] && warn "Pod is failing and will not recover: ${PF_ABORT_REASON}"
    die "The LoRA-serving vLLM never answered on :8000. This IS the failure mode this script warns about -- check: kubectl logs -l model=anyvc"
  fi
  curl -s http://localhost:8000/v1/chat/completions -H "Content-Type: application/json" -d '{
    "model": "anyvc-startup-expert",
    "messages": [{"role": "user", "content": "We are building TalentPulse, an AI recruiting platform for nurses. 40 nurses placed across 8 hospitals in 3 months, $200K revenue."}],
    "max_tokens": 512
  }' | jq
  kill "$PF_PID" 2>/dev/null || true
fi

log "Next: ./10-rag.sh"
