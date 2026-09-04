# Diagnostics round 10 — the plan upgrade worked, and exposed three latent bugs in the model-download Job (2026-09-04)

The account plan was upgraded to `PAID`, which cleared the blocker that
`DIAGNOSTICS0.md`–`DIAGNOSTICS8.md` chased for nine rounds:

```console
$ aws freetier get-account-plan-state
{
    "accountPlanType": "PAID",
    "accountPlanStatus": "ACTIVE",
    "accountPlanRemainingCredits": { "amount": 106.71, "unit": "USD" }
}
```

`01-deploy-infra.sh` then completed for the first time — **119 resources added,
0 errors**, including the `kube-prometheus-stack` Helm release that failed in
rounds 6, 7 and 8. The orphan self-heal added in round 8 had nothing to clean up.

So this round is not about the GPU. It is about the three bugs that were sitting
behind that blocker the whole time, in one resource: `kubectl_manifest
.job_model_download` (`terraform/pull.tf`). All three are upstream defects at
tag `v2.5.2`, all three were invisible until a run got far enough to hit them,
and all three are now patched at clone time.

**Why none of them announced itself:** for the entire ~40 minutes all of this was
going wrong, the cluster reported

```console
$ kubectl get job -n default model-download
NAME             STATUS    COMPLETIONS   DURATION   AGE
model-download   Running   0/1           19m        19m
```

`Running 0/1` is also exactly what a *healthy* long download looks like. There is
no failing condition to alert on until the deadline fires an hour in.

---

## Bug 1 — the Pod Identity admission race

### Symptom

```console
$ kubectl get pods -n default
NAME                   READY   STATUS   RESTARTS   AGE
model-download-n2mgs   1/2     Error    0          8m3s
```

```console
$ kubectl logs model-download-n2mgs -c validate-pod-identity
Checking Pod Identity...
aws: [ERROR]: An error occurred (NoCredentials): Unable to locate credentials.
Expected role: genai-model-storage-role
Current role:
ERROR: Pod Identity not working. Using node role instead of Pod Identity role.
Pod will be recreated to retry Pod Identity association.
```

Note `Current role:` is **empty**, not a node role. Bottlerocket blocks IMDS from
pods, so there was no credential of any kind — not a wrong identity, no identity.

### Root cause

EKS Pod Identity injects credentials through a mutating admission webhook that
looks up an existing association **at pod admission**. It is a one-shot decision.
A pod admitted before the association is visible never receives an
`eks-pod-identity-token` volume, and nothing inside the pod can recover it:

```console
$ kubectl get pod model-download-n2mgs -o json | jq '.spec.volumes[].name'
"kube-api-access-n86th"          # <- and nothing else
```

Compare the pod that was created after the association had settled:

```console
$ kubectl get pod -l job-name=model-download \
    -o jsonpath='{.items[0].spec.volumes[*].name}'
eks-pod-identity-token kube-api-access-cqq22
```

Same Job, same service account, same manifest. The only variable is *when* the
pod was admitted.

### This is NOT a missing `depends_on`

The obvious reading — and the one that matches `DIAGNOSTICS8.md`'s destroy-order
bug — is that Terraform created the Job before the association. It did not.
Upstream already has the edge:

```hcl
resource "kubectl_manifest" "job_model_download" {
  depends_on = [
    module.eks,
    module.eks.cluster_addons,
    kubectl_manifest.model_storage_service_account,
    aws_eks_pod_identity_association.model_storage,   # <- already there
    aws_s3_bucket.model_storage
  ]
```

Measured on the failing run:

| | timestamp |
|---|---|
| association `a-6ikf4meh0cyqu3pwo` `createdAt` | `2026-09-04T14:46:23.141Z` |
| `job/model-download` `creationTimestamp` | `2026-09-04T14:46:23Z` |

Terraform honored the dependency and created them in the right order, in the same
second. `CreatePodIdentityAssociation` returns success **before** the association
is visible to the admission path, so the ordering guarantee Terraform provides is
not the guarantee that matters here. There is no ordering fix available in
Terraform for an API that is eventually consistent behind its own success
response. The retry has to live in the Job.

---

## Bug 2 — the Job's own retry is structurally unable to fire

Upstream anticipated bug 1. That is what `Pod will be recreated to retry Pod
Identity association` and `backoffLimit: 10` are for. The pod was never recreated.

```yaml
      backoffLimit: 10
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: validate-pod-identity   # exits 1 on failure
            - name: download                # runs for ~40 minutes
```

`validate-pod-identity` is a **sibling** of `download`, not an initContainer. A
Job creates a replacement pod only once the current pod *fails*, and a pod fails
only when **all** of its containers terminate. `download` keeps running for the
length of a ~16GB HuggingFace pull, so the pod stays `Running` indefinitely, the
Job never retries, and `backoffLimit: 10` is dead code.

