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
# --- Image build --------------------------------------------------------------
# DEFAULT: build IN-CLUSTER, on an amd64 node this cluster is already running.
#
# The local-docker path produced three of this module's four failures on
# 2026-09-04 (DIAGNOSTICS9.md), none of which were AWS problems:
#   1. the Docker daemon was not running, and `docker login` succeeded anyway,
#      so the run reported success one line before it failed
#   2. the daemon WAS running, but the docker context pointed at a socket that
#      did not exist
#   3. the image was built for the build host (arm64 Apple Silicon) and died on
#      an amd64 node with "exec format error"
# All three are properties of the laptop, not of the workshop. Building where the
# image will actually run removes the whole class: no daemon to be down, no
# context to be wrong, and the build architecture IS the run architecture.
#
# It also costs nothing extra and creates no AWS resources -- it runs on capacity
# already provisioned, and everything it makes is a Kubernetes object that dies
# with the cluster. That matters here: teardown has been the repo's most
# expensive recurring problem, and CodeBuild would have added an IAM role, a
# build project and an S3 source upload to it, for one 3.6KB build context.
#
# ECR push credentials come from `aws ecr get-login-password` -- a 12h token in a
# Secret that is deleted as soon as the build finishes. No IAM role, no pod
# identity association, no change to the vendored Terraform.
#
# Set USE_LOCAL_DOCKER=1 to take the upstream-faithful local path instead. The
# published workshop builds locally; this is a deliberate, documented deviation.
log "Preparing ECR repository..."
aws ecr describe-repositories --repository-names strands-weather-agent >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name strands-weather-agent >/dev/null
ECR_REPO=$(aws ecr describe-repositories --repository-names strands-weather-agent --query 'repositories[0].repositoryUri' --output text)
export ECR_REPO
ECR_REGISTRY="${ECR_REPO%%/*}"
BUILD_CTX="${MANIFEST_DIR}/600-strands-agent"

if [ "${USE_LOCAL_DOCKER:-0}" = "1" ]; then
  # ---- Local Docker (upstream's path; opt-in) --------------------------------
  warn "USE_LOCAL_DOCKER=1 -- building on this machine instead of in-cluster."
  set +e
  docker_daemon_check
  DOCKER_RC=$?
  set -e
  if [ "$DOCKER_RC" -ne 0 ]; then
    warn "This script has to build an image, and 'docker info' failed."
    while IFS= read -r line; do warn "$line"; done <<< "$(docker_daemon_advice)"
    die "Docker is not usable. Nothing has been created."
  fi
  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
  # --platform is REQUIRED, not cosmetic -- see the note above. The cluster is
  # mixed (c6g.large/arm64 for system, c6a.large/amd64 for general-purpose), so
  # "whatever the host is" is wrong even by accident.
  log "Building for linux/amd64 (build host is $(uname -m))..."
  docker build --platform linux/amd64 -t strands-weather-agent "$BUILD_CTX"
  docker tag strands-weather-agent:latest "${ECR_REPO}:latest"
  docker push "${ECR_REPO}:latest"
