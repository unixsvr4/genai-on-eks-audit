# Diagnostics round 4 — reading a full CreateFleet response body

Follow-on from `DIAGNOSTICS2.md`.

## What round 3 found

- `describe-instance-type-offerings` confirms `c5.xlarge`, `c7i-flex.xlarge`,
  and `m5.xlarge` are all offered in **both** `us-east-2a` and `us-east-2b`.
  Instance-type/AZ availability is ruled out as the cause.
- `describe-log-groups --log-group-name-prefix "/aws/eks/genai-workshop"`
  found exactly one log group: `/aws/eks/genai-workshop/cluster`. EKS Auto
  Mode's Karpenter-equivalent controller does not expose its own CloudWatch
  log group to the account — confirming there is no
  `kubectl logs`-equivalent path at the AWS layer either.
- The properly-filtered CloudTrail query
  (`select(.errorCode != null)`) on `CreateFleet` events returned **nothing**
  — no top-level trail errors on any recent `CreateFleet` call.
- The "broad net" query (`Events[?contains(CloudTrailEvent, "errorCode")]`)
  was a **dead end**, not a finding: it matched essentially every
  `RunInstances`/`CreateFleet` event in the account for the full lookback
  hour (thousands of rows), because the text-match on the raw JSON matches
  even when `errorCode` is present and simply `null`. Recorded here so the
  next person doesn't waste a round rediscovering this.
- The raw event volume itself is a data point: `CreateFleet` calls recur
  roughly every 20-90 seconds continuously from cluster bootstrap through at
  least `11:40:17-04:00` — over an **hour** of continuous churn, well past
  what earlier rounds had tracked. Each `CreateFleet` is accompanied by a
  dense burst of `RunInstances` calls in the same window, consistent with
  EC2 Fleet trying multiple candidate instance types from the NodePool's
  ~300-entry list within a single Fleet request.

## Why round 3's error search came up empty — and where to look instead

EC2 Fleet's `CreateFleet` API can return **HTTP 200 (a "successful" call from
CloudTrail's perspective, no top-level `errorCode`)** while its response body
still reports **per-instance-type launch failures** in a `responseElements`
field like `errors` or `instances[].errors`. That's almost certainly why the
filtered query found nothing — the failure isn't recorded as a trail-level
API error at all. The fix is to stop filtering and just read one full event
body.

## Round 4 — read a full CreateFleet response body directly

```bash
# Pull ONE full, unfiltered CreateFleet event and inspect its response body
aws cloudtrail lookup-events --region us-east-2 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateFleet \
  --max-results 1 \
  --query 'Events[0].CloudTrailEvent' --output text | jq .

# If that shows a responseElements.errors (or similar) array, that's the
# real root cause — paste the whole jq output back.

# Also check the one log group that does exist, in case node registration
# is being rejected at the EKS control-plane/authenticator layer instead
# of the EC2 layer
aws logs describe-log-streams --region us-east-2 \
  --log-group-name /aws/eks/genai-workshop/cluster \
  --order-by LastEventTime --descending --max-items 10 \
  --query 'logStreams[].logStreamName' --output table

aws logs tail /aws/eks/genai-workshop/cluster --region us-east-2 --since 1h \
  --filter-pattern "authenticator" 2>/dev/null | tail -50

# Never actually confirmed this in round 3 — what's running/pending right now?
aws ec2 describe-instances --region us-east-2 \
  --filters 'Name=instance-state-name,Values=running,pending' \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,LaunchTime]' \
  --output table
```

## Outcome — root cause found

The full, unfiltered `CreateFleet` event body settled it. Every single
instance-type override in the request — dozens of them, across `c5.xlarge`,
`c6a.xlarge`, `m5.xlarge`, `c7i-flex.xlarge`, and every other candidate in
the `general-purpose` NodePool's ~300-entry type list — failed identically:

```json
{
  "errorCode": "InvalidParameterCombination",
  "errorMessage": "The specified instance type is not eligible for Free Tier. For a list of Free Tier instance types, run 'describe-instance-types' with the filter 'free-tier-eligible=true'."
}
```

**This is an AWS account-level restriction, not a Karpenter, quota, subnet,
or capacity problem.** The account is blocked from launching *any*
non-Free-Tier-eligible instance type — a guardrail AWS applies to some
brand-new accounts. It explains everything observed across all four rounds:
`general-purpose` never produces a node (every launch attempt is rejected
at the EC2 API layer, before Kubernetes ever sees a real error);
`s3-csi-controller`, `model-download`, and
`kube-prometheus-stack-admission-create` all stay `Pending` forever because
they need that pool; and `terraform apply` eventually times out waiting for
things that were never going to succeed.

The `system` NodePool's two `c7i-flex.large` nodes — also not Free-Tier
eligible — launched successfully at `14:52:31Z`/`14:52:41Z`, right at
cluster creation. The restriction appears to have started being enforced on
the account sometime shortly after that, since every `general-purpose`
attempt from `14:52:31Z` onward (`CreateFleet` events keep recurring through
at least `15:43:59Z`, over 50 minutes of continuous churn) failed the same
way.

**What was ruled out along the way** (see rounds 1-3): GPU quota (irrelevant
to this step), general-purpose vCPU quota (16, plenty of headroom),
instance-type/AZ availability (all three candidate types offered in both
AZs), and any Kubernetes-side scheduling issue (the `FailedScheduling`
"untolerated taint" messages were the scheduler correctly explaining the
*symptom*, not the cause).

**Next step for this account**: check the AWS Billing/Account console for a
Free Tier usage notice, or open an AWS Support case referencing the
`InvalidParameterCombination` error above — this is very likely something
that clears with account verification/age rather than anything fixable in
this repo's Terraform or scripts. Once `general-purpose` nodes can launch,
re-run `01-deploy-infra.sh` — it's idempotent and will pick up cleanly.