The validator diagnoses the fault correctly, prints the correct remedy, and
cannot act on it. Meanwhile `download` proceeds through the entire model pull and
would fail at the last step — `s3.upload_file` with no credentials — roughly 40
minutes later. Confirmed: at the point the pod was killed, the bucket held

```console
$ aws s3 ls s3://genai-models-<redacted>/ --recursive --summarize
2026-09-04 10:29:09          0 Ministral-3-8B-Instruct-2512/
Total Objects: 1
   Total Size: 0
```

Bug 2 is the more serious of the two. Bug 1 alone is a ~140ms race with a working
recovery path. Bug 2 is what converts it into a guaranteed 40-minute silent
failure.

### Fix

Move the validator to `initContainers`. Two things then work:

1. It **gates** the download instead of racing beside it, so a pod with no
   credentials costs ~3 seconds rather than ~40 minutes of bandwidth.
2. Its `exit 1` fails the **pod**, so the existing `backoffLimit: 10` finally
   does what it was written to do. Job backoff is 10s, 20s, 40s… — orders of
   magnitude more than the propagation window needs, and well inside
   `activeDeadlineSeconds: 3600`.

Nothing changes on a cluster that does not hit the race: the validator still runs
first, checks the same thing, and exits 0.

Patcher: `scripts/lib/fix_pod_identity_race.py`, applied by
`00-clone-terraform.sh` on every clone.

---

## Bug 3 — Karpenter consolidation evicts the download, repeatedly

### Symptom

After the pod was manually recreated and Pod Identity verified clean, the
download restarted anyway. Third pod in twenty minutes:

```console
$ kubectl describe job model-download | tail -5
  Normal  SuccessfulCreate  19m    job-controller  Created pod: model-download-n2mgs
  Normal  SuccessfulCreate  7m39s  job-controller  Created pod: model-download-gf247
  Normal  SuccessfulCreate  97s    job-controller  Created pod: model-download-d79px
```

```console
$ kubectl get events -n default --sort-by=.lastTimestamp
98s  Normal  DisruptionTerminating  node/i-<redacted>         Disrupting Node: Underutilized
97s  Normal  Evicted                pod/model-download-gf247  Evicted pod: Underutilized
97s  Normal  Killing                pod/model-download-gf247  Stopping container download
96s  Normal  SuccessfulCreate       job/model-download        Created pod: model-download-d79px
```

Karpenter consolidated the node out from under an in-flight 16GB download, six
minutes in, to save **$0.20/hr**.

### Root cause

The Job's pod template mounts nothing:

```console
Mounts:   <none>
Volumes:  <none>
```

The model is written to the container's ephemeral filesystem, so eviction
destroys **all** progress and the replacement pod restarts from zero. Three
factors make this an unwinnable loop rather than a slow path:

- the download needs tens of minutes — the Job sets no `HF_TOKEN`, so it is
  rate-limited by design (`Warning: You are sending unauthenticated requests to
  the HF Hub`)
- a node running one batch pod looks `Underutilized` to consolidation within a
  few minutes
- `activeDeadlineSeconds: 3600` is measured from **Job creation, not pod start**,
  so every restart is charged against the same one-hour budget

Left alone the Job churns pods until the deadline kills it. On this run, bugs 1
and 3 together had burned 25 of the 60 minutes before the first attempt that
could actually have succeeded got going.

`grep -rn do-not-disrupt terraform/*.tf` returns nothing at `v2.5.2` — there is
no disruption protection anywhere in the upstream Terraform.

### Fix

`karpenter.sh/do-not-disrupt: "true"` on the **pod** (not the node), set on the
Job's pod template so every retry pod inherits it. It is scoped to this pod, does
not disable consolidation cluster-wide, and stops applying the moment the Job's
pod terminates — so the node is free to be consolidated as soon as the download
is done.

This fixes only **voluntary** disruption. A spot interruption or node failure
would still lose the download; the real structural fix is a volume that outlives
the pod, which is a larger change to upstream's storage model and deliberately
out of scope.

Patcher: `scripts/lib/fix_download_disruption.py`.

### Live mitigation

The annotation applies to a running pod, so the in-flight download was rescued
without a fourth restart:

```console
$ kubectl annotate pod -n default -l job-name=model-download \
    karpenter.sh/do-not-disrupt=true --overwrite
pod/model-download-d79px annotated
```

Throughput measured inside the container immediately after, to confirm the
surviving pod was genuinely progressing (the `Fetching 11 files: 0%` progress bar
only advances on whole-file completion, so it reads `0/11` for most of a
multi-file pull and looks stuck when it is not):

