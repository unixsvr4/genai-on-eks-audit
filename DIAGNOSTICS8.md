# Diagnostics round 9 — root cause found: the account is on the FREE *plan*, and that never expires (2026-09-03)

This round overturns the interpretation in `DIAGNOSTICS0.md`–`DIAGNOSTICS7.md`.
Those rounds correctly identified the *error*; they were wrong about what
causes it and wrong that waiting fixes it. Cost of learning that: one 4-hour
On-Demand Capacity Reservation billed for capacity that could never be used.

## Symptom

`02-gpu-infrastructure.sh` created the ODCR fine, patched the NodeClass fine,
then sat in `kubectl wait` well past the "expect ~30s-1min" estimate:

```
[14:59:01] Created ODCR: cr-<redacted> (self-expires in 4h)
[14:59:02] Deploying nvidia-smi test pod ...
[14:59:03] Waiting for GPU node to provision + pod to succeed ...
```

```bash
kubectl get nodeclaim -o wide
```

```
general-purpose-tpkbg   c7i-flex.large   on-demand   us-east-2a   True      153m
gpu-llqxx                                                         Unknown   8s
system-bgqws            c7i-flex.large   on-demand   us-east-2b   True      3h40m
```

The `gpu` NodeClaim is seconds old because Karpenter had already churned
through `gpu-k6wk4` and `gpu-h8hsz` and thrown both away.

```bash
kubectl get nodeclaim -l karpenter.sh/nodepool=gpu -o json | jq '.items[].status.conditions'
```

```
Launched  Unknown  FreeTierIneligible  The specified instance type is not eligible for Free Tier
```

## The raw CreateFleet body

`CreateFleet` returns **HTTP 200**. The rejection is buried in the response:

```bash
aws cloudtrail lookup-events --region us-east-2 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateFleet --max-results 3
```

```json
"CreateFleetResponse": {
  "fleetInstanceSet": "",
  "errorSet": { "item": {
    "launchTemplateAndOverrides": { "overrides": {
      "instanceType": "g6e.2xlarge",
      "subnetId": "subnet-0c897b682cc7466c0",
      "availabilityZone": "us-east-2a"
    }},
    "errorCode": "InvalidParameterCombination",
    "errorMessage": "The specified instance type is not eligible for Free Tier. For a list of Free Tier instance types, run 'describe-instance-types' with the filter 'free-tier-eligible=true'."
  }}
}
```

Subnet and AZ are correct, the ODCR is active and matches. AWS is refusing the
**instance type**.

## Every dry-run signal is a false negative — measured, not assumed

`00-prereqs.sh` gated on `run-instances --dry-run` and reported the account
clear ~15 minutes before this failure. It was not a fluke. Three independent
dry-run paths were tested against a `g6e.2xlarge` that provably cannot launch,
and **all three reported success**:

| Signal | Result | Reality |
|---|---|---|
| `aws ec2 run-instances --dry-run --instance-type g6e.2xlarge` | `DryRunOperation` — "would have succeeded" | wrong |
| `aws ec2 create-fleet --dry-run` (same type, same subnet) | `DryRunOperation` | wrong |
| Karpenter's own internal CreateFleet dry-run (CloudTrail 19:00:03) | `Client.DryRunOperation` | wrong |

`RunInstances` does not evaluate Free Tier eligibility at all. `CreateFleet
--dry-run` validates almost nothing — it returned `DryRunOperation` even when
handed a **launch-template ID that no longer existed**. Only a real
`CreateFleet` surfaces the error, and a real `CreateFleet` launches an
instance, so it is useless as a pre-flight check.

**This kills the obvious fix.** The plan for this round was "use a CreateFleet
dry-run and parse `errorSet` instead of trusting the HTTP status." There is no
`errorSet` to parse: a dry-run never gets far enough to produce one.

## Root cause

The error message names its own diagnostic. Following it:

```bash
aws freetier get-account-plan-state
```

```json
{
  "accountId": "<redacted>",
  "accountPlanType": "FREE",
  "accountPlanStatus": "ACTIVE",
  "accountPlanRemainingCredits": { "amount": 108.52, "unit": "USD" },
  "accountPlanExpirationDate": "2026-11-29T22:25:29Z"
}
```

```bash
aws ec2 describe-instance-types --region us-east-2 \
  --filters "Name=free-tier-eligible,Values=true" \
  --query 'InstanceTypes[].InstanceType' --output text
```

```
c7i-flex.large  m7i-flex.large  t3.micro  t3.small  t4g.micro  t4g.small
```

**Six types. That is the entire launchable surface of this account.** Under
the 2025 AWS Free Tier redesign, an account on `accountPlanType: FREE` may only
launch Free-Tier-eligible instance types. This is a property of the account
*plan*, not a new-account validation hold:

- It does **not** expire or clear on its own.
- It is **independent of service quotas** — this account holds a granted
  16-vCPU `L-DB2E81BA` GPU quota (`DIAGNOSTICS7.md`) and still cannot launch a
  single `g6e`. Eligibility gates the launch *before* quota is consulted.
- `g6e.2xlarge` will never appear in that set.

## What this means for DIAGNOSTICS0–7

Look at the working nodes again: both are **`c7i-flex.large`** — which is in
the eligible set, at position one.

That reframes the entire earlier narrative. Rounds 1–7 concluded the
restriction was "a temporary hold that fades out", because `general-purpose`
eventually produced a node after churning. It did not fade. Karpenter's
`system` and `general-purpose` NodePools accept a broad instance-type range,
so they churn until they happen to select the one eligible type, then succeed
permanently. `DIAGNOSTICS6.md`'s "probabilistic / restriction fading out"
reading was a plausible fit to the evidence available then, and it was wrong.

