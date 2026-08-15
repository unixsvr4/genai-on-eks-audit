# Diagnostics round 5 — recovery after account validation

Follow-on from `DIAGNOSTICS3.md`.

## Account validation confirmed the root cause

Received this from AWS, unprompted, after the failed run in `DIAGNOSTICS3.md`:

> Dear AWS Customer,
>
> You recently requested Amazon Elastic Compute Cloud (EC2) in US East (Ohio)
> Region(s) that required additional validation. Your request has now been
> validated. If you did not make this request or still experiencing
> difficulty, then contact us through the Support Center.
>
> Sincerely, Amazon Web Services

This is AWS's own confirmation of the hypothesis in `DIAGNOSTICS3.md`'s
Outcome section: the account had a temporary EC2 launch restriction pending
validation, not a bug anywhere in this repo.

## Verifying the fix

```bash
kubectl get nodes -o wide
```

```
NAME                  STATUS   ROLES    AGE   VERSION               INTERNAL-IP   ...
i-01b5a00de57e4dd34   Ready    <none>   77m   v1.34.8-eks-a3a0722   10.0.46.82    ...
i-05129f11a45f4e1b4   Ready    <none>   77m   v1.34.8-eks-a3a0722   10.0.22.117   ...
i-0eba2ca3afa25b8b4   Ready    <none>   10m   v1.34.8-eks-a3a0722   10.0.45.235   ...
```

A third node (`i-0eba2ca3afa25b8b4`, 10 minutes old) — from the
`general-purpose` pool, which had churned for over an hour without ever
producing a node in `DIAGNOSTICS1.md`-`DIAGNOSTICS3.md` — is now `Ready`.
Confirms the restriction has lifted.

## What the interrupted apply left behind

`terraform apply` didn't just time out cleanly — it left the
`kube-prometheus-stack` Helm release in a `failed` state from the
pre-install hook timeout (`DIAGNOSTICS0.md`):

```bash
helm list -n monitoring
```

```
NAME                     NAMESPACE     REVISION    STATUS    CHART                           APP VERSION
kube-prometheus-stack    monitoring    1           failed    kube-prometheus-stack-69.8.2    v0.80.1
```

A `failed` release needs to be cleared before Terraform's `helm_release`
resource can cleanly install rather than trying to reconcile a broken one.

## Recovery steps

```bash
helm uninstall kube-prometheus-stack -n monitoring
./01-deploy-infra.sh
```

## Outcome — resolved

The re-run of `01-deploy-infra.sh` completed cleanly:

```
kube-system   s3-csi-controller-56664587f-9pbqs                           1/1     Running   0   61s
kube-system   s3-csi-node-r89jw                                           3/3     Running   0   61s
kube-system   s3-csi-node-w7mkk                                           3/3     Running   0   61s
kube-system   s3-csi-node-wf2zr                                           3/3     Running   0   61s
monitoring    kube-prometheus-stack-grafana-5f669c5dc8-gg9fg              3/3     Running   0   30s
monitoring    kube-prometheus-stack-kube-state-metrics-7885c984b8-t9krc   1/1     Running   0   30s
monitoring    kube-prometheus-stack-operator-75db6fc97-w7vpg              1/1     Running   0   30s
monitoring    patch-grafana-dashboards-gnkvx                              1/1     Running   0   14s
[12:14:51] Infra deployed. Next: ./02-gpu-infrastructure.sh
```