```console
$ kubectl exec model-download-d79px -c download -- sh -c \
    'F=...incomplete; A=$(stat -c %s "$F"); sleep 30; B=$(stat -c %s "$F"); ...'
start=8084520960 end=8724152320 delta=639631360 bytes over 30s = 20 MB/s
```

### Outcome

With both faults mitigated by hand, the fourth pod completed on its first
uninterrupted attempt:

```console
$ kubectl logs -l job-name=model-download -c download --tail=2
Uploading consolidated.safetensors...
Upload complete!

$ kubectl get job -n default model-download
NAME             STATUS     COMPLETIONS   DURATION   AGE
model-download   Complete   1/1           30m        31m

$ aws s3 ls s3://genai-models-<redacted>/Ministral-3-8B-Instruct-2512/ \
    --recursive --human-readable --summarize
2026-09-04 11:15:53    9.7 GiB .../consolidated.safetensors
Total Objects: 12
   Total Size: 9.7 GiB
```

The download itself took **11m09s** at ~20 MB/s once left alone
(`Fetching 11 files: 100%|██████████| 11/11 [11:09<00:00, 60.85s/it]`) — against
a `activeDeadlineSeconds` budget of 60m, of which bugs 1 and 3 had already
consumed 25m before the successful attempt began. It finished with ~29 minutes to
spare, but only because the loop was broken by hand. Unattended, the eviction
cycle would have restarted an 11-minute download every ~6 minutes until the
deadline killed the Job.

That is the measurement that matters for judging the fixes: the work was never
too slow for the budget. It was being destroyed faster than it could finish.

---

## The patchers

`00-clone-terraform.sh` now applies three in-place patches to every fresh clone.
They are separate files because they have independent drift modes — upstream may
fix any one of them without fixing the others, and the clone script should say
precisely which fix stopped matching.

| Patcher | Fixes | Change |
|---|---|---|
| `fix_destroy_order.py` | `DIAGNOSTICS8.md` teardown race | `module.vpc` → 5 resources' `depends_on` |
| `fix_pod_identity_race.py` | bugs 1 + 2 | validator → `initContainers` |
| `fix_download_disruption.py` | bug 3 | `do-not-disrupt` on the pod template |

Total footprint on pristine `v2.5.2`: 6 files, 8 changed lines.

```console
$ python3 scripts/lib/fix_destroy_order.py       <clone>/terraform
  + module.vpc -> kubernetes_namespace_v1.monitoring (amp.tf)
  + module.vpc -> kubectl_manifest.mistral_model_pv (k8s-s3-storage.tf)
  + module.vpc -> kubectl_manifest.model_storage_service_account (pod-identity.tf)
  + module.vpc -> kubectl_manifest.ingress_class_params (ingress.tf)
  + module.vpc -> kubectl_manifest.eks_node_class_gpu (nodepool.tf)
$ python3 scripts/lib/fix_pod_identity_race.py   <clone>/terraform
  + validate-pod-identity -> initContainers (pull.tf)
$ python3 scripts/lib/fix_download_disruption.py <clone>/terraform
  + karpenter.sh/do-not-disrupt -> model-download pod template (pull.tf)
```

Resulting `pull.tf` diff against upstream:

```diff
       template:
+        metadata:
+          annotations:
+            karpenter.sh/do-not-disrupt: "true"
         spec:
           serviceAccountName: ${kubectl_manifest.model_storage_service_account.name}
           restartPolicy: Never
-          containers:
+          initContainers:
             - name: validate-pod-identity
@@
                   echo "Pod Identity verified successfully!"
+          containers:
             - name: download
```

### Verification

Each patcher asserts the exact upstream shape before editing and exits 1 if it no
longer matches, so a moved tag fails the clone loudly instead of silently
patching something it no longer understands.

- **All three on pristine `v2.5.2`**: clean, in any order (all use content
  anchors, not line numbers).
- **Idempotent**: second run reports `already patched` for all three, exit 0.
- **Patched YAML parses** to `initContainers: ['validate-pod-identity']`,
  `containers: ['download']`, `annotations: {'karpenter.sh/do-not-disrupt':
  'true'}`, with `restartPolicy: Never` and `backoffLimit: 10` unchanged.
- **HCL parses** — `terraform fmt -check` flags only `outputs.tf`, which is
  pre-existing upstream formatting, untouched by any patcher.
- **Drift detection**, 9 cases, all exit 1 with a specific message: validator
  renamed, download container renamed, validator no longer first under
  `containers:`, Job duplicated across two files, Job absent, `template:`
  renamed, Job renamed, upstream added pod metadata, upstream added a
  `do-not-disrupt` annotation in a different form.

### Not yet exercised on a live apply

The clone was already deployed when these were written, and patching a live clone
would make Terraform want to recreate the Job (`force_new = true`) mid-download.
So the current deployment runs the **unpatched** manifest with both faults fixed
by hand instead:

- bug 1/2 — `kubectl delete pod` forced the Job to make a new pod, which was
  admitted after the association had settled
- bug 3 — `kubectl annotate … do-not-disrupt=true` on the running pod

The patchers' first live test is the next clone-and-apply cycle. This is the same
status as the destroy-order fix from `DIAGNOSTICS8.md`, which also remains proven
at the graph level and unexercised against a real destroy.

---

## Postscript — `02-gpu-infrastructure.sh` asked one AZ and called it a region

Same session, different script, unrelated to the Job above. With the plan now
`PAID`, the Free Tier hard gate passed on its first real test:

```console
[11:19:48] Checking the account's Free Tier plan permits g6e.2xlarge (before creating any billable reservation)...
[11:19:49] Account plan is PAID — no Free Tier instance-type restriction.
[11:19:50] Creating ODCR for 1x g6e.2xlarge, auto-expiring at 2026-09-04T19:19:50Z (4h from now)...

aws: [ERROR]: An error occurred (InsufficientInstanceCapacity) when calling the
CreateCapacityReservation operation (reached max retries: 2): Insufficient capacity.
```

Nothing was created and nothing was billed — but the script died, and the error
reads as "the region has no GPUs".

### Root cause

An ODCR is **AZ-scoped**, and the script hardcoded one zone:

```bash
--availability-zone "${AWS_REGION}a"
```

`InsufficientInstanceCapacity` from that call means *`us-east-2a` is out of
`g6e.2xlarge` right now*. It says nothing about the region. Measured at the time
of failure:

```console
$ aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=g6e.2xlarge" --query 'InstanceTypeOfferings[].Location'
us-east-2a   us-east-2b   us-east-2c

$ aws ec2 describe-subnets --subnet-ids <the cluster's three private subnets> \
    --query 'Subnets[].[SubnetId,AvailabilityZone]'
subnet-<a>  us-east-2a
subnet-<b>  us-east-2b
subnet-<c>  us-east-2c
```

Two other AZs offer the type and have a cluster subnet to launch into. Neither
was tried. The `(reached max retries: 2)` in the message is the AWS CLI retrying
the *same* zone twice more, which is the one retry that cannot help.

The GPU NodePool is also less restrictive than the script assumed:

```console
$ kubectl get nodepool gpu -o json | jq '.spec.template.spec.requirements'
kubernetes.io/arch            In ['amd64']
kubernetes.io/os              In ['linux']
karpenter.sh/capacity-type    In ['reserved', 'on-demand']
node.kubernetes.io/instance-type In ['g6e.2xlarge']
```

No AZ requirement, and `on-demand` is accepted alongside `reserved` — so the
reservation is a capacity *guarantee*, not a prerequisite. The script was
strictly more brittle than the cluster it configures.

### Fix

Try every AZ that can actually run the node: the AZs of the cluster's own subnets
(`eks describe-cluster` → `ec2 describe-subnets`) intersected with the AZs that
offer the instance type (`ec2 describe-instance-type-offerings`). Reserving in an
AZ with no cluster subnet would strand the reservation, and reserving in an AZ
that does not offer the type cannot succeed, so the intersection is the exact
candidate set. Both lookups are free.

Only a capacity shortage advances to the next AZ. Anything else — auth, quota,
bad parameters — fails identically everywhere, so the loop `die`s on the first
one instead of burning two more attempts to reach the same conclusion.

If **every** AZ is short, the script no longer dies. It warns loudly and
continues without a reservation, because that is a degraded mode rather than a
failure: the NodePool accepts `on-demand`, so the node can still launch whenever
capacity frees up. Continuing also costs *less*, not more — with no reservation
nothing bills until an instance exists, whereas an ODCR bills from creation
whether or not it is ever used (`docs/COST.md`). The NodeClass's
`capacityReservationSelectorTerms` is cleared in that path, or Karpenter would
keep waiting on a reservation that does not exist instead of falling back.

### Verification

The AZ discovery was run against the live cluster (read-only) and correctly
derived `us-east-2a us-east-2b us-east-2c`. The retry loop was then exercised
with `create-capacity-reservation` stubbed, so nothing was created:

| capacity available in | outcome |
|---|---|
| all three AZs | reserves in `us-east-2a`, no warnings |
| `us-east-2c` only | warns on `2a` and `2b`, reserves in `2c` |
| none | warns per AZ, continues with no ODCR, exit 0 |
| n/a — `UnauthorizedOperation` | `die`s on the first AZ, does not retry |

### The result, and the finding that came with it

On the re-run, **all three AZs refused the reservation** — so the new degraded
path was exercised on its first outing:

