# Diagnostics round 8 — GPU quota granted; same Helm symptom, *different* root cause (2026-09-03)

Two things happened on the same day and they are unrelated. Round 8 is worth
recording precisely because the surface symptom is identical to
`DIAGNOSTICS0.md`/`DIAGNOSTICS4.md`/`DIAGNOSTICS6.md` but the cause is **not**
the Free Tier hold this time — that is provably gone.

## Part 1 — the g6e GPU quota is granted (AWS support asked us to confirm)

AWS support wrote that the `g6e.2xlarge` EC2 GPU access request had been
"submitted for final processing" and asked whether the error was still
happening. Checked against the Service Quotas API rather than taking the
email's word for it:

```bash
aws service-quotas list-service-quotas --service-code ec2 --output json \
  | python3 -c "import json,sys;[print(q['QuotaCode'],q['Value'],q['QuotaName']) for q in json.load(sys.stdin)['Quotas'] if 'G ' in q['QuotaName']]"
```

```
L-DB2E81BA  16.0  Running On-Demand G and VT instances
```

**16.0 vCPUs**, up from the `0.0` recorded at the end of `DIAGNOSTICS4.md`.
`g6e.2xlarge` is 8 vCPUs, so this is room for two of them. The change-history
record shows the case AWS just closed:

```bash
aws service-quotas list-requested-service-quota-change-history --service-code ec2 --output json
```

```
CASE_CLOSED  desired=8.0  created=2026-08-13T12:30:32-04:00  updated=2026-08-13T13:09:12-04:00
```

We asked for 8; the granted ceiling is 16.

The separate account-wide **Free Tier launch restriction** (the one that
dominated `DIAGNOSTICS0.md`-`DIAGNOSTICS6.md`) is also gone. Both dry-runs
now return `DryRunOperation` — "would have succeeded" — where the restricted
account returned `not eligible for Free Tier`:

```bash
AMI=$(aws ssm get-parameter --region us-east-2 \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)
for T in c5.large g6e.2xlarge; do
  aws ec2 run-instances --region us-east-2 --dry-run --instance-type $T --image-id "$AMI" --count 1
done
```

```
An error occurred (DryRunOperation) ... Request would have succeeded, but DryRun flag is set.   # c5.large
An error occurred (DryRunOperation) ... Request would have succeeded, but DryRun flag is set.   # g6e.2xlarge
```

**Answer to support: no, the error is gone on both counts.** This is the
first time in the whole `DIAGNOSTICS*` series that both the general-purpose
*and* the GPU launch paths are clear at the same time.

## Part 2 — the Terraform error, which is NOT a quota problem

```
Plan: 18 to add, 0 to change, 1 to destroy.
aws_eks_addon.s3_csi_driver: Creation complete after 25s
│ Error: installation failed
│   with helm_release.kube_prometheus_stack, on helm.tf line 37
│ cannot re-use a name that is still in use
```

Note the s3 CSI addon completed in **25 seconds** — no `DEGRADED`, no
20-minute timeout. Nothing here resembles the earlier rounds' node-launch
failure. The Helm error is leftover state from an *earlier* apply that day:

```bash
helm list -n monitoring
```

```
kube-prometheus-stack  monitoring  1  2026-09-03 11:27:58 -0400  failed  kube-prometheus-stack-69.8.2  v0.80.1
```

```bash
terraform -chdir=.deploy/sample-genai-on-eks/terraform state list | grep helm_release
```

```
(no output)
```

That pairing is the whole bug: **Helm has a release record, Terraform has
none.** A partially-completed apply wrote the Helm release secret
(`sh.helm.release.v1.kube-prometheus-stack.v1`, confirmed present in the
`monitoring` namespace) and then died before persisting state. The next apply
therefore plans a fresh `helm install`, and Helm refuses a name it already
holds — even a `failed` one. This reads like a Terraform bug and is not one.

## Why the *original* 11:27 install failed — and why it is not the Free Tier hold