The `gpu` NodePool has no such escape:

```yaml
- key: node.kubernetes.io/instance-type
  operator: In
  values: ["g6e.2xlarge"]     # exactly one type — no fallback
```

Pinned to a single ineligible type, it can only churn forever. That is why
`01` is survivable on a FREE plan and `02` is not, and why the failure looked
intermittent for seven rounds.

The "AWS emails you when it clears" note in earlier rounds should be read as
coincidence with the separate quota case, not causation.

## Fix

Upgrade the account plan. There is nothing else to do and nothing to wait for.

```bash
aws freetier upgrade-account-plan --account-plan-type PAID
```

Or: AWS Billing console → Free Tier → *Upgrade to a paid plan*. Note the
account still holds `$108.52` of unexpired credits — upgrading does not
forfeit them, but confirm that in the console before committing.

## Fix applied to the repo

`00-prereqs.sh`'s Free Tier gate has been rewritten from **empirical to
authoritative**. Instead of probing with a dry-run that cannot see the
restriction, it asks the two questions that have real answers:

1. `aws freetier get-account-plan-state` → is the plan `FREE`?
2. `aws ec2 describe-instance-types --filters free-tier-eligible=true` → is
   `$INSTANCE_TYPE` in the permitted set?

If the plan is `FREE` and the GPU type is not in the set, the script now says
plainly that `02-gpu-infrastructure.sh` **cannot** succeed, that waiting will
not help, gives the upgrade command, and warns that running `02` anyway bills
a `$ODCR_HOURS`-hour reservation for capacity no node can occupy. It repeats
that as a summary block at the end so it cannot scroll past unnoticed.

Costs nothing, needs no cluster, no launch template, and works before anything
is deployed. Verified against this account both ways:

```
g6e.2xlarge      → "is NOT in that set ... CANNOT launch"   PLAN_BLOCKS_GPU=1
c7i-flex.large   → "IS Free-Tier-eligible"                  PLAN_BLOCKS_GPU=0
```

It also warns if *no* flex-class type is eligible in the chosen region, since
that would mean even `01-deploy-infra.sh` has no launchable type.

The gate degrades honestly rather than silently: an old CLI without the
`freetier` service, or a missing `freetier:GetAccountPlanState` permission,
prints "could not read the account plan — skipping" and names the symptom to
watch for, instead of reporting a clean account.

## Cost of this round

The ODCR was created at 14:59:01 and billed `$2.24208/hr` for `g6e.2xlarge`
from that moment, for capacity that no node could ever occupy. Cancelled on
diagnosis:

```bash
aws ec2 cancel-capacity-reservation --region us-east-2 --capacity-reservation-id cr-<redacted>
```

**The lesson worth keeping**: `02-gpu-infrastructure.sh` commits money *before*
it discovers whether a GPU node can launch — the ODCR was created at line 30,
the first evidence of failure arrived at line 81. Closing that window is worth
more than any amount of documentation, so the check now exists in two places:

- `00-prereqs.sh` — advisory, tells you before you start.
- `02-gpu-infrastructure.sh` — a **hard gate** that `die`s before the
  `create-capacity-reservation` call. `00-prereqs.sh` can be skipped or
  scrolled past; this one cannot. Escape hatch for anyone who wants to prove
  it to themselves: `ALLOW_FREE_TIER_BLOCKED=1 ./02-gpu-infrastructure.sh`
  (you will be billed for the reservation regardless).

Both call one `free_tier_check()` in `scripts/lib/env.sh`, so the advisory and
the gate cannot drift apart. It returns 0 launchable / 1 blocked /
2 indeterminate, and treats an empty `describe-instance-types` result as
indeterminate rather than as a block — an API hiccup should not hard-fail a
deploy. Both paths verified against the live FREE-plan account:

```
g6e.2xlarge     -> plan=FREE rc=1  BLOCK   -> FATAL, nothing created, nothing billed
c7i-flex.large  -> plan=FREE rc=0  ALLOW
```

## Teardown footnote — `terraform destroy` timing out on the monitoring namespace

The teardown that followed this round failed with:

```
kubernetes_namespace_v1.monitoring: Still destroying... [id=monitoring, 04m50s elapsed]
│ Error: context deadline exceeded
```

**This is a false alarm, and the destroy is resumable.** The namespace had
already been deleted successfully — `kubectl get ns monitoring` returned
`NotFound` immediately afterwards. The Kubernetes provider simply hit its own
5-minute wait timeout before the API reported completion.

It is slow for a structural reason worth noting: Terraform tore down
`module.vpc.aws_nat_gateway`, the public subnets and the internet gateway
*concurrently* with the namespace deletion, because `kubernetes_namespace_v1`
carries no dependency edge to the VPC. Removing the cluster's egress path
while it is finalizing namespaced resources is not a combination that finishes
quickly.

Recovery is just to re-run it — `terraform destroy` picks up where it stopped,
and on the next pass the namespace is already gone:

```bash
./99-destroy-all.sh
```

State after the failed run, for reference: NAT gateway, EIP, public subnets,
internet gateway, S3 bucket, AMP workspace and all IAM roles destroyed; no EC2
instances, no ALBs, no EIPs remaining; the EKS cluster still `ACTIVE` (control
plane still billing) with 54 resources left in state. The expensive line items
were already gone — only the control plane was still costing anything.