```console
[11:27:32]   AZs to try: us-east-2a us-east-2b us-east-2c
[11:27:36] WARNING:   us-east-2a: no g6e.2xlarge capacity right now — trying the next AZ.
[11:27:39] WARNING:   us-east-2b: no g6e.2xlarge capacity right now — trying the next AZ.
[11:27:41] WARNING:   us-east-2c: no g6e.2xlarge capacity right now — trying the next AZ.
[11:27:42] Clearing any capacityReservationSelectorTerms from the GPU NodeClass (running on-demand)...
[11:27:44] Waiting for GPU node to provision + pod to succeed...
pod/nvidia-smi condition met
```

**The on-demand node launched immediately — in `us-east-2b`**, one of the zones
that had just refused a reservation seconds earlier:

```console
$ kubectl get nodeclaims
NAME          TYPE          CAPACITY    ZONE         NODE                  READY   AGE
gpu-plv6n     g6e.2xlarge   on-demand   us-east-2b   i-01322b19ae60793d1   True    115s
```

```console
$ kubectl logs nvidia-smi
| NVIDIA-SMI 580.159.03    Driver Version: 580.159.03    CUDA Version: 13.0     |
|   0  NVIDIA L40S    On  | 00000000:30:00.0 Off |    0 |
| N/A   42C    P0    88W / 350W |   0MiB / 46068MiB |  0%   Default |
```

So: **`CreateCapacityReservation` failing with `InsufficientInstanceCapacity` in
every AZ does not mean an on-demand launch of the same instance type will fail.**
Reserving capacity is a strictly harder ask than consuming it — a reservation
requires AWS to set capacity aside and hold it, while a launch only needs a slot
at that instant. Measured here as a total inversion: 3/3 AZs refused the
reservation, and the launch succeeded in one of them within seconds.

This is the empirical justification for the degraded path. Had the script kept
its original behaviour — die on the first `InsufficientInstanceCapacity` — the
workshop would have been blocked by a reservation it never actually needed, on a
region that had the GPU available the whole time.

---

## Postscript 2 — `03-serve-model.sh` tested a server that had not started yet

```console
[11:34:29] node/i-<redacted> condition met
           pod/mistral-579665f7c4-546bp condition met
[11:34:44] Testing via port-forward...
Handling connection for 8000
E0904 11:34:47.410953 portforward.go:549] "An error occurred forwarding"
  err="... failed to connect to localhost:8000 inside namespace \"...\":
  dial tcp4 127.0.0.1:8000: connect: connection refused ..."
error: lost connection to pod
```

This reads like a port-forward or CNI fault. It is neither. The model was fine —
it just was not listening yet.

### Root cause

```bash
kubectl wait pods --for=jsonpath='{.status.phase}'=Running -l model=mistral --timeout=300s
...
sleep 3
curl -s http://localhost:8000/v1/completions ...
```

`phase == Running` means only that the container **process started**. vLLM then
has to pull 9.7GB of weights from S3, load them onto the L40S and initialise the
KV cache before it binds `:8000`. The deployment declares **no readinessProbe**,
so nothing in the Kubernetes object model reflects that gap — the pod reads
`1/1 Running` throughout.

Measured on this run:

| event | container clock |
|---|---|
| pod reaches `Running` (script proceeds) | `08:34:29` |
| script's `sleep 3` expires, curl fires | `08:34:47` |
| vLLM logs `Application startup complete` | `08:35:38` |

The test ran **51 seconds** before the server existed. A fixed `sleep 3` was
standing in for a 69-second model load.

The pod-scoped error message is what makes this expensive to read: `connection
refused` came from *inside the pod's own network namespace*, so it implicates the
pod's networking rather than the timing. The port-forward was working correctly —
it faithfully reported that nothing was listening on the other end.

### Fix

Poll vLLM's own `/health` from inside the pod until it answers (up to 300s),
*then* send the completion. Also bail out early if the pod leaves `Running`,
since a crash-looping or evicted pod will never become ready and there is no
point burning the full five minutes to discover that.

Verified with a stubbed `kubectl` across five paths: healthy immediately, ready
after 13 polls (reports "roughly 70s", matching the 69s measured), never ready →
`die` at 60 attempts, and pod phase leaving `Running` (`Failed` / `Succeeded`) →
fail fast with the phase named.

### The run itself succeeded

Only the readiness check was wrong. Confirmed against the live deployment:

```console
$ kubectl exec deploy/mistral -- curl -sf -o /dev/null -w "health HTTP %{http_code}\n" \
    http://localhost:8000/health
health HTTP 200

$ kubectl exec deploy/mistral -- curl -s http://localhost:8000/v1/completions \
    -d '{"prompt":"San Francisco is a city that has","max_tokens":7,"temperature":0, ...}'
completion: ' a lot of history and culture.'
usage: {'prompt_tokens': 8, 'total_tokens': 15, 'completion_tokens': 7}
```