else
  # ---- In-cluster build (default) --------------------------------------------
  log "Building in-cluster on an amd64 node (no local Docker; set USE_LOCAL_DOCKER=1 to build here instead)..."

  # The build context is ~3.6KB (Dockerfile, requirements.txt, strands-agent.py),
  # so a ConfigMap carries it with room to spare -- no S3 upload, no git clone.
  kubectl create configmap strands-build-context \
    --from-file=Dockerfile="${BUILD_CTX}/Dockerfile" \
    --from-file=requirements.txt="${BUILD_CTX}/requirements.txt" \
    --from-file=strands-agent.py="${BUILD_CTX}/strands-agent.py" \
    --dry-run=client -o yaml | kubectl apply -f -

  # ECR auth as a docker config.json. Written via mktemp with a trap so the token
  # never sits in the repo, in the shell history, or in the outputs/ transcript.
  ECR_CFG=$(mktemp); chmod 600 "$ECR_CFG"
  trap 'rm -f "$ECR_CFG"' EXIT
  ECR_AUTH=$(printf 'AWS:%s' "$(aws ecr get-login-password --region "$AWS_REGION")" | base64 | tr -d '\n')
  printf '{"auths":{"%s":{"auth":"%s"}}}' "$ECR_REGISTRY" "$ECR_AUTH" > "$ECR_CFG"
  kubectl create secret generic ecr-push-creds \
    --from-file=config.json="$ECR_CFG" --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$ECR_CFG"; trap - EXIT

  kubectl delete job strands-build --ignore-not-found >/dev/null
  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: strands-build
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      # This is a long-ish build with nothing else on the node -- exactly the
      # shape Karpenter consolidates out from under you (DIAGNOSTICS9.md bug 3).
      annotations:
        karpenter.sh/do-not-disrupt: "true"
    spec:
      restartPolicy: Never
      # Build where it will RUN. This is the line that makes "exec format error"
      # structurally impossible rather than merely fixed.
      nodeSelector:
        kubernetes.io/arch: amd64
      initContainers:
        # A ConfigMap volume is a SYMLINK FARM -- every key is a symlink into a
        # hidden ..data/ directory. kaniko's COPY copies the symlink rather than
        # following it, so the file lands in the image as a dangling link and the
        # build fails with an error that names the file as simply missing:
        #     ERROR: Could not open requirements file:
        #     [Errno 2] No such file or directory: 'requirements.txt'
        # Measured 2026-09-04. `cp -rL` dereferences into an emptyDir, so kaniko
        # sees ordinary files. Uses the ECR public mirror rather than Docker Hub
        # to stay clear of anonymous pull limits.
        - name: stage-context
          image: public.ecr.aws/docker/library/busybox:1.37
          command: [ "sh", "-c", "cp -rL /cm/. /workspace/ && ls -l /workspace" ]
          volumeMounts:
            - { name: cm, mountPath: /cm }
            - { name: context, mountPath: /workspace }
      containers:
        # kaniko, not BuildKit. Rootless BuildKit CANNOT run on Bottlerocket, which
        # is the AMI EKS Auto Mode uses: it sets user.max_user_namespaces=0, so
        # rootlesskit cannot create the user namespace it needs. Measured
        # 2026-09-04 -- and the errno is deeply unhelpful:
        #     /proc/sys/user/max_user_namespaces needs to be set to non-zero
        #     failed to start the child: fork/exec /proc/self/exe:
        #         no space left on device
        # That is not a disk problem. The alternative would be privileged: true,
        # which is a bad trade for building a 4KB context. kaniko needs neither
        # user namespaces nor privilege -- it extracts and snapshots layers in its
        # own filesystem -- so it works unmodified here.
        #
        # kaniko is archived upstream and that is a real drawback, accepted
        # deliberately: it is the only unprivileged in-cluster builder that runs
        # on this AMI without node-level changes. It is pinned, and the image is
        # doing one narrow job. Revisit if Bottlerocket ever permits user
        # namespaces.
        - name: kaniko
          image: gcr.io/kaniko-project/executor:v1.24.0
          args:
            - --dockerfile=/workspace/Dockerfile
            - --context=dir:///workspace
            - --destination=${ECR_REPO}:latest
            # No --custom-platform: the node IS amd64, so the natural build
            # target is already correct. That is the entire point of building here.
          volumeMounts:
            - { name: context, mountPath: /workspace }
            - { name: ecr, mountPath: /kaniko/.docker }
          resources:
            requests: { cpu: "500m", memory: 1Gi }
            limits:   { cpu: "1",    memory: 2Gi }
      volumes:
        - name: cm
          configMap: { name: strands-build-context }
        - name: context
          emptyDir: {}
        - name: ecr
          secret: { secretName: ecr-push-creds }
EOF

  log "Waiting for the in-cluster build (first run pulls the kaniko image; expect 2-4 min)..."
  BUILD_DEADLINE=$(( $(date +%s) + ${BUILD_TIMEOUT:-900} ))
  BUILD_STATE="running"
  while [ "$(date +%s)" -lt "$BUILD_DEADLINE" ]; do
    if [ "$(kubectl get job strands-build -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ]; then
      BUILD_STATE="ok"; break
    fi
    if [ -n "$(kubectl get job strands-build -o jsonpath='{.status.failed}' 2>/dev/null)" ]; then
      BUILD_STATE="failed"; break
    fi
    sleep 5
  done

  log "Build log:"
  kubectl logs job/strands-build --tail=40 2>/dev/null || true
  # Delete the credential as soon as it is no longer needed, whatever happened.
  kubectl delete secret ecr-push-creds --ignore-not-found >/dev/null

  case "$BUILD_STATE" in
    ok)     log "Image built and pushed to ${ECR_REPO}:latest by the cluster." ;;
    failed) die "The in-cluster build failed (log above). Re-run with USE_LOCAL_DOCKER=1 to fall back to a local Docker build." ;;
    *)      die "The in-cluster build did not finish within ${BUILD_TIMEOUT:-900}s. Check: kubectl describe job strands-build" ;;
  esac
fi

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
