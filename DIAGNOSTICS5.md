# Diagnostics round 6 — Free Tier restriction resurfaces for `g6e.2xlarge`

Follow-on from `DIAGNOSTICS4.md`. That round closed out the *general-purpose*
Free Tier restriction and the GPU quota approval (`8.0` confirmed). This round
covers `02-gpu-infrastructure.sh`'s first live attempt after both were clear.

## Symptom

```
./02-gpu-infrastructure.sh
```

ODCR created fine (`cr-EXAMPLE000000002`), NodeClass patched fine, test pod
applied fine — then:

```
error: timed out waiting for the condition on pods/nvidia-smi
```

(the script's actual `kubectl wait --timeout` is 300s, not the ~30s–1min the
log message suggests).

## Root cause — same restriction, different instance type

```bash
kubectl describe pod nvidia-smi
kubectl get nodeclaim -o wide
kubectl get events --sort-by='.lastTimestamp' | tail -40
```

showed the pod stuck `Pending` (`PodScheduled: False`), and a `gpu-*`
NodeClaim being created and torn down roughly every ~2.5 minutes
(`gpu-bdjrf` → `gpu-sxvbm` → `gpu-gfzsf` → `gpu-wpqlh` → `gpu-xddmx` →
`gpu-f9bnx` → `gpu-n47n6` → `gpu-dqxnc` → `gpu-hlm48` → `gpu-n58dl`) —
the exact same NodeClaim-churn signature as `DIAGNOSTICS1.md`-`DIAGNOSTICS3.md`.

This time the root cause was visible directly in `kubectl get events`,
no CloudTrail digging needed:

```
NodeRegistrationHealthy   nodepool/gpu   Status: Unknown -> False, Reason: FreeTierIneligible,
Message: The specified instance type is not eligible for Free Tier
```

**New understanding, refining `DIAGNOSTICS0.md`-`DIAGNOSTICS4.md`'s
conclusion**: the account's Free Tier launch restriction is not a single
account-wide switch that flips once and stays cleared — it appears to be
**scoped per instance type/family**. The earlier validation cleared the
`general-purpose` NodePool's `c5`/`m5`-class types (the ones it was actually
attempting at the time); `g6e.2xlarge`'s quota was `0` until this session, so
this was the **first time the account had ever attempted to launch that
type**, and it hit its own, separate instance of the same restriction.

## Cost note — acted on immediately, not just diagnosed

The ODCR (`cr-EXAMPLE000000002`) was `active` and billing the
`g6e.2xlarge` on-demand rate (~$2.20-2.30/hr) per `COST.md`'s billing model
regardless of whether an instance could actually launch into it — and none
could while this restriction held. Cancelled it immediately rather than
leaving it running through another wait-for-AWS-validation cycle:

```bash
aws ec2 cancel-capacity-reservation --region us-east-2 --capacity-reservation-id cr-EXAMPLE000000002
kubectl delete pod nvidia-smi
```

`02-gpu-infrastructure.sh` recreates the ODCR fresh on next run (its
existing-ODCR reuse check only fires if one is already `active`), so
cancelling here costs nothing but an extra `create-capacity-reservation`
call.

## Confirming before re-running

```bash
aws ec2 run-instances --region us-east-2 --dry-run --instance-type g6e.2xlarge \
  --image-id $(aws ssm get-parameter --region us-east-2 \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameter.Value' --output text) --count 1
```

```
An error occurred (DryRunOperation) when calling the RunInstances operation:
Request would have succeeded, but DryRun flag is set.
```

Clean — no Free Tier message this time. Unlike the `general-purpose` case in
`DIAGNOSTICS3.md`/`DIAGNOSTICS4.md`, there was no separate "your request has
been validated" email observed before this cleared; either it resolved
silently in the background, or the restriction only actually triggers on
requests that combine an ODCR + a not-yet-attempted instance type, and a
plain dry-run doesn't reproduce that combination closely enough to have ever
tripped it in the first place. Not fully certain which — noting the
uncertainty rather than guessing further.

## Re-run confirms: dry-run was a false negative

Re-ran `./02-gpu-infrastructure.sh`. Same churn signature immediately
(`gpu-ppms9` → `gpu-rlnbk`, ~2.5 min apart), and this time confirmed directly
against the NodePool's own status conditions rather than just events:

```bash
kubectl get nodepool gpu -o jsonpath='{.status.conditions}' | jq .
```

```json
{
  "lastTransitionTime": "2026-08-13T19:34:02Z",
  "message": "The specified instance type is not eligible for Free Tier",
  "reason": "FreeTierIneligible",
  "status": "False",
  "type": "NodeRegistrationHealthy"
}
```

Still blocked. This resolves the uncertainty noted above: the plain
`aws ec2 run-instances --dry-run` check that came back clean was a **false
negative** — it doesn't target a capacity reservation, so it doesn't
reproduce the exact request shape Karpenter sends (ODCR-backed `CreateFleet`).
A clean dry-run does not mean the real launch will succeed while this
restriction is active. `00-prereqs.sh`'s dry-run check has the same blind
spot for any ODCR-backed instance type — worth a follow-up note there.

Cancelled the second ODCR (`cr-EXAMPLE000000003`) and deleted the pod again,
same reasoning as above — no instance can launch while this holds, so no
reason to keep paying for idle reserved capacity:

```bash
aws ec2 cancel-capacity-reservation --region us-east-2 --capacity-reservation-id cr-EXAMPLE000000003
kubectl delete pod nvidia-smi
```

## Next step

Same fix as `DIAGNOSTICS0.md`-`DIAGNOSTICS4.md`: wait for AWS's own
validation to clear (an unprompted email last time, "under two hours").
Re-run `./02-gpu-infrastructure.sh` after that — it creates a fresh ODCR
each time it's needed, so there's no cleanup debt from cancelling early.
Don't trust a plain dry-run as a pre-check for this one; if a quick check is
wanted, re-run the real script and watch `kubectl get nodepool gpu -o
jsonpath='{.status.conditions}'` instead.