Ministral-3-8B, streamed from S3 by the Run:ai Streamer at `concurrency: 16`,
serving from the on-demand L40S that AWS would not reserve.

---

## Postscript 3 — reading ahead: the same defect in four more places

After 03, the remaining scripts were read looking for the shape rather than
waiting to hit each one at runtime: **a hardcoded assumption standing in for a
real check.** Four more instances, one of which is worse than a race.

### 04 — the Grafana URL was never going to work

```console
[11:39:08] Grafana: http://pending
```

```bash
GRAFANA_URL=$(kubectl get ingress/grafana-ingress -n monitoring \
  -o jsonpath='...' --timeout=120s 2>/dev/null || echo "pending")
```

`--timeout` **is not a valid flag for `kubectl get`**:

```console
$ kubectl get ingress grafana-ingress -n monitoring --timeout=5s
error: unknown flag: --timeout
```

So the command failed instantly, `2>/dev/null` hid the reason, and `|| echo
"pending"` supplied a plausible-looking answer. This was not a race that
sometimes lost — it printed `pending` on **every** run, and would have done so if
the ALB had been ready for an hour. The `--timeout=120s` reads as deliberate
patience and bought nothing.

The ALB was in fact fine. Hostname 39 seconds after the Ingress was created:

```console
$ kubectl get ingress grafana-ingress -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
grafana-ingress-1443646815.us-east-2.elb.amazonaws.com
```

### 05 and 09 — the 03 bug, verbatim

Both carried the identical `phase == Running` + `sleep 3` + `curl` sequence.

`09` is the one that matters. Its vLLM must load the base model **and** the LoRA
adapter, so it is strictly slower than the 69s measured in 03 — and the script's
own header documents LoRA *serving* as a known-risk step that has failed before.
A purely-timing failure there would have been read as the real LoRA problem and
written up as such. A three-second sleep was positioned to manufacture false
evidence for an existing open question.

### 10 and 11 — the ALB race, correctly spelled

Both read `.status.loadBalancer.ingress[0].hostname` immediately after `kubectl
apply`, with `|| echo "pending"`. Unlike 04 the syntax is valid, so these are
genuine races — and ones they lose, since the hostname takes ~40s to appear.

### Fix: two shared helpers in `scripts/lib/env.sh`

Kept in `lib/` rather than fixed per-script, for the same reason
`free_tier_check()` lives there: five copies of a readiness check drift, and the
drift is invisible until a run fails.

- **`lb_hostname <ingress> [-n ns]`** — polls until the load balancer publishes
  an address, up to `LB_TIMEOUT` (default 300s). Reads `.hostname` *and* `.ip`, so
  it stays correct for `gcloud/` and `azure/` (GKE/AKS publish `.ip`).
- **`pf_start <svc> <local:remote> [path]`** — starts a port-forward and blocks
  until the far end actually answers HTTP, setting `PF_PID`. It **restarts** the
  forward rather than holding a dead PID, because `kubectl port-forward` *exits*
  when the server is not listening yet — that is what produced `error: lost
  connection to pod` in 03. Any HTTP status counts as ready: a 404 still proves
  something is listening, and not every service has `/health`.

Both were verified against the live cluster:

| check | result |
|---|---|
| `lb_hostname` on the provisioned Grafana ingress | 1s, correct hostname |
| `lb_hostname` on a nonexistent ingress, `LB_TIMEOUT=8` | returns 1, empty, gives up on time |
| `pf_start svc/vllm-serve-svc 18000:8000 /health` | 2s, `HTTP 200` through the forward |
| `pf_start` at a port with nothing listening, `PF_TIMEOUT=20` | returns 1 at 20s, `PF_PID` empty, **no leaked port-forward processes** |

The helper block is byte-identical across `aws/`, `azure/` and `gcloud/`
(md5 `0ce6c7b1…`), since divergence between those three copies is how an earlier
masking bug survived.

### The pattern