```bash
helm status kube-prometheus-stack -n monitoring
```

```
STATUS: failed
DESCRIPTION: Release "kube-prometheus-stack" failed: failed pre-install: 1 error occurred:
	* timed out waiting for the condition
```

The chart's pre-install hook is the `kube-prometheus-stack-admission-create`
Job. Helm always blocks on hook Jobs regardless of `wait = false` on the
`helm_release` resource, and the default hook timeout is 300s.

Node timeline at the moment of the failure (ages read at ~14:46, worked
backwards):

| Node | NodePool | Born | Taints |
|---|---|---|---|
| `i-0539c8bca8448e3d0` | `system` | ~11:20 | `CriticalAddonsOnly:NoSchedule`, `karpenter.sh/disrupted:NoSchedule` |
| `i-0f9c30739f93d7de2` | `general-purpose` | ~12:27 | none |

The hook ran at **11:27:58** — a full hour before the `general-purpose` node
existed. The only node in the cluster was the `system` node, carrying
`CriticalAddonsOnly:NoSchedule`.

And `helm.tf` sets `nodeSelector` + the `CriticalAddonsOnly` toleration for
`grafana`, `prometheus`, `prometheusOperator`, `kube-state-metrics` and
`nodeExporter` — but **not** for `prometheusOperator.admissionWebhooks.patch`,
which is the separate values key that configures the hook Jobs. So the hook
pod had no toleration for the only node available and sat unschedulable for
its entire 300s budget.

*Caveat on confidence*: the hook Job is gone (`kubectl get jobs -n monitoring`
returns nothing — hook-delete-policy cleaned it up), so the pod's own
`FailedScheduling` events could not be read directly. The taint/toleration gap
plus the one-hour node-timing gap is inference from surviving evidence, not a
captured event. It is consistent with everything observable and it explains
why the symptom recurred on an account where the Free Tier hold has cleared.

This is upstream sample code under `.deploy/sample-genai-on-eks/`, which
`00-clone-terraform.sh` re-clones — patching `helm.tf` in place would be
overwritten, so it is recorded here rather than fixed.

## Recovery

Same one-liner as `DIAGNOSTICS4.md` and `DIAGNOSTICS6.md`. Safe here: the
release had **zero pods and zero jobs** in `monitoring`, so nothing running is
being torn down.

```bash
helm uninstall kube-prometheus-stack -n monitoring
```

```bash
./01-deploy-infra.sh
```

The retry should clear the original failure too, not just the name clash: the
`general-purpose` node now exists and is untainted, so the admission hook has
somewhere to land immediately instead of waiting on a cold Karpenter scale-up.

## Fix applied — `01-deploy-infra.sh` now self-heals this

Three occurrences of the same orphaned-release clash was enough. The script
now detects and clears it automatically after `terraform init`, guarded so it
can only ever remove a release that is genuinely orphaned:

- release status is `failed` / `pending-install` / `pending-upgrade`, **and**
- `terraform state list` has no `helm_release.kube_prometheus_stack`

If Terraform *does* track the release, the script warns and leaves it alone —
uninstalling a tracked release would be destructive rather than a repair.

Verified against the live broken cluster before committing (read-only):

```bash
helm list -n monitoring -o json | python3 -c 'import json,sys; print(repr(next((r["status"] for r in json.load(sys.stdin) if r["name"]=="kube-prometheus-stack"), "")))'
# 'failed'
terraform -chdir=.deploy/sample-genai-on-eks/terraform state list | grep -c '^helm_release\.kube_prometheus_stack$'
# 0
```

Both guard conditions match, so the new block would have fired and fixed this
run unattended.

## Standing gotcha, now automated

When a `terraform apply` in this repo fails on a Helm resource, check
`helm list -n monitoring` against `terraform state list` before assuming the
Terraform is wrong. Terraform cannot reconcile a Helm release it does not know
about. As of this round `01-deploy-infra.sh` does that check itself.
