# Diagnostics round 7 — same s3-csi-driver symptom on a brand-new cluster (2026-08-14)

Follow-on from `DIAGNOSTICS4.md`/`DIAGNOSTICS5.md`. Different day, different
cluster (destroyed and redeployed since `DIAGNOSTICS4.md`, hence `kubectl`
initially failing on a stale endpoint hostname — see below), but the exact
same surface symptom: `aws_eks_addon.s3_csi_driver` stuck `DEGRADED`, timing
out after 20 minutes, `kube-prometheus-stack`'s Helm pre-install hook timing
out with it.

## First: stale kubeconfig, unrelated to the real issue

```bash
kubectl get nodeclaim -o wide
```

```
Unable to connect to the server: dial tcp: lookup <old-endpoint-hash>.gr7.us-east-2.eks.amazonaws.com: no such host
```

A fresh cluster gets a new API endpoint hostname; the local `~/.kube/config`
still pointed at yesterday's. Fixed with:

```bash
aws eks update-kubeconfig --name genai-workshop --region us-east-2
```

Worth remembering any time a cluster gets torn down and redeployed in the
same terminal session — `01-deploy-infra.sh` runs this itself, but a
standalone `kubectl` call in a separate terminal won't have picked it up yet.

## Root cause — confirmed to be the same Free Tier restriction, but this time not blocking everything

```bash
kubectl get nodeclaim -o wide
kubectl get nodepool general-purpose -o jsonpath='{.status.conditions}' | jq .
kubectl get nodepool system -o jsonpath='{.status.conditions}' | jq .
kubectl get events --sort-by='.lastTimestamp' | tail -30
```

Both `general-purpose` and `system` NodePools showed a
`NodeRegistrationHealthy: False, Reason: FreeTierIneligible` condition — same
restriction as `DIAGNOSTICS0.md`-`DIAGNOSTICS5.md`. But this time the
evidence was more nuanced than a total block:

- **`general-purpose-mfzrg` was already `Ready`** (3m18s old at the time of
  the check) — a general-purpose node came up successfully, just after an
  earlier attempt had failed. Its `FreeTierIneligible` transition timestamp
  (15:06:32) lines up almost exactly with when the working node launched —
  consistent with the same churn-then-eventually-succeed pattern seen before,
  just resolving faster this time (single retry, not dozens over an hour).
- **The `system` pool's `FreeTierIneligible` condition and churn
  (`system-rs7wq`, `system-vbmwv` created then stuck
  `TerminationGracePeriodExpiring`) was Karpenter's own cost-consolidation
  logic** trying to replace a healthy 70-minute-old node for a small $0.06/hr
  saving — unrelated to the addon failure. The original nodes
  (`system-2vwwg`, `system-hjdhw`) stayed `Ready` throughout; a
  `PodDisruptionBudget` on `metrics-server` blocked the drain, so nothing was
  actually at risk of going down (Karpenter gives it a ~24h grace period
  before forcing it).

**Reading**: the account's Free Tier hold is not fully cleared, but it also
isn't a hard 100%-fail-every-attempt block anymore either — it looks
probabilistic/intermittent at this point, more consistent with the
restriction *fading out* over time than a clean binary flip. Consistent with
not having received a fresh "validated" email for this cluster yet, but the
practical effect (some launches now succeed) is much less disruptive than
`DIAGNOSTICS0.md`-`DIAGNOSTICS3.md`'s complete churn.

## Recovery — same as DIAGNOSTICS4.md

```bash
helm list -n monitoring
# kube-prometheus-stack ... failed
helm uninstall kube-prometheus-stack -n monitoring
./01-deploy-infra.sh
```

## Outcome — resolved

Clean re-apply: `18 added, 0 changed, 1 destroyed` (the one destroy being the
degraded `s3_csi_driver` addon Terraform correctly tore down before
recreating it). `s3-csi-controller` came up in 64s this time.
`kube-prometheus-stack` and the Grafana operator both progressed normally.
Script's own post-deploy check confirms:

```
[12:12:38] Infra deployed. Next: ./02-gpu-infrastructure.sh
```

Same lesson as `DIAGNOSTICS4.md`: when a `terraform apply` times out on the
CSI addon/Helm hooks, always check `helm list -n monitoring` for a `failed`
release before retrying — Terraform won't cleanly reconcile a failed Helm
release on its own, and the recovery is a one-line `helm uninstall` + re-run.

## Same day, GPU module: `FreeTierIneligible` still blocking `g6e.2xlarge`

With infra clean, `./02-gpu-infrastructure.sh` hit the familiar timeout:

```
error: timed out waiting for the condition on pods/nvidia-smi
```

Confirmed via the same check used in `DIAGNOSTICS5.md`:

```bash
kubectl get nodepool gpu -o jsonpath='{.status.conditions}' | jq .
```

```
"message": "The specified instance type is not eligible for Free Tier",
"reason": "FreeTierIneligible", "status": "False", "type": "NodeRegistrationHealthy"
```

Same NodeClaim-churn pattern as `DIAGNOSTICS5.md` (`gpu-mtwml` → `gpu-76rb7`
→ `gpu-2xwwx` → `gpu-dz8jc` → `gpu-n4kkg` → `gpu-rnkcf` → `gpu-6cqkc` →
`gpu-dn69h` → `gpu-wkz7v`, ~80s apart). Unlike `general-purpose` earlier
today, which self-recovered after one retry, the GPU pool is still fully
blocked — no successful launch yet on this fresh cluster.

**Considered switching to `g6e.xlarge` instead** (smaller GPU instance,
same L40S family, half the vCPUs — overridable via `INSTANCE_TYPE=g6e.xlarge
./02-gpu-infrastructure.sh` per `lib/env.sh`). **Ruled out without trying it**:
this restriction is a Free Tier *eligibility* check, not a quota or
instance-family-specific block — true Free Tier only covers
`t2.micro`/`t3.micro`, so `g6e.xlarge` is exactly as ineligible as
`g6e.2xlarge` and would almost certainly hit the identical wall. Switching
types would just cost another ODCR-billing cycle to confirm what we already
know.

Cancelled the ODCR (`cr-EXAMPLE000000001`) and deleted the pod again, same
reasoning as `DIAGNOSTICS5.md` — no reason to pay for idle reserved capacity
while blocked.

**Next step**: retry `./02-gpu-infrastructure.sh` after a short wait (the
account's hold has trended toward intermittent/fading rather than a hard
block over the last two days — `general-purpose` needed dozens of retries
over an hour in `DIAGNOSTICS0.md`-`DIAGNOSTICS3.md`, then just one retry
today). If several retries in a row still fail cleanly, fall back to waiting
for another AWS validation, same as `DIAGNOSTICS4.md`/`DIAGNOSTICS5.md`.