Five scripts, one defect: `us-east-2a` for "the region", `sleep 3` for "the server
is up", a sibling container for a gate, `--timeout=120s` for "wait", `phase ==
Running` for "ready". Each was true on the machine it was written on and wrong the
first time reality varied. Every fix in this round replaces a guess with an
observation — poll the endpoint, ask the API, intersect the real sets.

The 04 case is the one worth remembering, because it did not fail. It printed a
confident, wrong answer for the entire life of the repo, and only a read-through
found it. `2>/dev/null || echo "<plausible default>"` is how a broken command
becomes indistinguishable from a working one.


---

## Postscript 4 — `command -v docker` is not "Docker works"

`05-agentic-app.sh` is the only script in the workshop that builds an image, and
it failed immediately after a line saying the opposite:

```console
[11:47:42] Building + pushing to ECR...
Login Succeeded
ERROR: failed to connect to the docker API at unix:///var/run/docker.sock;
check if the path is correct and if the daemon is running:
dial unix /var/run/docker.sock: connect: no such file or directory
```

`docker login` against ECR **succeeds with no daemon running** — it only writes a
credential into the local docker config and never contacts the daemon. So the run
produced a confident `Login Succeeded` and then died one line later, in a way
that reads as an ECR or IAM problem. It is neither: OrbStack was installed and
simply not started.

`00-prereqs.sh` did not catch it, because its tooling check was:

```bash
for tool in aws kubectl helm terraform docker jq envsubst curl; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
```

`command -v docker` proves the CLI is on PATH. That is the same substitution as
everything else in this round — presence standing in for readiness.

### Fix

- `00-prereqs.sh` now runs `docker info` and **warns** (does not `die`): 05 is the
  only script that needs the daemon, and 00-04 and 06-11 run fine without it, so
  refusing the whole workshop over it would be wrong. The warning repeats in the
  end-of-run summary.
- `05-agentic-app.sh` `die`s on `docker info` **before** the ECR login, so the
  misleading `Login Succeeded` never gets printed and the error names the actual
  cause. Verified both ways with a stubbed `docker`: daemon down exits 1 with the
  start-it message, daemon up proceeds to the build.

### ...and then that fix told the user something false

The message above says *"Start it -- e.g. `open -a OrbStack`"*. The user ran it,
and Docker still did not work:

```console
$ open -a OrbStack
$ docker ps
failed to connect to the docker API at unix:///var/run/docker.sock; check if the
path is correct and if the daemon is running
```

OrbStack was already running, and had been. Two processes up, and its daemon
answering normally on its own socket:

```console
$ DOCKER_HOST="unix://<home>/.orbstack/run/docker.sock" docker info --format '{{.ServerVersion}} / {{.OperatingSystem}}'
29.4.0 / OrbStack
```

The active docker context was `default` pointing at `unix:///var/run/docker.sock`,
which did not exist, and no `orbstack` context was registered. So `docker info`
failing had nothing to do with the daemon being down — it was a client pointed at
the wrong socket.

Which makes the new check **the same defect as everything else in this round**: it
observed a symptom (`docker info` failed) and asserted a cause (*it is not
running*) instead of checking. Writing "start the daemon" to someone whose daemon
is already started is not a smaller version of that mistake; it is the mistake.

**Fix**: `docker_daemon_check()` in `scripts/lib/env.sh` distinguishes the two.
When `docker info` fails it probes the known per-runtime sockets (OrbStack,
Colima, Docker Desktop, Rancher Desktop) and reports which of the two situations
it is actually in:

| return | meaning | advice given |
|---|---|---|
| 0 | reachable | none |
| 1 | a daemon IS running, at a socket the current config is not using | the exact `docker context create` / `use` pair, with the discovered socket path |
| 2 | nothing found anywhere | start one |

`docker_daemon_advice()` renders the message, so 00 and 05 cannot describe the
same state in two different ways. All three branches verified: the misconfigured
case emits the working socket path and the exact two commands, and the genuinely
absent case (probed with `HOME=/tmp`) falls through to "start one".

**Correction.** An earlier revision of this section claimed the situation
"resolved itself" when OrbStack finished initialising and created
`/var/run/docker.sock`. That was wrong, and asserted for the same reason as
everything else here — Docker started working, and a cause was assumed instead of
checked. `/var/run/docker.sock` was never created:

```console
$ ls -l /var/run/docker.sock
No such file or directory

$ DOCKER_HOST=unix:///var/run/docker.sock docker info --format '{{.ServerVersion}}'
(fails)

$ docker context ls --format '{{.Name}} current={{.Current}}'
default  current=false
orbstack current=true
```

Docker works because the **user ran the two `docker context` commands**. The
`default` context is still broken and always was. There was no startup race.

### Auto-repair

Printing two commands for someone to retype, on every run, is not a fix — so
`00-prereqs.sh` now performs the repair when `docker_daemon_check()` returns 1,
i.e. only after a daemon has been **proven** to answer on the discovered socket.
`docker_daemon_autofix()` names the context after the detected runtime
(`orbstack` / `colima` / `rancher-desktop` / `desktop-linux`), creates it — or
`update`s it if it already exists, so a re-run is idempotent — points it at the
socket, selects it, and re-verifies with `docker info`.

This is the one change `00-prereqs.sh` makes, and its header now says so instead
of claiming it changes nothing. It is docker-CLI config only: no AWS call, no
cluster call, no cost, and `docker context use default` undoes it.

Verified against a throwaway `DOCKER_CONFIG`, so the real config was untouched
during the test: from a simulated broken state it created `orbstack ->
unix://<home>/.orbstack/run/docker.sock`, made it current, confirmed
`29.4.0 / OrbStack`, and a second run returned 0 without duplicating anything.

