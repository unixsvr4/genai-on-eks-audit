# Diagnostics round 2 — why does `general-purpose` never reach Ready?

Follow-on from `DIAGNOSTICS0.md`. That first round of diagnostics (results
below) narrowed the failure down to one specific pool — this round is aimed
at getting the actual error message behind it.

## What round 1 found

- `kubectl get nodes` showed **2 Ready nodes**, both from the `system` pool
  (`c7i-flex.large`, one per AZ), both up within ~13 seconds of the cluster
  existing.
- `kubectl get nodepools` showed:

  ```
  NAME              NODECLASS   NODES   READY   AGE
  general-purpose   default     0       True    38m
  gpu               gpu         0       True    30m
  system            default     2       True    38m
  ```

  `general-purpose` still had **zero nodes after 38 minutes**, despite the
  NodePool object itself reporting `READY: True` (that column reflects the
  NodePool/NodeClass config being valid, not that it has produced a node).
- `kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver`
  showed the DaemonSet pods (`s3-csi-node-*`) `Running` fine on the `system`
  nodes, but the Deployment pod `s3-csi-controller-*` stuck `Pending`,
  `Node: <none>`.
- `kubectl get events -A --sort-by='.lastTimestamp' | tail -40` showed a
  repeating cycle, roughly every ~85-90 seconds, of:
  1. `Normal Nominated` — a pending pod (`s3-csi-controller-*`,
     `model-download-*`, or later `kube-prometheus-stack-admission-create-*`)
     told to schedule on a freshly-created `nodeclaim/general-purpose-XXXXX`
  2. `Warning TerminationGracePeriodExpiring` — that same NodeClaim, ~90s
     later, entering termination
  3. A brand new `nodeclaim/general-purpose-YYYYY` created, pods re-nominated
     onto it, and the cycle repeats

  At least 14 distinct NodeClaim names were observed churning this way:
  `55nmx zn9g2 6t22m t26f5 tkjfh b6g99 fnm2k d4hzx v269t 58s9v ddk9x ndrht
  pqbnf skh75` — none of them ever went `Ready`. This is what starved
  `s3-csi-controller`, the `model-download` Job, and (later)
  `kube-prometheus-stack-admission-create` of a node, which is what actually
  caused the `terraform apply` failure in `DIAGNOSTICS0.md`.
- `system` is tainted `CriticalAddonsOnly:NoSchedule`, so none of those
  pending pods could fall back to the two healthy `system` nodes even though
  they existed and had spare capacity.
- The general-purpose EC2 quota check came back:

  ```bash
  aws service-quotas get-service-quota --region us-east-2 --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value'
  # → 16.0
  ```

  `system` already consumes 4 vCPUs (2× `c7i-flex.large`), leaving 12 vCPU
  of headroom — comfortably more than the ~4 vCPU a single general-purpose
  node needs. So this doesn't look like a flat quota wall by itself; more
  likely each individual launch attempt is failing for some other reason
  (capacity, subnet, AZ) and Karpenter is retrying with a fresh NodeClaim
  each time instead of the same one recovering.

## Round 2 — get the actual failure reason

None of round 1's output showed Karpenter's real error message — only the
generic `Nominated` / `TerminationGracePeriodExpiring` lifecycle events.
Run these:

```bash
# Catch a currently-pending general-purpose nodeclaim's real status/condition
kubectl get nodeclaims -l karpenter.sh/nodepool=general-purpose
kubectl describe nodeclaim -l karpenter.sh/nodepool=general-purpose

# Events specifically on NodeClaims, unfiltered by the two we've already seen
kubectl get events -A --field-selector involvedObject.kind=NodeClaim --sort-by='.lastTimestamp' | tail -30

# Broad search for the actual error keyword (capacity/quota/subnet/fleet)
kubectl get events -A --sort-by='.lastTimestamp' | grep -iE 'insufficient|capacity|quota|unauthorized|fail|error' | tail -30

# What's actually running/pending in EC2 right now, across the whole account
aws ec2 describe-instances --region us-east-2 --filters 'Name=instance-state-name,Values=running,pending' --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,SubnetId]' --output table
```

## Outcome

*(to be filled in once round 2 results come back)*
