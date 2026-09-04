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