---

## Postscript 5 — an arm64 image on an amd64 node

`05-agentic-app.sh` built and pushed cleanly, deployed, and then the pod said:

```console
$ kubectl get pods -l app=strands-weather-agent
NAME                                     READY   STATUS   RESTARTS      AGE
strands-weather-agent-67cf778554-kmh8t   0/1     Error    5 (97s ago)   3m21s

$ kubectl logs -l app=strands-weather-agent
exec /usr/local/bin/python: exec format error
```

`exec format error` is the kernel refusing a binary built for another
architecture. Nothing in the message says so.

### Root cause

```bash
docker build -t strands-weather-agent "${MANIFEST_DIR}/600-strands-agent"
```

No `--platform`, so Docker builds for the **build host** — an Apple Silicon Mac.
The build log said so all along, in the wheel names:

```
pydantic_core-2.46.4-cp312-cp312-manylinux_2_17_aarch64...whl
numpy-2.5.2-cp312-cp312-manylinux_2_27_aarch64...whl
```

The cluster is **mixed-architecture**, which makes "whatever the host is" wrong
even by accident:

```console
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture
i-<gpu>       amd64      # g6e.2xlarge
i-<system>    arm64      # c6g.large
i-<general>   amd64      # c6a.large
```

EKS Auto Mode picked `c6g.large` (Graviton) for the system pool and `c6a.large`
for general-purpose. An unpinned image would have been wrong on one of them
whichever way the build host had gone, and upstream's Deployment has no
`nodeSelector`, so placement was luck.

### Fix

Pin **both** halves, so they cannot disagree:

- `docker build --platform linux/amd64` — the image
- `nodeSelector: { kubernetes.io/arch: amd64 }` on the Deployment — the placement

Pinning only the image would still allow the pod onto the arm64 system node;
pinning only the pod would still ship an arm64 binary. This is the same class as
the ODCR AZ bug — a single hardcoded assumption where the surrounding system is
heterogeneous.

### And a weakness in the fix from Postscript 3

`pf_start` polled this doomed pod for the full 300s. It was waiting correctly for
something that was never going to happen: the pod had already restarted 5 times
with a permanent error. Correct behaviour, useless outcome.

`pf_start` now takes an optional pod selector and gives up immediately on a pod
that **cannot** become ready — `CrashLoopBackOff`, `ImagePullBackOff`,
`ErrImagePull`, `CreateContainerError`, or a non-zero exit with 3+ restarts —
returning 2 with the reason in `PF_ABORT_REASON`. Verified against this exact
live failure:

```console
rc=2 elapsed=0s reason='strands-weather-agent: CrashLoopBackOff (5 restarts)'
```

and confirmed not to regress the healthy path (`svc/vllm-serve-svc` with
`model=mistral`: `rc=0 elapsed=3s`, `HTTP 200` through the forward). 05 turns
return 2 into a message that names architecture explicitly, since `exec format
error` does not.

### ...and the crash-loop guard then aborted a healthy rollout

The amd64 rebuild pushed correctly — `manylinux_2_17_x86_64` wheels this time —
and 05 still failed, one second in:

```console
[12:01:22] deployment.apps/strands-weather-agent configured
           pod/strands-weather-agent-67cf778554-kmh8t condition met
           pod/strands-weather-agent-67f66d84d-w9tp4 condition met
[12:01:35] FATAL: The strands agent pod is failing and will not recover:
           strands-weather-agent: exited 255, 6 restarts
```

Two pods, two ReplicaSets. `67cf778554-kmh8t` is the **old arm64 pod being
replaced**; `67f66d84d-w9tp4` is the new amd64 one, which came up fine:

```console
$ kubectl logs strands-weather-agent-67f66d84d-w9tp4
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8000
```

The guard selected on `app=strands-weather-agent`, which matches pods from
**both** ReplicaSets during a rollout. It found the corpse of the very pod the
deploy was fixing and used it to abort the wait for its healthy replacement.

This is a nastier version of the same mistake as everywhere else in this round:
it looked at *a* pod rather than *the* pod, and a label selector is not an
identity. The failure mode is specifically perverse — the guard is most likely to
misfire exactly when you are redeploying to fix a broken revision, which is the
only time it gets used.

**Fix**: consider only the newest pod that is not already being deleted — filter
on `metadata.deletionTimestamp`, then take the max by `creationTimestamp`.

Verified against the live deployment after the rollout settled: `rc=0` in 3s, and
05's own test payload answered correctly through the forward —

```console
$ curl -s -X POST http://localhost:8080/agent -d '{"query": "What time is it in Dallas?"}'
The current time in Dallas is **11:03 AM CDT** (Central Daylight Time).
```

which is tool-calling working end to end against the vLLM backend. 05 had in fact
succeeded; only the guard disagreed.
