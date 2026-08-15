# Diagnostics — stuck `s3_csi_driver` addon / `kube-prometheus-stack` pre-install timeout

Run this if `01-deploy-infra.sh` fails the way it did on the first live run
(see `docs/FIRST_RUN.md`):

```
Error: waiting for EKS Add-On (genai-workshop:aws-mountpoint-s3-csi-driver) create: timeout while
waiting for state to become 'ACTIVE' (last state: 'DEGRADED', timeout: 20m0s)
...
Error: Helm release error
failed pre-install: 1 error occurred:
    * timed out waiting for the condition
```

Both failures point at the same root cause: nothing was available to
actually run the pods. `terraform apply` errors out without rolling back, so
the EKS control plane + NAT gateway are still up and billing — safe to
inspect the live cluster now.

## 0. Point `kubectl` at the cluster

If you're running these in a fresh terminal (not the one that ran
`01-deploy-infra.sh`), `kubectl` has no context yet — run this first or
every command below will fail with "the server doesn't have a resource type"
or a connection error, not the diagnostic you're after:

```bash
aws eks update-kubeconfig --region us-east-2 --name genai-workshop
```

## Diagnostic commands

```bash
# 1. Are there any nodes at all?
kubectl get nodes -o wide

# 2. Auto Mode uses Karpenter under the hood - check if it's even trying to provision nodes
kubectl get nodeclaims
kubectl get nodepools

# 3. If a nodeclaim exists but is stuck, this shows why
kubectl describe nodeclaim --all 2>/dev/null || kubectl get nodeclaims -o yaml

# 4. The stuck pods themselves
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver -o wide
kubectl describe pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver

# 5. Cluster-wide events, newest last - often shows the real blocker (quota, capacity, subnet)
kubectl get events -A --sort-by='.lastTimestamp' | tail -40

# 6. The quota that actually matters for this step (NOT the GPU one 00-prereqs.sh checks)
aws service-quotas get-service-quota --region us-east-2 --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value'
```

## After you have the output

- If nodes/nodeclaims never appeared at all → check the quota output from
  step 6 and cluster events from step 5 for the actual blocker.
- Re-running `terraform apply` (or `01-deploy-infra.sh`) is safe — it's
  idempotent. Terraform will warn that it's purging and recreating the
  `s3_csi_driver` addon config; that's expected and harmless, it's stateless.
- Once root-caused, fold the finding into `docs/FIRST_RUN.md`'s "Outcome"
  section and, if it's a quota gap, add the check to `scripts/00-prereqs.sh`
  so the next run catches it before the clock starts.
