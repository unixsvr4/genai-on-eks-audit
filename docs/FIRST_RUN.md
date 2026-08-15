# First Live Run — Field Notes

Real-world timing and a live gotcha from actually running `01-deploy-infra.sh`
against a fresh account, captured as it happened — not from the original
workshop event. This doc exists because the first real run of this repo
surfaced something the scripted RESEARCH.md capture never hit: the workshop's
own environment was pre-warmed by AWS, so nobody there ever watched a cold
`terraform apply` against a brand-new account/region.

## Account/run context

- Region: `us-east-2`
- `terraform apply` started: 10:41:33 (after `00-prereqs.sh` + `00-clone-terraform.sh`, run ~10:37–10:41)
- GPU quota (`g6e.2xlarge`) at prereqs check: **0.0 vCPUs** — flagged by `00-prereqs.sh` as too low, but this doesn't block anything until `02-gpu-infrastructure.sh`

## Observed timeline

| Resource | Duration | Notes |
|---|---|---|
| `module.eks.aws_eks_cluster.this[0]` (EKS control plane) | 10m7s | Normal — EKS control planes typically take 10-15 min. |
| `aws_eks_addon.before_compute["metrics-server"]` | 7m12s | Slower than typical (usually 1-2 min) — first sign nodes were slow to come up. |
| `aws_eks_addon.s3_csi_driver` (Mountpoint-for-S3 CSI driver) | **16+ min and still creating** at time of writing | The actual bottleneck — see gotcha below. |

Total elapsed at the 16-minute mark on the S3 CSI driver addon: **~34-38
minutes**, already past the `01-deploy-infra.sh` comment's own "~20-25
minutes" estimate — driven entirely by addon provisioning, not the control
plane itself.

## The gotcha: EKS addons that run as DaemonSets wait on a node existing

`aws-mountpoint-s3-csi-driver` (like `metrics-server`) runs as a Kubernetes
DaemonSet. AWS won't report the addon `ACTIVE`/healthy until its pod is
actually **scheduled and running** — which means EKS Auto Mode first has to
provision a `system`/`general-purpose` node via Karpenter. If that node is
slow to launch (or can't launch), the addon just sits in `CREATING`
indefinitely from Terraform's point of view, ticking `Still creating...`
every 10 seconds with no other signal.

**This is a different quota than the GPU one `00-prereqs.sh` checks.** The
GPU quota (`g6e.2xlarge`, checked via `L-DB2E81BA`) only matters for the
`gpu` NodePool created in `02-gpu-infrastructure.sh` — it does not block
`01-deploy-infra.sh` at all. The quota that can actually block *this* step is
the general-purpose EC2 instance quota (`L-1216C47A`, "Running On-Demand
Standard (A, C, D, H, I, M, R, T, Z) instances") that Auto Mode's
`system`/`general-purpose` pools draw from. **`00-prereqs.sh` does not check
this quota** — that's a gap worth knowing about before you start the clock.

## Live diagnostic commands (run in a second terminal — don't touch the running `apply`)

```bash
aws eks update-kubeconfig --region us-east-2 --name genai-workshop
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide
aws eks describe-addon --cluster-name genai-workshop \
  --addon-name aws-mountpoint-s3-csi-driver --region us-east-2 \
  --query 'addon.{status:status,health:health}'

# If nodes are missing/NotReady, check the general-purpose quota directly:
aws service-quotas get-service-quota --region us-east-2 \
  --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value'
```

## What "normal" vs "concerning" looks like

- The `aws_eks_addon` Terraform resource has a default create timeout around
  20 minutes. If the underlying node issue doesn't resolve, `terraform
  apply` will fail on its own with a clear timeout/status error rather than
  hang forever.
- `terraform apply` is idempotent — if it does time out, just re-run
  `01-deploy-infra.sh` (or `terraform apply` directly in
  `.deploy/sample-genai-on-eks/terraform`) rather than tearing anything down.
- **Cost impact of this delay is low**: no GPU node exists yet at this stage
  (that's `02-gpu-infrastructure.sh`), so the only things billing during a
  stuck-addon wait are the EKS control plane (~$0.10/hr) and the NAT gateway
  — not the ~$2.20-2.30/hr GPU line item from `docs/COST.md`.

## Outcome

`terraform apply` timed out after 20 minutes exactly as flagged above:
`aws_eks_addon.s3_csi_driver` stuck `DEGRADED`, plus
`helm_release.kube_prometheus_stack`'s pre-install hook timing out. Four
rounds of diagnostics (`DIAGNOSTICS0.md` → `DIAGNOSTICS3.md`) traced it past
the addon, past Kubernetes NodeClaim status, and down to a full CloudTrail
`CreateFleet` event body, which showed the real cause: **every** instance
type Karpenter's `general-purpose` NodePool tried was rejected by EC2 with
`InvalidParameterCombination: "The specified instance type is not eligible
for Free Tier"` — an account-level restriction on this particular AWS
account, not a bug in this repo, Terraform, or the general-purpose vCPU
quota (which had plenty of headroom). It was not the GPU quota flagged by
`00-prereqs.sh` either — that only matters for `02-gpu-infrastructure.sh`,
several steps later. The `system` NodePool's two nodes launched fine because
they came up in the few seconds right at cluster creation, apparently before
this restriction started being enforced.

**Takeaway for `00-prereqs.sh`**: there is no reliable pre-flight API check
for this — it's an account-level EC2 launch restriction, not a queryable
service quota. The practical mitigation is checking the AWS Billing/Account
console for a Free Tier notice, or asking AWS Support, before spending time
debugging Kubernetes/Terraform symptoms that are actually downstream of it.
See `DIAGNOSTICS3.md`'s Outcome section for the full trail and
`docs/GOTCHAS.md`'s new "Reproducing this repo in a fresh AWS account"
section for the summarized version.