`s3-csi-controller` — the exact pod that spent 20+ minutes `Pending` in
`DIAGNOSTICS0.md` — came up in 61 seconds. `kube-prometheus-stack`
reinstalled cleanly after the `helm uninstall`. The `general-purpose`
NodePool now has a working node (visible as the third `Ready` node in
`DIAGNOSTICS4.md`'s verification step above), confirming the entire chain
traced across `DIAGNOSTICS0.md`-`DIAGNOSTICS4.md` (stuck addon → NodeClaim
churn → CloudTrail `CreateFleet` errors → account Free Tier restriction →
AWS validation email → node launches → clean deploy) was correct end to end.

**Before running `./02-gpu-infrastructure.sh` next**: this fix resolved the
*general-purpose* launch restriction, but `00-prereqs.sh` separately flagged
the `g6e.2xlarge` **GPU** quota (`L-DB2E81BA`, "Running On-Demand G and VT
instances") at `0.0` vCPUs — a distinct quota that this account validation
does not appear to cover. Worth re-checking that quota specifically before
starting the GPU module, so it doesn't turn into a second multi-round
diagnostic chase:

```bash
aws service-quotas get-service-quota --region us-east-2 \
  --service-code ec2 --quota-code L-DB2E81BA --query 'Quota.Value'
```

If it's still `0.0`, request an increase (EC2 → Service Quotas →
"Running On-Demand G and VT instances") before running
`./02-gpu-infrastructure.sh` — see `docs/COST.md`'s "GPU quota" section.

**Confirmed: still `0.0`.** This is a real, separate blocker — the account
validation that fixed the general-purpose restriction did not touch this
quota. Request the increase before running `02-gpu-infrastructure.sh`:

```bash
aws service-quotas request-service-quota-increase --region us-east-2 \
  --service-code ec2 --quota-code L-DB2E81BA --desired-value 8
```

`8` is the minimum for one `g6e.2xlarge` (8 vCPUs); request more if you want
headroom for a second instance. Unlike the account-wide validation above,
quota increase requests are typically approved automatically within
minutes for small values like this — but can occasionally take longer or
require manual review. Check status with:

```bash
aws service-quotas list-requested-service-quota-change-history \
  --region us-east-2 --service-code ec2 \
  --query "RequestedQuotas[?QuotaCode=='L-DB2E81BA']"
```

**Request submitted**: `PENDING` as of `2026-08-13T12:30:32-04:00`
(request ID `54db954efe9143f7bd9dc59bd6d42424q4PjyFAX`, desired value `8`).
Waiting on approval before `02-gpu-infrastructure.sh` can run.

**Update `12:31:23-04:00`**: status moved from `PENDING` to `CASE_OPENED`
(AWS Support case `CASE-REDACTED`) within about a minute — this GPU-family
quota did **not** get the instant auto-approval that's typical for smaller
EC2 quota bumps; it went to manual review instead. Correcting the earlier
assumption in `00-prereqs.sh`/`README.md` that this is "usually auto-approved
within minutes" — for `g6e` GPU quota specifically, expect a support case
and a real wait (hours to a few business days), not a near-instant approval.
`CASE_OPENED` is a normal, non-error state — just means a human will review
it. Keep polling `list-requested-service-quota-change-history` for
`APPROVED`.

**Approved.** AWS Support's approval email confirmed the new limit directly:
`[US East (Ohio)]: EC2 Instances / All G and VT instances, New Limit = 8`,
noting it takes effect ~30 minutes after the email. Total turnaround from
`CASE_OPENED` to approved: well under an hour in this case — faster than the
"hours to a few business days" ceiling above, but still nowhere near the
instant auto-approval smaller quotas get. Verify with the same command used
throughout this trail (wait for the 30-minute propagation window first):

```bash
aws service-quotas get-service-quota --region us-east-2 \
  --service-code ec2 --quota-code L-DB2E81BA --query 'Quota.Value'
```

Once that returns `8.0` (not `0.0`), `./02-gpu-infrastructure.sh` is clear to
run — this closes out the last blocker from this entire diagnostic trail.

**Confirmed `8.0`.** Every blocker traced across `DIAGNOSTICS0.md`-`DIAGNOSTICS4.md`
is now resolved: stuck addon → NodeClaim churn → CloudTrail `CreateFleet`
errors → account Free Tier restriction → validation email → general-purpose
node launches → clean infra deploy → GPU quota support case → approved.
`./02-gpu-infrastructure.sh` is clear to run.
