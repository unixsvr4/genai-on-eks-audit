# Diagnostics round 3 — chasing the real error into CloudTrail

Follow-on from `DIAGNOSTICS1.md`.

## What round 2 found

- `kubectl describe nodeclaim -l karpenter.sh/nodepool=general-purpose`
  only ever catches a NodeClaim in its **first ~49 seconds of existence**:
  `Initialized=Unknown (AwaitingReconciliation)`, `Launched=Unknown
  (FreeTierIneligible message — informational, not an error)`,
  `Registered=Unknown (NodeNotFound)`, `Ready=Unknown`, and `Events: <none>`
  on the NodeClaim object itself. By the time a NodeClaim would show a
  terminal failure, it's already been torn down and a new one has taken its
  name's place in the churn — this command keeps catching the *next* one at
  its very start, never the failure.
- `kubectl get events -A --field-selector involvedObject.kind=NodeClaim`
  confirms the churn continued: **25 distinct `general-purpose-*` NodeClaims**
  observed over ~40 minutes, cycling on the same ~90s
  create → `TerminationGracePeriodExpiring` → replace pattern from
  `DIAGNOSTICS1.md`. Still zero reaching `Ready`.
- The `FailedScheduling` events (`model-download`, `s3-csi-controller`,
  `kube-prometheus-stack-admission-create`, even `metrics-server` early on)
  all say the same thing: `0/2 nodes are available: 2 node(s) had
  untolerated taint(s)`. **This is not the root cause** — it's the scheduler
  correctly explaining that the two `system` nodes are tainted
  `CriticalAddonsOnly:NoSchedule` and can't take these pods, which is exactly
  why a `general-purpose` node needs to launch. It says nothing about why
  the launch itself keeps failing.
- Net result: two full rounds of `kubectl`-level diagnostics have narrowed
  the problem to "general-purpose NodeClaims never complete" but **cannot
  see the actual launch failure**, because in EKS Auto Mode the
  Karpenter-equivalent controller is AWS-managed — there's no
  `kubectl logs -n kube-system deployment/karpenter` to check like a
  self-managed Karpenter install would have.

## Round 3 — go to the AWS API layer

The NodeClaim conditions and Kubernetes events are downstream of whatever
EC2 API call is actually failing. Auto Mode provisions nodes via `CreateFleet`
under the hood, so CloudTrail should hold the real error:

```bash
# Real EC2 API errors behind these launch attempts
aws cloudtrail lookup-events --region us-east-2 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateFleet \
  --max-results 10 \
  --query 'Events[].CloudTrailEvent' --output text \
  | jq -r 'select(.errorCode != null) | "\(.eventTime)  \(.errorCode): \(.errorMessage)"'

# Broader net: any EC2 write-API call that errored in the last hour
aws cloudtrail lookup-events --region us-east-2 \
  --start-time "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'Events[?contains(CloudTrailEvent, `"errorCode"`)].{Event:EventName,Time:EventTime}' \
  --output table

# Confirm whether requested instance types are even offered in these specific AZs
aws ec2 describe-instance-type-offerings --region us-east-2 \
  --location-type availability-zone \
  --filters Name=location,Values=us-east-2a,us-east-2b Name=instance-type,Values=c5.xlarge,c7i-flex.xlarge,m5.xlarge \
  --query 'InstanceTypeOfferings[].[InstanceType,Location]' --output table

# Check whether Auto Mode surfaces controller logs to CloudWatch at all
aws logs describe-log-groups --region us-east-2 \
  --log-group-name-prefix "/aws/eks/genai-workshop" \
  --query 'logGroups[].logGroupName' --output table
```

If `CreateFleet` shows a clean `errorCode`/`errorMessage`
(`VcpuLimitExceeded`, `InsufficientInstanceCapacity`,
`UnauthorizedOperation`, etc.) that's the real root cause and this
investigation is done. If CloudTrail shows nothing failing at all, that's
its own useful (if stranger) finding — it would mean the NodeClaims are
being deleted for a Kubernetes-side reason rather than an EC2-side one, and
the next place to look is the EKS control plane's own log group
(`enabled_cluster_log_types` includes `api`, `audit`, `authenticator` per
`terraform/README.md` — worth checking `authenticator` and `api` for
anything rejecting the node registration).

## Outcome

*(to be filled in once round 3 results come back)*
